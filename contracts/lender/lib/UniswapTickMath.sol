// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/libraries/FullMath.sol";
import "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IUniswapV3Pool} from "../../../contracts/interfaces/IUniswapV3Pool.sol";

/// @title Uniswap tick math wrapper for price calculations
/// @notice Uses Uniswap v4 core libraries for accuracy and consistency, backward compatible with v3
/// @dev This library provides functions to calculate prices from Uniswap V3 pool data
library UniswapTickMath {
    /// @notice Calculates the next sqrt price after a token input
    /// @dev Wrapper around Uniswap's SqrtPriceMath library
    /// @param sqrtPriceX96 The current sqrt price in X96 format
    /// @param liquidity The amount of usable liquidity
    /// @param amountIn The amount of token being swapped in
    /// @param isToken0 Whether the token being swapped in is token0 or token1
    /// @return The next sqrt price after the swap in X96 format
    function getNextSqrtPriceFromInput(uint160 sqrtPriceX96, uint128 liquidity, uint256 amountIn, bool isToken0)
        internal
        pure
        returns (uint160)
    {
        return SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountIn, isToken0);
    }

    /// @notice Calculates price from sqrt price for token0/token1 pair
    /// @dev Uses different formulas based on which token's price is being calculated
    /// @param sqrtPriceX96 The sqrt price in X96 format
    /// @param isToken0 Whether to calculate price for token0 or token1
    /// @param precision The desired precision (e.g., 1e6, 1e18)
    /// @return price The calculated price in the specified precision
    function getPriceFromSqrtPrice(uint160 sqrtPriceX96, bool isToken0, uint256 precision)
        internal
        pure
        returns (uint256 price)
    {
        if (isToken0) {
            // token0/token1 price = sqrtPrice^2 / 2^192 * precision
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            return FullMath.mulDiv(ratioX192, precision, 1 << 192);
        } else {
            // token1/token0 price = 2^192 / sqrtPrice^2 * precision
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            return FullMath.mulDiv(1 << 192, precision, ratioX192);
        }
    }

    /// @notice Gets the raw price from a Uniswap V3 pool using TWAP
    /// @dev Calculates time-weighted average price using tick cumulative data
    /// @param pool The Uniswap V3 pool to query
    /// @param isToken0 Whether to get the price for token0 or token1
    /// @param precision The desired precision for the returned price
    /// @param twapPeriod The period over which to calculate the TWAP (in seconds)
    /// @return rawPrice The calculated raw price with the specified precision
    function getRawPrice(IUniswapV3Pool pool, bool isToken0, uint256 precision, uint32 twapPeriod)
        internal
        view
        returns (uint256 rawPrice)
    {
        // Prepare observation timestamps
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriod; // 30 minutes ago
        secondsAgos[1] = 0; // now

        // Get tick cumulative data from Uniswap
        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 timeWeightedAverageTick = int24(tickCumulativesDelta / int56(uint56(twapPeriod)));

        // Get sqrtPriceX96 from the tick
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(timeWeightedAverageTick);

        // Calculate raw price
        rawPrice = getPriceFromSqrtPrice(sqrtPriceX96, isToken0, precision);
    }

    /// @notice Gets the sqrt price in X96 format for a given tick
    /// @dev Wrapper around Uniswap's TickMath library
    /// @param tick The tick to convert to a sqrt price
    /// @return The sqrt price in X96 format for the given tick
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }
}
