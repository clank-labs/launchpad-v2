// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {ClankFeeEscrow} from "./ClankFeeEscrow.sol";
import {IERC721Owner} from "./ClankLaunchLocker.sol";

/// @title Clank Uniswap V4 graduation executor
/// @notice Mints a full-range native-ETH or ERC-20 quote V4 position directly to the immutable launch locker.
/// @dev This contract isolates V4-specific approval, action encoding, dust accounting, and
/// position ownership checks from launch administration. Only the factory may execute a migration.
contract ClankGraduationExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Auditable outcome of a V4 graduation attempt.
    struct Result {
        uint256 positionId;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint128 seededQuote;
        uint128 seededToken;
        uint128 quoteDust;
        /// @notice Unused launch tokens permanently transferred to the locker.
        uint128 tokenDust;
    }

    error InvalidAddress();
    error InvalidAmount();
    error InvalidPositionOwner();
    error InvalidSqrtPrice();
    error NoLiquidity();
    error NotFactory();
    error NothingToFlush();
    error UnexpectedNativeSender();

    /// @notice Launch factory authorised to invoke pool creation.
    address public immutable factory;
    /// @notice Uniswap V4 pool registry and accounting manager.
    IPoolManager public immutable poolManager;
    /// @notice Uniswap V4 position NFT manager.
    IPositionManager public immutable positionManager;
    /// @notice Permit2 instance used by PositionManager to pull launched tokens.
    IAllowanceTransfer public immutable permit2;
    /// @notice Initialization-only hook embedded in every graduated PoolKey.
    IHooks public immutable initializationHook;
    /// @notice Permanent recipient of every minted liquidity position.
    address public immutable locker;
    /// @notice Pull-payment escrow receiving migration dust.
    ClankFeeEscrow public immutable feeEscrow;
    /// @notice Beneficiary credited with migration dust and recovered foreign native ETH.
    address public immutable protocolFeeRecipient;
    /// @notice Unflushed ERC-20 quote dust, excluding pre-existing donations.
    mapping(address asset => uint256 amount) public pendingQuoteDust;

    event PoolCreated(
        address indexed token,
        uint256 indexed positionId,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint128 seededQuote,
        uint128 seededToken,
        uint128 quoteDust,
        uint128 tokenDust
    );
    event ForeignNativeRecovered(uint256 amount, address indexed escrowBeneficiary);
    event QuoteDustFlushed(address indexed asset, uint256 amount);

    /// @param factory_ Launch factory authorised to call mintFullRangePosition.
    /// @param poolManager_ Uniswap V4 PoolManager.
    /// @param positionManager_ Uniswap V4 PositionManager wired to poolManager_.
    /// @param permit2_ Permit2 contract used by PositionManager.
    /// @param initializationHook_ No-fee hook restricting pool initialization to the factory.
    /// @param locker_ Permanent liquidity-position recipient.
    /// @param feeEscrow_ Native and ERC-20 credit escrow.
    /// @param protocolFeeRecipient_ Beneficiary for migration dust and recovered foreign native ETH.
    constructor(
        address factory_,
        address poolManager_,
        address positionManager_,
        address permit2_,
        address initializationHook_,
        address locker_,
        address feeEscrow_,
        address protocolFeeRecipient_
    ) {
        if (
            factory_ == address(0) || poolManager_ == address(0) || positionManager_ == address(0)
                || permit2_ == address(0) || initializationHook_ == address(0) || locker_ == address(0)
                || feeEscrow_ == address(0) || protocolFeeRecipient_ == address(0)
        ) revert InvalidAddress();

        factory = factory_;
        poolManager = IPoolManager(poolManager_);
        positionManager = IPositionManager(positionManager_);
        permit2 = IAllowanceTransfer(permit2_);
        initializationHook = IHooks(initializationHook_);
        locker = locker_;
        feeEscrow = ClankFeeEscrow(feeEscrow_);
        protocolFeeRecipient = protocolFeeRecipient_;
    }

    /// @notice Accepts native refunds and sweep output only from PositionManager.
    receive() external payable {
        if (msg.sender != address(positionManager)) revert UnexpectedNativeSender();
    }

    /// @notice Permissionlessly transfers accumulated ERC-20 quote dust to the fixed escrow beneficiary.
    /// @dev Failed transfers revert the pending amount and remain retryable after pool creation.
    function flushQuoteDust(address asset) external nonReentrant returns (uint256 amount) {
        amount = pendingQuoteDust[asset];
        if (amount == 0) revert NothingToFlush();
        pendingQuoteDust[asset] = 0;

        IERC20 quoteToken = IERC20(asset);
        quoteToken.forceApprove(address(feeEscrow), amount);
        feeEscrow.creditToken(protocolFeeRecipient, asset, amount);
        quoteToken.forceApprove(address(feeEscrow), 0);

        emit QuoteDustFlushed(asset, amount);
    }

    /// @notice Mints a full-range position into the factory-initialized V4 pool.
    /// @dev Currencies are sorted by address and the PoolKey contains the initialization-only guard.
    /// The executor snapshots its own and PositionManager's pre-existing balances so foreign native
    /// ETH returned by SWEEP is never attributed to the current launch.
    /// Temporary approvals are cleared on success.
    /// @param tokenAddress Launched ERC-20 token.
    /// @param pairToken Quote asset; address(0) represents native ETH.
    /// @param poolFee Static V4 LP fee encoded in the PoolKey.
    /// @param tickSpacing Tick spacing encoded in the PoolKey.
    /// @param quoteAmount Quote asset allocated to the position.
    /// @param tokenAmount Token amount allocated to the position.
    /// @return result Position identifier, price, liquidity, seeded amounts, and rounding dust.
    function mintFullRangePosition(
        address tokenAddress,
        address pairToken,
        uint24 poolFee,
        int24 tickSpacing,
        uint128 quoteAmount,
        uint128 tokenAmount
    ) external payable nonReentrant returns (Result memory result) {
        if (msg.sender != factory) revert NotFactory();
        if (
            tokenAddress == address(0) || pairToken == tokenAddress || quoteAmount == 0 || tokenAmount == 0
                || (pairToken == address(0) ? msg.value != quoteAmount : msg.value != 0)
        ) {
            revert InvalidAmount();
        }

        IERC20 token = IERC20(tokenAddress);
        uint256 tokenBalance = token.balanceOf(address(this));
        if (tokenBalance < tokenAmount) revert InvalidAmount();
        IERC20 quoteToken = IERC20(pairToken);
        uint256 quoteTokenBalance;
        if (pairToken != address(0)) {
            quoteTokenBalance = quoteToken.balanceOf(address(this));
            if (quoteTokenBalance < quoteAmount) revert InvalidAmount();
        }

        // Separate assets supplied for this launch from balances that predate the call.
        uint256 nativeBaseline = address(this).balance - msg.value;
        uint256 tokenBaseline = tokenBalance - tokenAmount;
        uint256 quoteTokenBaseline = pairToken == address(0) ? 0 : quoteTokenBalance - quoteAmount;
        uint256 positionManagerNativeBaseline = address(positionManager).balance;

        bool quoteIsCurrency0 = pairToken < tokenAddress;
        address currency0 = quoteIsCurrency0 ? pairToken : tokenAddress;
        address currency1 = quoteIsCurrency0 ? tokenAddress : pairToken;
        uint128 amount0Max = quoteIsCurrency0 ? quoteAmount : tokenAmount;
        uint128 amount1Max = quoteIsCurrency0 ? tokenAmount : quoteAmount;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: initializationHook
        });
        (result.sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(key));
        if (result.sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || result.sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidSqrtPrice();
        }

        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        result.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            result.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );
        if (result.liquidity == 0) revert NoLiquidity();

        token.forceApprove(address(permit2), tokenAmount);
        permit2.approve(
            tokenAddress, address(positionManager), uint160(tokenAmount), uint48(block.timestamp + 5 minutes)
        );
        if (pairToken != address(0)) {
            quoteToken.forceApprove(address(permit2), quoteAmount);
            permit2.approve(
                pairToken, address(positionManager), uint160(quoteAmount), uint48(block.timestamp + 5 minutes)
            );
        }

        result.positionId = positionManager.nextTokenId();

        // Mint directly to the locker, settle both currencies, then recover unused native ETH.
        bool hasNative = currency0 == address(0);
        bytes memory actions = hasNative
            ? abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP))
            : abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](hasNative ? 3 : 2);
        params[0] =
            abi.encode(key, tickLower, tickUpper, uint256(result.liquidity), amount0Max, amount1Max, locker, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        if (hasNative) params[2] = abi.encode(key.currency0, address(this));

        positionManager.modifyLiquidities{value: msg.value}(abi.encode(actions, params), block.timestamp + 5 minutes);
        if (IERC721Owner(address(positionManager)).ownerOf(result.positionId) != locker) {
            revert InvalidPositionOwner();
        }

        permit2.approve(tokenAddress, address(positionManager), 0, 0);
        token.forceApprove(address(permit2), 0);
        if (pairToken != address(0)) {
            permit2.approve(pairToken, address(positionManager), 0, 0);
            quoteToken.forceApprove(address(permit2), 0);
        }

        // PositionManager's SWEEP may include native ETH it held before this launch. Attribute at most
        // its baseline balance to foreign ETH, and only the remainder to this launch's rounding dust.
        uint256 foreignNative;
        uint256 launchQuoteDust;
        if (pairToken == address(0)) {
            uint256 nativeDelta = address(this).balance - nativeBaseline;
            foreignNative = Math.min(positionManagerNativeBaseline, nativeDelta);
            launchQuoteDust = nativeDelta - foreignNative;
        } else {
            uint256 quoteAfter = quoteToken.balanceOf(address(this));
            if (quoteAfter < quoteTokenBaseline) revert InvalidAmount();
            launchQuoteDust = quoteAfter - quoteTokenBaseline;
        }
        if (launchQuoteDust > quoteAmount) revert InvalidAmount();

        uint256 tokenAfter = token.balanceOf(address(this));
        if (tokenAfter < tokenBaseline) revert InvalidAmount();
        uint256 launchTokenDust = tokenAfter - tokenBaseline;
        if (launchTokenDust > tokenAmount) revert InvalidAmount();

        result.quoteDust = uint128(launchQuoteDust);
        result.tokenDust = uint128(launchTokenDust);
        result.seededQuote = quoteAmount - result.quoteDust;
        result.seededToken = tokenAmount - result.tokenDust;

        if (launchTokenDust != 0) token.safeTransfer(locker, launchTokenDust);

        if (launchQuoteDust != 0) {
            if (pairToken == address(0)) {
                feeEscrow.credit{value: launchQuoteDust}(protocolFeeRecipient);
            } else {
                pendingQuoteDust[pairToken] += launchQuoteDust;
            }
        }
        uint256 totalForeignNative = nativeBaseline + foreignNative;
        if (totalForeignNative != 0) {
            feeEscrow.credit{value: totalForeignNative}(protocolFeeRecipient);
            emit ForeignNativeRecovered(totalForeignNative, protocolFeeRecipient);
        }

        emit PoolCreated(
            tokenAddress,
            result.positionId,
            result.sqrtPriceX96,
            result.liquidity,
            result.seededQuote,
            result.seededToken,
            result.quoteDust,
            result.tokenDust
        );
    }
}
