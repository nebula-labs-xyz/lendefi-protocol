// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title Lendefi Oracle Interface
 * @notice Interface for the Lendefi Oracle price feed system
 * @author alexei@nebula-labs(dot)xyz
 * @dev Implements the oracle module interface
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */
interface ILendefiOracle {
    /**
     * @notice Emitted when a new oracle is added for an asset
     * @param asset Address of the asset
     * @param oracle Address of the oracle being added
     */
    event OracleAdded(address indexed asset, address indexed oracle);

    /**
     * @notice Emitted when an oracle is removed from an asset
     * @param asset Address of the asset
     * @param oracle Address of the oracle being removed
     */
    event OracleRemoved(address indexed asset, address indexed oracle);

    /**
     * @notice Emitted when primary oracle is set for an asset
     * @param asset Address of the asset
     * @param oracle Address of the new primary oracle
     */
    event PrimaryOracleSet(address indexed asset, address indexed oracle);

    /**
     * @notice Emitted when price freshness threshold is updated
     * @param oldValue Previous threshold value
     * @param newValue New threshold value
     */
    event FreshnessThresholdUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when volatility time threshold is updated
     * @param oldValue Previous threshold value
     * @param newValue New threshold value
     */
    event VolatilityThresholdUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when volatility percentage threshold is updated
     * @param oldValue Previous percentage value
     * @param newValue New percentage value
     */
    event VolatilityPercentageUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when circuit breaker threshold is updated
     * @param oldValue Previous threshold value
     * @param newValue New threshold value
     */
    event CircuitBreakerThresholdUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when circuit breaker is triggered for an asset
     * @param asset Address of the affected asset
     * @param currentPrice Price that triggered the circuit breaker
     * @param previousPrice Last valid price before trigger
     */
    event CircuitBreakerTriggered(address indexed asset, uint256 currentPrice, uint256 previousPrice);

    /**
     * @notice Emitted when circuit breaker is reset for an asset
     * @param asset Address of the asset being reset
     */
    event CircuitBreakerReset(address indexed asset);

    /**
     * @notice Emitted when price is updated for an asset
     * @param asset Address of the asset
     * @param price New price value
     * @param median Median price from all oracles
     * @param numOracles Number of oracles used in calculation
     */
    event PriceUpdated(address indexed asset, uint256 price, uint256 median, uint256 numOracles);

    /**
     * @notice Emitted when minimum required oracles is updated
     * @param oldValue Previous minimum value
     * @param newValue New minimum value
     */
    event MinimumOraclesUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when asset-specific minimum oracles is updated
     * @param asset Address of the affected asset
     * @param oldValue Previous minimum value
     * @param newValue New minimum value
     */
    event AssetMinimumOraclesUpdated(address indexed asset, uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when there are insufficient oracles for an asset
     * @param asset Address of the affected asset
     * @param required Required number of oracles
     * @param actual Actual number of oracles available
     */
    event NotEnoughOraclesWarning(address indexed asset, uint256 required, uint256 actual);

    /**
     * @notice Oracle returned an invalid or negative price
     * @param oracle Address of the oracle
     * @param price Invalid price value
     */
    error OracleInvalidPrice(address oracle, int256 price);

    /**
     * @notice Oracle round ID mismatch indicates stale price
     * @param oracle Address of the oracle
     * @param roundId Current round ID
     * @param answeredInRound Round when price was updated
     */
    error OracleStalePrice(address oracle, uint80 roundId, uint80 answeredInRound);

    /**
     * @notice Oracle price update is older than allowed threshold
     * @param oracle Address of the oracle
     * @param timestamp Price timestamp
     * @param currentTimestamp Current block timestamp
     * @param maxAge Maximum allowed age
     */
    error OracleTimeout(address oracle, uint256 timestamp, uint256 currentTimestamp, uint256 maxAge);

    /**
     * @notice Price change exceeds volatility threshold
     * @param oracle Address of the oracle
     * @param price Current price
     * @param volatility Maximum allowed volatility
     */
    error OracleInvalidPriceVolatility(address oracle, int256 price, uint256 volatility);

    /**
     * @notice No oracle configured for asset
     * @param asset Address of the asset
     */
    error OracleNotFound(address asset);

    /**
     * @notice No primary oracle set for asset
     * @param asset Address of the asset
     */
    error PrimaryOracleNotSet(address asset);

    /**
     * @notice Circuit breaker is currently active for asset
     * @param asset Address of the asset
     */
    error CircuitBreakerActive(address asset);

    /**
     * @notice Threshold value outside allowed range
     * @param name Name of the threshold
     * @param value Provided value
     * @param minValue Minimum allowed value
     * @param maxValue Maximum allowed value
     */
    error InvalidThreshold(string name, uint256 value, uint256 minValue, uint256 maxValue);

    /**
     * @notice Insufficient number of valid oracles
     * @param asset Address of the asset
     * @param required Required number of oracles
     * @param actual Available valid oracles
     */
    error NotEnoughOracles(address asset, uint256 required, uint256 actual);

    /**
     * @notice Oracle already configured for asset
     * @param asset Address of the asset
     * @param oracle Address of the oracle
     */
    error OracleAlreadyAdded(address asset, address oracle);

    /**
     * @notice Oracle address is invalid or not supported
     * @param oracle Address of the invalid oracle
     */
    error InvalidOracle(address oracle);

    /**
     * @notice Circuit breaker cooldown period not elapsed
     * @param asset Address of the asset
     * @param remainingTime Time remaining until reset allowed
     */
    error CircuitBreakerCooldown(address asset, uint256 remainingTime);

    /**
     * @notice Price deviation exceeds allowed threshold
     * @param asset Address of the asset
     * @param price Current price
     * @param previousPrice Previous price
     * @param deviationPct Percentage deviation
     */
    error LargeDeviation(address asset, uint256 price, uint256 previousPrice, uint256 deviationPct);

    /**
     * @notice Gets the maximum age allowed for price data
     * @return Maximum age in seconds
     */
    function freshnessThreshold() external view returns (uint256);

    /**
     * @notice Gets the time threshold for volatile price checks
     * @return Time threshold in seconds
     */
    function volatilityThreshold() external view returns (uint256);

    /**
     * @notice Gets the percentage that triggers volatility checks
     * @return Percentage in basis points
     */
    function volatilityPercentage() external view returns (uint256);

    /**
     * @notice Gets the percentage that triggers circuit breaker
     * @return Percentage in basis points
     */
    function circuitBreakerThreshold() external view returns (uint256);

    /**
     * @notice Gets minimum oracles required for price feeds
     * @return Minimum number of oracles
     */
    function minimumOraclesRequired() external view returns (uint256);

    /**
     * @notice Gets primary oracle for an asset
     * @param asset Address of the asset
     * @return Address of primary oracle
     */
    function primaryOracle(address asset) external view returns (address);

    /**
     * @notice Gets decimals for an oracle
     * @param oracle Address of the oracle
     * @return Number of decimals
     */
    function oracleDecimals(address oracle) external view returns (uint8);

    /**
     * @notice Checks if circuit breaker is active for asset
     * @param asset Address of the asset
     * @return True if circuit breaker is active
     */
    function circuitBroken(address asset) external view returns (bool);

    /**
     * @notice Gets last valid price for an asset
     * @param asset Address of the asset
     * @return Last valid price
     */
    function lastValidPrice(address asset) external view returns (uint256);

    /**
     * @notice Gets timestamp of last price update
     * @param asset Address of the asset
     * @return Timestamp of last update
     */
    function lastUpdateTimestamp(address asset) external view returns (uint256);

    /**
     * @notice Gets minimum oracles required for specific asset
     * @param asset Address of the asset
     * @return Minimum oracles required
     */
    function assetMinimumOracles(address asset) external view returns (uint256);

    /**
     * @notice Gets validated price for an asset
     * @param asset Address of the asset to price
     * @return Current validated price
     */
    function getAssetPrice(address asset) external returns (uint256);

    /**
     * @notice Gets price from a single oracle
     * @param oracle Address of the oracle
     * @return Current price from oracle
     */
    function getSingleOraclePrice(address oracle) external view returns (uint256);

    /**
     * @notice Adds new oracle for an asset
     * @param asset Address of the asset
     * @param oracle Address of the oracle
     * @param decimals Number of decimals for oracle
     */
    function addOracle(address asset, address oracle, uint8 decimals) external;

    /**
     * @notice Removes oracle from an asset
     * @param asset Address of the asset
     * @param oracle Address of the oracle
     */
    function removeOracle(address asset, address oracle) external;

    /**
     * @notice Sets primary oracle for an asset
     * @param asset Address of the asset
     * @param oracle Address of the oracle
     */
    function setPrimaryOracle(address asset, address oracle) external;

    /**
     * @notice Gets number of oracles for an asset
     * @param asset Address of the asset
     * @return Number of configured oracles
     */
    function getOracleCount(address asset) external view returns (uint256);

    /**
     * @notice Gets all oracles for an asset
     * @param asset Address of the asset
     * @return Array of oracle addresses
     */
    function getAssetOracles(address asset) external view returns (address[] memory);

    /**
     * @notice Updates price freshness threshold
     * @param freshness New threshold in seconds
     */
    function updateFreshnessThreshold(uint256 freshness) external;

    /**
     * @notice Updates volatility time threshold
     * @param volatility New threshold in seconds
     */
    function updateVolatilityThreshold(uint256 volatility) external;

    /**
     * @notice Updates volatility percentage threshold
     * @param percentage New threshold in basis points
     */
    function updateVolatilityPercentage(uint256 percentage) external;

    /**
     * @notice Updates circuit breaker threshold
     * @param percentage New threshold in basis points
     */
    function updateCircuitBreakerThreshold(uint256 percentage) external;

    /**
     * @notice Updates minimum required oracles
     * @param minimum New minimum number of oracles
     */
    function updateMinimumOracles(uint256 minimum) external;

    /**
     * @notice Updates minimum oracles for specific asset
     * @param asset Address of the asset
     * @param minimum New minimum number of oracles
     */
    function updateAssetMinimumOracles(address asset, uint256 minimum) external;

    /**
     * @notice Manually triggers circuit breaker
     * @param asset Address of the asset
     */
    function triggerCircuitBreaker(address asset) external;

    /**
     * @notice Resets circuit breaker
     * @param asset Address of the asset
     */
    function resetCircuitBreaker(address asset) external;
}
