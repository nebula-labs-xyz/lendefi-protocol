// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title LendefiAssets
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

/// @custom:oz-upgrades
contract LendefiAssets is
    IASSETS,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;

    // ==================== ROLES ====================

    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant CIRCUIT_BREAKER_ROLE = keccak256("CIRCUIT_BREAKER_ROLE");

    // ==================== STATE VARIABLES ====================
    // Core info
    uint8 public version;
    address public coreAddress;
    IPROTOCOL internal lendefiInstance;

    // Asset management
    EnumerableSet.AddressSet internal listedAssets;
    mapping(address => Asset) internal assetInfo;

    // Tier configuration
    mapping(CollateralTier => TierRates) public tierConfig;

    // Oracle configuration
    OracleConfig public oracleConfig;

    // Asset oracles
    mapping(address asset => address[] oracles) private assetOracles;
    mapping(address asset => address primary) public primaryOracle;
    mapping(address oracle => uint8 decimals) public oracleDecimals;
    mapping(address asset => uint256 minOraclesForAsset) public assetMinimumOracles;

    // Oracle state
    mapping(address asset => bool broken) public circuitBroken;
    // Track oracle types
    mapping(address oracle => OracleType) public oracleTypes;
    mapping(address asset => mapping(OracleType => address oracle)) public assetOracleByType;

    // Virtual oracle address => Uniswap config
    mapping(address virtualOracle => UniswapOracleConfig) public uniswapConfigs;

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
        oracleConfig = OracleConfig({
            freshnessThreshold: 28800, // 8 hours
            volatilityThreshold: 3600, // 1 hour
            volatilityPercentage: 20, // 20%
            circuitBreakerThreshold: 50, // 50%
            minimumOraclesRequired: 1 // Min 2 oracles
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
    function addUniswapOracle(
        address asset,
        address uniswapPool,
        address quoteToken,
        uint32 twapPeriod,
        uint8 resultDecimals
    ) external nonZeroAddress(uniswapPool) onlyListedAsset(asset) onlyRole(MANAGER_ROLE) whenNotPaused {
        // Verify the pool contains the asset
        address token0 = IUniswapV3Pool(uniswapPool).token0();
        address token1 = IUniswapV3Pool(uniswapPool).token1();

        if (asset != token0 && asset != token1) {
            revert AssetNotInUniswapPool(asset, uniswapPool);
        }

        if (quoteToken != token0 && quoteToken != token1) {
            revert TokenNotInUniswapPool(quoteToken, uniswapPool);
        }

        // Create a deterministic virtual oracle address from the pool
        address virtualOracle = address(uint160(uint256(keccak256(abi.encodePacked(asset, uniswapPool, "UNISWAP_V3")))));

        // Configure Uniswap oracle
        uniswapConfigs[virtualOracle] = UniswapOracleConfig({
            pool: uniswapPool,
            quoteToken: quoteToken,
            isToken0: asset == token0,
            twapPeriod: twapPeriod
        });

        // Register the virtual oracle
        _addOracleInternal(asset, virtualOracle, resultDecimals, OracleType.UNISWAP_V3_TWAP);
    }

    /**
     * @notice Add an oracle with type specification
     * @param asset The asset to add the oracle for
     * @param oracle The oracle address
     * @param decimals_ The oracle decimals
     * @param oracleType The type of oracle
     */
    function addOracle(address asset, address oracle, uint8 decimals_, OracleType oracleType)
        external
        nonZeroAddress(oracle)
        onlyListedAsset(asset)
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        _addOracleInternal(asset, oracle, decimals_, oracleType);
    }

    // ==================== OTHER FUNCTIONS ====================
    // ==================== BATCH CONFIGURATION ====================

    function updateOracleConfig(
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
        OracleConfig memory oldConfig = oracleConfig;

        oracleConfig.freshnessThreshold = freshness;
        oracleConfig.volatilityThreshold = volatility;
        oracleConfig.volatilityPercentage = volatilityPct;
        oracleConfig.circuitBreakerThreshold = circuitBreakerPct;
        oracleConfig.minimumOraclesRequired = minOracles;

        // Emit events
        emit FreshnessThresholdUpdated(oldConfig.freshnessThreshold, freshness);
        emit VolatilityThresholdUpdated(oldConfig.volatilityThreshold, volatility);
        emit VolatilityPercentageUpdated(oldConfig.volatilityPercentage, volatilityPct);
        emit CircuitBreakerThresholdUpdated(oldConfig.circuitBreakerThreshold, circuitBreakerPct);
        emit MinimumOraclesUpdated(oldConfig.minimumOraclesRequired, minOracles);
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

    function updateAllTierConfigs(uint256[4] calldata jumpRates, uint256[4] calldata liquidationFees)
        external
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        for (uint8 i = 0; i < 4; i++) {
            if (jumpRates[i] > 0.25e6) revert RateTooHigh(jumpRates[i], 0.25e6);
            if (liquidationFees[i] > 0.1e6) revert FeeTooHigh(liquidationFees[i], 0.1e6);

            CollateralTier tier = CollateralTier(i);
            tierConfig[tier].jumpRate = jumpRates[i];
            tierConfig[tier].liquidationFee = liquidationFees[i];

            emit TierParametersUpdated(tier, jumpRates[i], liquidationFees[i]);
        }
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
    ) external onlyRole(MANAGER_ROLE) whenNotPaused {
        // Validation logic
        if (liquidationThreshold > 990) revert InvalidLiquidationThreshold(liquidationThreshold);
        if (borrowThreshold > liquidationThreshold - 10) revert InvalidBorrowThreshold(borrowThreshold);

        bool newAsset = !listedAssets.contains(asset);
        if (newAsset) {
            require(listedAssets.add(asset), "ADDING_ASSET");
        }

        // Update asset config
        Asset storage item = assetInfo[asset];
        item.active = active;
        item.oracleUSD = oracle_;
        item.oracleDecimals = oracleDecimals_;
        item.decimals = assetDecimals;
        item.borrowThreshold = borrowThreshold;
        item.liquidationThreshold = liquidationThreshold;
        item.maxSupplyThreshold = maxSupplyLimit;
        item.isolationDebtCap = isolationDebtCap;
        item.tier = tier;
        item.oracleType = uint8(oracleType);

        // Handle oracle registration
        if (oracle_ != address(0) && (newAsset || item.oracleUSD != oracle_)) {
            _addOracleInternal(asset, oracle_, oracleDecimals_, oracleType);
        }

        emit UpdateAssetConfig(asset);
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

    function removeOracle(address asset, address oracle)
        external
        onlyListedAsset(asset)
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        _removeOracleInternal(asset, oracle);
    }

    function setPrimaryOracle(address asset, address oracle)
        external
        onlyListedAsset(asset)
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        _setPrimaryOracleInternal(asset, oracle);
    }

    function updateMinimumOracles(address asset, uint256 minimum) external onlyRole(MANAGER_ROLE) {
        uint256 oldValue = assetMinimumOracles[asset];
        assetMinimumOracles[asset] = minimum;
        emit AssetMinimumOraclesUpdated(asset, oldValue, minimum);
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
     * @notice Replace an existing oracle of a specific type for an asset
     * @dev If an oracle of the specified type exists, it will be removed and replaced with the new one.
     *      If no oracle of that type exists, the new oracle is simply added.
     *      If the oracle being replaced is the primary oracle, the new oracle will become the primary.
     *      Asset configuration is updated if the oracle type matches the asset's configured oracle type.
     * @param asset The asset to replace the oracle for
     * @param oracleType The type of oracle to replace
     * @param newOracle The address of the new oracle
     * @param oracleDecimalsValue The number of decimals used by the new oracle
     */
    function replaceOracle(address asset, OracleType oracleType, address newOracle, uint8 oracleDecimalsValue)
        external
        nonZeroAddress(newOracle)
        onlyListedAsset(asset)
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        if (newOracle == address(0)) revert InvalidOracle(newOracle);

        bool updatingConfigOracle = (oracleType == OracleType(assetInfo[asset].oracleType));
        // Find the existing oracle of this type
        address oldOracle = address(0);
        address[] storage oracles = assetOracles[asset];

        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracleTypes[oracles[i]] == oracleType) {
                oldOracle = oracles[i];
                break;
            }
        }

        _removeOracleInternal(asset, oldOracle);
        // Add the new oracle with the same type
        _addOracleInternal(asset, newOracle, oracleDecimalsValue, oracleType);
        // Update asset config if the primary oracle was replaced

        if (updatingConfigOracle) {
            assetInfo[asset].oracleUSD = newOracle;
            assetInfo[asset].oracleDecimals = oracleDecimalsValue;
            assetInfo[asset].oracleType = uint8(oracleType);
        }

        emit OracleReplaced(asset, oldOracle, newOracle, uint8(oracleType));
    }

    /**
     * @notice Get the oracle address for a specific asset and oracle type
     * @param asset The asset address
     * @param oracleType The oracle type to retrieve
     * @return The oracle address for the specified type, or address(0) if none exists
     */
    function getOracleByType(address asset, OracleType oracleType) external view returns (address) {
        return assetOracleByType[asset][oracleType];
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

        address oracle = assetOracleByType[asset][oracleType];
        if (oracle == address(0)) {
            revert OracleNotFound(asset);
        }

        return _getSingleOraclePrice(oracle);
    }
    // ==================== ASSET VIEW FUNCTIONS ====================

    /**
     * @notice Get asset price as a view function (no state changes)
     * @param asset The asset to get price for
     * @return The current price of the asset
     */
    function getAssetPrice(address asset) public view onlyListedAsset(asset) returns (uint256) {
        // When circuit breaker is active, we can't retrieve prices
        if (circuitBroken[asset]) {
            revert CircuitBreakerActive(asset);
        }

        address[] memory oracles = assetOracles[asset];
        uint256 length = oracles.length;

        // Check minimum oracles required
        uint256 minRequired =
            assetMinimumOracles[asset] > 0 ? assetMinimumOracles[asset] : oracleConfig.minimumOraclesRequired;

        // Fast path for single oracle
        if (length == 1) {
            return _getSingleOraclePrice(oracles[0]);
        }

        // Calculate median price
        (uint256 median, uint256 validCount,) = _calculateMedianPrice(asset);

        // Handle case where we don't have enough valid oracles
        if (validCount < minRequired) {
            // Try primary oracle as fallback
            if (primaryOracle[asset] != address(0)) {
                try this.getSingleOraclePrice(primaryOracle[asset]) returns (uint256 price) {
                    return price;
                } catch {
                    // Primary oracle failed
                }
            }

            // No fallback to last valid price anymore
            revert NotEnoughValidOracles(asset, minRequired, validCount);
        }

        return median;
    }

    /**
     * @notice DEPRECATED: Direct oracle price access
     * @dev This function is maintained for backward compatibility
     * @param oracle The address of the Chainlink price feed oracle
     * @return Price from the oracle (use getAssetPrice instead)
     */
    function getAssetPriceOracle(address oracle) external view returns (uint256) {
        return getSingleOraclePrice(oracle);
    }

    function getAssetDetails(address asset)
        external
        view
        onlyListedAsset(asset)
        returns (uint256 price, uint256 totalSupplied, uint256 maxSupply, CollateralTier tier)
    {
        Asset memory assetConfig = assetInfo[asset];
        price = getAssetPrice(asset);
        totalSupplied = lendefiInstance.assetTVL(asset);
        maxSupply = assetConfig.maxSupplyThreshold;
        tier = assetConfig.tier;
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

    function getTierLiquidationFee(CollateralTier tier) external view returns (uint256) {
        return tierConfig[tier].liquidationFee;
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

    function isIsolationAsset(address asset) external view onlyListedAsset(asset) returns (bool) {
        return assetInfo[asset].tier == CollateralTier.ISOLATED;
    }

    function getIsolationDebtCap(address asset) external view onlyListedAsset(asset) returns (uint256) {
        return assetInfo[asset].isolationDebtCap;
    }

    // ==================== ORACLE VIEW FUNCTIONS ====================

    function getOracleCount(address asset) external view returns (uint256) {
        return assetOracles[asset].length;
    }

    function getAssetOracles(address asset) external view returns (address[] memory) {
        return assetOracles[asset];
    }

    /**
     * @notice Check for price deviation without modifying state
     * @param asset The asset to check
     * @return Whether the asset has a large price deviation
     */
    function checkPriceDeviation(address asset) external view returns (bool, uint256) {
        (, uint256 validCount, uint256 deviation) = _calculateMedianPrice(asset);

        if (validCount < 2) {
            return (false, 0); // Not enough prices to calculate deviation
        }

        return (deviation >= oracleConfig.circuitBreakerThreshold, deviation);
    }

    function getSingleOraclePrice(address oracle) public view returns (uint256) {
        return _getSingleOraclePrice(oracle);
    }

    function getOracleConfig()
        external
        view
        returns (
            uint256 freshness,
            uint256 volatility,
            uint256 volatilityPct,
            uint256 circuitBreakerPct,
            uint256 minOracles
        )
    {
        return (
            oracleConfig.freshnessThreshold,
            oracleConfig.volatilityThreshold,
            oracleConfig.volatilityPercentage,
            oracleConfig.circuitBreakerThreshold,
            oracleConfig.minimumOraclesRequired
        );
    }

    // ==================== INTERNAL FUNCTIONS ====================
    // ==================== INTERNAL FUNCTIONS ====================
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

    function _removeOracleInternal(address asset, address oracle) internal {
        address[] storage oracles = assetOracles[asset];
        uint256 length = oracles.length;
        bool found = false;
        uint256 index = 0;

        // Find the oracle to remove
        for (uint256 i = 0; i < length; i++) {
            if (oracles[i] == oracle) {
                found = true;
                index = i;
                break;
            }
        }

        if (!found) revert OracleNotFound(asset);
        OracleType oType = oracleTypes[oracle];
        delete assetOracleByType[asset][oType];

        // If removing the primary oracle, set a new primary
        if (primaryOracle[asset] == oracle) {
            if (length > 1) {
                // Set the next oracle as primary, or the previous if removing the last one
                address newPrimary = index < length - 1 ? oracles[index + 1] : oracles[0];
                primaryOracle[asset] = newPrimary;
                emit PrimaryOracleSet(asset, newPrimary);
            } else {
                // If it's the only oracle, clear the primary
                delete primaryOracle[asset];
            }
        }

        // Remove the oracle by swapping with the last element and popping
        if (index < length - 1) {
            oracles[index] = oracles[length - 1];
        }
        oracles.pop();

        // Check if remaining oracles are sufficient
        uint256 minRequired =
            assetMinimumOracles[asset] > 0 ? assetMinimumOracles[asset] : oracleConfig.minimumOraclesRequired;

        if (oracles.length < minRequired) {
            emit NotEnoughOraclesWarning(asset, minRequired, oracles.length);
        }

        emit OracleRemoved(asset, oracle);
    }

    function _setPrimaryOracleInternal(address asset, address oracle) internal {
        address[] storage oracles = assetOracles[asset];
        bool found = false;

        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == oracle) {
                found = true;
                break;
            }
        }

        if (!found) revert OracleNotFound(asset);
        primaryOracle[asset] = oracle;
        emit PrimaryOracleSet(asset, oracle);
    }

    /**
     * @notice Calculate median price from oracles without modifying state
     * @param asset The asset to get price for
     * @return median The median price across all valid oracles
     * @return validCount Number of valid oracle readings found
     * @return deviation Maximum deviation between any two prices (instead of vs stored price)
     */
    function _calculateMedianPrice(address asset)
        internal
        view
        returns (uint256 median, uint256 validCount, uint256 deviation)
    {
        address[] memory oracles = assetOracles[asset];
        uint256 length = oracles.length;

        // Early return for no oracles
        if (length == 0) {
            return (0, 0, 0);
        }

        // Fast path for single oracle
        if (length == 1) {
            try this.getSingleOraclePrice(oracles[0]) returns (uint256 price) {
                return (price, 1, 0);
            } catch {
                return (0, 0, 0);
            }
        }

        // With our constraint, we now have exactly 2 oracles of different types
        uint256 price1;
        uint256 price2;
        bool valid1;
        bool valid2;

        try this.getSingleOraclePrice(oracles[0]) returns (uint256 price) {
            price1 = price;
            valid1 = true;
        } catch {}

        try this.getSingleOraclePrice(oracles[1]) returns (uint256 price) {
            price2 = price;
            valid2 = true;
        } catch {}

        validCount = (valid1 ? 1 : 0) + (valid2 ? 1 : 0);

        if (validCount == 0) {
            return (0, 0, 0);
        }

        if (validCount == 1) {
            return (valid1 ? price1 : price2, 1, 0);
        }

        // Calculate median (average of two prices)
        median = (price1 + price2) / 2;

        // Calculate deviation
        uint256 minPrice = price1 < price2 ? price1 : price2;
        uint256 maxPrice = price1 > price2 ? price1 : price2;
        uint256 priceDelta = maxPrice - minPrice;
        deviation = (priceDelta * 100) / minPrice;

        return (median, validCount, deviation);
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /**
     * @notice Add an oracle with type specification
     * @param asset The asset to add the oracle for
     * @param oracle The oracle address
     * @param oracleDecimalsValue The oracle decimals
     * @param oracleType The type of oracle
     */
    function _addOracleInternal(address asset, address oracle, uint8 oracleDecimalsValue, OracleType oracleType)
        internal
        nonZeroAddress(oracle)
    {
        assetOracleByType[asset][oracleType] = oracle;

        // Check if oracle is already added for this asset
        address[] storage oracles = assetOracles[asset];
        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == oracle) {
                revert OracleAlreadyAdded(asset, oracle);
            }

            // Check if an oracle of this type already exists
            if (oracleTypes[oracles[i]] == oracleType) {
                revert OracleTypeAlreadyAdded(asset, oracleType);
            }
        }

        // Add the oracle
        oracles.push(oracle);
        oracleDecimals[oracle] = oracleDecimalsValue;
        oracleTypes[oracle] = oracleType;

        // If this is the first oracle, set it as primary
        if (oracles.length == 1) {
            primaryOracle[asset] = oracle;
            emit PrimaryOracleSet(asset, oracle);
        }

        emit OracleAdded(asset, oracle);
        emit OracleTypeSet(asset, oracle, uint8(oracleType));
    }

    /**
     * @notice Get price from any oracle based on its type
     * @param oracleAddress The oracle address
     * @return The price with the specified decimals
     */
    function _getSingleOraclePrice(address oracleAddress) internal view returns (uint256) {
        OracleType oracleType = oracleTypes[oracleAddress];

        if (oracleType == OracleType.UNISWAP_V3_TWAP) {
            return _getUniswapTWAPPrice(oracleAddress);
        } else {
            // Default to Chainlink
            return _getChainlinkPrice(oracleAddress);
        }
    }

    /**
     * @notice Get price from Chainlink oracle
     * @param oracleAddress The Chainlink oracle address
     * @return The price with the specified decimals
     */
    function _getChainlinkPrice(address oracleAddress) internal view returns (uint256) {
        (uint80 roundId, int256 price,, uint256 timestamp, uint80 answeredInRound) =
            AggregatorV3Interface(oracleAddress).latestRoundData();

        if (price <= 0) {
            revert OracleInvalidPrice(oracleAddress, price);
        }

        if (answeredInRound < roundId) {
            revert OracleStalePrice(oracleAddress, roundId, answeredInRound);
        }

        uint256 age = block.timestamp - timestamp;
        if (age > oracleConfig.freshnessThreshold) {
            revert OracleTimeout(oracleAddress, timestamp, block.timestamp, oracleConfig.freshnessThreshold);
        }

        if (roundId > 1) {
            (, int256 previousPrice,, uint256 previousTimestamp,) =
                AggregatorV3Interface(oracleAddress).getRoundData(roundId - 1);

            if (previousPrice > 0 && previousTimestamp > 0) {
                uint256 currentPrice = uint256(price);
                uint256 prevPrice = uint256(previousPrice);

                uint256 priceDelta = currentPrice > prevPrice ? currentPrice - prevPrice : prevPrice - currentPrice;
                uint256 changePercent = (priceDelta * 100) / prevPrice;

                if (changePercent >= oracleConfig.volatilityPercentage && age >= oracleConfig.volatilityThreshold) {
                    revert OracleInvalidPriceVolatility(oracleAddress, price, changePercent);
                }
            }
        }

        return uint256(price);
    }

    /**
     * @notice Get time-weighted average price from Uniswap V3
     * @param virtualOracle The virtual oracle address
     * @return The TWAP price with the specified decimals
     */
    function _getUniswapTWAPPrice(address virtualOracle) internal view returns (uint256) {
        UniswapOracleConfig memory config = uniswapConfigs[virtualOracle];

        if (config.pool == address(0)) {
            revert InvalidUniswapConfig(virtualOracle);
        }

        // Prepare observation timestamps
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = config.twapPeriod; // e.g., 1800 seconds ago (30 min)
        secondsAgos[1] = 0; // now

        // Get tick cumulative data from Uniswap
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(config.pool).observe(secondsAgos);

        // Calculate time-weighted tick
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 timeWeightedAverageTick = int24(tickCumulativesDelta / int56(uint56(config.twapPeriod)));

        // Convert tick to price based on whether asset is token0 or token1
        uint256 price;

        if (config.isToken0) {
            // Asset is token0, so we need the price of token0 in terms of token1
            // For token0: price = 1.0001^(-tick)
            price = _getQuoteAtTick(-timeWeightedAverageTick);
        } else {
            // Asset is token1, so we need the price of token1 in terms of token0
            // For token1: price = 1.0001^tick
            price = _getQuoteAtTick(timeWeightedAverageTick);
        }

        // Convert to expected decimals
        uint8 decimals = oracleDecimals[virtualOracle];
        if (decimals < 18) {
            return price / (10 ** (18 - decimals));
        } else if (decimals > 18) {
            return price * (10 ** (decimals - 18));
        }

        return price;
    }

    /**
     * @notice Convert tick to price
     * @param tick The tick value
     * @return The price in 18 decimals
     */
    function _getQuoteAtTick(int24 tick) internal pure returns (uint256) {
        // 1.0001^tick
        uint160 sqrtRatioX96 = _getSqrtRatioAtTick(tick);

        // Calculate price with proper decimal scaling
        // price = (sqrtRatio/2^96)^2
        uint256 price = (uint256(sqrtRatioX96) * uint256(sqrtRatioX96)) / (1 << 192);

        return price * 10 ** 18; // Convert to 18 decimals
    }

    /**
     * @notice Convert tick to sqrtPriceX96
     * @dev Uniswap V3 TickMath implementation
     * @param tick The tick value
     * @return The sqrtPriceX96 value
     */
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(int256(887272)), "Tick out of range");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;

        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        // This divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
        // We then downcast because we know the result always fits within 160 bits due to our tick input constraint.
        return uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
