// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ClankCurveMath} from "./ClankCurveMath.sol";

/// @title Clank graduation mathematics
/// @notice Converts terminal curve reserves into Uniswap V4 prices.
library ClankMigrationMath {
    error UnsupportedPrice();
    error ZeroAmount();

    /// @notice Computes the terminal curve price from the same effective reserves used for trading.
    function migrationPrice(
        address token,
        address pairToken,
        uint256 realQuote,
        uint256 realTokens,
        uint256 phantomQuote
    ) internal pure returns (uint160) {
        uint256 quote = realQuote + phantomQuote;
        uint256 tokens = realTokens + ClankCurveMath.VIRTUAL_TOKENS;
        return pairToken < token ? sqrtPriceX96(quote, tokens) : sqrtPriceX96(tokens, quote);
    }

    /// @notice Converts an amount1/amount0 ratio into Uniswap's Q64.96 square-root price.
    /// @dev Uses two precision paths to avoid overflow across the supported uint256 range.
    /// @param amount0 Amount of the address-sorted currency0.
    /// @param amount1 Amount of the address-sorted currency1.
    /// @return result floor(sqrt(amount1 / amount0) * 2^96).
    function sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160 result) {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();

        if (amount0 > type(uint192).max || amount1 < (amount0 << 64)) {
            uint256 ratioX192 = FullMath.mulDiv(amount1, 1 << 192, amount0);
            uint256 root = Math.sqrt(ratioX192);
            if (root > type(uint160).max) revert UnsupportedPrice();
            return uint160(root);
        }

        if (amount0 <= type(uint128).max && amount1 >= (amount0 << 128)) revert UnsupportedPrice();
        uint256 ratioX128 = FullMath.mulDiv(amount1, 1 << 128, amount0);
        uint256 rootX64 = Math.sqrt(ratioX128);
        if (rootX64 > type(uint128).max) revert UnsupportedPrice();
        result = uint160(rootX64 << 32);
    }
}
