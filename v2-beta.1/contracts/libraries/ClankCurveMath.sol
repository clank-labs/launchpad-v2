// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Clank bonding-curve mathematics
/// @notice Contains fee conversions and virtual-reserve XYK quote functions.
/// @dev Rounding deliberately favours protocol solvency: outputs round down while required
/// inputs and fees round up.
library ClankCurveMath {
    error GraduationQuoteTooLarge();

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_GRADUATION_QUOTE = uint256(uint128(type(int128).max));
    uint256 internal constant TOKEN_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant MIGRATION_TOKENS = 220_000_000 ether;
    uint256 internal constant SOLD_TOKENS = TOKEN_SUPPLY - MIGRATION_TOKENS;
    uint256 internal constant ALLOCATION_DIFFERENCE = SOLD_TOKENS - MIGRATION_TOKENS;
    // U = L^2 / (A - L). Round down by less than one token base unit.
    uint256 internal constant VIRTUAL_TOKENS = MIGRATION_TOKENS * MIGRATION_TOKENS / ALLOCATION_DIFFERENCE;
    // Absolute full-range V4 seed boundary for the fixed allocation at tick spacing 1 with the token sorted first.
    // The boundary leaves no rounding headroom: intermediate trades near it may revert when their projected terminal
    // liquidity exceeds V4's per-tick cap. We deliberately retain the theoretical maximum for initial configuration
    // and rely on the curve's per-trade graduation validation to ensure every accepted state remains migratable.
    uint256 internal constant MAX_PHANTOM_QUOTE = 65_662_411_597_810_441_635_668_862_687_492_298_262;

    /// @notice Required net quote threshold for the fixed 780M/220M allocation.
    /// @dev Quote inputs are bounded to uint128 by callers; multiplication cannot overflow.
    function graduationThreshold(uint256 phantomQuote) internal pure returns (uint256) {
        return Math.mulDiv(phantomQuote, ALLOCATION_DIFFERENCE, MIGRATION_TOKENS);
    }

    /// @notice Quote required to sell the allocation in one trade, including integer rounding.
    function minimumTerminalQuote(uint256 phantomQuote) internal pure returns (uint256) {
        return requiredBuyInput(phantomQuote, TOKEN_SUPPLY + VIRTUAL_TOKENS, SOLD_TOKENS);
    }

    /// @notice Rejects trades whose rounded reserves would exceed V4's signed quote limit at graduation.
    function validateGraduationQuote(uint256 realQuote, uint256 realTokens, uint256 phantomQuote)
        internal
        pure
        returns (uint256 terminalQuote)
    {
        terminalQuote = realQuote
            + requiredBuyInput(realQuote + phantomQuote, realTokens + VIRTUAL_TOKENS, realTokens - MIGRATION_TOKENS);
        if (terminalQuote > MAX_GRADUATION_QUOTE) revert GraduationQuoteTooLarge();
    }

    /// @notice Calculates a fee included in a gross amount.
    /// @param grossAmount Total amount including the fee.
    /// @param feeBps Fee rate in basis points.
    /// @return Fee amount rounded up.
    function feeFromGross(uint256 grossAmount, uint256 feeBps) internal pure returns (uint256) {
        return Math.mulDiv(grossAmount, feeBps, BPS, Math.Rounding.Ceil);
    }

    /// @notice Converts a gross amount into the amount available after its included fee.
    /// @param grossAmount Total amount including the fee.
    /// @param feeBps Fee rate in basis points.
    /// @return Net amount rounded down.
    function netFromGross(uint256 grossAmount, uint256 feeBps) internal pure returns (uint256) {
        return Math.mulDiv(grossAmount, BPS - feeBps, BPS);
    }

    /// @notice Calculates the gross amount required to produce an exact net amount.
    /// @param netAmount Amount that must remain after the fee.
    /// @param feeBps Fee rate in basis points.
    /// @return Gross amount rounded up.
    function grossFromNet(uint256 netAmount, uint256 feeBps) internal pure returns (uint256) {
        return Math.mulDiv(netAmount, BPS, BPS - feeBps, Math.Rounding.Ceil);
    }

    /// @notice Quotes token output for a net quote-asset input.
    /// @param effectiveQuote Virtual plus tracked real quote reserve before the trade.
    /// @param tokenReserve Virtual plus tracked real token reserve before the trade.
    /// @param netQuoteIn Quote amount entering the pricing reserve after fees.
    /// @return Token output rounded down.
    function buyOutput(uint256 effectiveQuote, uint256 tokenReserve, uint256 netQuoteIn)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(netQuoteIn, tokenReserve, effectiveQuote + netQuoteIn);
    }

    /// @notice Quotes the net quote input required for an exact token output.
    /// @param effectiveQuote Virtual plus tracked real quote reserve before the trade.
    /// @param tokenReserve Virtual plus tracked real token reserve before the trade.
    /// @param tokensOut Exact token amount requested.
    /// @return Required quote input rounded up.
    function requiredBuyInput(uint256 effectiveQuote, uint256 tokenReserve, uint256 tokensOut)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(effectiveQuote, tokensOut, tokenReserve - tokensOut, Math.Rounding.Ceil);
    }

    /// @notice Quotes gross quote output for a token input.
    /// @param effectiveQuote Virtual plus tracked real quote reserve before the trade.
    /// @param tokenReserve Virtual plus tracked real token reserve before the trade.
    /// @param tokensIn Token amount entering the reserve.
    /// @return Gross quote output rounded down.
    function sellOutput(uint256 effectiveQuote, uint256 tokenReserve, uint256 tokensIn)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(effectiveQuote, tokensIn, tokenReserve + tokensIn);
    }
}
