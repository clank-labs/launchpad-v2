// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {ClankInitializationGuardHook} from "./ClankInitializationGuardHook.sol";

/// @title CREATE2 deployer for the Clank initialization guard
/// @notice Deploys the hook at an address whose low bits encode the Uniswap V4 permissions.
contract ClankHookDeployer {
    error DeploymentAddressMismatch(address expected, address actual);

    event HookDeployed(address indexed hook, bytes32 indexed salt);

    function deploy(IPoolManager poolManager, address initialOwner, bytes32 salt, address expectedHook)
        external
        returns (ClankInitializationGuardHook hook)
    {
        hook = new ClankInitializationGuardHook{salt: salt}(poolManager, initialOwner);
        if (address(hook) != expectedHook) {
            revert DeploymentAddressMismatch(expectedHook, address(hook));
        }
        emit HookDeployed(address(hook), salt);
    }

    function predict(IPoolManager poolManager, address initialOwner, bytes32 salt)
        external
        view
        returns (address hook)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(ClankInitializationGuardHook).creationCode, abi.encode(poolManager, initialOwner))
        );
        hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
