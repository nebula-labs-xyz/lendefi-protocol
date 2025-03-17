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

    /**
     * @notice Structure to store pending upgrade details
     * @param implementation Address of the new implementation contract
     * @param scheduledTime Timestamp when the upgrade was scheduled
     * @param exists Boolean flag indicating if an upgrade is currently scheduled
     */
    struct UpgradeRequest {
        address implementation;
        uint64 scheduledTime;
        bool exists;
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
    /// @notice Emitted when an upgrade is scheduled
    /// @param scheduler The address scheduling the upgrade
    /// @param implementation The new implementation contract address
    /// @param scheduledTime The timestamp when the upgrade was scheduled
    /// @param effectiveTime The timestamp when the upgrade can be executed
    event UpgradeScheduled(
        address indexed scheduler, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );

    /// @notice Emitted when a scheduled upgrade is cancelled
    /// @param canceller The address that cancelled the upgrade
    /// @param implementation The implementation address that was cancelled
    event UpgradeCancelled(address indexed canceller, address indexed implementation);

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
    /// @notice Thrown when attempting to execute an upgrade before timelock expires
    /// @param timeRemaining The time remaining until the upgrade can be executed
    error UpgradeTimelockActive(uint256 timeRemaining);

    /// @notice Thrown when attempting to execute an upgrade that wasn't scheduled
    error UpgradeNotScheduled();

    /// @notice Thrown when implementation address doesn't match scheduled upgrade
    /// @param scheduledImpl The address that was scheduled for upgrade
    /// @param attemptedImpl The address that was attempted to be used
    error ImplementationMismatch(address scheduledImpl, address attemptedImpl);

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

    function getAssetDetails(address asset)
        external
        view
        returns (uint256 price, uint256 totalSupplied, uint256 maxSupply, CollateralTier tier);

    function getTierRates() external view returns (uint256[4] memory jumpRates, uint256[4] memory liquidationFees);

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

    function version() external view returns (uint8);

    function coreAddress() external view returns (address);

    function primaryOracle(address) external view returns (address);

    function oracleDecimals(address) external view returns (uint8);

    function assetMinimumOracles(address) external view returns (uint256);

    function circuitBroken(address) external view returns (bool);

    function oracleTypes(address) external view returns (OracleType);

    /**
     * @notice Returns the timelock duration for upgrades
     * @return The duration in seconds (3 days)
     * @dev Constant value defined in the contract
     * @custom:state-changes None, view-only function
     */
    function UPGRADE_TIMELOCK_DURATION() external view returns (uint256);

    /**
     * @notice Schedules an upgrade to a new implementation with timelock
     * @param newImplementation Address of the new implementation contract
     * @dev Schedules an upgrade that can be executed after the timelock period
     * @custom:access Restricted to UPGRADER_ROLE
     * @custom:state-changes
     *      - Sets pendingUpgrade with implementation and schedule details
     *      - Emits an UpgradeScheduled event
     */
    function scheduleUpgrade(address newImplementation) external;

    /**
     * @notice Cancels a previously scheduled upgrade
     * @dev Removes a pending upgrade from the schedule
     * @custom:access Restricted to UPGRADER_ROLE
     * @custom:state-changes
     *      - Clears the pendingUpgrade data
     *      - Emits an UpgradeCancelled event
     */
    function cancelUpgrade() external;

    /**
     * @notice Returns the remaining time before a scheduled upgrade can be executed
     * @return timeRemaining The time remaining in seconds
     * @dev Returns 0 if no upgrade is scheduled or if the timelock has expired
     * @custom:state-changes None, view-only function
     */
    function upgradeTimelockRemaining() external view returns (uint256);

    /**
     * @notice Returns information about the currently pending upgrade
     * @return implementation Address of the pending implementation
     * @return scheduledTime Timestamp when the upgrade was scheduled
     * @return exists Boolean indicating if an upgrade is currently scheduled
     * @dev Use this to get detailed information about the pending upgrade
     * @custom:state-changes None, view-only function
     */
    function pendingUpgrade() external view returns (address implementation, uint64 scheduledTime, bool exists);
}
