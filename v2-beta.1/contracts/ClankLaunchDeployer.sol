// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {ClankBondingCurve} from "./ClankBondingCurve.sol";
import {ClankLauncherToken} from "./ClankLauncherToken.sol";

/// @notice Complete deterministic deployment input for one curve/token pair.
struct ClankLaunchDeployment {
    string name;
    string symbol;
    ClankLauncherToken.Metadata metadata;
    address creator;
    uint256 supply;
    bytes32 launchId;
    ClankBondingCurve.Config curveConfig;
}

/// @title Clank launch deployer
/// @notice Handles CREATE2 deployment and address prediction for launch curve/token pairs.
/// @dev Split from the factory to mirror Pons' contract responsibilities and keep deployment
/// bytecode out of the orchestration surface exposed to integrations.
contract ClankLaunchDeployer {
    error AddressMismatch(address expected, address actual);
    error InvalidAddress();
    error NotFactory();

    address public immutable factory;

    constructor(address factory_) {
        if (factory_ == address(0)) revert InvalidAddress();
        factory = factory_;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    function deployLaunch(ClankLaunchDeployment calldata params)
        external
        onlyFactory
        returns (address token, address curve)
    {
        (address predictedToken, address predictedCurve) = predictLaunchAddresses(params);

        curve = address(new ClankBondingCurve{salt: curveSalt(params.launchId)}(params.curveConfig));
        if (curve != predictedCurve) revert AddressMismatch(predictedCurve, curve);

        token = address(
            new ClankLauncherToken{salt: tokenSalt(params.launchId)}(
                params.name, params.symbol, params.metadata, params.creator, curve, factory, params.supply
            )
        );
        if (token != predictedToken) revert AddressMismatch(predictedToken, token);
    }

    function predictLaunchAddresses(ClankLaunchDeployment calldata params)
        public
        view
        returns (address token, address curve)
    {
        bytes32 curveBytecodeHash =
            keccak256(abi.encodePacked(type(ClankBondingCurve).creationCode, abi.encode(params.curveConfig)));
        curve = Create2.computeAddress(curveSalt(params.launchId), curveBytecodeHash, address(this));

        bytes32 tokenBytecodeHash = keccak256(
            abi.encodePacked(
                type(ClankLauncherToken).creationCode,
                abi.encode(params.name, params.symbol, params.metadata, params.creator, curve, factory, params.supply)
            )
        );
        token = Create2.computeAddress(tokenSalt(params.launchId), tokenBytecodeHash, address(this));
    }

    function curveSalt(bytes32 launchId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(launchId, "CLANK_CURVE"));
    }

    function tokenSalt(bytes32 launchId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(launchId, "CLANK_TOKEN"));
    }
}
