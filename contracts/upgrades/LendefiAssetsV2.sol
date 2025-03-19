// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title LendefiAssetsV2 (for testing upgrades)
 * @author alexei@nebula-labs(dot)xyz
 * @notice Manages asset configurations, listings, and oracle integrations
 * @dev Extracted component for asset-related functionality
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {IASSETS} from "../interfaces/IASSETS.sol";
import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AggregatorV3Interface} from "../vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";
import {UniswapTickMath} from "../lender/lib/UniswapTickMath.sol";

/// @custom:oz-upgrades-from contracts/lender/LendefiAssets.sol:LendefiAssets
contract LendefiAssetsV2 is
    IASSETS,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using UniswapTickMath for int24;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ==================== ROLES ====================

    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant CIRCUIT_BREAKER_ROLE = keccak256("CIRCUIT_BREAKER_ROLE");
    /// @notice Duration of the timelock for upgrade operations (3 days)
    uint256 public constant UPGRADE_TIMELOCK_DURATION = 3 days;
    // ==================== STATE VARIABLES ====================
    // Core info
    uint8 public version;
    address public coreAddress;
    /// @notice Information about the currently pending upgrade
    UpgradeRequest public pendingUpgrade;
    IPROTOCOL internal lendefiInstance;

    // Asset management
    EnumerableSet.AddressSet internal listedAssets;
    mapping(address => Asset) internal assetInfo;

    // Tier configuration
    mapping(CollateralTier => TierRates) public tierConfig;

    // Oracle configuration
    MainOracleConfig public mainOracleConfig;

    mapping(address asset => bool broken) public circuitBroken;

    modifier onlyListedAsset(address asset) {
        if (!listedAssets.contains(asset)) revert AssetNotListed(asset);
        _;
    }

    /**
     * @notice Checks that an address is not zero
     * @param addr The address to check
     */
    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddressNotAllowed();
        _;
    }
    // ==================== CONSTRUCTOR & INITIALIZER ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address timelock, address guardian) external initializer {
        if (timelock == address(0) || guardian == address(0)) revert ZeroAddressNotAllowed();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(MANAGER_ROLE, timelock);
        _grantRole(UPGRADER_ROLE, guardian);
        _grantRole(PAUSER_ROLE, guardian);
        _grantRole(CIRCUIT_BREAKER_ROLE, guardian);

        // Initialize oracle config
        mainOracleConfig = MainOracleConfig({
            freshnessThreshold: 28800, // 8 hours
            volatilityThreshold: 3600, // 1 hour
            volatilityPercentage: 20, // 20%
            circuitBreakerThreshold: 50, // 50%
            minimumRequiredOracles: 1 // Min 2 oracles
        });

        _initializeDefaultTierParameters();

        version = 1;
    }

    // ==================== ORACLE MANAGEMENT ====================

    /**
     * @notice Register a Uniswap V3 pool as an oracle for an asset
     * @param asset The asset to register the oracle for
     * @param uniswapPool The Uniswap V3 pool address (must contain the asset)
     * @param quoteToken The quote token (usually a stable or WETH)
     * @param twapPeriod The TWAP period in seconds
     * @param resultDecimals The expected decimals for the price result
     */
    function updateUniswapOracle(
        address asset,
        address uniswapPool,
        address quoteToken,
        uint32 twapPeriod,
        uint8 resultDecimals,
        uint8 active
    ) public nonZeroAddress(uniswapPool) onlyListedAsset(asset) onlyRole(MANAGER_ROLE) whenNotPaused {
        // Validate the pool contains both tokens
        bool isToken0 = _validatePool(asset, quoteToken, uniswapPool);

        // Asset storage item = assetInfo[asset];
        assetInfo[asset].poolConfig = UniswapPoolConfig({
            pool: uniswapPool,
            quoteToken: quoteToken,
            isToken0: isToken0,
            decimalsUniswap: resultDecimals == 8 ? resultDecimals : 8, //enforce
            twapPeriod: twapPeriod,
            active: active
        });
    }

    /**
     * @notice Add an oracle with type specification
     * @param asset The asset to add the oracle for
     * @param oracle The oracle address
     * @param decimals The oracle decimals
     */
    function updateChainlinkOracle(address asset, address oracle, uint8 decimals, uint8 active)
        external
        nonZeroAddress(oracle)
        onlyListedAsset(asset)
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        assetInfo[asset].chainlinkConfig = ChainlinkOracleConfig({
            oracleUSD: oracle,
            oracleDecimals: decimals, // Always enforce 8 decimals
            active: active
        });

        emit ChainlinkOracleUpdated(asset, oracle, active);
    }

    // ==================== OTHER FUNCTIONS ====================
    // ==================== BATCH CONFIGURATION ====================

    function updateMainOracleConfig(
        uint80 freshness,
        uint80 volatility,
        uint40 volatilityPct,
        uint40 circuitBreakerPct,
        uint16 minOracles
    ) external onlyRole(MANAGER_ROLE) whenNotPaused {
        // Validate parameters
        if (freshness < 15 minutes || freshness > 24 hours) {
            revert InvalidThreshold("freshness", freshness, 15 minutes, 24 hours);
        }

        if (volatility < 5 minutes || volatility > 4 hours) {
            revert InvalidThreshold("volatility", volatility, 5 minutes, 4 hours);
        }

        if (volatilityPct < 5 || volatilityPct > 30) {
            revert InvalidThreshold("volatilityPct", volatilityPct, 5, 30);
        }

        if (circuitBreakerPct < 25 || circuitBreakerPct > 70) {
            revert InvalidThreshold("circuitBreaker", circuitBreakerPct, 25, 70);
        }

        if (minOracles < 1) {
            revert InvalidThreshold("minOracles", minOracles, 1, type(uint16).max);
        }

        // Update config
        MainOracleConfig memory oldConfig = mainOracleConfig;

        mainOracleConfig.freshnessThreshold = freshness;
        mainOracleConfig.volatilityThreshold = volatility;
        mainOracleConfig.volatilityPercentage = volatilityPct;
        mainOracleConfig.circuitBreakerThreshold = circuitBreakerPct;
        mainOracleConfig.minimumRequiredOracles = minOracles;

        // Emit events
        emit FreshnessThresholdUpdated(oldConfig.freshnessThreshold, freshness);
        emit VolatilityThresholdUpdated(oldConfig.volatilityThreshold, volatility);
        emit VolatilityPercentageUpdated(oldConfig.volatilityPercentage, volatilityPct);
        emit CircuitBreakerThresholdUpdated(oldConfig.circuitBreakerThreshold, circuitBreakerPct);
        emit MinimumOraclesUpdated(oldConfig.minimumRequiredOracles, minOracles);
    }

    function updateTierConfig(CollateralTier tier, uint256 jumpRate, uint256 liquidationFee)
        external
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        if (jumpRate > 0.25e6) revert RateTooHigh(jumpRate, 0.25e6);
        if (liquidationFee > 0.1e6) revert FeeTooHigh(liquidationFee, 0.1e6);

        tierConfig[tier].jumpRate = jumpRate;
        tierConfig[tier].liquidationFee = liquidationFee;

        emit TierParametersUpdated(tier, jumpRate, liquidationFee);
    }

    // ==================== CORE FUNCTIONS ====================

    function setCoreAddress(address newCore)
        external
        nonZeroAddress(newCore)
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        coreAddress = newCore;
        lendefiInstance = IPROTOCOL(newCore);
        emit CoreAddressUpdated(newCore);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ==================== ASSET MANAGEMENT ====================

    function updateAssetConfig(address asset, Asset calldata config)
        external
        nonZeroAddress(asset)
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        // Validate the entire config in one go
        _validateAssetConfig(config);

        bool newAsset = !listedAssets.contains(asset);
        if (newAsset) {
            require(listedAssets.add(asset), "ADDING_ASSET");
        }

        assetInfo[asset] = config;
        emit UpdateAssetConfig(config);
    }

    function updateAssetTier(address asset, CollateralTier newTier)
        external
        onlyListedAsset(asset)
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        assetInfo[asset].tier = newTier;
        emit AssetTierUpdated(asset, newTier);
    }

    // ==================== ORACLE MANAGEMENT ====================

    function setPrimaryOracle(address asset, OracleType oracleType)
        external
        onlyListedAsset(asset)
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        _setPrimaryOracleInternal(asset, oracleType);
    }

    function triggerCircuitBreaker(address asset) external onlyRole(CIRCUIT_BREAKER_ROLE) {
        circuitBroken[asset] = true;
        emit CircuitBreakerTriggered(asset, 0, 0);
    }

    function resetCircuitBreaker(address asset) external onlyRole(CIRCUIT_BREAKER_ROLE) {
        circuitBroken[asset] = false;
        emit CircuitBreakerReset(asset);
    }

    /**
     * @notice Get the oracle address for a specific asset and oracle type
     * @param asset The asset address
     * @param oracleType The oracle type to retrieve
     * @return The oracle address for the specified type, or address(0) if none exists
     */
    function getOracleByType(address asset, OracleType oracleType) external view returns (address) {
        if (oracleType == OracleType.UNISWAP_V3_TWAP) {
            return assetInfo[asset].poolConfig.pool;
        }

        return assetInfo[asset].chainlinkConfig.oracleUSD;
    }

    /**
     * @notice Get the price from a specific oracle type for an asset
     * @param asset The asset to get price for
     * @param oracleType The specific oracle type to query
     * @return The price from the specified oracle type
     */
    function getAssetPriceByType(address asset, OracleType oracleType)
        external
        view
        onlyListedAsset(asset)
        returns (uint256)
    {
        if (circuitBroken[asset]) {
            revert CircuitBreakerActive(asset);
        }

        if (oracleType == OracleType.UNISWAP_V3_TWAP) {
            return _getUniswapTWAPPrice(asset);
        }

        return _getChainlinkPrice(asset);
    }
    // ==================== ASSET VIEW FUNCTIONS ====================

    /**
     * @notice Get asset price as a view function (no state changes)
     * @param asset The asset to get price for
     * @return price The current price of the asset
     */
    function getAssetPrice(address asset) public view onlyListedAsset(asset) returns (uint256) {
        // When circuit breaker is active, we can't retrieve prices
        if (circuitBroken[asset]) {
            revert CircuitBreakerActive(asset);
        }

        // Direct storage access instead of copying entire struct to memory
        uint8 chainlinkActive = assetInfo[asset].chainlinkConfig.active;
        uint8 uniswapActive = assetInfo[asset].poolConfig.active;
        uint8 totalActive = chainlinkActive + uniswapActive;

        // Use early returns for clearer control flow
        if (totalActive == 1) {
            return chainlinkActive == 1 ? _getChainlinkPrice(asset) : _getUniswapTWAPPrice(asset);
        }

        // If two oracles are active, calculate median
        (uint256 price,) = _calculateMedianPrice(asset);
        return price;
    }

    /**
     * @notice Schedules an upgrade to a new implementation with timelock
     * @dev Only callable by addresses with UPGRADER_ROLE
     * @param newImplementation Address of the new implementation contract
     */
    function scheduleUpgrade(address newImplementation)
        external
        nonZeroAddress(newImplementation)
        onlyRole(UPGRADER_ROLE)
    {
        uint64 currentTime = uint64(block.timestamp);
        uint64 effectiveTime = currentTime + uint64(UPGRADE_TIMELOCK_DURATION);

        pendingUpgrade = UpgradeRequest({implementation: newImplementation, scheduledTime: currentTime, exists: true});

        emit UpgradeScheduled(msg.sender, newImplementation, currentTime, effectiveTime);
    }

    /**
     * @notice Cancels a previously scheduled upgrade
     * @dev Only callable by addresses with UPGRADER_ROLE
     */
    function cancelUpgrade() external onlyRole(UPGRADER_ROLE) {
        if (!pendingUpgrade.exists) {
            revert UpgradeNotScheduled();
        }

        address implementation = pendingUpgrade.implementation;
        delete pendingUpgrade;

        emit UpgradeCancelled(msg.sender, implementation);
    }

    /**
     * @notice Returns the remaining time before a scheduled upgrade can be executed
     * @dev Returns 0 if no upgrade is scheduled or if the timelock has expired
     * @return timeRemaining The time remaining in seconds
     */
    function upgradeTimelockRemaining() external view returns (uint256) {
        return pendingUpgrade.exists && block.timestamp < pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION
            ? pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION - block.timestamp
            : 0;
    }

    function getAssetDetails(address asset)
        external
        view
        onlyListedAsset(asset)
        returns (uint256 price, uint256 totalSupplied, uint256 maxSupply, CollateralTier tier)
    {
        // Direct storage access instead of copying entire struct
        maxSupply = assetInfo[asset].maxSupplyThreshold;
        tier = assetInfo[asset].tier;

        // Get price (this will revert if circuit breaker is active)
        price = getAssetPrice(asset);

        // Get total supplied from protocol
        totalSupplied = lendefiInstance.assetTVL(asset);
    }

    function getTierRates() external view returns (uint256[4] memory jumpRates, uint256[4] memory liquidationFees) {
        jumpRates[0] = tierConfig[CollateralTier.STABLE].jumpRate;
        jumpRates[1] = tierConfig[CollateralTier.CROSS_A].jumpRate;
        jumpRates[2] = tierConfig[CollateralTier.CROSS_B].jumpRate;
        jumpRates[3] = tierConfig[CollateralTier.ISOLATED].jumpRate;

        liquidationFees[0] = tierConfig[CollateralTier.STABLE].liquidationFee;
        liquidationFees[1] = tierConfig[CollateralTier.CROSS_A].liquidationFee;
        liquidationFees[2] = tierConfig[CollateralTier.CROSS_B].liquidationFee;
        liquidationFees[3] = tierConfig[CollateralTier.ISOLATED].liquidationFee;
    }

    function getTierJumpRate(CollateralTier tier) external view returns (uint256) {
        return tierConfig[tier].jumpRate;
    }

    function isAssetValid(address asset) external view returns (bool) {
        return listedAssets.contains(asset) && assetInfo[asset].active == 1;
    }

    function isAssetAtCapacity(address asset, uint256 additionalAmount)
        external
        view
        onlyListedAsset(asset)
        returns (bool)
    {
        return lendefiInstance.assetTVL(asset) + additionalAmount > assetInfo[asset].maxSupplyThreshold;
    }

    function getAssetInfo(address asset) external view onlyListedAsset(asset) returns (Asset memory) {
        return assetInfo[asset];
    }

    function getListedAssets() external view returns (address[] memory) {
        uint256 length = listedAssets.length();
        address[] memory assets = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            assets[i] = listedAssets.at(i);
        }
        return assets;
    }

    function getLiquidationFee(CollateralTier tier) external view returns (uint256) {
        return tierConfig[tier].liquidationFee;
    }

    function getAssetTier(address asset) external view onlyListedAsset(asset) returns (CollateralTier tier) {
        return assetInfo[asset].tier;
    }

    function getAssetDecimals(address asset) external view onlyListedAsset(asset) returns (uint8) {
        return assetInfo[asset].decimals;
    }

    function getAssetLiquidationThreshold(address asset) external view onlyListedAsset(asset) returns (uint16) {
        return assetInfo[asset].liquidationThreshold;
    }

    function getAssetBorrowThreshold(address asset) external view onlyListedAsset(asset) returns (uint16) {
        return assetInfo[asset].borrowThreshold;
    }

    function getIsolationDebtCap(address asset) external view onlyListedAsset(asset) returns (uint256) {
        return assetInfo[asset].isolationDebtCap;
    }

    /**
     * @notice Gets all parameters needed for collateral calculations in a single call
     * @dev Consolidates multiple getter calls into a single cross-contract call
     * @param asset Address of the asset to query
     * @return Struct containing price, thresholds and decimals
     */
    function getAssetCalculationParams(address asset)
        external
        view
        onlyListedAsset(asset)
        returns (AssetCalculationParams memory)
    {
        return AssetCalculationParams({
            price: getAssetPrice(asset),
            borrowThreshold: assetInfo[asset].borrowThreshold,
            liquidationThreshold: assetInfo[asset].liquidationThreshold,
            decimals: assetInfo[asset].decimals
        });
    }

    function getOracleCount(address asset) external view returns (uint256) {
        return assetInfo[asset].chainlinkConfig.active + assetInfo[asset].poolConfig.active;
    }

    /**
     * @notice Check for price deviation without modifying state
     * @param asset The asset to check
     * @return Whether the asset has a large price deviation
     */
    function checkPriceDeviation(address asset) external view returns (bool, uint256) {
        (, uint256 deviation) = _calculateMedianPrice(asset);
        return (deviation >= mainOracleConfig.circuitBreakerThreshold, deviation);
    }

    // ==================== INTERNAL FUNCTIONS ====================

    function _initializeDefaultTierParameters() internal {
        // This function should now initialize the tierConfig struct for each tier
        tierConfig[CollateralTier.STABLE] = TierRates({
            jumpRate: 0.05e6, // 5%
            liquidationFee: 0.01e6 // 1%
        });

        tierConfig[CollateralTier.CROSS_A] = TierRates({
            jumpRate: 0.08e6, // 8%
            liquidationFee: 0.02e6 // 2%
        });

        tierConfig[CollateralTier.CROSS_B] = TierRates({
            jumpRate: 0.12e6, // 12%
            liquidationFee: 0.03e6 // 3%
        });

        tierConfig[CollateralTier.ISOLATED] = TierRates({
            jumpRate: 0.15e6, // 15%
            liquidationFee: 0.04e6 // 4%
        });
    }

    function _setPrimaryOracleInternal(address asset, OracleType oracleType) internal {
        assetInfo[asset].primaryOracleType = oracleType;
        emit PrimaryOracleSet(asset, oracleType);
    }

    /**
     * @notice Calculate median price from oracles without modifying state
     * @param asset The asset to get price for
     * @return median The median price across all valid oracles
     * @return deviation Maximum deviation between any two prices (instead of vs stored price)
     */
    function _calculateMedianPrice(address asset) internal view returns (uint256 median, uint256 deviation) {
        uint8 active = assetInfo[asset].chainlinkConfig.active + assetInfo[asset].poolConfig.active;
        if (active != 2) {
            revert NotEnoughValidOracles(asset, 2, active);
        }

        // Get prices directly - will revert if either fails
        uint256 price1 = _getChainlinkPrice(asset);
        uint256 price2 = _getUniswapTWAPPrice(asset);

        // Calculate median (average of two prices)
        median = (price1 + price2) / 2;

        // Calculate deviation with guaranteed non-zero minPrice
        uint256 minPrice = price1 < price2 ? price1 : price2;
        uint256 maxPrice = price1 > price2 ? price1 : price2;
        uint256 priceDelta = maxPrice - minPrice;
        deviation = (priceDelta * 100) / minPrice;

        return (median, deviation);
    }

    // ==================== INTERNAL FUNCTIONS ====================
    /**
     * @notice Validate asset configuration parameters
     * @dev Centralized validation to ensure consistent checks across all configuration updates
     * @param config The asset configuration to validate
     */
    function _validateAssetConfig(Asset calldata config) internal pure {
        // Basic validation
        if (config.chainlinkConfig.oracleUSD == address(0)) revert ZeroAddressNotAllowed();

        // Threshold validations
        if (config.liquidationThreshold > 990) {
            revert InvalidLiquidationThreshold(config.liquidationThreshold);
        }

        if (config.borrowThreshold > config.liquidationThreshold - 10) {
            revert InvalidBorrowThreshold(config.borrowThreshold);
        }

        // Decimal validations
        if (config.chainlinkConfig.oracleDecimals != 8) {
            revert InvalidParameter("oracleDecimals", config.chainlinkConfig.oracleDecimals);
        }

        if (config.decimals == 0 || config.decimals > 18) {
            revert InvalidParameter("assetDecimals", config.decimals);
        }

        // Activity check
        if (config.active > 1) {
            revert InvalidParameter("active", config.active);
        }

        // Supply limit validation
        if (config.maxSupplyThreshold == 0) {
            revert InvalidParameter("maxSupplyThreshold", 0);
        }

        // For isolated assets, check debt cap
        if (config.tier == CollateralTier.ISOLATED && config.isolationDebtCap == 0) {
            revert InvalidParameter("isolationDebtCap", 0);
        }
    }

    /**
     * @notice Get price from Chainlink oracle
     * @param asset The Chainlink oracle address
     * @return The price with the specified decimals
     */
    function _getChainlinkPrice(address asset) internal view returns (uint256) {
        // Asset memory item = assetInfo[asset];
        address oracle = assetInfo[asset].chainlinkConfig.oracleUSD;
        (uint80 roundId, int256 price,, uint256 timestamp, uint80 answeredInRound) =
            AggregatorV3Interface(oracle).latestRoundData();

        if (price <= 0) {
            revert OracleInvalidPrice(oracle, price);
        }

        if (answeredInRound < roundId) {
            revert OracleStalePrice(oracle, roundId, answeredInRound);
        }

        uint256 age = block.timestamp - timestamp;
        if (age > mainOracleConfig.freshnessThreshold) {
            revert OracleTimeout(oracle, timestamp, block.timestamp, mainOracleConfig.freshnessThreshold);
        }

        if (roundId > 1) {
            (, int256 previousPrice,, uint256 previousTimestamp,) =
                AggregatorV3Interface(oracle).getRoundData(roundId - 1);

            if (previousPrice > 0 && previousTimestamp > 0) {
                uint256 currentPrice = uint256(price);
                uint256 prevPrice = uint256(previousPrice);

                uint256 priceDelta = currentPrice > prevPrice ? currentPrice - prevPrice : prevPrice - currentPrice;
                uint256 changePercent = (priceDelta * 100) / prevPrice;

                if (
                    changePercent >= mainOracleConfig.volatilityPercentage
                        && age >= mainOracleConfig.volatilityThreshold
                ) {
                    revert OracleInvalidPriceVolatility(oracle, price, changePercent);
                }
            }
        }

        return uint256(price);
    }

    /**
     * @notice Get time-weighted average price from Uniswap V3
     * @param asset The virtual oracle address
     * @return price The TWAP price with the specified decimals
     */
    function _getUniswapTWAPPrice(address asset) internal view returns (uint256 price) {
        UniswapPoolConfig memory config = assetInfo[asset].poolConfig;

        if (config.pool == address(0) || config.active == 0) {
            revert InvalidUniswapConfig(asset);
        }

        // Prepare observation timestamps
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = config.twapPeriod; // e.g., 1800 seconds ago (30 min)
        secondsAgos[1] = 0; // now

        // Get tick cumulative data from Uniswap
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(config.pool).observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 timeWeightedAverageTick = int24(tickCumulativesDelta / int56(uint56(config.twapPeriod)));

        // Convert tick to price based on whether asset is token0 or token1
        price = config.isToken0
            ? UniswapTickMath.getQuoteAtTick(timeWeightedAverageTick)
            : UniswapTickMath.getQuoteAtTick(-timeWeightedAverageTick);

        if (price <= 0) revert OracleInvalidPrice(config.pool, int256(price));
    }

    /**
     * @notice Validates that both asset and quote token are present in a Uniswap V3 pool
     * @param asset The asset token address to validate
     * @param quoteToken The quote token address to validate
     * @param uniswapPool The Uniswap V3 pool address
     * @return isToken0 Whether the asset is token0 in the pool
     */
    function _validatePool(address asset, address quoteToken, address uniswapPool)
        internal
        view
        returns (bool isToken0)
    {
        address token0 = IUniswapV3Pool(uniswapPool).token0();
        address token1 = IUniswapV3Pool(uniswapPool).token1();

        if (asset != token0 && asset != token1) {
            revert AssetNotInUniswapPool(asset, uniswapPool);
        }

        if (quoteToken != token0 && quoteToken != token1) {
            revert TokenNotInUniswapPool(quoteToken, uniswapPool);
        }

        return asset == token0;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        if (!pendingUpgrade.exists) revert UpgradeNotScheduled();
        if (pendingUpgrade.implementation != newImplementation) {
            revert ImplementationMismatch(pendingUpgrade.implementation, newImplementation);
        }
        if (block.timestamp - pendingUpgrade.scheduledTime < UPGRADE_TIMELOCK_DURATION) {
            revert UpgradeTimelockActive(UPGRADE_TIMELOCK_DURATION - (block.timestamp - pendingUpgrade.scheduledTime));
        }

        delete pendingUpgrade;

        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
