// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IUniswapV3Pool} from "../../contracts/interfaces/IUniswapV3Pool.sol";

contract MockUniswapV3Pool is IUniswapV3Pool {
    uint256 public mockPrice = 1100e8; // Default mock price
    uint128 private _liquidity = 1_000_000e6; // Default 1M USDC liquidity

    address public override token0;
    address public override token1;
    uint24 public fee;

    int56[] internal tickCumulatives;
    uint160[] internal secondsPerLiquidityCumulativeX128s;
    bool internal observeSuccess;

    constructor(address _token0, address _token1, uint24 _fee) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        observeSuccess = true;

        // Initialize with some default values for TWAP
        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128s = new uint160[](2);

        // Set default values - price slightly increasing over time
        tickCumulatives[0] = 5000000;
        tickCumulatives[1] = 5100000; // Higher value to simulate time passing

        secondsPerLiquidityCumulativeX128s[0] = 1000;
        secondsPerLiquidityCumulativeX128s[1] = 1100;
    }

    function liquidity() external view override returns (uint128) {
        return _liquidity;
    }

    function setLiquidity(uint128 newLiquidity) external {
        require(newLiquidity > 0, "MockUniswapV3Pool: Invalid liquidity");
        _liquidity = newLiquidity;
    }

    function setMockPrice(uint256 price) external {
        mockPrice = price;
    }

    function observe(uint32[] calldata) external view override returns (int56[] memory, uint160[] memory) {
        require(observeSuccess, "MockUniswapV3Pool: Observation failed");
        return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
    }

    function setTokens(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    function setTickCumulatives(int56[] memory _tickCumulatives) external {
        require(_tickCumulatives.length == 2, "MockUniswapV3Pool: Need exactly 2 values");
        tickCumulatives = _tickCumulatives;
    }

    function setSecondsPerLiquidity(uint160[] memory _secondsPerLiquidityCumulativeX128s) external {
        require(_secondsPerLiquidityCumulativeX128s.length == 2, "MockUniswapV3Pool: Need exactly 2 values");
        secondsPerLiquidityCumulativeX128s = _secondsPerLiquidityCumulativeX128s;
    }

    function setObserveSuccess(bool success) external {
        observeSuccess = success;
    }

    function slot0()
        external
        pure
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (
            1 << 96, // sqrtPriceX96 = 1.0
            0, // tick at 0 (price = 1.0)
            0, // observationIndex
            1, // observationCardinality
            1, // observationCardinalityNext
            0, // feeProtocol
            true // unlocked
        );
    }
}
