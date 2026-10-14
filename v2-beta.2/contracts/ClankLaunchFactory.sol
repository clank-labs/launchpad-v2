// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";

import {ClankBondingCurve} from "./ClankBondingCurve.sol";
import {ClankFeeEscrow} from "./ClankFeeEscrow.sol";
import {ClankGraduationGuard} from "./ClankGraduationGuard.sol";
import {ClankGraduationExecutor} from "./ClankGraduationExecutor.sol";
import {ClankInitializationGuardHook} from "./ClankInitializationGuardHook.sol";
import {ClankLaunchDeployer, ClankLaunchDeployment} from "./ClankLaunchDeployer.sol";
import {ClankLaunchLocker} from "./ClankLaunchLocker.sol";
import {ClankLauncherToken} from "./ClankLauncherToken.sol";
import {ClankCurveMath} from "./libraries/ClankCurveMath.sol";

/// @title Clank launch factory and graduation coordinator
/// @notice Manages launch configuration, deploys predictable token/curve pairs with
/// CREATE2, snapshots each launch's economics, and coordinates permissionless V4 graduation.
/// @dev Existing curves retain their economic snapshot. The owner controls new-launch terms and
/// availability, the current fee destination, and delayed recovery of failed swept launches.
/// Recovery retries migration before releasing reserves; locked positions cannot be withdrawn.
contract ClankLaunchFactory is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_NAME_LENGTH = 64;
    uint256 public constant MAX_SYMBOL_LENGTH = 16;
    uint256 public constant MAX_LOGO_LENGTH = 256;
    uint256 public constant MAX_DESCRIPTION_LENGTH = 1_024;
    uint256 public constant MAX_SOCIAL_URI_LENGTH = 256;
    uint16 public constant MAX_CURVE_FEE_BPS = 1_000;
    uint256 private constant MAX_TOTAL_TRADE_FEE_BPS = 2_000;
    uint256 private constant MAX_SNIPE_TAX_START_BPS = 9_900;
    uint256 private constant MAX_SNIPE_TAX_SECONDS = 60;
    uint256 private constant MAX_SNIPE_TAX_EXEMPTIONS = 32;
    uint8 public constant MIN_PAIR_TOKEN_DECIMALS = 6;
    uint24 public constant MAX_V4_STATIC_FEE = 999_999;
    int24 public constant MAX_V4_TICK_SPACING = 32_767;
    uint256 public constant GRADUATION_RESCUE_DELAY = 7 days;
    /// @notice Fixed execution budget for force-sweep graduation and rescue migration attempts.
    uint256 public constant RESCUE_MIGRATION_GAS = 5_000_000;
    /// @dev Covers call setup, error handling, and recovery after forwarding the full migration budget.
    uint256 private constant RESCUE_GAS_RESERVE = 500_000;

    /// @notice Economic template snapshotted by new launches.
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

    /// @notice Quote-denominated curve terms for one approved ERC-20 pair asset.
    struct PairTokenEconomics {
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint8 decimals;
    }

    /// @notice External infrastructure and governance addresses fixed at factory deployment.
    struct DeploymentConfig {
        address initialOwner;
        address poolManager;
        address positionManager;
        address permit2;
        address initializationHook;
    }

    /// @notice Creator-supplied launch metadata, config selection, and CREATE2 entropy.
    struct LaunchParams {
        string name;
        string symbol;
        string logo;
        uint256 launchConfigId;
        bytes32 expectedEconomics;
        bytes32 userSalt;
    }

    /// @notice Pons-compatible social metadata tuple.
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    /// @notice Pons-compatible launch parameters accepted by the compatibility overload.
    /// @dev Clank rejects creator tax and buyback requests.
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

    /// @notice Immutable launch snapshot plus migration progress and result data.
    struct Launch {
        address token;
        address curve;
        address creator;
        address pairToken;
        bytes32 launchId;
        uint256 launchConfigId;
        bytes32 economics;
        string name;
        string symbol;
        string logo;
        uint128 supply;
        uint128 phantomQuote;
        uint128 graduationThreshold;
        uint16 curveFeeBps;
        uint24 poolFee;
        int24 tickSpacing;
        uint128 sweptQuote;
        uint128 sweptTokens;
        uint64 sweptAt;
        uint128 targetLpTokens;
        uint128 seededQuote;
        uint128 seededToken;
        uint256 positionId;
    }

    /// @notice Pons-shaped launch record for generic launchpad integrations.
    /// @dev Unsupported creator-fee and buyback fields are returned as zero values.
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

    error AddressMismatch(address expected, address actual);
    error ZeroAddress();
    error InvalidEconomics();
    error InvalidBasisPoints();
    error InvalidSnipeTaxWindow();
    error CurveFeeTooHigh();
    error InvalidInitializationHook();
    error InvalidLaunchConfigId();
    error InvalidMetadata();
    error InvalidPoolConfiguration();
    error LaunchFeeNotPaid();
    error NotLaunchForwarder();
    error ExemptionListTooLong();
    error AlreadySet();
    error LaunchDeployerNotSet();
    error LaunchDeployerWiringMismatch();
    error LaunchAlreadyExists();
    error LaunchConfigDisabled();
    error LaunchEconomicsMismatch(bytes32 expected, bytes32 actual);
    error NotWhitelisted();
    error TokenNotFound();
    error MigrationAmountTooSmall();
    error MissingCode(address dependency);
    error PositionManagerPoolMismatch(address expected, address actual);
    error PositionManagerPermit2Mismatch(address expected, address actual);
    error UnsupportedBuyback();
    error UnsupportedCreatorTax();
    error PairTokenValidationFailed();
    error PairTokenNotApproved();
    error PairTokenEconomicsInvalid();
    error PairTokenDecimalsMismatch(uint8 expected, uint8 actual);
    error PairTokenDecimalsUnavailable();
    error PairTokenAuthorityUnauthorizedAccount(address account);
    error InitializationHookFactoryMismatch(address expected, address actual);
    error InitializationHookOwnerMismatch(address expected, address actual);
    error InitializationHookPoolMismatch(address expected, address actual);
    error UnexpectedNativeSender();
    error GraduationRescueTooEarly(uint256 availableAt);
    error NothingToGraduate();
    error OnlySelf();
    error InsufficientRescueGas();
    error PositionManagerLocked();
    error FeeTransferFailed();
    error OwnershipCannotBeRenounced();

    /// @notice Current recipient of bonding, snipe-tax, migration-dust, and V4 LP fees.
    address public feeDestination;
    /// @notice Pons-compatible launch-fee getter that always returns zero.
    uint256 public launchFee;
    /// @notice Uniswap V4 PoolManager used by every launch from this factory.
    address public immutable poolManager;
    /// @notice Uniswap V4 PositionManager used by every launch from this factory.
    address public immutable positionManager;
    /// @notice Permit2 instance used during V4 position creation.
    address public immutable permit2;
    /// @notice No-fee V4 hook that restricts initialization to this factory.
    ClankInitializationGuardHook public immutable initializationHook;
    /// @notice Shared pull-payment escrow for protocol credits.
    ClankFeeEscrow public immutable feeEscrow;
    /// @notice Permanent liquidity-position sink shared by all launches.
    ClankLaunchLocker public immutable locker;
    /// @notice Shared adapter that executes V4 graduation.
    ClankGraduationExecutor public immutable graduationExecutor;
    /// @notice Dedicated CREATE2 deployer shared by all launches and wired once after deployment.
    ClankLaunchDeployer public launchDeployer;
    /// @notice Trusted router allowed to preserve the original deployer on forwarded launches.
    address public launchForwarder;
    /// @notice Authority allowed to approve pair tokens and update their economics.
    address public pairTokenAuthority;
    /// @notice Stateless V4 seed preflight used before reserves leave a curve.
    ClankGraduationGuard public immutable graduationGuard;

    LaunchConfig[] private _launchConfigs;
    mapping(address token => Launch launch) private _launches;
    /// @notice Token deployed for each curve address.
    mapping(address curve => address token) public tokenForCurve;
    /// @notice ERC-20 quote assets available to new launches.
    mapping(address pairToken => bool approved) public approvedPairTokens;
    /// @notice Curve economics denominated in each ERC-20 quote asset's smallest unit.
    mapping(address pairToken => PairTokenEconomics economics) public pairTokenEconomics;
    /// @notice Peak total buy fee snapshotted by new launches; zero disables snipe tax.
    uint256 public snipeTaxStartBps;
    /// @notice Anti-snipe decay window snapshotted by new launches.
    uint256 public snipeTaxSeconds = 15;
    /// @notice Global gate for creation of new launches.
    bool public launchEnabled;
    mapping(address token => address recipient) private _creatorFeeRecipients;
    /// @dev Scoped sender permitted to deliver tracked native reserves during graduation.
    address private _expectedNativeSender;

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
    event FeeDestinationUpdated(address indexed previousDestination, address indexed newDestination);
    event FeesCollected(address indexed asset, address indexed destination, uint256 amount);

    /// @notice Pons-compatible launch event for generic launchpad indexers.
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
    /// @notice Compact Pons-compatible graduation event.
    event PoolGraduated(address indexed token, uint256 positionId, uint256 tokenAmount, uint256 pairTokenAmount);

    /// @param config Initial owner and validated V4 infrastructure addresses.
    constructor(DeploymentConfig memory config) Ownable(config.initialOwner) {
        if (
            config.poolManager == address(0) || config.positionManager == address(0) || config.permit2 == address(0)
                || config.initializationHook == address(0)
        ) revert ZeroAddress();
        if (config.poolManager.code.length == 0) revert MissingCode(config.poolManager);
        if (config.positionManager.code.length == 0) revert MissingCode(config.positionManager);
        if (config.permit2.code.length == 0) revert MissingCode(config.permit2);
        if (config.initializationHook.code.length == 0) revert MissingCode(config.initializationHook);

        address wiredPoolManager = address(IPositionManager(config.positionManager).poolManager());
        if (wiredPoolManager != config.poolManager) {
            revert PositionManagerPoolMismatch(config.poolManager, wiredPoolManager);
        }
        address wiredPermit2 = address(IPositionManagerPermit2(config.positionManager).permit2());
        if (wiredPermit2 != config.permit2) {
            revert PositionManagerPermit2Mismatch(config.permit2, wiredPermit2);
        }

        ClankInitializationGuardHook hook = ClankInitializationGuardHook(config.initializationHook);
        if ((uint160(config.initializationHook) & Hooks.ALL_HOOK_MASK) != Hooks.BEFORE_INITIALIZE_FLAG) {
            revert InvalidInitializationHook();
        }
        address hookPoolManager = address(hook.poolManager());
        if (hookPoolManager != config.poolManager) {
            revert InitializationHookPoolMismatch(config.poolManager, hookPoolManager);
        }
        address hookOwner = hook.owner();
        if (hookOwner != config.initialOwner) {
            revert InitializationHookOwnerMismatch(config.initialOwner, hookOwner);
        }
        if (hook.factory() != address(0)) revert InvalidInitializationHook();

        feeDestination = config.initialOwner;
        pairTokenAuthority = config.initialOwner;
        poolManager = config.poolManager;
        positionManager = config.positionManager;
        permit2 = config.permit2;
        initializationHook = hook;
        feeEscrow = new ClankFeeEscrow();
        locker = new ClankLaunchLocker(config.positionManager);
        graduationGuard = new ClankGraduationGuard();
        graduationExecutor = new ClankGraduationExecutor(
            address(this),
            config.poolManager,
            config.positionManager,
            config.permit2,
            config.initializationHook,
            address(locker),
            address(feeEscrow),
            address(this)
        );
        emit PairTokenAuthorityUpdated(address(0), config.initialOwner);
    }

    modifier onlyPairTokenAuthority() {
        if (msg.sender != pairTokenAuthority) revert PairTokenAuthorityUnauthorizedAccount(msg.sender);
        _;
    }

    /// @notice Accepts native ETH only from the curve currently being swept by this factory.
    /// @dev The scoped sender prevents unsolicited ETH from being mixed with migration accounting.
    receive() external payable {
        if (msg.sender != _expectedNativeSender) revert UnexpectedNativeSender();
    }

    /// @notice Returns the number of configured launch templates.
    function launchConfigCount() external view returns (uint256) {
        return _launchConfigs.length;
    }

    /// @notice Returns a launch configuration by identifier.
    /// @param id Zero-based configuration identifier.
    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory) {
        return _requireLaunchConfig(id);
    }

    /// @notice Returns the current economic commitment hash for a launch configuration.
    /// @dev Creators include this digest in LaunchParams to prevent an admin configuration update
    /// from silently changing economics between address prediction and transaction execution.
    function previewLaunchEconomics(uint256 launchConfigId) public view returns (bytes32) {
        LaunchConfig memory config = _requireLaunchConfig(launchConfigId);
        return _economicsDigest(config, address(0), config.phantomQuote, config.graduationThreshold);
    }

    /// @notice Pons-compatible economics preview for native or approved ERC-20 quote launches.
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32) {
        LaunchConfig memory config = _requireLaunchConfig(launchConfigId);
        (uint128 phantomQuote, uint128 threshold) = _quoteEconomics(config, pairToken);
        return _economicsDigest(config, pairToken, phantomQuote, threshold);
    }

    /// @notice Changes the authority that manages ERC-20 pair assets and their economics.
    /// @dev Setting the authority to the zero address disables pair-token administration.
    function setPairTokenAuthority(address newAuthority) external onlyOwner {
        address previousAuthority = pairTokenAuthority;
        pairTokenAuthority = newAuthority;
        emit PairTokenAuthorityUpdated(previousAuthority, newAuthority);
    }

    /// @notice Sets quote-denominated economics before an ERC-20 pair can be approved.
    function setPairTokenEconomics(
        address pairToken,
        uint256 phantomQuote,
        uint256 graduationThreshold,
        uint8 expectedDecimals
    ) external onlyPairTokenAuthority {
        if (
            pairToken == address(0) || pairToken.code.length == 0 || phantomQuote == 0
                || phantomQuote > ClankCurveMath.MAX_PHANTOM_QUOTE || expectedDecimals < MIN_PAIR_TOKEN_DECIMALS
                || graduationThreshold != ClankCurveMath.graduationThreshold(phantomQuote)
        ) {
            revert PairTokenEconomicsInvalid();
        }
        _requirePairTokenDecimals(pairToken, expectedDecimals);
        // Check both currency orderings with V4's strictest per-tick liquidity limit.
        _validateResolvedMigration(address(1), address(0), 1, uint128(phantomQuote));
        _validateResolvedMigration(address(1), address(2), 1, uint128(phantomQuote));
        pairTokenEconomics[pairToken] = PairTokenEconomics(phantomQuote, graduationThreshold, expectedDecimals);
        emit PairTokenEconomicsUpdated(pairToken, phantomQuote, graduationThreshold, expectedDecimals);
    }

    /// @notice Enables or disables an ERC-20 quote asset for new launches.
    function setPairTokenApproved(address pairToken, bool approved) external onlyPairTokenAuthority {
        if (pairToken == address(0) || pairToken.code.length == 0) revert PairTokenValidationFailed();
        if (approved) {
            PairTokenEconomics memory economics = pairTokenEconomics[pairToken];
            if (economics.phantomQuote == 0 || economics.graduationThreshold == 0) {
                revert PairTokenEconomicsInvalid();
            }
            _requirePairTokenDecimals(pairToken, economics.decimals);
        }
        approvedPairTokens[pairToken] = approved;
        emit PairTokenApprovalUpdated(pairToken, approved);
    }

    /// @notice Sets the peak total buy fee snapshotted by each new launch.
    function setSnipeTaxStartBps(uint256 bps) external onlyOwner {
        if (bps != 0 && (bps <= MAX_TOTAL_TRADE_FEE_BPS || bps > MAX_SNIPE_TAX_START_BPS)) {
            revert InvalidBasisPoints();
        }
        snipeTaxStartBps = bps;
        emit SnipeTaxStartBpsUpdated(bps);
    }

    /// @notice Sets the anti-snipe decay window snapshotted by each new launch.
    function setSnipeTaxSeconds(uint256 secondsWindow) external onlyOwner {
        if (secondsWindow == 0 || secondsWindow > MAX_SNIPE_TAX_SECONDS) revert InvalidSnipeTaxWindow();
        snipeTaxSeconds = secondsWindow;
        emit SnipeTaxSecondsUpdated(secondsWindow);
    }

    /// @notice Updates the sole recipient used by every protocol fee collection path.
    function setFeeDestination(address newDestination) external onlyOwner {
        if (newDestination == address(0)) revert ZeroAddress();
        address previousDestination = feeDestination;
        feeDestination = newDestination;
        emit FeeDestinationUpdated(previousDestination, newDestination);
    }

    /// @notice Permissionlessly forwards all accrued native or ERC-20 protocol credits.
    /// @param asset Native ETH when zero, otherwise the ERC-20 quote asset to collect.
    function collectFees(address asset) external nonReentrant returns (uint256 amount) {
        address destination = feeDestination;
        if (asset == address(0)) {
            amount = feeEscrow.claimTo(payable(destination));
        } else {
            amount = feeEscrow.claimTokenTo(asset, destination);
        }
        emit FeesCollected(asset, destination, amount);
    }

    /// @notice Legacy getter retained for integrations that used the previous immutable name.
    function protocolFeeRecipient() external view returns (address) {
        return feeDestination;
    }

    /// @notice Pons-compatible pool hook getter used by third-party graduation clients.
    function memeHook() external view returns (address) {
        return address(initializationHook);
    }

    /// @notice Disabled to preserve the owner-operated delayed recovery path.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @notice Adds a validated configuration for new launches.
    /// @param config Supply, virtual reserve, threshold, bonding fee, and V4 pool parameters.
    /// @return id Identifier assigned to the new configuration.
    function addLaunchConfig(LaunchConfig calldata config) external onlyOwner returns (uint256 id) {
        _validateLaunchConfig(config);
        id = _launchConfigs.length;
        _launchConfigs.push(config);
        emit LaunchConfigAdded(id);
    }

    /// @notice Replaces a configuration used by new launches.
    /// @dev Existing launch snapshots are not modified.
    /// @param id Configuration to replace.
    /// @param config New validated configuration.
    function updateLaunchConfig(uint256 id, LaunchConfig calldata config) external onlyOwner {
        _requireLaunchConfig(id);
        _validateLaunchConfig(config);
        _launchConfigs[id] = config;
        emit LaunchConfigUpdated(id);
    }

    /// @notice Enables or disables one configuration for new launches.
    function setLaunchConfigEnabled(uint256 launchConfigId, bool enabled) external onlyOwner {
        LaunchConfig storage config = _requireLaunchConfig(launchConfigId);
        config.enabled = enabled;
        emit LaunchConfigEnabledUpdated(launchConfigId, enabled);
    }

    /// @notice Enables or disables all new launch creation.
    /// @dev This gate does not stop trading or graduation for existing launches.
    function setLaunchEnabled(bool enabled) external onlyOwner {
        if (enabled) _requireInitializationHookWiring();
        launchEnabled = enabled;
        emit LaunchEnabledUpdated(enabled);
    }

    /// @notice Returns whether a creator may launch through the current public gate.
    /// @dev The argument is retained for Pons router compatibility; Clank does not maintain a separate whitelist.
    function canLaunch(address launcher) public view returns (bool) {
        launcher;
        return launchEnabled;
    }

    /// @notice Wires the Pons-style CREATE2 helper exactly once.
    /// @dev The helper must already identify this factory as its immutable caller.
    function setLaunchDeployer(ClankLaunchDeployer deployer) external onlyOwner {
        if (address(launchDeployer) != address(0)) revert AlreadySet();
        if (address(deployer) == address(0) || address(deployer).code.length == 0) {
            revert LaunchDeployerNotSet();
        }
        if (deployer.factory() != address(this)) revert LaunchDeployerWiringMismatch();
        launchDeployer = deployer;
        emit LaunchDeployerSet(address(deployer));
    }

    /// @notice Sets the trusted launch-and-buy router; the owner may rotate it.
    function setLaunchForwarder(address forwarder) external onlyOwner {
        if (forwarder == address(0)) revert ZeroAddress();
        launchForwarder = forwarder;
        emit LaunchForwarderSet(forwarder);
    }

    /// @notice Pons-compatible native or approved ERC-20 quote launch entrypoint.
    /// @dev Creator tax, buyback, and launch payments are unsupported. A zero expectedEconomics
    /// value waives the economics pin as in Pons.
    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        nonReentrant
        returns (address token, address curve)
    {
        return _launchCompatibleToken(params, launchConfigId, pairToken, msg.sender);
    }

    /// @notice Creates a launch with up to 32 additional snipe-tax-exempt recipients.
    function launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions
    ) external payable nonReentrant returns (address token, address curve) {
        (token, curve) = _launchCompatibleToken(params, launchConfigId, pairToken, msg.sender);
        _exemptFromSnipeTax(curve, snipeTaxExemptions);
    }

    /// @notice Creates a launch for the trusted router's original caller.
    function launchTokenFor(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address originalDeployer,
        address[] calldata snipeTaxExemptions
    ) external payable nonReentrant returns (address token, address curve) {
        if (msg.sender != launchForwarder) revert NotLaunchForwarder();
        (token, curve) = _launchCompatibleToken(params, launchConfigId, pairToken, originalDeployer);
        _exemptFromSnipeTax(curve, snipeTaxExemptions);
    }

    function _exemptFromSnipeTax(address curve, address[] calldata snipeTaxExemptions) private {
        if (snipeTaxExemptions.length > MAX_SNIPE_TAX_EXEMPTIONS) revert ExemptionListTooLong();
        for (uint256 i; i < snipeTaxExemptions.length; ++i) {
            ClankBondingCurve(payable(curve)).exemptFromSnipeTax(snipeTaxExemptions[i]);
        }
    }

    function _launchCompatibleToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address creator
    ) private returns (address token, address curve) {
        if (msg.value != 0) revert LaunchFeeNotPaid();
        if (params.creatorTaxBps != 0) revert UnsupportedCreatorTax();
        if (params.buybackEnabled) revert UnsupportedBuyback();

        LaunchParams memory launchParams = _compatibleLaunchParams(params, launchConfigId, pairToken);
        address creatorFeeRecipient = params.creatorFeeRecipient == address(0) ? creator : params.creatorFeeRecipient;
        return _launchToken(
            launchParams, creator, creatorFeeRecipient, pairToken, params.logo, params.description, params.socials
        );
    }

    function _compatibleLaunchParams(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        private
        view
        returns (LaunchParams memory launchParams)
    {
        bytes32 expectedEconomics = params.expectedEconomics;
        if (expectedEconomics == bytes32(0)) {
            LaunchConfig memory config = _requireLaunchConfig(launchConfigId);
            (uint128 phantomQuote, uint128 threshold) = _quoteEconomics(config, pairToken);
            expectedEconomics = _economicsDigest(config, pairToken, phantomQuote, threshold);
        }
        launchParams = LaunchParams({
            name: params.name,
            symbol: params.symbol,
            logo: params.logo,
            launchConfigId: launchConfigId,
            expectedEconomics: expectedEconomics,
            userSalt: params.salt
        });
    }

    function _launchToken(
        LaunchParams memory params,
        address creator,
        address creatorFeeRecipient,
        address pairToken,
        string memory logo,
        string memory description,
        Socials memory socials
    ) private returns (address token, address curve) {
        if (address(launchDeployer) == address(0)) revert LaunchDeployerNotSet();
        if (!canLaunch(creator)) revert NotWhitelisted();
        _validateMetadata(params, logo, description, socials);
        (LaunchConfig memory config, bytes32 economics, uint128 phantomQuote, uint128 threshold) =
            _resolveLaunchTerms(params, pairToken);
        if (!config.enabled) revert LaunchConfigDisabled();
        bytes32 launchId = _launchIdFor(creator, params, economics, logo, description, socials);
        ClankLaunchDeployment memory deployment = _launchDeployment(
            params, config, pairToken, phantomQuote, threshold, launchId, creator, logo, description, socials
        );
        (address predictedToken, address predictedCurve) = launchDeployer.predictLaunchAddresses(deployment);
        _validateResolvedMigration(predictedToken, pairToken, config.tickSpacing, phantomQuote);

        (token, curve) = launchDeployer.deployLaunch(deployment);
        if (curve != predictedCurve) revert AddressMismatch(predictedCurve, curve);
        if (token != predictedToken) revert AddressMismatch(predictedToken, token);
        if (_launches[token].token != address(0)) revert LaunchAlreadyExists();

        ClankBondingCurve(payable(curve)).initialize(token);
        ClankBondingCurve(payable(curve)).exemptFromSnipeTax(creator);
        if (creatorFeeRecipient != creator) {
            ClankBondingCurve(payable(curve)).exemptFromSnipeTax(creatorFeeRecipient);
        }
        _launches[token] = Launch({
            token: token,
            curve: curve,
            creator: creator,
            pairToken: pairToken,
            launchId: launchId,
            launchConfigId: params.launchConfigId,
            economics: economics,
            name: params.name,
            symbol: params.symbol,
            logo: params.logo,
            supply: uint128(config.supply),
            phantomQuote: phantomQuote,
            graduationThreshold: threshold,
            curveFeeBps: uint16(config.curveFeeBps),
            poolFee: config.poolFee,
            tickSpacing: config.tickSpacing,
            sweptQuote: 0,
            sweptTokens: 0,
            sweptAt: 0,
            targetLpTokens: 0,
            seededQuote: 0,
            seededToken: 0,
            positionId: 0
        });
        tokenForCurve[curve] = token;
        _creatorFeeRecipients[token] = creatorFeeRecipient;

        emit TokenLaunched(token, curve, creator, pairToken, params.launchConfigId, threshold);
    }

    /// @notice Returns the stored launch record for a token.
    /// @dev An unknown token returns an all-zero record; state-changing functions use _requireLaunch.
    function getLaunch(address token) external view returns (Launch memory) {
        return _launches[token];
    }

    /// @notice Returns a Pons-shaped record for launchpad indexers and bots.
    function getLaunchedToken(address token) external view returns (LaunchedToken memory launched) {
        Launch storage launch = _launches[token];
        bool exists = launch.token != address(0);
        uint8 phase;
        if (exists) {
            ClankBondingCurve.State curveState = ClankBondingCurve(payable(launch.curve)).state();
            if (curveState == ClankBondingCurve.State.Swept) phase = 1;
            if (curveState == ClankBondingCurve.State.PoolCreated) phase = 2;
            if (curveState == ClankBondingCurve.State.Rescued) phase = 3;
        }
        launched = LaunchedToken({
            token: launch.token,
            curve: launch.curve,
            deployer: launch.creator,
            creatorFeeRecipient: _creatorFeeRecipients[token],
            pairToken: launch.pairToken,
            graduationThreshold: launch.graduationThreshold,
            poolFee: launch.poolFee,
            tickSpacing: launch.tickSpacing,
            creatorTaxBps: 0,
            buybackEnabled: false,
            phase: phase,
            sweptQuote: launch.sweptQuote,
            sweptTokens: launch.sweptTokens,
            sweptAt: launch.sweptAt,
            exists: exists
        });
    }

    /// @notice Advances a Ready launch to Swept by collecting its exact tracked reserves.
    /// @dev Permissionless and retryable. Forced ETH is not swept. A revert restores both the
    /// curve state and this factory's scoped receive guard.
    /// @param token Launched token identifying the curve.
    function graduate(address token) external nonReentrant {
        _graduate(token);
    }

    function _graduate(address token) private {
        Launch storage launch = _requireLaunch(token);
        ClankBondingCurve curve = ClankBondingCurve(payable(launch.curve));
        ClankBondingCurve.State curveState = curve.state();
        if (curveState != ClankBondingCurve.State.Ready) {
            revert ClankBondingCurve.InvalidState(ClankBondingCurve.State.Ready, curveState);
        }
        uint256 quotedReserve = curve.realQuoteReserve();
        uint256 quotedTokens = curve.realTokenReserve();
        graduationGuard.assertSeedableForCurve(
            token, launch.pairToken, launch.tickSpacing, quotedReserve, quotedTokens, launch.phantomQuote
        );

        _sweepCurve(token, launch, curve);
    }

    /// @notice After seven days in Ready, retries graduation before sweeping without the seed preflight.
    /// @dev The normal attempt uses the rescue gas budget and rolls back before the fallback sweep on failure.
    function forceSweptGraduation(address token) external onlyOwner nonReentrant {
        Launch storage launch = _requireLaunch(token);
        ClankBondingCurve curve = ClankBondingCurve(payable(launch.curve));
        ClankBondingCurve.State curveState = curve.state();
        if (curveState != ClankBondingCurve.State.Ready) {
            revert ClankBondingCurve.InvalidState(ClankBondingCurve.State.Ready, curveState);
        }
        uint256 availableAt = uint256(curve.readyAt()) + GRADUATION_RESCUE_DELAY;
        if (block.timestamp < availableAt) revert GraduationRescueTooEarly(availableAt);

        // Preserve the full call budget under EIP-150 and leave gas for the fallback sweep.
        if (gasleft() < RESCUE_MIGRATION_GAS + RESCUE_MIGRATION_GAS / 63 + RESCUE_GAS_RESERVE) {
            revert InsufficientRescueGas();
        }
        try this.attemptForceGraduation{gas: RESCUE_MIGRATION_GAS}(token) {
            return;
        } catch {}

        _sweepCurve(token, launch, curve);
        emit LaunchForceSwept(token);
    }

    /// @dev Rollback boundary for force-sweep's normal graduation attempt; the outer guard stays active.
    function attemptForceGraduation(address token) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _graduate(token);
    }

    function _sweepCurve(address token, Launch storage launch, ClankBondingCurve curve) private {
        uint256 quoteBalanceBefore =
            launch.pairToken == address(0) ? address(this).balance : IERC20(launch.pairToken).balanceOf(address(this));
        if (launch.pairToken == address(0)) _expectedNativeSender = launch.curve;
        (, uint256 tokenAmount) = curve.graduate(address(this));
        _expectedNativeSender = address(0);
        uint256 quoteBalanceAfter =
            launch.pairToken == address(0) ? address(this).balance : IERC20(launch.pairToken).balanceOf(address(this));
        if (quoteBalanceAfter < quoteBalanceBefore) revert InvalidEconomics();
        uint256 quoteAmount = quoteBalanceAfter - quoteBalanceBefore;
        if (quoteAmount == 0 || tokenAmount == 0) revert NothingToGraduate();
        if (quoteAmount > type(uint128).max || tokenAmount > type(uint128).max) {
            revert InvalidEconomics();
        }

        launch.sweptQuote = uint128(quoteAmount);
        launch.sweptTokens = uint128(tokenAmount);
        launch.sweptAt = uint64(block.timestamp);
        emit LaunchSwept(token, quoteAmount, tokenAmount);
    }

    /// @notice Advances a Swept launch to PoolCreated and permanently locks V4 liquidity.
    function createGraduatedPool(address token) external nonReentrant returns (uint256 positionId) {
        ClankGraduationExecutor.Result memory result = _createGraduatedPool(token);
        return result.positionId;
    }

    function _createGraduatedPool(address token) private returns (ClankGraduationExecutor.Result memory result) {
        Launch storage launch = _requireLaunch(token);
        ClankBondingCurve curve = ClankBondingCurve(payable(launch.curve));
        ClankBondingCurve.State curveState = curve.state();
        if (curveState != ClankBondingCurve.State.Swept) {
            revert ClankBondingCurve.InvalidState(ClankBondingCurve.State.Swept, curveState);
        }
        uint256 quoteAmount = launch.sweptQuote;
        uint256 tokenAmount = launch.sweptTokens;
        if (quoteAmount == 0 || tokenAmount == 0) revert MigrationAmountTooSmall();

        launch.targetLpTokens = uint128(tokenAmount);

        _requireInitializationHookWiring();
        bool quoteIsCurrency0 = launch.pairToken < token;
        address currency0 = quoteIsCurrency0 ? launch.pairToken : token;
        address currency1 = quoteIsCurrency0 ? token : launch.pairToken;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: launch.poolFee,
            tickSpacing: launch.tickSpacing,
            hooks: IHooks(address(initializationHook))
        });
        uint160 sqrtPriceX96 = graduationGuard.assertSeedableForCurve(
            token, launch.pairToken, launch.tickSpacing, quoteAmount, tokenAmount, launch.phantomQuote
        );
        IPoolManager(poolManager).initialize(key, sqrtPriceX96);

        IERC20(token).safeTransfer(address(graduationExecutor), tokenAmount);
        if (launch.pairToken != address(0)) {
            IERC20(launch.pairToken).safeTransfer(address(graduationExecutor), quoteAmount);
        }

        result = graduationExecutor.mintFullRangePosition{value: launch.pairToken == address(0) ? quoteAmount : 0}(
            token, launch.pairToken, launch.poolFee, launch.tickSpacing, uint128(quoteAmount), uint128(tokenAmount)
        );

        launch.seededQuote = result.seededQuote;
        launch.seededToken = result.seededToken;
        launch.positionId = result.positionId;
        launch.sweptQuote = 0;
        launch.sweptTokens = 0;
        launch.sweptAt = 0;

        locker.lockPosition(token, result.positionId, launch.pairToken);
        curve.markPoolCreated();

        emit PoolGraduated(token, result.positionId, result.seededToken, result.seededQuote);
    }

    /// @notice Seven days after sweeping, retries migration before releasing failed reserves to the owner.
    /// @dev Ordinary migration remains permissionless and retryable without resetting sweptAt.
    /// Any failure within the fixed migration gas budget permits recovery, including out-of-gas.
    /// @param recipient Retained for ABI compatibility; must be nonzero. Recovery always pays owner().
    function rescueSweptGraduation(address token, address recipient) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        Launch storage launch = _requireLaunch(token);
        ClankBondingCurve curve = ClankBondingCurve(payable(launch.curve));
        ClankBondingCurve.State curveState = curve.state();
        if (curveState != ClankBondingCurve.State.Swept) {
            revert ClankBondingCurve.InvalidState(ClankBondingCurve.State.Swept, curveState);
        }

        uint256 availableAt = uint256(launch.sweptAt) + GRADUATION_RESCUE_DELAY;
        if (block.timestamp < availableAt) revert GraduationRescueTooEarly(availableAt);

        // Active Uniswap callbacks are not migration failures and must never authorize recovery.
        if (TransientStateLibrary.isUnlocked(IPoolManager(poolManager))) revert IPoolManager.AlreadyUnlocked();
        if (IMsgSender(positionManager).msgSender() != address(0)) revert PositionManagerLocked();

        // Include the EIP-150 headroom so the EVM cannot silently truncate the requested call gas.
        if (gasleft() < RESCUE_MIGRATION_GAS + RESCUE_MIGRATION_GAS / 63 + RESCUE_GAS_RESERVE) {
            revert InsufficientRescueGas();
        }
        try this.attemptRescueMigration{gas: RESCUE_MIGRATION_GAS}(token) {
            return;
        } catch {}

        uint256 quoteAmount = launch.sweptQuote;
        uint256 tokenAmount = launch.sweptTokens;
        if (quoteAmount == 0 || tokenAmount == 0) revert NothingToGraduate();
        address pairToken = launch.pairToken;
        address recoveryOwner = owner();

        launch.sweptQuote = 0;
        launch.sweptTokens = 0;
        launch.sweptAt = 0;
        curve.markRescued();

        if (pairToken == address(0)) {
            (bool sent,) = payable(recoveryOwner).call{value: quoteAmount}("");
            if (!sent) revert FeeTransferFailed();
        } else {
            IERC20(pairToken).safeTransfer(recoveryOwner, quoteAmount);
        }
        IERC20(token).safeTransfer(recoveryOwner, tokenAmount);

        emit LaunchGraduationRescued(token, recoveryOwner, quoteAmount, tokenAmount);
    }

    /// @dev External rollback boundary for rescue's try/catch. Only the guarded rescue may enter.
    /// The outer nonReentrant guard remains active throughout migration and reserve release.
    function attemptRescueMigration(address token) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _createGraduatedPool(token);
    }

    /// @notice Predicts the exact Pons-compatible launch, including quote asset and full metadata.
    /// @dev Applies launch metadata bounds and returns the committed launch identifier with both addresses.
    function predictLaunch(address creator, TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        view
        returns (address token, address curve, bytes32 launchId)
    {
        return _predictCompatibleLaunch(creator, params, launchConfigId, pairToken);
    }

    function _predictCompatibleLaunch(
        address creator,
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken
    ) private view returns (address token, address curve, bytes32 launchId) {
        if (address(launchDeployer) == address(0)) revert LaunchDeployerNotSet();
        if (params.creatorTaxBps != 0) revert UnsupportedCreatorTax();
        if (params.buybackEnabled) revert UnsupportedBuyback();

        LaunchParams memory launchParams = _compatibleLaunchParams(params, launchConfigId, pairToken);
        _validateMetadata(launchParams, params.logo, params.description, params.socials);
        (LaunchConfig memory config, bytes32 economics, uint128 phantomQuote, uint128 threshold) =
            _resolveLaunchTerms(launchParams, pairToken);
        launchId = _launchIdFor(creator, launchParams, economics, params.logo, params.description, params.socials);
        (token, curve) = launchDeployer.predictLaunchAddresses(
            _launchDeployment(
                launchParams,
                config,
                pairToken,
                phantomQuote,
                threshold,
                launchId,
                creator,
                params.logo,
                params.description,
                params.socials
            )
        );
    }

    /// @dev Builds the exact deployer input shared by deployment and address prediction.
    function _launchDeployment(
        LaunchParams memory params,
        LaunchConfig memory config,
        address pairToken,
        uint128 phantomQuote,
        uint128 graduationThreshold,
        bytes32 launchId,
        address creator,
        string memory logo,
        string memory description,
        Socials memory socials
    ) private view returns (ClankLaunchDeployment memory deployment) {
        ClankBondingCurve.Config memory curveConfig = ClankBondingCurve.Config({
            factory: address(this),
            feeEscrow: address(feeEscrow),
            protocolFeeRecipient: address(this),
            creator: creator,
            pairToken: pairToken,
            feeBps: uint16(config.curveFeeBps),
            snipeTaxStartBps: uint16(snipeTaxStartBps),
            snipeTaxSeconds: uint32(snipeTaxSeconds),
            phantomQuote: phantomQuote,
            graduationThreshold: graduationThreshold,
            graduationGuard: address(graduationGuard),
            tickSpacing: config.tickSpacing
        });
        deployment = ClankLaunchDeployment({
            name: params.name,
            symbol: params.symbol,
            metadata: ClankLauncherToken.Metadata({
                logo: logo,
                description: description,
                socials: ClankLauncherToken.Socials({
                    twitter: socials.twitter,
                    telegram: socials.telegram,
                    discord: socials.discord,
                    website: socials.website,
                    farcaster: socials.farcaster
                })
            }),
            creator: creator,
            supply: config.supply,
            launchId: launchId,
            curveConfig: curveConfig
        });
    }

    /// @dev Commits creator identity, metadata, config identifier, economics, and user salt.
    function _launchIdFor(
        address creator,
        LaunchParams memory params,
        bytes32 economics,
        string memory logo,
        string memory description,
        Socials memory socials
    ) private pure returns (bytes32) {
        bytes32 metadataDigest = keccak256(abi.encode(logo, description, socials));
        return keccak256(
            abi.encode(
                creator,
                params.name,
                params.symbol,
                params.logo,
                metadataDigest,
                params.launchConfigId,
                economics,
                params.userSalt
            )
        );
    }

    /// @dev Resolves the current config and requires the creator's expected economics commitment.
    function _resolveLaunchTerms(LaunchParams memory params, address pairToken)
        private
        view
        returns (LaunchConfig memory config, bytes32 economics, uint128 phantomQuote, uint128 threshold)
    {
        config = _requireLaunchConfig(params.launchConfigId);
        (phantomQuote, threshold) = _quoteEconomics(config, pairToken);
        economics = _economicsDigest(config, pairToken, phantomQuote, threshold);
        if (params.expectedEconomics != economics) {
            revert LaunchEconomicsMismatch(params.expectedEconomics, economics);
        }
    }

    /// @dev Hashes every economic field that determines curve or V4 launch behaviour.
    function _economicsDigest(
        LaunchConfig memory config,
        address pairToken,
        uint256 phantomQuote,
        uint256 graduationThreshold
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                config.supply,
                pairToken,
                phantomQuote,
                graduationThreshold,
                config.curveFeeBps,
                config.poolFee,
                config.tickSpacing,
                snipeTaxStartBps,
                snipeTaxSeconds
            )
        );
    }

    function _quoteEconomics(LaunchConfig memory config, address pairToken)
        private
        view
        returns (uint128 phantomQuote, uint128 threshold)
    {
        if (pairToken == address(0)) {
            return (uint128(config.phantomQuote), uint128(config.graduationThreshold));
        }
        if (!approvedPairTokens[pairToken]) revert PairTokenNotApproved();
        PairTokenEconomics memory economics = pairTokenEconomics[pairToken];
        if (economics.phantomQuote == 0 || economics.graduationThreshold == 0) {
            revert PairTokenEconomicsInvalid();
        }
        _requirePairTokenDecimals(pairToken, economics.decimals);
        if (economics.phantomQuote > type(uint128).max || economics.graduationThreshold > type(uint128).max) {
            revert PairTokenEconomicsInvalid();
        }
        return (uint128(economics.phantomQuote), uint128(economics.graduationThreshold));
    }

    function _requirePairTokenDecimals(address pairToken, uint8 expectedDecimals) private view {
        try IERC20Metadata(pairToken).decimals() returns (uint8 actual) {
            if (actual != expectedDecimals) revert PairTokenDecimalsMismatch(expectedDecimals, actual);
        } catch {
            revert PairTokenDecimalsUnavailable();
        }
    }

    function _validateResolvedMigration(address token, address pairToken, int24 tickSpacing, uint128 phantomQuote)
        private
        view
    {
        uint256 quoteAmount = ClankCurveMath.minimumTerminalQuote(phantomQuote);
        graduationGuard.assertSeedableForCurve(
            token, pairToken, tickSpacing, quoteAmount, ClankCurveMath.MIGRATION_TOKENS, phantomQuote
        );
    }

    /// @dev Applies bounded metadata lengths before constructor bytecode and storage allocation.
    function _validateMetadata(
        LaunchParams memory params,
        string memory logo,
        string memory description,
        Socials memory socials
    ) private pure {
        uint256 nameLength = bytes(params.name).length;
        uint256 symbolLength = bytes(params.symbol).length;
        if (
            nameLength == 0 || nameLength > MAX_NAME_LENGTH || symbolLength == 0 || symbolLength > MAX_SYMBOL_LENGTH
                || bytes(params.logo).length == 0 || bytes(params.logo).length > MAX_LOGO_LENGTH
                || bytes(logo).length == 0 || bytes(logo).length > MAX_LOGO_LENGTH
                || bytes(description).length > MAX_DESCRIPTION_LENGTH
                || bytes(socials.twitter).length > MAX_SOCIAL_URI_LENGTH
                || bytes(socials.telegram).length > MAX_SOCIAL_URI_LENGTH
                || bytes(socials.discord).length > MAX_SOCIAL_URI_LENGTH
                || bytes(socials.website).length > MAX_SOCIAL_URI_LENGTH
                || bytes(socials.farcaster).length > MAX_SOCIAL_URI_LENGTH
        ) revert InvalidMetadata();
    }

    /// @dev Rejects zero economics, invalid V4 parameters, and configurations that cannot produce
    /// a non-zero terminal liquidity token allocation.
    function _validateLaunchConfig(LaunchConfig memory config) private view {
        if (
            config.supply != ClankCurveMath.TOKEN_SUPPLY || config.phantomQuote == 0
                || config.phantomQuote > ClankCurveMath.MAX_PHANTOM_QUOTE
                || config.graduationThreshold != ClankCurveMath.graduationThreshold(config.phantomQuote)
        ) {
            revert InvalidEconomics();
        }
        if (config.curveFeeBps > MAX_CURVE_FEE_BPS) revert CurveFeeTooHigh();
        if (config.poolFee > MAX_V4_STATIC_FEE || config.tickSpacing <= 0 || config.tickSpacing > MAX_V4_TICK_SPACING) {
            revert InvalidPoolConfiguration();
        }

        _validateResolvedMigration(address(1), address(0), config.tickSpacing, uint128(config.phantomQuote));
    }

    /// @dev Returns a config storage reference or reverts for an unknown identifier.
    function _requireLaunchConfig(uint256 launchConfigId) private view returns (LaunchConfig storage config) {
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        config = _launchConfigs[launchConfigId];
    }

    /// @dev Returns a launch storage reference or reverts for an unknown token.
    function _requireLaunch(address token) private view returns (Launch storage launch) {
        launch = _launches[token];
        if (launch.token == address(0)) revert TokenNotFound();
    }

    /// @dev Ensures the one-time hook wiring is complete before a pool can be initialized.
    function _requireInitializationHookWiring() private view {
        address wiredFactory = initializationHook.factory();
        if (wiredFactory != address(this)) {
            revert InitializationHookFactoryMismatch(address(this), wiredFactory);
        }
    }
}

/// @dev PositionManager's public immutable Permit2 getter is not declared by IPositionManager.
interface IPositionManagerPermit2 {
    function permit2() external view returns (address);
}
