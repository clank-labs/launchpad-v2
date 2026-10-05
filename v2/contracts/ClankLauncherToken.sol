// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ClankCurveMath} from "./libraries/ClankCurveMath.sol";

/// @title Clank launcher token
/// @notice Burnable ERC-20 deployed for one launch and initially minted completely to its curve.
/// @dev The reference and metadata fields mirror the Pons launcher-token model for indexer
/// compatibility and grant no privileges.
contract ClankLauncherToken is ERC20, ERC20Burnable {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct Metadata {
        string logo;
        string description;
        Socials socials;
    }

    error InvalidAddress();
    error InvalidSupply();

    address public immutable deployer;
    address public immutable launchFactory;
    address public immutable curve;
    string public logo;
    string public description;

    Socials private _socials;

    constructor(
        string memory name_,
        string memory symbol_,
        Metadata memory metadata_,
        address deployer_,
        address curve_,
        address launchFactory_,
        uint256 supply_
    ) ERC20(name_, symbol_) {
        if (deployer_ == address(0) || curve_ == address(0) || launchFactory_ == address(0)) {
            revert InvalidAddress();
        }
        if (supply_ != ClankCurveMath.TOKEN_SUPPLY) revert InvalidSupply();

        deployer = deployer_;
        launchFactory = launchFactory_;
        curve = curve_;
        logo = metadata_.logo;
        description = metadata_.description;
        _socials = metadata_.socials;
        _mint(curve_, supply_);
    }

    /// @notice Returns the five social metadata fields in the Pons-compatible order.
    function socials()
        external
        view
        returns (
            string memory twitter,
            string memory telegram,
            string memory discord,
            string memory website,
            string memory farcaster
        )
    {
        Socials memory values = _socials;
        return (values.twitter, values.telegram, values.discord, values.website, values.farcaster);
    }

    /// @notice Returns creator and metadata in the Pons-compatible launcher-token tuple.
    function getTokenInfo()
        external
        view
        returns (
            address tokenDeployer,
            string memory tokenLogo,
            string memory tokenDescription,
            Socials memory tokenSocials
        )
    {
        return (deployer, logo, description, _socials);
    }
}
