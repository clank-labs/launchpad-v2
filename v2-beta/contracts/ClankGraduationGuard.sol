// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {ClankMigrationMath} from "./libraries/ClankMigrationMath.sol";
import {ClankCurveMath} from "./libraries/ClankCurveMath.sol";

/// @title Clank graduation preflight
/// @notice Validates that terminal assets produce nonzero full-range liquidity within V4's per-tick limit.
contract ClankGraduationGuard {
    error GraduationSeedNotViable();
    error InvalidAddress();
    error InvalidTickSpacing();
    error SqrtPriceOutOfBounds();

    /// @notice Checks a curve's terminal assets and returns the price used to initialize V4.
    function assertSeedableForCurve(
        address token,
        address pairToken,
        int24 tickSpacing,
        uint256 quoteAmount,
        uint256 tokenAmount,
        uint256 phantomQuote
    ) external pure returns (uint160 price) {
        price = ClankMigrationMath.migrationPrice(token, pairToken, quoteAmount, tokenAmount, phantomQuote);
        _assertSeedableAtPrice(token, pairToken, tickSpacing, quoteAmount, tokenAmount, price);
    }

    function assertSeedable(
        address token,
        address pairToken,
        int24 tickSpacing,
        uint256 quoteAmount,
        uint256 tokenAmount
    ) external pure {
        (uint256 amount0, uint256 amount1) = pairToken < token ? (quoteAmount, tokenAmount) : (tokenAmount, quoteAmount);
        _assertSeedableAtPrice(
            token, pairToken, tickSpacing, quoteAmount, tokenAmount, ClankMigrationMath.sqrtPriceX96(amount0, amount1)
        );
    }

    function _assertSeedableAtPrice(
        address token,
        address pairToken,
        int24 tickSpacing,
        uint256 quoteAmount,
        uint256 tokenAmount,
        uint160 sqrtPriceX96
    ) private pure {
        if (token == address(0)) revert InvalidAddress();
        if (pairToken == token) revert InvalidAddress();
        if (tickSpacing <= 0) revert InvalidTickSpacing();
        if (
            quoteAmount == 0 || tokenAmount == 0 || quoteAmount > ClankCurveMath.MAX_GRADUATION_QUOTE
                || tokenAmount > ClankCurveMath.MAX_GRADUATION_QUOTE
        ) {
            revert GraduationSeedNotViable();
        }

        (uint256 amount0, uint256 amount1) = pairToken < token ? (quoteAmount, tokenAmount) : (tokenAmount, quoteAmount);
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert SqrtPriceOutOfBounds();
        }

        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        if (liquidity == 0 || liquidity > Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing)) {
            revert GraduationSeedNotViable();
        }
    }
}
