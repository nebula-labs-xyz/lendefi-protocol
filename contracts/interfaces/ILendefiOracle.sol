// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * @title Lendefi Oracle Interface
 * @notice Interface for the Lendefi Oracle price feed system
 */
interface ILendefiOracle {
    // Roles
    function ORACLE_MANAGER_ROLE() external view returns (bytes32);
    function CIRCUIT_BREAKER_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);

    // Configuration getters
    function freshnessThreshold() external view returns (uint256);
    function volatilityThreshold() external view returns (uint256);
    function volatilityPercentage() external view returns (uint256);
    function circuitBreakerThreshold() external view returns (uint256);
    function minimumOraclesRequired() external view returns (uint256);
    function primaryOracle(address asset) external view returns (address);
    function oracleDecimals(address oracle) external view returns (uint8);
    function circuitBroken(address asset) external view returns (bool);
    function lastValidPrice(address asset) external view returns (uint256);
    function lastUpdateTimestamp(address asset) external view returns (uint256);
    function assetMinimumOracles(address asset) external view returns (uint256);

    // Core price functionality
    function getAssetPrice(address asset) external returns (uint256);
    function getSingleOraclePrice(address oracle) external view returns (uint256);

    // Oracle management
    function addOracle(address asset, address oracle, uint8 decimals) external;
    function removeOracle(address asset, address oracle) external;
    function setPrimaryOracle(address asset, address oracle) external;
    function getOracleCount(address asset) external view returns (uint256);
    function getAssetOracles(address asset) external view returns (address[] memory);

    // Configuration setters
    function updateFreshnessThreshold(uint256 freshness) external;
    function updateVolatilityThreshold(uint256 volatility) external;
    function updateVolatilityPercentage(uint256 percentage) external;
    function updateCircuitBreakerThreshold(uint256 percentage) external;
    function updateMinimumOracles(uint256 minimum) external;
    function updateAssetMinimumOracles(address asset, uint256 minimum) external;

    // Circuit breaker controls
    function triggerCircuitBreaker(address asset) external;
    function resetCircuitBreaker(address asset) external;

    // AccessControl
    function hasRole(bytes32 role, address account) external view returns (bool);

    // Error definitions
    error OracleInvalidPrice(address oracle, int256 price);
    error OracleStalePrice(address oracle, uint80 roundId, uint80 answeredInRound);
    error OracleTimeout(address oracle, uint256 timestamp, uint256 currentTimestamp, uint256 maxAge);
    error OracleInvalidPriceVolatility(address oracle, int256 price, uint256 volatility);
    error OracleNotFound(address asset);
    error PrimaryOracleNotSet(address asset);
    error CircuitBreakerActive(address asset);
    error InvalidThreshold(string name, uint256 value, uint256 minValue, uint256 maxValue);
    error NotEnoughOracles(address asset, uint256 required, uint256 actual);
    error OracleAlreadyAdded(address asset, address oracle);
    error InvalidOracle(address oracle);
    error CircuitBreakerCooldown(address asset, uint256 remainingTime);
    error LargeDeviation(address asset, uint256 price, uint256 previousPrice, uint256 deviationPct);

    // Events
    event OracleAdded(address indexed asset, address indexed oracle);
    event OracleRemoved(address indexed asset, address indexed oracle);
    event PrimaryOracleSet(address indexed asset, address indexed oracle);
    event FreshnessThresholdUpdated(uint256 oldValue, uint256 newValue);
    event VolatilityThresholdUpdated(uint256 oldValue, uint256 newValue);
    event VolatilityPercentageUpdated(uint256 oldValue, uint256 newValue);
    event CircuitBreakerThresholdUpdated(uint256 oldValue, uint256 newValue);
    event CircuitBreakerTriggered(address indexed asset, uint256 currentPrice, uint256 previousPrice);
    event CircuitBreakerReset(address indexed asset);
    event PriceUpdated(address indexed asset, uint256 price, uint256 median, uint256 numOracles);
    event MinimumOraclesUpdated(uint256 oldValue, uint256 newValue);
    event AssetMinimumOraclesUpdated(address indexed asset, uint256 oldValue, uint256 newValue);
    event NotEnoughOraclesWarning(address indexed asset, uint256 required, uint256 actual);
}
