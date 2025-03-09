// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title LendefiRates
 * @notice Library for core calculation functions used by Lendefi protocol
 * @dev Contains math-heavy functions to reduce main contract size
 */

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ILendefiAssets} from "../../interfaces/ILendefiAssets.sol";
import {IPROTOCOL} from "../../interfaces/IProtocol.sol";

library LendefiRates {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev base scale
    uint256 internal constant WAD = 1e6;
    /// @dev ray scale
    uint256 internal constant RAY = 1e27;
    /// @dev seconds per year on ray scale
    uint256 internal constant SECONDS_PER_YEAR_RAY = 365 * 86400 * RAY;

    /**
     * @dev rmul function
     * @param x amount
     * @param y amount
     * @return z value
     */
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = ((x * y) + RAY / 2) / RAY;
    }

    /**
     * @dev rdiv function
     * @param x amount
     * @param y amount
     * @return z value
     */
    function rdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = ((x * RAY) + y / 2) / y;
    }

    /**
     * @dev rpow function - Calculates x raised to the power of n with RAY precision
     * @param x base value (in RAY precision)
     * @param n exponent
     * @return z result (in RAY precision)
     */
    function rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        // Initialize result to RAY (1.0 in ray precision)
        z = RAY;

        // Early return for x^0 = 1 and x^1 = x cases
        if (n == 0) {
            return z;
        }
        if (n == 1) {
            return x;
        }

        // Binary exponentiation algorithm
        while (n > 0) {
            // If the lowest bit of n is 1, multiply result by x
            if (n & 1 == 1) {
                z = rmul(z, x);
            }
            // Square the base
            x = rmul(x, x);
            // Shift n right by one bit (divide by 2)
            n = n >> 1;
        }
    }

    /**
     * @dev Converts rate to rateRay
     * @param rate rate
     * @return r rateRay
     */
    function annualRateToRay(uint256 rate) internal pure returns (uint256 r) {
        r = RAY + rdiv((rate * RAY) / WAD, SECONDS_PER_YEAR_RAY);
    }

    /**
     * @dev Accrues compounded interest
     * @param principal amount
     * @param rateRay rateray
     * @param time duration
     * @return amount (principal + compounded interest)
     */
    function accrueInterest(uint256 principal, uint256 rateRay, uint256 time) internal pure returns (uint256) {
        return rmul(principal, rpow(rateRay, time));
    }

    /**
     * @dev Calculates compounded interest
     * @param principal amount
     * @param rateRay rateray
     * @param time duration
     * @return amount (compounded interest)
     */
    function getInterest(uint256 principal, uint256 rateRay, uint256 time) internal pure returns (uint256) {
        return rmul(principal, rpow(rateRay, time)) - principal;
    }

    /**
     * @dev Calculates breakeven borrow rate
     * @param loan amount
     * @param supplyInterest amount
     * @return breakeven borrow rate
     */
    function breakEvenRate(uint256 loan, uint256 supplyInterest) internal pure returns (uint256) {
        return ((WAD * (loan + supplyInterest)) / loan) - WAD;
    }

    /**
     * @notice Calculates debt with accrued interest
     * @param debtAmount Current debt amount
     * @param borrowRate Borrow rate for the tier
     * @param timeElapsed Time since last accrual
     * @return Total debt with interest
     */
    function calculateDebtWithInterest(uint256 debtAmount, uint256 borrowRate, uint256 timeElapsed)
        internal
        pure
        returns (uint256)
    {
        if (debtAmount == 0) return 0;
        return accrueInterest(debtAmount, annualRateToRay(borrowRate), timeElapsed);
    }

    /**
     * @notice Calculates credit limit for a position
     * @param assets Set of assets in the position
     * @param positionCollateralAmounts Mapping of asset to collateral amount
     * @param assetsModule Interface to the assets module
     * @return credit limit in USD
     */
    function calculateCreditLimit(
        EnumerableSet.AddressSet storage assets,
        mapping(address => uint256) storage positionCollateralAmounts,
        ILendefiAssets assetsModule
    ) internal view returns (uint256 credit) {
        if (assets.length() == 0) return 0;
        // Works for both isolated and cross-collateral positions
        uint256 len = assets.length();
        for (uint256 i; i < len; i++) {
            address asset = assets.at(i);
            uint256 amount = positionCollateralAmounts[asset];
            if (amount > 0) {
                ILendefiAssets.Asset memory item = assetsModule.getAssetInfo(asset);
                credit += (amount * assetsModule.getAssetPriceOracle(item.oracleUSD) * item.borrowThreshold * WAD)
                    / (10 ** item.decimals * 1000 * 10 ** item.oracleDecimals);
            }
        }
    }

    /**
     * @notice Calculates raw collateral value
     * @param assets Set of assets in the position
     * @param positionCollateralAmounts Mapping of asset to collateral amount
     * @param assetsModule Interface to the assets module
     * @return value Collateral value in USD
     */
    function calculateCollateralValue(
        EnumerableSet.AddressSet storage assets,
        mapping(address => uint256) storage positionCollateralAmounts,
        ILendefiAssets assetsModule
    ) internal view returns (uint256 value) {
        if (assets.length() == 0) return 0;
        uint256 len = assets.length();
        for (uint256 i; i < len; i++) {
            address asset = assets.at(i);
            uint256 amount = positionCollateralAmounts[asset];
            if (amount > 0) {
                ILendefiAssets.Asset memory item = assetsModule.getAssetInfo(asset);
                value += (amount * assetsModule.getAssetPriceOracle(item.oracleUSD) * WAD)
                    / (10 ** item.decimals * 10 ** item.oracleDecimals);
            }
        }
        return value;
    }

    /**
     * @notice Calculates health factor for a position
     * @param assets Set of assets in the position
     * @param positionCollateralAmounts Mapping of asset to collateral amount
     * @param debt Current debt with interest
     * @param assetsModule Interface to the assets module
     * @return Health factor (>1 is healthy)
     */
    function healthFactor(
        EnumerableSet.AddressSet storage assets,
        mapping(address => uint256) storage positionCollateralAmounts,
        uint256 debt,
        ILendefiAssets assetsModule
    ) internal view returns (uint256) {
        if (debt == 0) return type(uint256).max;

        uint256 liqLevel;
        uint256 len = assets.length();
        for (uint256 i; i < len; i++) {
            address asset = assets.at(i);
            uint256 amount = positionCollateralAmounts[asset];

            if (amount != 0) {
                ILendefiAssets.Asset memory item = assetsModule.getAssetInfo(asset);
                liqLevel += (
                    amount * assetsModule.getAssetPriceOracle(item.oracleUSD) * item.liquidationThreshold * WAD
                ) / (10 ** item.decimals * 1000 * 10 ** item.oracleDecimals);
            }
        }

        return (liqLevel * WAD) / debt;
    }

    /**
     * @notice Determines highest risk tier in the position
     * @param assets Set of assets in the position
     * @param positionCollateralAmounts Mapping of asset to collateral amount
     * @param assetsModule Interface to the assets module
     * @return Highest tier among position's assets
     */
    function getHighestTier(
        EnumerableSet.AddressSet storage assets,
        mapping(address => uint256) storage positionCollateralAmounts,
        ILendefiAssets assetsModule
    ) internal view returns (ILendefiAssets.CollateralTier) {
        uint256 len = assets.length();
        ILendefiAssets.CollateralTier tier = ILendefiAssets.CollateralTier.STABLE;

        for (uint256 i; i < len; i++) {
            address asset = assets.at(i);
            uint256 amount = positionCollateralAmounts[asset];

            if (amount > 0) {
                ILendefiAssets.Asset memory assetConfig = assetsModule.getAssetInfo(asset);
                if (uint8(assetConfig.tier) > uint8(tier)) {
                    tier = assetConfig.tier;
                }
            }
        }

        return tier;
    }

    /**
     * @notice Calculates supply rate based on protocol metrics
     * @param totalSupply Total LP token supply
     * @param totalBorrow Current borrowed amount
     * @param totalSuppliedLiquidity Total liquidity supplied
     * @param baseProfitTarget Protocol profit target
     * @param usdcBalance Current USDC balance
     * @return Supply rate in parts per million
     */
    function getSupplyRate(
        uint256 totalSupply,
        uint256 totalBorrow,
        uint256 totalSuppliedLiquidity,
        uint256 baseProfitTarget,
        uint256 usdcBalance
    ) internal pure returns (uint256) {
        if (totalSuppliedLiquidity == 0) return 0;

        uint256 fee;
        uint256 target = (totalSupply * baseProfitTarget) / WAD;
        uint256 total = usdcBalance + totalBorrow;

        if (total >= totalSuppliedLiquidity + target) {
            fee = target;
        }

        return ((WAD * total) / (totalSuppliedLiquidity + fee)) - WAD;
    }

    /**
     * @notice Calculates borrow rate for a tier
     * @param utilization Protocol utilization rate
     * @param baseBorrowRate Base borrow rate
     * @param baseProfitTarget Protocol profit target
     * @param supplyRate Current supply rate
     * @param tierJumpRate Jump rate for the tier
     * @return Borrow rate in parts per million
     */
    function getBorrowRate(
        uint256 utilization,
        uint256 baseBorrowRate,
        uint256 baseProfitTarget,
        uint256 supplyRate,
        uint256 tierJumpRate
    ) internal pure returns (uint256) {
        if (utilization == 0) return baseBorrowRate;

        uint256 duration = 365 days;
        uint256 defaultSupply = WAD;
        uint256 loan = (defaultSupply * utilization) / WAD;

        // Calculate base rate from supply rate
        uint256 supplyRateRay = annualRateToRay(supplyRate);
        uint256 supplyInterest = getInterest(defaultSupply, supplyRateRay, duration);
        uint256 breakEven = breakEvenRate(loan, supplyInterest);

        // Calculate final rate with tier premium
        uint256 rate = breakEven + baseProfitTarget;
        uint256 baseRate = rate > baseBorrowRate ? rate : baseBorrowRate;

        return baseRate + ((tierJumpRate * utilization) / WAD);
    }

    /**
     * @notice Calculates utilization rate
     * @param totalBorrow Total borrowed amount
     * @param totalSuppliedLiquidity Total supplied liquidity
     * @return Utilization rate scaled by WAD
     */
    function getUtilization(uint256 totalBorrow, uint256 totalSuppliedLiquidity) internal pure returns (uint256) {
        if (totalSuppliedLiquidity == 0) return 0;
        return (totalBorrow * WAD) / totalSuppliedLiquidity;
    }

    /**
     * @notice Calculates liquidation fee for a position
     * @param assets Set of collateral assets in position
     * @param positionCollateralAmounts Mapping of asset to collateral amount
     * @param assetsModule Interface to the assets module
     * @return Liquidation fee as percentage in WAD format
     */
    function getPositionLiquidationFee(
        EnumerableSet.AddressSet storage assets,
        mapping(address => uint256) storage positionCollateralAmounts,
        ILendefiAssets assetsModule
    ) internal view returns (uint256) {
        // For non-isolated positions, use highest tier
        ILendefiAssets.CollateralTier tier = getHighestTier(assets, positionCollateralAmounts, assetsModule);
        return assetsModule.getLiquidationFee(tier);
    }
}
