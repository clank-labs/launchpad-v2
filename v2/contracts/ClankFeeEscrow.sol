// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Clank fee escrow
/// @notice Holds beneficiary-specific native and ERC-20 credits and lets beneficiaries pull them later.
/// @dev Separating crediting from claiming prevents trade execution from calling an untrusted
/// fee recipient. Forced ETH is surplus and does not create a beneficiary credit.
contract ClankFeeEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidBeneficiary();
    error NothingToClaim();
    error NativeTransferFailed();
    error InvalidToken();

    /// @notice Claimable native balance for each beneficiary.
    mapping(address beneficiary => uint256 amount) private _credits;
    /// @notice Sum of all beneficiary credits backed by this contract.
    uint256 public totalCredits;
    mapping(address beneficiary => mapping(address token => uint256 amount)) private _tokenCredits;
    mapping(address token => uint256 amount) public totalTokenCredits;

    event Credited(address indexed beneficiary, uint256 amount);
    event Claimed(address indexed beneficiary, address indexed recipient, uint256 amount);
    event TokenCredited(address indexed beneficiary, address indexed token, uint256 amount);
    event TokenClaimed(address indexed beneficiary, address indexed token, address indexed recipient, uint256 amount);

    /// @notice Adds the attached native amount to a beneficiary's claimable credit.
    /// @dev Any caller may fund a beneficiary, but cannot redirect or withdraw that credit.
    /// @param beneficiary Account whose credit is increased.
    function credit(address beneficiary) external payable {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        _credits[beneficiary] += msg.value;
        totalCredits += msg.value;
        emit Credited(beneficiary, msg.value);
    }

    /// @notice Claims the caller's complete credit to an explicit recipient.
    /// @dev This lets a trusted controller keep the credited beneficiary stable while routing
    /// collections to a destination that may change over time.
    function claimTo(address payable recipient) external nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidBeneficiary();
        amount = _credits[msg.sender];
        if (amount == 0) revert NothingToClaim();
        _claim(msg.sender, recipient, amount);
    }

    /// @notice Returns a beneficiary's claimable native balance.
    function balanceOf(address beneficiary) external view returns (uint256) {
        return _credits[beneficiary];
    }

    /// @notice Pulls quote tokens from the caller and credits them to a beneficiary.
    function creditToken(address beneficiary, address token, uint256 amount) external nonReentrant {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (token == address(0) || token.code.length == 0) revert InvalidToken();
        if (amount == 0) return;

        IERC20 quoteToken = IERC20(token);
        uint256 balanceBefore = quoteToken.balanceOf(address(this));
        quoteToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = quoteToken.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert InvalidToken();

        _tokenCredits[beneficiary][token] += amount;
        totalTokenCredits[token] += amount;
        emit TokenCredited(beneficiary, token, amount);
    }

    /// @notice Claims the caller's complete ERC-20 credit to an explicit recipient.
    function claimTokenTo(address token, address recipient) external nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidBeneficiary();
        amount = _tokenCredits[msg.sender][token];
        if (amount == 0) revert NothingToClaim();
        _claimToken(msg.sender, token, recipient, amount);
    }

    function balanceOfToken(address beneficiary, address token) external view returns (uint256) {
        return _tokenCredits[beneficiary][token];
    }

    function _claim(address beneficiary, address payable recipient, uint256 amount) private {
        _credits[beneficiary] -= amount;
        totalCredits -= amount;

        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert NativeTransferFailed();

        emit Claimed(beneficiary, recipient, amount);
    }

    function _claimToken(address beneficiary, address token, address recipient, uint256 amount) private {
        _tokenCredits[beneficiary][token] -= amount;
        totalTokenCredits[token] -= amount;
        IERC20(token).safeTransfer(recipient, amount);
        emit TokenClaimed(beneficiary, token, recipient, amount);
    }
}
