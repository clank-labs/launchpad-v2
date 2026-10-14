// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ClankFeeEscrow} from "./ClankFeeEscrow.sol";
import {ClankGraduationGuard} from "./ClankGraduationGuard.sol";
import {ClankCurveMath} from "./libraries/ClankCurveMath.sol";

interface IClankLaunchFactoryGraduation {
    function graduate(address token) external;
}

/// @title Clank bonding curve
/// @notice Trades a fixed-supply launch token against tracked native ETH or an approved ERC-20 using virtual-reserve
/// XYK pricing until 780M tokens have been sold, leaving 220M for migration.
/// @dev Pricing depends on trackedQuote, never on address(this).balance. Consequently forced
/// ETH cannot change price or trigger graduation. Direct native transfers revert, trading fees
/// are credited outside the pricing reserve, and terminal overpayment is returned immediately.
contract ClankBondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 private constant BPS = 10_000;

    /// @notice Lifecycle of one bonding curve and its graduation.
    enum State {
        /// @notice Buy and sell operations are enabled.
        Trading,
        /// @notice The sale allocation is exhausted and trading is permanently closed.
        Ready,
        /// @notice The factory collected the tracked reserves for migration.
        Swept,
        /// @notice The factory confirmed creation of the locked V4 position.
        PoolCreated,
        /// @notice The factory released unseedable swept reserves through the delayed recovery path.
        Rescued
    }

    /// @notice Immutable deployment parameters supplied by the launch factory.
    struct Config {
        address factory;
        address feeEscrow;
        address protocolFeeRecipient;
        address creator;
        address pairToken;
        uint16 feeBps;
        uint16 snipeTaxStartBps;
        uint32 snipeTaxSeconds;
        uint128 phantomQuote;
        uint128 graduationThreshold;
        address graduationGuard;
        int24 tickSpacing;
    }

    struct BuyQuote {
        uint256 grossQuoteUsed;
        uint256 netQuoteIn;
        uint256 fee;
        uint256 tax;
        uint256 tokensOut;
        uint256 refund;
    }

    error AlreadyInitialized();
    error CurveGraduated();
    error ZeroAmount();
    error ZeroAddress();
    error NativeValueMismatch(uint256 supplied, uint256 expected);
    error UnexpectedNativeValue();
    error DirectNativeTransferDisabled();
    error FeeEscrowCallFailed();
    error InsufficientRealReserve();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidConfiguration();
    error InvalidState(State expected, State actual);
    error TransferFailed();
    error QuoteTransferFailed();
    error NotFactory();
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error NotInitialized();
    error ZeroOutput();

    /// @notice Factory authorised to initialize and advance this curve's lifecycle.
    address public immutable factory;
    /// @notice Pull-payment escrow receiving protocol fees.
    ClankFeeEscrow public immutable feeEscrow;
    /// @notice Stable escrow beneficiary credited with bonding fees; this is the factory, not the final fee destination.
    /// @dev Permissionless collection forwards these credits to the factory's current feeDestination, so even previously
    /// accrued fees follow a destination update until they have been collected.
    address public immutable protocolFeeRecipient;
    /// @notice Launch creator, exempt from the globally configured snipe tax.
    address public immutable creator;
    /// @notice Quote asset; address(0) represents native ETH.
    address public immutable pairToken;
    /// @notice Bonding fee snapshotted for this launch, denominated in basis points.
    uint256 public immutable feeBps;
    /// @notice Peak total buy fee globally configured when this launch was created.
    uint16 public immutable snipeTaxStartBps;
    /// @notice Duration of the globally configured anti-snipe decay.
    uint32 public immutable snipeTaxSeconds;
    /// @notice Curve deployment timestamp used for anti-snipe fee decay.
    uint64 public immutable launchedAt;
    /// @notice Virtual quote reserve used for pricing but never held as a real asset.
    uint256 public immutable phantomQuote;
    /// @notice Nominal net quote target; actual funding includes XYK trade rounding.
    uint256 public immutable graduationThreshold;

    ClankGraduationGuard private immutable _graduationGuard;
    int24 private immutable _tickSpacing;

    /// @notice Fixed-supply token traded by this curve, initialized once by the factory.
    IERC20 public token;
    /// @notice Current lifecycle state.
    State public state;
    /// @notice Timestamp of the terminal buy; preserved across graduation retries.
    uint64 public readyAt;
    /// @notice Real quote assets included in pricing and reserved for traders or graduation.
    uint256 public trackedQuote;
    /// @notice Real tokens reserved for traders or graduation; excludes virtual tokens.
    uint256 public trackedTokens;
    /// @notice Recipients exempt from the launch-window snipe tax.
    mapping(address account => bool exempt) public snipeTaxExempt;
    event SnipeTaxExempted(address indexed account);
    event TokenInitialized(address indexed token, uint256 supply);
    event Initialized(address token);
    event StateChanged(State indexed previousState, State indexed newState);
    /// @notice Pons-compatible compact buy event.
    event CurveBuy(
        address indexed buyer, address indexed recipient, uint256 quoteIn, uint256 tokensOut, uint256 fee, uint256 tax
    );
    /// @notice Pons-compatible signal for an immediately returned terminal-buy remainder.
    event CurveBuyRefunded(address indexed buyer, uint256 refund);
    /// @notice Pons-compatible compact sell event; creator tax is always zero.
    event CurveSell(
        address indexed seller, address indexed recipient, uint256 tokensIn, uint256 quoteOut, uint256 fee, uint256 tax
    );
    event CurveCompleted(address recipient, uint256 quoteOut, uint256 tokenOut);
    event AutoGraduationFailed(address indexed token, uint256 gasRemaining);

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier inState(State expected) {
        if (state != expected) {
            if (expected == State.Trading) revert CurveGraduated();
            revert InvalidState(expected, state);
        }
        _;
    }

    /// @param config Immutable factory, fee, virtual reserve, and graduation configuration.
    constructor(Config memory config) {
        if (
            config.factory == address(0) || config.feeEscrow == address(0) || config.protocolFeeRecipient == address(0)
                || config.creator == address(0) || config.graduationGuard.code.length == 0
        ) {
            revert InvalidAddress();
        }
        if (
            config.feeBps >= BPS || config.snipeTaxStartBps >= BPS || config.snipeTaxSeconds == 0
                || config.phantomQuote == 0 || config.tickSpacing < TickMath.MIN_TICK_SPACING
                || config.tickSpacing > TickMath.MAX_TICK_SPACING
                || config.graduationThreshold != ClankCurveMath.graduationThreshold(config.phantomQuote)
        ) {
            revert InvalidConfiguration();
        }

        factory = config.factory;
        feeEscrow = ClankFeeEscrow(config.feeEscrow);
        protocolFeeRecipient = config.protocolFeeRecipient;
        creator = config.creator;
        if (config.pairToken != address(0) && config.pairToken.code.length == 0) revert InvalidAddress();
        pairToken = config.pairToken;
        feeBps = config.feeBps;
        snipeTaxStartBps = config.snipeTaxStartBps;
        snipeTaxSeconds = config.snipeTaxSeconds;
        launchedAt = uint64(block.timestamp);
        phantomQuote = config.phantomQuote;
        graduationThreshold = config.graduationThreshold;
        _graduationGuard = ClankGraduationGuard(config.graduationGuard);
        _tickSpacing = config.tickSpacing;
    }

    /// @notice Rejects accidental native transfers that do not call a trading entrypoint.
    /// @dev Forced ETH remains possible at the EVM level and is excluded from tracked accounting.
    receive() external payable {
        revert DirectNativeTransferDisabled();
    }

    /// @notice Binds the fixed-supply token to the curve and snapshots its full reserve.
    /// @dev Callable exactly once by the factory after the token has minted its supply here.
    /// @param token_ Address of the launched ERC-20 token.
    function initialize(address token_) external onlyFactory {
        if (address(token) != address(0)) revert AlreadyInitialized();
        if (token_ == address(0)) revert ZeroAddress();

        uint256 supply = IERC20(token_).balanceOf(address(this));
        if (supply != ClankCurveMath.TOKEN_SUPPLY) revert InvalidAmount();

        token = IERC20(token_);
        trackedTokens = supply;
        emit TokenInitialized(token_, supply);
        emit Initialized(token_);
    }

    function isNativeQuote() external view returns (bool) {
        return pairToken == address(0);
    }

    /// @notice Returns effective pricing reserves, including both virtual reserves.
    function getReserves() external view returns (uint256 quoteReserve_, uint256 tokenReserve_) {
        return (_effectiveQuoteReserve(), tokenReserve());
    }

    function quoteReserve() external view returns (uint256 quoteReserve_) {
        return _effectiveQuoteReserve();
    }

    function realQuoteReserve() external view returns (uint256) {
        return trackedQuote;
    }

    /// @notice Real tokens held in tracked accounting, excluding donations and virtual tokens.
    function realTokenReserve() external view returns (uint256) {
        return trackedTokens;
    }

    /// @notice Additive pricing reserve; these tokens are never minted or transferred.
    function virtualTokenReserve() external pure returns (uint256) {
        return ClankCurveMath.VIRTUAL_TOKENS;
    }

    /// @notice Effective token reserve for Pons XYK pricing.
    function tokenReserve() public view returns (uint256 tokenReserve_) {
        return trackedTokens + ClankCurveMath.VIRTUAL_TOKENS;
    }

    function readyToGraduate() external view returns (bool) {
        return state == State.Ready;
    }

    function graduated() external view returns (bool) {
        return state == State.Swept || state == State.PoolCreated || state == State.Rescued;
    }

    /// @notice Exempts a recipient from snipe tax; only the factory may grant exemptions.
    function exemptFromSnipeTax(address account) external onlyFactory {
        if (account == address(0)) revert InvalidAddress();
        snipeTaxExempt[account] = true;
        emit SnipeTaxExempted(account);
    }

    /// @notice Returns the additional protocol tax currently applied to a token recipient.
    /// @dev A zero snapshotted start rate disables the tax for this launch.
    function currentSnipeTaxBps(address recipient) public view returns (uint256) {
        // Read the exemption mapping second to avoid a storage read when the tax is disabled.
        if (snipeTaxStartBps <= feeBps || snipeTaxExempt[recipient]) return 0;

        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed >= snipeTaxSeconds) return 0;

        uint256 initialTaxBps = uint256(snipeTaxStartBps) - feeBps;
        return Math.mulDiv(initialTaxBps, snipeTaxSeconds - elapsed, snipeTaxSeconds);
    }

    /// @dev Returns the virtual plus tracked real quote reserve used in XYK pricing.
    function _effectiveQuoteReserve() private view returns (uint256) {
        return uint256(phantomQuote) + trackedQuote;
    }

    /// @notice Quotes a gross quote-asset buy, including terminal partial-fill behaviour.
    /// @param grossQuoteIn Total quote amount offered, including the bonding fee.
    /// @return grossQuoteUsed Portion of the offer consumed by the trade, including fee.
    /// @return netQuoteIn Portion added to the tracked pricing reserve.
    /// @return fee Amount credited to the protocol beneficiary.
    /// @return tokensOut Token output rounded down.
    /// @return refund Unused gross amount returned to the buyer.
    function quoteBuy(uint256 grossQuoteIn)
        external
        view
        returns (uint256 grossQuoteUsed, uint256 netQuoteIn, uint256 fee, uint256 tokensOut, uint256 refund)
    {
        BuyQuote memory quote = _quoteBuy(grossQuoteIn, msg.sender);
        return (quote.grossQuoteUsed, quote.netQuoteIn, quote.fee + quote.tax, quote.tokensOut, quote.refund);
    }

    /// @notice Quotes a buy for an explicit token recipient under the globally configured fee policy.
    function quoteBuyFor(address recipient, uint256 grossQuoteIn)
        external
        view
        returns (uint256 grossQuoteUsed, uint256 netQuoteIn, uint256 fee, uint256 tokensOut, uint256 refund)
    {
        if (recipient == address(0)) revert ZeroAddress();
        BuyQuote memory quote = _quoteBuy(grossQuoteIn, recipient);
        return (quote.grossQuoteUsed, quote.netQuoteIn, quote.fee + quote.tax, quote.tokensOut, quote.refund);
    }

    /// @notice Quotes a token sale against the current tracked reserves.
    /// @dev Reverts under the same reserve and lifecycle conditions as an executable sale.
    /// @param tokensIn Token amount offered for sale.
    /// @return grossQuoteOut Quote amount removed from the tracked reserve before fee.
    /// @return netQuoteOut Quote amount paid to the recipient after fee.
    /// @return fee Amount credited to the protocol beneficiary.
    function quoteSell(uint256 tokensIn)
        external
        view
        returns (uint256 grossQuoteOut, uint256 netQuoteOut, uint256 fee)
    {
        return _quoteSell(tokensIn);
    }

    /// @notice Pons-compatible buy without an execution deadline.
    /// @dev Native buys require msg.value == quoteIn; ERC-20 buys require zero msg.value and pull
    /// quoteIn from msg.sender. A terminal remainder is returned immediately in the quote asset.
    /// Failure to return it reverts the buy. A terminal buy then attempts a permissionless reserve
    /// sweep without making the sweep a condition of trade success.
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        inState(State.Trading)
        returns (uint256 tokensOut)
    {
        if (pairToken == address(0)) {
            if (msg.value != quoteIn) revert NativeValueMismatch(msg.value, quoteIn);
        } else if (msg.value != 0) {
            revert UnexpectedNativeValue();
        }
        (tokensOut,) = _buy(quoteIn, minTokensOut, recipient);
        if (state == State.Ready) _tryAutoGraduate();
    }

    function _buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        private
        returns (uint256 tokensOut, uint256 grossQuoteUsed)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (address(token) == address(0)) revert NotInitialized();
        if (quoteIn == 0) revert ZeroAmount();

        _receiveQuote(quoteIn);

        BuyQuote memory quote = _quoteBuy(quoteIn, recipient);
        grossQuoteUsed = quote.grossQuoteUsed;
        tokensOut = quote.tokensOut;
        if (quote.netQuoteIn == 0) revert ZeroAmount();

        uint256 proportionalMinimum = Math.mulDiv(minTokensOut, grossQuoteUsed, quoteIn, Math.Rounding.Ceil);
        if (tokensOut < proportionalMinimum) revert SlippageExceeded(tokensOut, minTokensOut);

        trackedQuote += quote.netQuoteIn;
        trackedTokens -= tokensOut;

        if (trackedTokens == ClankCurveMath.MIGRATION_TOKENS) _transition(State.Ready);

        _creditFee(quote.fee + quote.tax);
        token.safeTransfer(recipient, tokensOut);
        if (quote.refund != 0) {
            _sendQuote(msg.sender, quote.refund);
            emit CurveBuyRefunded(msg.sender, quote.refund);
        }

        emit CurveBuy(msg.sender, recipient, grossQuoteUsed, tokensOut, quote.fee, quote.tax);
    }

    /// @notice Pons-compatible sell without an execution deadline.
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient)
        external
        nonReentrant
        inState(State.Trading)
        returns (uint256 quoteOut)
    {
        return _sell(tokensIn, minQuoteOut, payable(recipient));
    }

    function _sell(uint256 tokensIn, uint256 minEthOut, address payable recipient)
        private
        returns (uint256 netQuoteOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (address(token) == address(0)) revert NotInitialized();
        if (tokensIn == 0) revert ZeroAmount();

        uint256 grossQuoteOut;
        uint256 fee;
        (grossQuoteOut, netQuoteOut, fee) = _quoteSell(tokensIn);
        if (netQuoteOut < minEthOut) revert SlippageExceeded(netQuoteOut, minEthOut);

        trackedQuote -= grossQuoteOut;
        trackedTokens += tokensIn;

        token.safeTransferFrom(msg.sender, address(this), tokensIn);
        _creditFee(fee);

        _sendQuote(recipient, netQuoteOut);

        emit CurveSell(msg.sender, recipient, tokensIn, netQuoteOut, fee, 0);
    }

    /// @notice Transfers a Ready curve's exact tracked reserves into factory custody.
    /// @dev Forced ETH remains excluded from graduation assets. This entrypoint deliberately does
    /// not use nonReentrant because the factory may call it back from a terminal buy's guarded scope.
    /// Safety comes from onlyFactory plus the Ready-to-Swept checks-effects-interactions transition.
    function graduate(address recipient)
        external
        onlyFactory
        inState(State.Ready)
        returns (uint256 quoteOut, uint256 tokenOut)
    {
        if (recipient == address(0)) revert ZeroAddress();

        quoteOut = trackedQuote;
        tokenOut = trackedTokens;
        trackedQuote = 0;
        trackedTokens = 0;
        _transition(State.Swept);

        token.safeTransfer(recipient, tokenOut);
        _sendQuote(recipient, quoteOut);

        emit CurveCompleted(recipient, quoteOut, tokenOut);
    }

    /// @dev Mirrors Pons best-effort auto-graduation: a failed sweep never reverts the crossing buy,
    /// and the public factory entrypoint remains available for a permissionless retry.
    function _tryAutoGraduate() private {
        try IClankLaunchFactoryGraduation(factory).graduate(address(token)) {}
        catch {
            emit AutoGraduationFailed(address(token), gasleft());
        }
    }

    /// @notice Confirms that the factory completed V4 pool creation and position locking.
    function markPoolCreated() external onlyFactory inState(State.Swept) {
        _transition(State.PoolCreated);
    }

    /// @notice Confirms that the factory completed the delayed recovery of swept reserves.
    function markRescued() external onlyFactory inState(State.Swept) {
        _transition(State.Rescued);
    }

    /// @dev Caps token output at the remaining sale allocation and charges its rounded-up XYK cost.
    function _quoteBuy(uint256 grossQuoteIn, address recipient) private view returns (BuyQuote memory quote) {
        if (state != State.Trading) revert CurveGraduated();
        if (address(token) == address(0)) revert NotInitialized();
        if (grossQuoteIn == 0) revert ZeroAmount();

        uint256 taxBps = currentSnipeTaxBps(recipient);
        uint256 totalFeeBps = uint256(feeBps) + taxBps;
        uint256 offeredNet = ClankCurveMath.netFromGross(grossQuoteIn, totalFeeBps);
        if (offeredNet == 0) revert ZeroAmount();
        uint256 sellable = trackedTokens - ClankCurveMath.MIGRATION_TOKENS;
        quote.tokensOut = ClankCurveMath.buyOutput(_effectiveQuoteReserve(), tokenReserve(), offeredNet);
        bool terminalFill = quote.tokensOut >= sellable;
        if (terminalFill) quote.tokensOut = sellable;
        if (quote.tokensOut == 0) revert ZeroOutput();
        quote.netQuoteIn = terminalFill
            ? ClankCurveMath.requiredBuyInput(_effectiveQuoteReserve(), tokenReserve(), quote.tokensOut)
            : offeredNet;
        _validateGraduation(trackedQuote + quote.netQuoteIn, trackedTokens - quote.tokensOut);
        quote.grossQuoteUsed = terminalFill ? ClankCurveMath.grossFromNet(quote.netQuoteIn, totalFeeBps) : grossQuoteIn;
        uint256 totalFee = quote.grossQuoteUsed - quote.netQuoteIn;
        quote.fee = ClankCurveMath.feeFromGross(quote.grossQuoteUsed, feeBps);
        quote.tax = totalFee - quote.fee;
        quote.refund = grossQuoteIn - quote.grossQuoteUsed;
    }

    /// @dev Mirrors the executable sell checks so routing quotes cannot describe an impossible trade.
    function _quoteSell(uint256 tokensIn)
        private
        view
        returns (uint256 grossQuoteOut, uint256 netQuoteOut, uint256 fee)
    {
        if (state != State.Trading) {
            revert CurveGraduated();
        }
        if (address(token) == address(0)) revert NotInitialized();
        if (tokensIn == 0) revert ZeroAmount();

        grossQuoteOut = ClankCurveMath.sellOutput(_effectiveQuoteReserve(), tokenReserve(), tokensIn);
        if (grossQuoteOut == 0) revert ZeroOutput();
        if (grossQuoteOut > trackedQuote) revert InsufficientRealReserve();
        _validateGraduation(trackedQuote - grossQuoteOut, trackedTokens + tokensIn);

        fee = ClankCurveMath.feeFromGross(grossQuoteOut, feeBps);
        netQuoteOut = grossQuoteOut - fee;
    }

    /// @dev Every accepted trade must leave enough headroom to finish the sale and seed V4.
    function _validateGraduation(uint256 realQuote, uint256 realTokens) private view {
        uint256 terminalQuote = ClankCurveMath.validateGraduationQuote(realQuote, realTokens, phantomQuote);
        _graduationGuard.assertSeedableForCurve(
            address(token), pairToken, _tickSpacing, terminalQuote, ClankCurveMath.MIGRATION_TOKENS, phantomQuote
        );
    }

    /// @dev Credits protocol fees without calling the beneficiary during trade execution.
    function _creditFee(uint256 fee) private {
        if (fee == 0) return;
        if (pairToken == address(0)) {
            try feeEscrow.credit{value: fee}(protocolFeeRecipient) {}
            catch {
                revert FeeEscrowCallFailed();
            }
        } else {
            IERC20 quoteToken = IERC20(pairToken);
            quoteToken.forceApprove(address(feeEscrow), fee);
            try feeEscrow.creditToken(protocolFeeRecipient, pairToken, fee) {}
            catch {
                revert FeeEscrowCallFailed();
            }
            quoteToken.forceApprove(address(feeEscrow), 0);
        }
    }

    function _receiveQuote(uint256 amount) private {
        if (pairToken == address(0)) {
            if (msg.value != amount) revert NativeValueMismatch(msg.value, amount);
            return;
        }

        IERC20 quoteToken = IERC20(pairToken);
        uint256 balanceBefore = quoteToken.balanceOf(address(this));
        quoteToken.safeTransferFrom(msg.sender, address(this), amount);
        if (quoteToken.balanceOf(address(this)) - balanceBefore != amount) revert QuoteTransferFailed();
    }

    function _sendQuote(address recipient, uint256 amount) private {
        if (pairToken == address(0)) {
            (bool success,) = payable(recipient).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(pairToken).safeTransfer(recipient, amount);
        }
    }

    /// @dev Records a one-way lifecycle transition and emits the corresponding state event.
    function _transition(State next) private {
        State previous = state;
        state = next;
        if (next == State.Ready) readyAt = uint64(block.timestamp);
        emit StateChanged(previous, next);
    }
}
