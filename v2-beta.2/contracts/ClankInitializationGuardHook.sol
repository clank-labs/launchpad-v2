// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title Clank V4 initialization guard
/// @notice Prevents third parties from initializing predictable Clank pool keys before graduation.
/// @dev The hook has only beforeInitialize permission. It never runs during swaps and charges no fee.
contract ClankInitializationGuardHook is Ownable2Step {
    error FactoryAlreadySet();
    error InvalidAddress();
    error NotPoolManager();
    error NotFactory();
    error OwnershipCannotBeRenounced();

    /// @notice Uniswap V4 PoolManager allowed to invoke the hook callback.
    IPoolManager public immutable poolManager;
    /// @notice Factory exclusively authorized to initialize pools using this hook.
    address public factory;

    event FactorySet(address indexed factory);

    constructor(IPoolManager poolManager_, address initialOwner) Ownable(initialOwner) {
        if (address(poolManager_) == address(0) || initialOwner == address(0)) revert InvalidAddress();
        poolManager = poolManager_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice Preserves the owner required to complete factory wiring.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @notice Declares that only the initialization callback is enabled.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Permanently wires the factory after both contracts have been deployed.
    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0)) revert FactoryAlreadySet();
        if (factory_ == address(0) || factory_.code.length == 0) revert InvalidAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    /// @dev Rejects every pool initialization not initiated directly by the wired factory.
    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (sender != factory) revert NotFactory();
        return IHooks.beforeInitialize.selector;
    }
}
