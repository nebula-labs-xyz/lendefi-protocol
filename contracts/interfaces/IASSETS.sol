// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title ILendefiAssets
 * @notice Interface for the LendefiAssets contract
 * @dev Manages asset configurations, listings, and oracle integrations
 */

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
        uint32 twapPeriod;
        uint8 active;
    }

    /**
     * @notice Configuration for Chainlink oracle
     */
    struct ChainlinkOracleConfig {
        address oracleUSD;
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
    // ==================== EVENTS ====================

    /**
     * @notice Emitted when the core protocol address is updated
     * @param newCore Address of the new core protocol
     */
    event CoreAddressUpdated(address indexed newCore);

    /**
     * @notice Emitted when an asset's configuration is updated
     * @param asset Address of the asset being updated
     * @param config New configuration parameters
     */
    event UpdateAssetConfig(address indexed asset, Asset config);

    /**
     * @notice Emitted when an asset's collateral tier is changed
     * @param asset Address of the affected asset
     * @param tier New collateral tier
     */
    event AssetTierUpdated(address indexed asset, CollateralTier tier);

    /**
     * @notice Emitted when the circuit breaker is triggered for an asset
     * @param asset Address of the affected asset
     * @param deviationPct Percentage deviation that triggered the circuit breaker
     * @param timestamp Time when the circuit breaker was triggered
     */
    event CircuitBreakerTriggered(address indexed asset, uint256 deviationPct, uint256 timestamp);

    /**
     * @notice Emitted when a circuit breaker is reset for an asset
     * @param asset Address of the affected asset
     */
    event CircuitBreakerReset(address indexed asset);

    /**
     * @notice Emitted when the oracle freshness threshold is updated
     * @param oldValue Previous freshness threshold in seconds
     * @param newValue New freshness threshold in seconds
     */
    event FreshnessThresholdUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when the oracle volatility threshold is updated
     * @param oldValue Previous volatility threshold in seconds
     * @param newValue New volatility threshold in seconds
     */
    event VolatilityThresholdUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when the oracle volatility percentage is updated
     * @param oldValue Previous volatility percentage
     * @param newValue New volatility percentage
     */
    event VolatilityPercentageUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when the circuit breaker threshold is updated
     * @param oldValue Previous circuit breaker threshold percentage
     * @param newValue New circuit breaker threshold percentage
     */
    event CircuitBreakerThresholdUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when tier parameters are updated
     * @param tier The collateral tier being updated
     * @param jumpRate New jump rate for the tier
     * @param liquidationFee New liquidation fee for the tier
     */
    event TierParametersUpdated(CollateralTier indexed tier, uint256 jumpRate, uint256 liquidationFee);

    /**
     * @notice Emitted when a contract upgrade is scheduled
     * @param sender Address that scheduled the upgrade
     * @param implementation Address of the new implementation
     * @param scheduledTime Timestamp when the upgrade was scheduled
     * @param effectiveTime Timestamp when the upgrade becomes effective
     */
    event UpgradeScheduled(
        address indexed sender, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );

    /**
     * @notice Emitted when a scheduled upgrade is cancelled
     * @param sender Address that cancelled the upgrade
     * @param implementation Address of the cancelled implementation
     */
    event UpgradeCancelled(address indexed sender, address indexed implementation);

    /**
     * @notice Emitted when a contract upgrade is executed
     * @param sender Address that executed the upgrade
     * @param implementation Address of the new implementation
     */
    event Upgrade(address indexed sender, address indexed implementation);

    /**
     * @notice Emitted when a Chainlink oracle is updated for an asset
     * @param asset Address of the affected asset
     * @param oracle Address of the Chainlink oracle
     * @param active Whether the oracle is active (0=inactive, 1=active)
     */
    event ChainlinkOracleUpdated(address indexed asset, address indexed oracle, uint8 active);

    /**
     * @notice Emitted when a Uniswap oracle is updated for an asset
     * @param asset Address of the affected asset
     * @param pool Address of the Uniswap pool
     * @param active Whether the oracle is active (0=inactive, 1=active)
     */
    event UniswapOracleUpdated(address indexed asset, address indexed pool, uint8 active);

    // ==================== ERRORS ====================

    /**
     * @notice Error thrown when a zero address is provided where it's not allowed
     */
    error ZeroAddressNotAllowed();

    /**
     * @notice Error thrown when attempting to use an asset that isn't listed
     * @param asset Address of the unlisted asset
     */
    error AssetNotListed(address asset);

    /**
     * @notice Error thrown when an asset isn't part of the specified Uniswap pool
     * @param asset Address of the asset
     * @param pool Address of the Uniswap pool
     */
    error AssetNotInUniswapPool(address asset, address pool);

    /**
     * @notice Error thrown when attempting to get a price while circuit breaker is active
     * @param asset Address of the affected asset
     */
    error CircuitBreakerActive(address asset);

    /**
     * @notice Error thrown when an invalid parameter value is provided
     * @param param Name of the invalid parameter
     * @param value The invalid value
     */
    error InvalidParameter(string param, uint256 value);

    /**
     * @notice Error thrown when a threshold value is outside allowed range
     * @param param Name of the threshold parameter
     * @param value The provided value
     * @param min Minimum allowed value
     * @param max Maximum allowed value
     */
    error InvalidThreshold(string param, uint256 value, uint256 min, uint256 max);

    /**
     * @notice Error thrown when a rate is set too high
     * @param rate The proposed rate
     * @param maxAllowed Maximum allowed rate
     */
    error RateTooHigh(uint256 rate, uint256 maxAllowed);

    /**
     * @notice Error thrown when a fee is set too high
     * @param fee The proposed fee
     * @param maxAllowed Maximum allowed fee
     */
    error FeeTooHigh(uint256 fee, uint256 maxAllowed);

    /**
     * @notice Error thrown when there aren't enough active oracles for an asset
     * @param asset Address of the affected asset
     * @param required Number of required oracles
     * @param available Number of available oracles
     */
    error NotEnoughValidOracles(address asset, uint8 required, uint8 available);

    /**
     * @notice Error thrown when an oracle returns an invalid price
     * @param oracle Address of the oracle
     * @param price The invalid price
     */
    error OracleInvalidPrice(address oracle, int256 price);

    /**
     * @notice Error thrown when an oracle returns a stale price
     * @param oracle Address of the oracle
     * @param roundId Current round ID
     * @param answeredInRound Round when price was last updated
     */
    error OracleStalePrice(address oracle, uint80 roundId, uint80 answeredInRound);

    /**
     * @notice Error thrown when an oracle price is older than the freshness threshold
     * @param oracle Address of the oracle
     * @param timestamp Timestamp of the price
     * @param blockTimestamp Current block timestamp
     * @param threshold Maximum allowed age in seconds
     */
    error OracleTimeout(address oracle, uint256 timestamp, uint256 blockTimestamp, uint256 threshold);

    /**
     * @notice Error thrown when price volatility exceeds allowed threshold
     * @param oracle Address of the oracle
     * @param price Current price
     * @param changePercent Percentage change from previous price
     */
    error OracleInvalidPriceVolatility(address oracle, int256 price, uint256 changePercent);

    /**
     * @notice Error thrown when a Uniswap oracle is improperly configured
     * @param asset Address of the affected asset
     */
    error InvalidUniswapConfig(address asset);

    /**
     * @notice Error thrown when an invalid liquidation threshold is provided
     * @param threshold The invalid threshold
     */
    error InvalidLiquidationThreshold(uint256 threshold);

    /**
     * @notice Error thrown when an invalid borrow threshold is provided
     * @param threshold The invalid threshold
     */
    error InvalidBorrowThreshold(uint256 threshold);

    /**
     * @notice Error thrown when trying to execute an upgrade that wasn't scheduled
     */
    error UpgradeNotScheduled();

    /**
     * @notice Error thrown when the implementation address doesn't match expected
     * @param expected The expected implementation address
     * @param actual The actual implementation address
     */
    error ImplementationMismatch(address expected, address actual);

    /**
     * @notice Error thrown when trying to execute an upgrade before timelock expires
     * @param timeRemaining Time remaining until upgrade becomes executable
     */
    error UpgradeTimelockActive(uint256 timeRemaining);

    /**
     * @notice Error thrown when trying to use an oracle that isn't active
     * @param asset Address of the affected asset
     * @param oracleType Type of oracle being used
     */
    error OracleNotActive(address asset, OracleType oracleType);

    /**
     * @notice Error thrown when too many assets are listed
     * @param maxAllowedAssets Maximum allowed assets
     */
    error AssetListTooLarge(uint32 maxAllowedAssets);

    // ==================== FUNCTIONS ====================

    /**
     * @notice Initialize the contract
     * @param timelock Address with manager role
     * @param multisig Address with admin roles
     * @param usdc USDC address
     */
    function initialize(address timelock, address multisig, address usdc) external;

    /**
     * @notice Register a Uniswap V3 pool as an oracle for an asset
     * @param asset The asset to register the oracle for
     * @param uniswapPool The Uniswap V3 pool address (must contain the asset)
     * @param twapPeriod The TWAP period in seconds
     * @param active Whether this oracle is active (0 = inactive, 1 = active)
     */
    function updateUniswapOracle(address asset, address uniswapPool, uint32 twapPeriod, uint8 active) external;

    /**
     * @notice Add a Chainlink oracle for an asset
     * @param asset The asset to add the oracle for
     * @param oracle The oracle address
     * @param active Whether this oracle is active (0 = inactive, 1 = active)
     */
    function updateChainlinkOracle(address asset, address oracle, uint8 active) external;

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
     * @notice Schedules an upgrade to a new implementation with timelock
     * @param newImplementation Address of the new implementation contract
     */
    function scheduleUpgrade(address newImplementation) external;

    /**
     * @notice Cancels a previously scheduled upgrade
     */
    function cancelUpgrade() external;
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
     * @notice Gets all parameters needed for collateral calculations in a single call
     * @dev Consolidates multiple getter calls into a single cross-contract call
     * @param asset Address of the asset to query
     * @return Struct containing price, thresholds and decimals
     */
    function getAssetCalculationParams(address asset) external view returns (AssetCalculationParams memory);

    /**
     * @notice Checks if an amount exceeds pool liquidity limits
     * @dev Only applicable for assets with active Uniswap oracle
     * @param asset The asset address to check
     * @param amount The amount to validate against pool liquidity
     * @return Boolean - If amount exceeds 3% of the Uniswap v3 pool liquidity
     */
    function poolLiquidityLimit(address asset, uint256 amount) external view returns (bool);
}
