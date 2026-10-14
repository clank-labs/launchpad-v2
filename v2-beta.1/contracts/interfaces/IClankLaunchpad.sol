// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Public interface for Clank fee credits.
interface IClankFeeEscrow {
    event Credited(address indexed beneficiary, uint256 amount);
    event Claimed(address indexed beneficiary, address indexed recipient, uint256 amount);
    event TokenCredited(address indexed beneficiary, address indexed token, uint256 amount);
    event TokenClaimed(address indexed beneficiary, address indexed token, address indexed recipient, uint256 amount);

    function credit(address beneficiary) external payable;
    function claimTo(address payable recipient) external returns (uint256 amount);
    function balanceOf(address beneficiary) external view returns (uint256 amount);
    function totalCredits() external view returns (uint256 amount);
    function creditToken(address beneficiary, address token, uint256 amount) external;
    function claimTokenTo(address token, address recipient) external returns (uint256 amount);
    function balanceOfToken(address beneficiary, address token) external view returns (uint256 amount);
    function totalTokenCredits(address token) external view returns (uint256 amount);
}

/// @notice Public token interface shared by every Clank launch.
interface IClankLauncherToken is IERC20 {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    function deployer() external view returns (address);
    function launchFactory() external view returns (address);
    function curve() external view returns (address);
    function logo() external view returns (string memory);
    function description() external view returns (string memory);
    function socials()
        external
        view
        returns (
            string memory twitter,
            string memory telegram,
            string memory discord,
            string memory website,
            string memory farcaster
        );
    function getTokenInfo()
        external
        view
        returns (
            address tokenDeployer,
            string memory tokenLogo,
            string memory tokenDescription,
            Socials memory tokenSocials
        );
}

/// @notice Public bonding-curve interface with Pons-style reserve naming.
interface IClankBondingCurve {
    event TokenInitialized(address indexed token, uint256 supply);
    event Initialized(address token);
    event StateChanged(uint8 indexed previousState, uint8 indexed newState);
    event CurveBuy(
        address indexed buyer, address indexed recipient, uint256 quoteIn, uint256 tokensOut, uint256 fee, uint256 tax
    );
    event CurveBuyRefunded(address indexed buyer, uint256 refund);
    event CurveSell(
        address indexed seller, address indexed recipient, uint256 tokensIn, uint256 quoteOut, uint256 fee, uint256 tax
    );
    event CurveCompleted(address recipient, uint256 quoteOut, uint256 tokenOut);
    event SnipeTaxExempted(address indexed account);
    event AutoGraduationFailed(address indexed token, uint256 gasRemaining);

    function token() external view returns (address);
    function creator() external view returns (address);
    function pairToken() external view returns (address);
    function feeBps() external view returns (uint256);
    function snipeTaxStartBps() external view returns (uint16);
    function snipeTaxSeconds() external view returns (uint32);
    function launchedAt() external view returns (uint64);
    function readyAt() external view returns (uint64);
    function snipeTaxExempt(address account) external view returns (bool);
    function exemptFromSnipeTax(address account) external;
    function currentSnipeTaxBps(address recipient) external view returns (uint256);
    function phantomQuote() external view returns (uint256);
    function graduationThreshold() external view returns (uint256);
    function state() external view returns (uint8);
    /// @notice Pricing reserves including phantom quote and additive virtual tokens.
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    /// @notice Tracked quote reserve plus phantom quote.
    function quoteReserve() external view returns (uint256);
    function realQuoteReserve() external view returns (uint256);
    /// @notice Tracked token inventory plus additive virtual tokens.
    function tokenReserve() external view returns (uint256);
    /// @notice Tracked token inventory, excluding donations and virtual tokens.
    function realTokenReserve() external view returns (uint256);
    /// @notice Additive virtual tokens used for pricing; these tokens are never minted.
    function virtualTokenReserve() external pure returns (uint256);
    /// @notice Tracked token inventory, equal to realTokenReserve().
    function trackedTokens() external view returns (uint256);
    function readyToGraduate() external view returns (bool);
    function graduated() external view returns (bool);
    function graduate(address recipient) external returns (uint256 quoteOut, uint256 tokenOut);
    function markRescued() external;

    function quoteBuy(uint256 grossQuoteIn)
        external
        view
        returns (uint256 grossQuoteUsed, uint256 netQuoteIn, uint256 fee, uint256 tokensOut, uint256 refund);

    function quoteBuyFor(address recipient, uint256 grossQuoteIn)
        external
        view
        returns (uint256 grossQuoteUsed, uint256 netQuoteIn, uint256 fee, uint256 tokensOut, uint256 refund);

    function quoteSell(uint256 tokensIn) external view returns (uint256 grossQuoteOut, uint256 netQuoteOut, uint256 fee);

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);

    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 quoteOut);
}

/// @notice Public launch-factory interface.
interface IClankLaunchFactory {
    /// @dev Field order and ABI types intentionally match Pons V2.
    struct LaunchConfig {
        uint256 supply;
        uint256 curveFeeBps;
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        bool enabled;
    }

    struct PairTokenEconomics {
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint8 decimals;
    }

    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    event LaunchConfigAdded(uint256 indexed id);
    event LaunchConfigUpdated(uint256 indexed id);
    event LaunchConfigEnabledUpdated(uint256 indexed launchConfigId, bool enabled);
    event LaunchEnabledUpdated(bool enabled);
    event LaunchForwarderSet(address forwarder);
    event LaunchDeployerSet(address deployer);
    event PairTokenAuthorityUpdated(address indexed previousAuthority, address indexed newAuthority);
    event PairTokenApprovalUpdated(address indexed pairToken, bool approved);
    event PairTokenEconomicsUpdated(
        address indexed pairToken, uint256 phantomQuote, uint256 graduationThreshold, uint8 decimals
    );
    event SnipeTaxStartBpsUpdated(uint256 bps);
    event SnipeTaxSecondsUpdated(uint256 secondsWindow);
    event TokenLaunched(
        address indexed token,
        address indexed curve,
        address indexed deployer,
        address pairToken,
        uint256 launchConfigId,
        uint256 graduationThreshold
    );
    event LaunchSwept(address indexed token, uint256 quoteOut, uint256 tokenOut);
    event LaunchForceSwept(address indexed token);
    event LaunchGraduationRescued(
        address indexed token, address indexed recipient, uint256 quoteAmount, uint256 tokenAmount
    );
    event PoolGraduated(address indexed token, uint256 positionId, uint256 tokenAmount, uint256 pairTokenAmount);
    event FeeDestinationUpdated(address indexed previousDestination, address indexed newDestination);
    event FeesCollected(address indexed asset, address indexed destination, uint256 amount);

    function launchConfigCount() external view returns (uint256);
    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory);
    function previewLaunchEconomics(uint256 launchConfigId) external view returns (bytes32);
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);
    function approvedPairTokens(address pairToken) external view returns (bool approved);
    function pairTokenAuthority() external view returns (address);
    function pairTokenEconomics(address pairToken)
        external
        view
        returns (uint256 phantomQuote, uint256 graduationThreshold, uint8 decimals);
    function setPairTokenEconomics(
        address pairToken,
        uint256 phantomQuote,
        uint256 graduationThreshold,
        uint8 expectedDecimals
    ) external;
    function setPairTokenAuthority(address newAuthority) external;
    function setPairTokenApproved(address pairToken, bool approved) external;
    function snipeTaxStartBps() external view returns (uint256);
    function snipeTaxSeconds() external view returns (uint256);
    function setSnipeTaxStartBps(uint256 bps) external;
    function setSnipeTaxSeconds(uint256 secondsWindow) external;
    function launchFee() external view returns (uint256);
    function feeDestination() external view returns (address);
    function GRADUATION_RESCUE_DELAY() external view returns (uint256);
    function protocolFeeRecipient() external view returns (address);
    function setFeeDestination(address newDestination) external;
    function collectFees(address asset) external returns (uint256 amount);
    function canLaunch(address launcher) external view returns (bool);
    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        returns (address token, address curve);
    function launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve);
    function launchTokenFor(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address originalDeployer,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve);
    function launchForwarder() external view returns (address);
    function setLaunchForwarder(address forwarder) external;
    /// @notice Predicts both addresses and the launch identifier, enforcing launch metadata bounds.
    function predictLaunch(address creator, TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        view
        returns (address token, address curve, bytes32 launchId);
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    function memeHook() external view returns (address);
    function graduate(address token) external;
    /// @notice After seven days in Ready, retries graduation before sweeping without the seed preflight.
    function forceSweptGraduation(address token) external;
    function createGraduatedPool(address token) external returns (uint256 positionId);
    /// @notice Seven days after sweeping, retries migration before paying failed reserves to owner().
    /// @dev recipient is a nonzero ABI compatibility argument, not the recovery destination.
    function rescueSweptGraduation(address token, address recipient) external;
}

/// @notice Permanent V4 position custody and permissionless protocol fee collection.
interface IClankLaunchLocker {
    event PositionLocked(address indexed token, uint256 indexed tokenId);
    event LpFeesCollected(address indexed token, uint256 indexed positionId, address indexed beneficiary);

    function lockedPositions(address token) external view returns (uint256 positionId);
    function pairTokenForToken(address token) external view returns (address pairToken);
    function isLocked(address token) external view returns (bool);
    /// @notice Permanently locked token balance from migration dust and direct donations.
    function lockedTokenSupply(address token) external view returns (uint256);
    function collectFees(address token) external;
}

/// @notice Pons-compatible atomic launch-and-buy entrypoint.
interface IClankLaunchAndBuy {
    event Launched(
        address indexed token,
        address indexed curve,
        address indexed recipient,
        address launcher,
        uint256 quoteSpent,
        uint256 tokensReceived
    );

    function factory() external view returns (IClankLaunchFactory);
    function launchAndBuy(
        IClankLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 quoteIn,
        uint256 minTokensOut,
        address recipient,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve, uint256 tokensOut);
}
