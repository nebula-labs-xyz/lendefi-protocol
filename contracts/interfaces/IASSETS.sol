// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title ILendefiAssets
 * @notice Interface for the LendefiAssets contract
 * @dev Manages asset configurations, listings, and oracle integrations
 */

import {IPROTOCOL} from "./IProtocol.sol";

interface IASSETS {
    // ==================== STRUCTS ====================
    /**
     * @notice Information about a scheduled contract upgrade
     */
    struct UpgradeRequest {
        address implementation;
        uint64 scheduledTime;
        bool exists;
    }

    /**
     * @notice Configuration for Uniswap V3 pool-based oracle
     */
    struct UniswapPoolConfig {
        address pool;
        address quoteToken;
        bool isToken0;
        uint8 decimalsUniswap;
        uint32 twapPeriod;
        uint8 active;
    }

    /**
     * @notice Configuration for Chainlink oracle
     */
    struct ChainlinkOracleConfig {
        address oracleUSD;
        uint8 oracleDecimals;
        uint8 active;
    }

    /**
     * @notice Asset configuration
     */
    struct Asset {
        uint8 active;
        uint8 decimals;
        uint16 borrowThreshold;
        uint16 liquidationThreshold;
        uint256 maxSupplyThreshold;
        uint256 isolationDebtCap;
        uint8 assetMinimumOracles;
        OracleType primaryOracleType;
        CollateralTier tier;
        ChainlinkOracleConfig chainlinkConfig;
        UniswapPoolConfig poolConfig;
    }

    /**
     * @notice Rate configuration for each collateral tier
     */
    struct TierRates {
        uint256 jumpRate;
        uint256 liquidationFee;
    }

    /**
     * @notice Global oracle configuration
     */
    struct MainOracleConfig {
        uint80 freshnessThreshold;
        uint80 volatilityThreshold;
        uint40 volatilityPercentage;
        uint40 circuitBreakerThreshold;
    }

    // Add to IASSETS.sol
    struct AssetCalculationParams {
        uint256 price; // Current asset price
        uint16 borrowThreshold; // For credit limit calculations
        uint16 liquidationThreshold; // For health factor calculations
        uint8 decimals; // Asset decimals
    }
    // ==================== ENUMS ====================
    /**
     * @notice Collateral tiers for assets
     */

    enum CollateralTier {
        STABLE,
        CROSS_A,
        CROSS_B,
        ISOLATED
    }

    /**
     * @notice Oracle types
     */
    enum OracleType {
        CHAINLINK,
        UNISWAP_V3_TWAP
    }

    // ==================== EVENTS ====================
    event CoreAddressUpdated(address indexed newCore);
    event UpdateAssetConfig(Asset config);
    event AssetTierUpdated(address indexed asset, CollateralTier tier);
    event PrimaryOracleSet(address indexed asset, OracleType oracleType);
    event AssetMinimumOraclesUpdated(address indexed asset, uint256 oldValue, uint256 newValue);
    event CircuitBreakerTriggered(address indexed asset, uint256 oldPrice, uint256 newPrice);
    event CircuitBreakerReset(address indexed asset);
    event FreshnessThresholdUpdated(uint256 oldValue, uint256 newValue);
    event VolatilityThresholdUpdated(uint256 oldValue, uint256 newValue);
    event VolatilityPercentageUpdated(uint256 oldValue, uint256 newValue);
    event CircuitBreakerThresholdUpdated(uint256 oldValue, uint256 newValue);
    event TierParametersUpdated(CollateralTier indexed tier, uint256 jumpRate, uint256 liquidationFee);
    event UpgradeScheduled(
        address indexed sender, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );
    event UpgradeCancelled(address indexed sender, address indexed implementation);
    event Upgrade(address indexed sender, address indexed implementation);
    event ChainlinkOracleUpdated(address indexed asset, address indexed oracle, uint8 active);

    // ==================== ERRORS ====================
    error ZeroAddressNotAllowed();
    error AssetNotListed(address asset);
    error AssetNotInUniswapPool(address asset, address pool);
    error TokenNotInUniswapPool(address token, address pool);
    error CircuitBreakerActive(address asset);
    error InvalidParameter(string param, uint256 value);
    error InvalidThreshold(string param, uint256 value, uint256 min, uint256 max);
    error RateTooHigh(uint256 rate, uint256 maxAllowed);
    error FeeTooHigh(uint256 fee, uint256 maxAllowed);
    error NotEnoughValidOracles(address asset, uint8 required, uint8 available);
    error OracleInvalidPrice(address oracle, int256 price);
    error OracleStalePrice(address oracle, uint80 roundId, uint80 answeredInRound);
    error OracleTimeout(address oracle, uint256 timestamp, uint256 blockTimestamp, uint256 threshold);
    error OracleInvalidPriceVolatility(address oracle, int256 price, uint256 changePercent);
    error InvalidUniswapConfig(address asset);
    error InvalidLiquidationThreshold(uint256 threshold);
    error InvalidBorrowThreshold(uint256 threshold);
    error UpgradeNotScheduled();
    error ImplementationMismatch(address expected, address actual);
    error UpgradeTimelockActive(uint256 timeRemaining);

    // ==================== FUNCTIONS ====================

    /**
     * @notice Initialize the contract
     * @param timelock Address with manager role
     * @param guardian Address with admin roles
     */
    function initialize(address timelock, address guardian) external;

    /**
     * @notice Register a Uniswap V3 pool as an oracle for an asset
     * @param asset The asset to register the oracle for
     * @param uniswapPool The Uniswap V3 pool address (must contain the asset)
     * @param quoteToken The quote token (usually a stable or WETH)
     * @param twapPeriod The TWAP period in seconds
     * @param resultDecimals The expected decimals for the price result
     * @param active Whether this oracle is active (0 = inactive, 1 = active)
     */
    function updateUniswapOracle(
        address asset,
        address uniswapPool,
        address quoteToken,
        uint32 twapPeriod,
        uint8 resultDecimals,
        uint8 active
    ) external;

    /**
     * @notice Add a Chainlink oracle for an asset
     * @param asset The asset to add the oracle for
     * @param oracle The oracle address
     * @param decimals The oracle decimals
     * @param active Whether this oracle is active (0 = inactive, 1 = active)
     */
    function updateChainlinkOracle(address asset, address oracle, uint8 decimals, uint8 active) external;

    /**
     * @notice Update main oracle configuration parameters
     * @param freshness Maximum staleness threshold in seconds
     * @param volatility Volatility monitoring period in seconds
     * @param volatilityPct Maximum price change percentage allowed
     * @param circuitBreakerPct Percentage difference that triggers circuit breaker
     */
    function updateMainOracleConfig(uint80 freshness, uint80 volatility, uint40 volatilityPct, uint40 circuitBreakerPct)
        external;

    /**
     * @notice Update rate configuration for a collateral tier
     * @param tier The collateral tier to update
     * @param jumpRate The new jump rate (in basis points * 100)
     * @param liquidationFee The new liquidation fee (in basis points * 100)
     */
    function updateTierConfig(CollateralTier tier, uint256 jumpRate, uint256 liquidationFee) external;

    /**
     * @notice Set the core protocol address
     * @param newCore The new core protocol address
     */
    function setCoreAddress(address newCore) external;

    /**
     * @notice Pause the contract
     */
    function pause() external;

    /**
     * @notice Unpause the contract
     */
    function unpause() external;

    /**
     * @notice Update or add an asset configuration
     * @param asset The asset address to update
     * @param config The complete asset configuration
     */
    function updateAssetConfig(address asset, Asset calldata config) external;

    /**
     * @notice Update the tier of an existing asset
     * @param asset The asset to update
     * @param newTier The new collateral tier
     */
    function updateAssetTier(address asset, CollateralTier newTier) external;

    /**
     * @notice Set the primary oracle type for an asset
     * @param asset The asset address
     * @param oracleType The oracle type to set as primary
     */
    function setPrimaryOracle(address asset, OracleType oracleType) external;

    /**
     * @notice Update the minimum oracle count for an asset
     * @param asset The asset address
     * @param minimum The minimum number of oracles required
     */
    // function updateMinimumOracles(address asset, uint8 minimum) external;

    /**
     * @notice Trigger circuit breaker for an asset (suspend price feeds)
     * @param asset The asset to trigger circuit breaker for
     */
    function triggerCircuitBreaker(address asset) external;

    /**
     * @notice Reset circuit breaker for an asset (resume price feeds)
     * @param asset The asset to reset circuit breaker for
     */
    function resetCircuitBreaker(address asset) external;

    /**
     * @notice Get the oracle address for a specific asset and oracle type
     * @param asset The asset address
     * @param oracleType The oracle type to retrieve
     * @return The oracle address for the specified type
     */
    function getOracleByType(address asset, OracleType oracleType) external view returns (address);

    /**
     * @notice Get the price from a specific oracle type for an asset
     * @param asset The asset to get price for
     * @param oracleType The specific oracle type to query
     * @return The price from the specified oracle type
     */
    function getAssetPriceByType(address asset, OracleType oracleType) external view returns (uint256);

    /**
     * @notice Get asset price using optimal oracle configuration
     * @param asset The asset to get price for
     * @return price The current price of the asset
     */
    function getAssetPrice(address asset) external view returns (uint256 price);

    /**
     * @notice Schedules an upgrade to a new implementation with timelock
     * @param newImplementation Address of the new implementation contract
     */
    function scheduleUpgrade(address newImplementation) external;

    /**
     * @notice Cancels a previously scheduled upgrade
     */
    function cancelUpgrade() external;

    /**
     * @notice Returns the remaining time before a scheduled upgrade can be executed
     * @return The time remaining in seconds
     */
    function upgradeTimelockRemaining() external view returns (uint256);

    /**
     * @notice Get comprehensive details about an asset
     * @param asset The asset address
     * @return price Current asset price
     * @return totalSupplied Total amount supplied to the protocol
     * @return maxSupply Maximum supply threshold
     * @return tier Collateral tier of the asset
     */
    function getAssetDetails(address asset)
        external
        view
        returns (uint256 price, uint256 totalSupplied, uint256 maxSupply, CollateralTier tier);

    /**
     * @notice Get rates for all tiers
     * @return jumpRates Array of jump rates for all tiers
     * @return liquidationFees Array of liquidation fees for all tiers
     */
    function getTierRates() external view returns (uint256[4] memory jumpRates, uint256[4] memory liquidationFees);

    /**
     * @notice Get jump rate for a specific tier
     * @param tier The collateral tier
     * @return The jump rate for the tier
     */
    function getTierJumpRate(CollateralTier tier) external view returns (uint256);

    /**
     * @notice Check if an asset is valid (listed and active)
     * @param asset The asset to check
     * @return Whether the asset is valid
     */
    function isAssetValid(address asset) external view returns (bool);

    /**
     * @notice Check if adding more supply would exceed an asset's capacity
     * @param asset The asset to check
     * @param additionalAmount The additional amount to supply
     * @return Whether the asset would be at capacity after adding the amount
     */
    function isAssetAtCapacity(address asset, uint256 additionalAmount) external view returns (bool);

    /**
     * @notice Get full asset configuration
     * @param asset The asset address
     * @return The complete asset configuration
     */
    function getAssetInfo(address asset) external view returns (Asset memory);

    /**
     * @notice Get all listed assets
     * @return Array of listed asset addresses
     */
    function getListedAssets() external view returns (address[] memory);

    /**
     * @notice Get liquidation fee for a collateral tier
     * @param tier The collateral tier
     * @return The liquidation fee for the tier
     */
    function getLiquidationFee(CollateralTier tier) external view returns (uint256);

    /**
     * @notice Check if an asset is in the isolated tier
     * @param asset The asset to check
     * @return tier Whether the asset is isolated
     */
    function getAssetTier(address asset) external view returns (CollateralTier tier);

    /**
     * @notice Get the asset decimals
     * @param asset The asset to query
     * @return decimals
     */
    function getAssetDecimals(address asset) external view returns (uint8);

    /**
     * @notice Get the asset liquidation threshold
     * @param asset The asset to query
     * @return liq threshold
     */
    function getAssetLiquidationThreshold(address asset) external view returns (uint16);

    /**
     * @notice Get the asset borrow threshold
     * @param asset The asset to query
     * @return borrow threshold
     */
    function getAssetBorrowThreshold(address asset) external view returns (uint16);

    /**
     * @notice Get the debt cap for an isolated asset
     * @param asset The asset to query
     * @return The isolation debt cap
     */
    function getIsolationDebtCap(address asset) external view returns (uint256);

    /**
     * @notice Get the number of active oracles for an asset
     * @param asset The asset to check
     * @return The count of active oracles
     */
    function getOracleCount(address asset) external view returns (uint256);

    /**
     * @notice Check for price deviation without modifying state
     * @param asset The asset to check
     * @return Whether the asset has a large price deviation and the deviation percentage
     */
    function checkPriceDeviation(address asset) external view returns (bool, uint256);

    /**
     * @notice Get protocol version
     * @return The current protocol version
     */
    function version() external view returns (uint8);

    /**
     * @notice Get the core protocol address
     * @return The address of the core protocol
     */
    function coreAddress() external view returns (address);

    /**
     * @notice Get circuit breaker status for an asset
     * @param asset The asset to check
     * @return Whether the circuit breaker is active
     */
    function circuitBroken(address asset) external view returns (bool);

    /**
     * @notice Get tier configuration for a specific collateral tier
     * @param tier The collateral tier to query
     * @return The tier rates configuration
     */
    // function tierConfig(CollateralTier tier) external view returns (TierRates memory);

    /**
     * @notice Get the current upgrade timelock duration
     * @return The timelock duration in seconds
     */
    function UPGRADE_TIMELOCK_DURATION() external view returns (uint256);

    /**
     * @notice Get information about a pending upgrade
     * @return The pending upgrade request
     */
    // function pendingUpgrade() external view returns (UpgradeRequest memory);

    /**
     * @notice Get the main oracle configuration
     * @return The current oracle configuration
     */
    // function mainOracleConfig() external view returns (MainOracleConfig memory);

    /**
     * @notice Gets all parameters needed for collateral calculations in a single call
     * @dev Consolidates multiple getter calls into a single cross-contract call
     * @param asset Address of the asset to query
     * @return Struct containing price, thresholds and decimals
     */
    function getAssetCalculationParams(address asset) external view returns (AssetCalculationParams memory);
}
