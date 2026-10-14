// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ClankLaunchFactory} from "./ClankLaunchFactory.sol";
import {ClankBondingCurve} from "./ClankBondingCurve.sol";

/// @title Atomic Clank launch and initial buy
/// @notice Creates a launch and buys for its recipient in one transaction.
/// @dev Adapted from the MIT-licensed PonsV2LaunchAndBuy. The cited upstream deployment is an
/// exact Sourcify match: chain 4663, 0xe33E9E479dF8802cb0866d5d05258bEc4cF62948.
/// The factory trusts this router to preserve the caller's deployer identity.
contract ClankLaunchAndBuy is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error NotApprovedLauncher();
    error NativeValueMismatch(uint256 sent, uint256 expected);
    error RefundFailed();

    /// @dev quoteSpent is the requested quoteIn, including any refunded portion, as in Pons.
    event Launched(
        address indexed token,
        address indexed curve,
        address indexed recipient,
        address launcher,
        uint256 quoteSpent,
        uint256 tokensReceived
    );

    /// @notice Launch factory this contract creates tokens through.
    ClankLaunchFactory public immutable factory;

    /// @dev Applies the factory launch gate to the initiating account.
    modifier onlyPermittedLauncher() {
        if (!factory.canLaunch(msg.sender)) revert NotApprovedLauncher();
        _;
    }

    constructor(ClankLaunchFactory factory_) {
        if (address(factory_) == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /**
     * @notice Launches a token and immediately buys `quoteIn` of its curve for
     * `recipient`, both in this transaction.
     *
     * @param params Launch parameters, forwarded to the factory untouched.
     * Set `creatorFeeRecipient` explicitly; Clank does not pay creator fees.
     * Set `expectedEconomics` to the value `previewLaunchEconomics`
     * returned, which still pins the terms as it would on a direct launch.
     * @param launchConfigId Factory launch config to launch against.
     * @param pairToken Quote asset, or the zero address for a native launch.
     * @param quoteIn Amount of the quote asset to spend on the opening buy. An
     * amount past what the curve can sell is clamped by the curve and the
     * remainder comes back to the caller.
     * @param minTokensOut Slippage bound on the opening buy. The curve prices
     * a clamped fill against this too, so a buy sized to take the whole
     * allocation can still set a meaningful floor.
     * @param recipient Receives the purchased tokens.
     * @param snipeTaxExemptions Additional recipients to exempt from the
     * launch-window snipe tax. `recipient` is appended automatically. At most
     * 31 entries may be supplied because the factory caps the combined list
     * at 32.
     *
     * @dev For a native launch the call must carry the launch fee and the buy
     * together. For an ERC-20 quote asset it carries the launch fee only, and
     * the buy is pulled from the caller, who must have approved this contract
     * for `quoteIn` first.
     */
    function launchAndBuy(
        ClankLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 quoteIn,
        uint256 minTokensOut,
        address recipient,
        address[] calldata snipeTaxExemptions
    ) external payable onlyPermittedLauncher nonReentrant returns (address token, address curve, uint256 tokensOut) {
        if (recipient == address(0)) revert ZeroAddress();
        // The atomic path keeps its payout routing explicit because the token
        // recipient, initiating account, and creator fee recipient may all be
        // different addresses.
        if (params.creatorFeeRecipient == address(0)) revert ZeroAddress();
        if (quoteIn == 0) revert ZeroAmount();

        uint256 launchFee = factory.launchFee();
        bool nativeQuote = pairToken == address(0);

        // Balance held before this call funds itself, measured on the leg
        // the curve refunds in: native for a native launch, the quote token
        // otherwise. The refund is measured against this rather than swept
        // wholesale, so dust left behind by an earlier caller is never paid
        // out to this one.
        uint256 balanceBefore =
            nativeQuote ? address(this).balance - msg.value : IERC20(pairToken).balanceOf(address(this));

        uint256 expectedValue = nativeQuote ? launchFee + quoteIn : launchFee;
        if (msg.value != expectedValue) revert NativeValueMismatch(msg.value, expectedValue);

        if (!nativeQuote) {
            IERC20(pairToken).safeTransferFrom(msg.sender, address(this), quoteIn);
        }

        // Exempt the opening-buy recipient from the launch-window tax.
        address[] memory exemptions = new address[](snipeTaxExemptions.length + 1);
        for (uint256 i = 0; i < snipeTaxExemptions.length; ++i) {
            exemptions[i] = snipeTaxExemptions[i];
        }
        exemptions[snipeTaxExemptions.length] = recipient;

        (token, curve) =
            factory.launchTokenFor{value: launchFee}(params, launchConfigId, pairToken, msg.sender, exemptions);

        if (nativeQuote) {
            tokensOut = ClankBondingCurve(payable(curve)).buy{value: quoteIn}(quoteIn, minTokensOut, recipient);
        } else {
            IERC20(pairToken).forceApprove(curve, quoteIn);
            tokensOut = ClankBondingCurve(payable(curve)).buy(quoteIn, minTokensOut, recipient);
            // A clamped fill leaves the unused allowance standing.
            IERC20(pairToken).forceApprove(curve, 0);
        }

        _refund(pairToken, nativeQuote, balanceBefore);

        emit Launched(token, curve, recipient, msg.sender, quoteIn, tokensOut);
    }

    /**
     * @dev Returns whatever the curve handed back for a buy it could not fill
     * in full. The curve refunds to its caller, which is this contract, so the
     * excess would otherwise settle here rather than with the launcher who
     * paid it.
     */
    function _refund(address pairToken, bool nativeQuote, uint256 balanceBefore) private {
        if (nativeQuote) {
            uint256 refund = address(this).balance - balanceBefore;
            if (refund == 0) return;
            (bool sent,) = payable(msg.sender).call{value: refund}("");
            if (!sent) revert RefundFailed();
            return;
        }

        uint256 quoteRefund = IERC20(pairToken).balanceOf(address(this)) - balanceBefore;
        if (quoteRefund == 0) return;
        IERC20(pairToken).safeTransfer(msg.sender, quoteRefund);
    }

    /**
     * @notice Accepts the native refund a partially filled curve returns.
     */
    receive() external payable {}
}
