// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @notice Minimal ownership query used to verify a Uniswap V4 position recipient.
interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Current protocol fee destination exposed by the factory.
interface IClankFeeDestination {
    function feeDestination() external view returns (address);
}

/// @title Clank permanent liquidity locker
/// @notice Receives and records each graduated launch's Uniswap V4 position NFT.
/// @dev The contract intentionally exposes no withdrawal, approval, transfer, or arbitrary-call
/// surface. A recorded position therefore remains owned by this locker permanently.
contract ClankLaunchLocker is IERC721Receiver, ReentrancyGuard {
    error InvalidCurrencyPair();
    error InvalidPositionOwner();
    error NotFactory();
    error NotPositionManager();
    error PositionAlreadyRecorded();

    /// @notice Factory authorised to record positions after successful graduation.
    address public immutable factory;
    /// @notice Only ERC-721 contract accepted by this locker.
    address public immutable positionManager;

    /// @notice Position NFT associated with each launched token.
    mapping(address token => uint256 positionId) public lockedPositions;
    /// @notice Explicit token marker because a zero position ID is valid.
    mapping(address token => bool recorded) private _locked;
    /// @notice Explicit position marker prevents one NFT from representing multiple launches.
    mapping(uint256 positionId => bool recorded) private _positionRecorded;
    /// @notice Quote currency paired with each launched token; address(0) represents native ETH.
    mapping(address token => address pairToken) public pairTokenForToken;

    event PositionLocked(address indexed token, uint256 indexed tokenId);
    event LpFeesCollected(address indexed token, uint256 indexed positionId, address indexed beneficiary);

    /// @param positionManager_ Uniswap V4 PositionManager whose NFTs may be received.
    constructor(address positionManager_) {
        if (positionManager_ == address(0)) revert NotPositionManager();
        factory = msg.sender;
        positionManager = positionManager_;
    }

    /// @notice Records the permanent token-to-position relationship.
    /// @dev The NFT must already be owned by this locker. Explicit markers prevent reuse even when
    /// positionId is zero.
    function lockPosition(address token, uint256 positionId, address pairToken) external {
        if (msg.sender != factory) revert NotFactory();
        if (token == address(0) || token == pairToken) revert InvalidCurrencyPair();
        if (_positionRecorded[positionId] || _locked[token]) {
            revert PositionAlreadyRecorded();
        }
        if (IERC721Owner(positionManager).ownerOf(positionId) != address(this)) {
            revert InvalidPositionOwner();
        }

        lockedPositions[token] = positionId;
        pairTokenForToken[token] = pairToken;
        _locked[token] = true;
        _positionRecorded[positionId] = true;
        emit PositionLocked(token, positionId);
    }

    /// @notice Permissionlessly collects both currencies earned by a locked V4 position.
    /// @dev Zero liquidity is removed, so principal stays permanently locked while fees go directly
    /// to the factory's current protocol fee destination.
    function collectFees(address token) external nonReentrant {
        _collectFees(token, IClankFeeDestination(factory).feeDestination());
    }

    function _collectFees(address token, address recipient) private {
        if (!_locked[token]) revert InvalidPositionOwner();

        address pairToken = pairTokenForToken[token];
        Currency currency0 = Currency.wrap(pairToken < token ? pairToken : token);
        Currency currency1 = Currency.wrap(pairToken < token ? token : pairToken);
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(lockedPositions[token], uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(currency0, currency1, recipient);

        IPositionManager(positionManager).modifyLiquidities(abi.encode(actions, params), block.timestamp);
        emit LpFeesCollected(token, lockedPositions[token], recipient);
    }

    /// @notice Returns whether a launch position has been permanently recorded.
    function isLocked(address token) external view returns (bool) {
        return _locked[token];
    }

    /// @notice Permanently locked migration dust and direct token donations.
    function lockedTokenSupply(address token) external view returns (uint256) {
        if (token.code.length == 0) return 0;
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Accepts a position NFT only from the immutable PositionManager.
    /// @return ERC-721 receiver selector confirming acceptance.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != positionManager) revert NotPositionManager();
        return IERC721Receiver.onERC721Received.selector;
    }
}
