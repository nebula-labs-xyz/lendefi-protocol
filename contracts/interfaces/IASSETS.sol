// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {AggregatorV3Interface} from "../vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";

interface IASSETS {
    enum OracleType {
        CHAINLINK, // Default Chainlink Oracle (8 decimals)
        UNISWAP_V3_TWAP // Uniswap V3 TWAP Oracle

    }

    enum CollateralTier {
        STABLE,
        CROSS_A,
        CROSS_B,
        ISOLATED
    }

    struct Asset {
        address oracleUSD;
        uint8 active;
        uint8 oracleDecimals;
        uint8 decimals;
        uint32 borrowThreshold;
        uint32 liquidationThreshold;
        uint256 maxSupplyThreshold;
        uint256 isolationDebtCap;
        CollateralTier tier;
        uint8 oracleType;
    }

    struct TierRates {
        uint256 jumpRate;
        uint256 liquidationFee;
    }

    struct OracleConfig {
        uint80 freshnessThreshold;
        uint80 volatilityThreshold;
        uint40 volatilityPercentage;
        uint40 circuitBreakerThreshold;
        uint16 minimumOraclesRequired;
    }

    struct UniswapOracleConfig {
        address pool;
        address quoteToken;
        bool isToken0;
        uint32 twapPeriod;
    }

    // Events
    event OracleAdded(address indexed asset, address indexed oracle);
    event OracleRemoved(address indexed asset, address indexed oracle);
    event PrimaryOracleSet(address indexed asset, address indexed oracle);
    event Upgrade(address indexed account, address indexed implementation);
    event CoreAddressUpdated(address newCore);
    event UpdateAssetConfig(address indexed asset);
    event AssetTierUpdated(address indexed asset, CollateralTier tier);
    event CircuitBreakerTriggered(address indexed asset, uint256 oldPrice, uint256 newPrice);
    event CircuitBreakerReset(address indexed asset);
    event AssetMinimumOraclesUpdated(address indexed asset, uint256 oldMinimum, uint256 newMinimum);
    event TierParametersUpdated(CollateralTier tier, uint256 jumpRate, uint256 liquidationFee);
    event NotEnoughOraclesWarning(address indexed asset, uint256 required, uint256 available);
    event FreshnessThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event VolatilityThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event VolatilityPercentageUpdated(uint256 oldPercentage, uint256 newPercentage);
    event CircuitBreakerThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event MinimumOraclesUpdated(uint256 oldMinimum, uint256 newMinimum);
    event OracleTypeSet(address indexed asset, address indexed oracle, uint8 oracleType);
    event UniswapOracleAdded(address indexed asset, address indexed virtualOracle, address pool, uint32 twapPeriod);
    event OracleReplaced(address indexed asset, address indexed oldOracle, address indexed newOracle, uint8 oracleType);
    // Errors

    error AssetNotListed(address asset);
    error OracleNotFound(address asset);
    error OracleAlreadyAdded(address asset, address oracle);
    error OracleInvalidPrice(address oracle, int256 price);
    error OracleStalePrice(address oracle, uint80 roundId, uint80 answeredInRound);
    error OracleTimeout(address oracle, uint256 timestamp, uint256 now, uint256 threshold);
    error OracleInvalidPriceVolatility(address oracle, int256 price, uint256 changePercent);
    error NotEnoughValidOracles(address asset, uint256 required, uint256 available);
    error InvalidOracle(address oracle);
    error ZeroAddressNotAllowed();
    error InvalidThreshold(string param, uint256 value, uint256 min, uint256 max);
    error RateTooHigh(uint256 rate, uint256 maxRate);
    error FeeTooHigh(uint256 fee, uint256 maxFee);
    error InvalidLiquidationThreshold(uint32 threshold);
    error InvalidBorrowThreshold(uint32 threshold);
    error AssetNotInUniswapPool(address asset, address pool);
    error TokenNotInUniswapPool(address token, address pool);
    error InvalidUniswapConfig(address virtualOracle);
    error CircuitBreakerActive(address asset);
    error OracleTypeAlreadyAdded(address asset, OracleType oracleType);

    function initialize(address timelock, address guardian) external;

    function addUniswapOracle(
        address asset,
        address uniswapPool,
        address quoteToken,
        uint32 twapPeriod,
        uint8 resultDecimals
    ) external;

    function addOracle(address asset, address oracle, uint8 decimals_, OracleType oracleType) external;

    function updateOracleConfig(
        uint80 freshness,
        uint80 volatility,
        uint40 volatilityPct,
        uint40 circuitBreakerPct,
        uint16 minOracles
    ) external;

    function updateTierConfig(CollateralTier tier, uint256 jumpRate, uint256 liquidationFee) external;

    function updateAllTierConfigs(uint256[4] calldata jumpRates, uint256[4] calldata liquidationFees) external;

    function setCoreAddress(address newCore) external;

    function pause() external;

    function unpause() external;

    function updateAssetConfig(
        address asset,
        address oracle_,
        uint8 oracleDecimals_,
        uint8 assetDecimals,
        uint8 active,
        uint32 borrowThreshold,
        uint32 liquidationThreshold,
        uint256 maxSupplyLimit,
        uint256 isolationDebtCap,
        CollateralTier tier,
        OracleType oracleType
    ) external;

    function updateAssetTier(address asset, CollateralTier newTier) external;

    function removeOracle(address asset, address oracle) external;

    function setPrimaryOracle(address asset, address oracle) external;

    function updateMinimumOracles(address asset, uint256 minimum) external;

    function triggerCircuitBreaker(address asset) external;

    function resetCircuitBreaker(address asset) external;

    function getAssetPrice(address asset) external view returns (uint256);

    function getAssetPriceOracle(address oracle) external view returns (uint256);

    function getAssetDetails(address asset)
        external
        view
        returns (uint256 price, uint256 totalSupplied, uint256 maxSupply, CollateralTier tier);

    function getTierRates() external view returns (uint256[4] memory jumpRates, uint256[4] memory liquidationFees);

    function getTierLiquidationFee(CollateralTier tier) external view returns (uint256);

    function getTierJumpRate(CollateralTier tier) external view returns (uint256);

    function isAssetValid(address asset) external view returns (bool);

    function isAssetAtCapacity(address asset, uint256 additionalAmount) external view returns (bool);

    function getAssetInfo(address asset) external view returns (Asset memory);

    function getListedAssets() external view returns (address[] memory);

    function getLiquidationFee(CollateralTier tier) external view returns (uint256);

    function isIsolationAsset(address asset) external view returns (bool);

    function getIsolationDebtCap(address asset) external view returns (uint256);

    function getOracleCount(address asset) external view returns (uint256);

    function getAssetOracles(address asset) external view returns (address[] memory);

    function checkPriceDeviation(address asset) external view returns (bool, uint256);

    function getSingleOraclePrice(address oracle) external view returns (uint256);

    function getOracleConfig()
        external
        view
        returns (
            uint256 freshness,
            uint256 volatility,
            uint256 volatilityPct,
            uint256 circuitBreakerPct,
            uint256 minOracles
        );

    function version() external view returns (uint8);

    function coreAddress() external view returns (address);
    // function tierConfig(CollateralTier) external view returns (TierRates memory);
    // function uniswapConfigs(address) external view returns (UniswapOracleConfig memory);
    function primaryOracle(address) external view returns (address);

    function oracleDecimals(address) external view returns (uint8);

    function assetMinimumOracles(address) external view returns (uint256);

    function circuitBroken(address) external view returns (bool);

    function oracleTypes(address) external view returns (OracleType);
}
