// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/libraries/FullMath.sol";
import "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title Uniswap tick math wrapper for price calculations
/// @notice Uses Uniswap v4 core libraries for accuracy and consistency, backward compatible with v3
library UniswapTickMath {
    function getNextSqrtPriceFromInput(uint160 sqrtPriceX96, uint128 liquidity, uint256 amountIn, bool isToken0)
        internal
        pure
        returns (uint160)
    {
        return SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountIn, isToken0);
    }

    function getQuoteAtTick(int24 tick) internal pure returns (uint256) {
        uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);

        // We're calculating a price, so we need a "base amount" - use 1e6 for USDC decimals
        uint256 baseAmount = 1e8;

        // Calculate price with proper precision
        uint256 ratioX192 = uint256(sqrtRatioX96) * uint256(sqrtRatioX96);
        return FullMath.mulDiv(ratioX192, baseAmount, 1 << 192);
    }

    /// @notice Calculates price from sqrt price for token0/token1 pair
    /// @param sqrtPriceX96 The sqrt price in X96 format
    /// @param isToken0 Whether to calculate price for token0 or token1
    /// @return price The calculated price in 1e6 (USDC) precision
    function getPriceFromSqrtPrice(uint160 sqrtPriceX96, bool isToken0) internal pure returns (uint256 price) {
        if (isToken0) {
            // token0/token1 price = sqrtPrice^2 / 2^192 * 1e6
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            return FullMath.mulDiv(ratioX192, 1e6, 1 << 192);
        } else {
            // token1/token0 price = 2^192 / sqrtPrice^2 * 1e6
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            return FullMath.mulDiv(1 << 192, 1e6, ratioX192);
        }
    }

    /// @notice Calculates average price between current and impacted price
    /// @param currentSqrtPriceX96 Current sqrt price in X96 format
    /// @param impactedSqrtPriceX96 Price after impact in X96 format
    /// @param isToken0 Whether to calculate price for token0 or token1
    /// @return price The average price in 1e6 (USDC) precision
    function getAveragePriceFromImpact(uint160 currentSqrtPriceX96, uint160 impactedSqrtPriceX96, bool isToken0)
        internal
        pure
        returns (uint256 price)
    {
        uint256 currentPrice = getPriceFromSqrtPrice(currentSqrtPriceX96, isToken0);
        uint256 impactedPrice = getPriceFromSqrtPrice(impactedSqrtPriceX96, isToken0);
        return (currentPrice + impactedPrice) / 2;
    }
}
