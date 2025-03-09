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

import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ILendefiOracle} from "../interfaces/ILendefiOracle.sol";
import {ILendefiAssets} from "../interfaces/ILendefiAssets.sol";

/// @custom:oz-upgrades
contract LendefiAssets is
    ILendefiAssets,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Role for managing asset configurations and parameters
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Role for upgrading contract implementations
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Role for emergency pause functionality
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Current version of the contract
    uint8 public version;

    /// @notice Address of the core Lendefi contract
    address public coreAddress;

    /// @notice Oracle module for asset price feeds
    ILendefiOracle public oracleModule;

    IPROTOCOL internal LendefiInstance;

    /// @notice Set of all assets listed in the protocol
    EnumerableSet.AddressSet internal listedAsset;

    /// @notice Detailed configuration for each asset
    mapping(address => Asset) internal assetInfo;

    /// @notice Base borrow rate for each collateral risk tier
    /// @dev Higher tiers have higher interest rates due to increased risk
    mapping(CollateralTier => uint256) public tierJumpRate;

    /// @notice Liquidation bonus percentage for each collateral tier
    /// @dev Higher risk tiers have larger liquidation bonuses
    mapping(CollateralTier => uint256) public tierLiquidationFee;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the asset management module
     * @param timelock Address with MANAGER_ROLE for asset configuration
     * @param oracle_ Address of oracle module for price feeds
     * @param guardian Address with PAUSER_ROLE for emergency functions
     */
    function initialize(address timelock, address oracle_, address guardian) external initializer {
        if (timelock == address(0) || oracle_ == address(0) || guardian == address(0)) {
            revert ZeroAddressNotAllowed();
        }

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(MANAGER_ROLE, timelock);
        _grantRole(UPGRADER_ROLE, guardian);
        _grantRole(PAUSER_ROLE, guardian);

        oracleModule = ILendefiOracle(oracle_);
        _initializeDefaultTierParameters();

        version = 1;
    }

    /**
     * @notice Pauses all module operations in case of emergency
     * @dev Can only be called by accounts with PAUSER_ROLE
     * @custom:security This is a critical emergency function that should be carefully controlled
     * @custom:access Restricted to PAUSER_ROLE
     * @custom:events Emits a Paused event
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses module operations, returning to normal functioning
     * @dev Can only be called by accounts with PAUSER_ROLE
     * @custom:security Should only be called after thorough security verification
     * @custom:access Restricted to PAUSER_ROLE
     * @custom:events Emits an Unpaused event
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Updates the oracle module address
     * @param newOracle New oracle module address
     * @dev Only callable by accounts with MANAGER_ROLE
     */
    function updateOracleModule(address newOracle) external onlyRole(MANAGER_ROLE) whenNotPaused {
        if (newOracle == address(0)) revert ZeroAddressNotAllowed();
        oracleModule = ILendefiOracle(newOracle);
        emit OracleModuleUpdated(newOracle);
    }

    /**
     * @notice Updates or adds a new asset configuration in the protocol
     * @param asset Address of the token to configure
     * @param oracle_ Address of the Chainlink price feed for asset/USD
     * @param oracleDecimals Number of decimals in the oracle price feed
     * @param assetDecimals Number of decimals in the asset token
     * @param active Whether the asset is enabled (1) or disabled (0)
     * @param borrowThreshold LTV ratio for borrowing (e.g., 870 = 87%)
     * @param liquidationThreshold LTV ratio for liquidation (e.g., 920 = 92%)
     * @param maxSupplyLimit Maximum amount of this asset allowed in protocol
     * @param tier Risk category of the asset (STABLE, CROSS_A, CROSS_B, ISOLATED)
     * @param isolationDebtCap Maximum debt allowed when used in isolation mode
     * @dev Manages all configuration parameters for an asset in a single function
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     * @custom:validation Adds asset to listedAsset set if not already present
     */
    function updateAssetConfig(
        address asset,
        address oracle_,
        uint8 oracleDecimals,
        uint8 assetDecimals,
        uint8 active,
        uint32 borrowThreshold,
        uint32 liquidationThreshold,
        uint256 maxSupplyLimit,
        CollateralTier tier,
        uint256 isolationDebtCap
    ) external onlyRole(MANAGER_ROLE) whenNotPaused {
        bool newAsset = !listedAsset.contains(asset);

        if (newAsset) {
            require(listedAsset.add(asset), "ADDING_ASSET");
        }

        Asset storage item = assetInfo[asset];

        item.active = active;
        item.oracleUSD = oracle_;
        item.oracleDecimals = oracleDecimals;
        item.decimals = assetDecimals;
        item.borrowThreshold = borrowThreshold;
        item.liquidationThreshold = liquidationThreshold;
        item.maxSupplyThreshold = maxSupplyLimit;
        item.tier = tier;
        item.isolationDebtCap = isolationDebtCap;

        // Register oracle with oracle module if it's a new asset or oracle changed
        if (oracle_ != address(0) && (newAsset || item.oracleUSD != oracle_)) {
            try oracleModule.addOracle(asset, oracle_, oracleDecimals) {
                // Oracle successfully added
            } catch {
                // If adding fails (e.g., oracle already exists), continue without error
            }
        }
        emit UpdateAssetConfig(asset);
    }

    /**
     * @notice Updates the risk tier classification for a listed asset
     * @param asset The address of the asset to update
     * @param newTier The new CollateralTier to assign to the asset
     * @dev Changes the risk classification which affects interest rates and liquidation parameters
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     */
    function updateAssetTier(address asset, CollateralTier newTier) external onlyRole(MANAGER_ROLE) whenNotPaused {
        if (!listedAsset.contains(asset)) {
            revert AssetNotListed(asset);
        }
        assetInfo[asset].tier = newTier;
        emit AssetTierUpdated(asset, newTier);
    }

    /**
     * @notice Adds an additional oracle data source for an asset
     * @param asset Address of the asset
     * @param oracle Address of the Chainlink price feed to add
     * @param decimals_ Number of decimals in the oracle price feed
     * @dev Allows adding secondary or backup oracles to enhance price reliability
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     */
    function addAssetOracle(address asset, address oracle, uint8 decimals_)
        external
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        if (!listedAsset.contains(asset)) {
            revert AssetNotListed(asset);
        }
        oracleModule.addOracle(asset, oracle, decimals_);
    }

    /**
     * @notice Removes an oracle data source for an asset
     * @param asset Address of the asset
     * @param oracle Address of the Chainlink price feed to remove
     * @dev Allows removing unreliable or deprecated oracles
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     */
    function removeAssetOracle(address asset, address oracle) external onlyRole(MANAGER_ROLE) whenNotPaused {
        if (!listedAsset.contains(asset)) {
            revert AssetNotListed(asset);
        }
        oracleModule.removeOracle(asset, oracle);
    }

    /**
     * @notice Sets the primary oracle for an asset
     * @param asset Address of the asset
     * @param oracle Address of the Chainlink price feed to set as primary
     * @dev The primary oracle is used as a fallback when median calculation fails
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     */
    function setPrimaryAssetOracle(address asset, address oracle) external onlyRole(MANAGER_ROLE) whenNotPaused {
        if (!listedAsset.contains(asset)) {
            revert AssetNotListed(asset);
        }
        oracleModule.setPrimaryOracle(asset, oracle);
    }

    /**
     * @notice Updates oracle time thresholds
     * @param freshness Maximum age for all price data (in seconds)
     * @param volatility Maximum age for volatile price data (in seconds)
     * @dev Controls how old price data can be before rejection
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     */
    function updateOracleTimeThresholds(uint256 freshness, uint256 volatility)
        external
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        oracleModule.updateFreshnessThreshold(freshness);
        oracleModule.updateVolatilityThreshold(volatility);
    }

    /**
     * @notice Updates the core Lendefi contract address
     * @param newCore New Lendefi core address
     * @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
     */
    function setCoreAddress(address newCore) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newCore == address(0)) revert ZeroAddressNotAllowed();
        coreAddress = newCore;
        LendefiInstance = IPROTOCOL(newCore);
        emit CoreAddressUpdated(newCore);
    }

    /**
     * @notice Updates the risk parameters for a collateral tier
     * @param tier The collateral tier to update
     * @param jumpRate The new base borrow rate for the tier (in parts per million)
     * @param liquidationFee The new liquidation bonus for the tier (in parts per million)
     * @dev Updates both interest rates and liquidation incentives for a specific risk tier
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     */
    function updateTierParameters(CollateralTier tier, uint256 jumpRate, uint256 liquidationFee)
        external
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        if (jumpRate > 0.25e6) {
            revert RateTooHigh(jumpRate, 0.25e6);
        }
        if (liquidationFee > 0.1e6) {
            revert FeeTooHigh(liquidationFee, 0.1e6);
        }

        tierJumpRate[tier] = jumpRate;
        tierLiquidationFee[tier] = liquidationFee;

        emit TierParametersUpdated(tier, jumpRate, liquidationFee);
    }

    /**
     * @notice Retrieves the current borrow rates and liquidation bonuses for all collateral tiers
     * @dev Returns two fixed arrays containing rates for ISOLATED, CROSS_A, CROSS_B, and STABLE tiers in that order
     * @return jumpRates Array of borrow rates for each tier [ISOLATED, CROSS_A, CROSS_B, STABLE]
     * @return liquidationFees Array of liquidation bonuses for each tier [ISOLATED, CROSS_A, CROSS_B, STABLE]
     */
    function getTierRates() external view returns (uint256[4] memory jumpRates, uint256[4] memory liquidationFees) {
        jumpRates[3] = tierJumpRate[CollateralTier.ISOLATED];
        jumpRates[2] = tierJumpRate[CollateralTier.CROSS_B];
        jumpRates[1] = tierJumpRate[CollateralTier.CROSS_A];
        jumpRates[0] = tierJumpRate[CollateralTier.STABLE];

        liquidationFees[3] = tierLiquidationFee[CollateralTier.ISOLATED];
        liquidationFees[2] = tierLiquidationFee[CollateralTier.CROSS_B];
        liquidationFees[1] = tierLiquidationFee[CollateralTier.CROSS_A];
        liquidationFees[0] = tierLiquidationFee[CollateralTier.STABLE];
    }

    /**
     * @notice Gets the base liquidation bonus percentage for a specific collateral tier
     * @param tier The collateral tier to query
     * @return uint256 The liquidation bonus rate in parts per million (e.g., 0.05e6 = 5%)
     */
    function getTierLiquidationFee(CollateralTier tier) external view returns (uint256) {
        return tierLiquidationFee[tier];
    }

    /**
     * @notice Gets the jump rate for a specific collateral tier
     * @param tier The collateral tier to query
     * @return uint256 The jump rate in parts per million
     */
    function getTierJumpRate(CollateralTier tier) external view returns (uint256) {
        return tierJumpRate[tier];
    }

    /**
     * @notice Validates asset is listed and active
     * @param asset Address of the asset to check
     * @return True if asset exists and is active
     * @dev Core contracts should call this before accepting asset deposits
     */
    function isAssetValid(address asset) external view returns (bool) {
        return listedAsset.contains(asset) && assetInfo[asset].active == 1;
    }

    /**
     * @notice Checks if a given asset is at capacity
     * @param asset Address of the asset to check
     * @param additionalAmount Amount potentially being added
     * @return True if adding amount would exceed max supply threshold
     */
    function isAssetAtCapacity(address asset, uint256 additionalAmount) external view returns (bool) {
        if (!listedAsset.contains(asset)) {
            revert AssetNotListed(asset);
        }
        return LendefiInstance.assetTVL(asset) + additionalAmount > assetInfo[asset].maxSupplyThreshold;
    }

    /**
     * @notice Retrieves complete configuration details for a listed asset
     * @param asset The address of the asset to query
     * @return Asset struct containing all configuration parameters
     * @dev Returns the full Asset struct from assetInfo mapping
     */
    function getAssetInfo(address asset) external view returns (Asset memory) {
        if (!listedAsset.contains(asset)) {
            revert AssetNotListed(asset);
        }
        return assetInfo[asset];
    }

    /**
     * @notice Retrieves detailed information about a listed asset
     * @param asset The address of the asset to query
     * @return price Current USD price from oracle
     * @return totalSupplied Total amount of asset supplied as collateral
     * @return maxSupply Maximum supply threshold allowed
     * @return tier Risk classification tier of the asset
     * @dev Aggregates asset configuration and current state into a single view
     */
    function getAssetDetails(address asset)
        external
        view
        returns (uint256 price, uint256 totalSupplied, uint256 maxSupply, CollateralTier tier)
    {
        if (!listedAsset.contains(asset)) {
            revert AssetNotListed(asset);
        }

        Asset memory assetConfig = assetInfo[asset];
        price = getAssetPriceOracle(assetConfig.oracleUSD);
        totalSupplied = LendefiInstance.assetTVL(asset);
        maxSupply = assetConfig.maxSupplyThreshold;
        tier = assetConfig.tier;
    }

    /**
     * @notice Returns an array of all listed asset addresses in the protocol
     * @dev Retrieves assets from the EnumerableSet storing listed assets
     * @return Array of addresses representing all listed assets
     * @custom:complexity O(n) where n is the number of listed assets
     */
    function getListedAssets() external view returns (address[] memory) {
        uint256 length = listedAsset.length();
        address[] memory assets = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            assets[i] = listedAsset.at(i);
        }
        return assets;
    }

    /**
     * @notice Gets the base liquidation bonus percentage for a specific collateral tier
     * @param tier The collateral tier to query
     * @return uint256 The liquidation bonus rate in parts per million (e.g., 0.05e6 = 5%)
     * @dev Alias of getTierLiquidationFee for backward compatibility
     */
    function getLiquidationFee(CollateralTier tier) external view returns (uint256) {
        return tierLiquidationFee[tier];
    }

    /**
     * @notice Checks if an asset is in isolation mode
     * @param asset Address of the asset to check
     * @return True if asset is configured for ISOLATED tier
     */
    function isIsolationAsset(address asset) external view returns (bool) {
        if (!listedAsset.contains(asset)) {
            revert AssetNotListed(asset);
        }
        return assetInfo[asset].tier == CollateralTier.ISOLATED;
    }

    /**
     * @notice Gets the isolation debt cap for an asset
     * @param asset Address of the asset to check
     * @return The maximum debt allowed in isolation mode
     */
    function getIsolationDebtCap(address asset) external view returns (uint256) {
        if (!listedAsset.contains(asset)) {
            revert AssetNotListed(asset);
        }
        return assetInfo[asset].isolationDebtCap;
    }

    /**
     * @notice Gets the current USD price for an asset from the oracle module
     * @param asset The address of the asset to price
     * @return uint256 The asset price in USD (scaled by oracle decimals)
     * @dev Uses the oracle module to get the median price from multiple sources
     */
    function getAssetPrice(address asset) public returns (uint256) {
        if (!listedAsset.contains(asset)) {
            revert AssetNotListed(asset);
        }
        return oracleModule.getAssetPrice(asset);
    }

    /**
     * @notice DEPRECATED: Direct oracle price access
     * @dev This function is maintained for backward compatibility
     * @param oracle The address of the Chainlink price feed oracle
     * @return Price from the oracle (use getAssetPrice instead)
     */
    function getAssetPriceOracle(address oracle) public view returns (uint256) {
        return oracleModule.getSingleOraclePrice(oracle);
    }

    /**
     * @notice Initializes tier parameters with default values
     * @dev Sets up default interest rates and liquidation fees for all tiers
     * @custom:security Should only be called once during initialization
     */
    function _initializeDefaultTierParameters() internal {
        // Initialize tier parameters with sensible defaults
        tierJumpRate[CollateralTier.ISOLATED] = 0.15e6; // 15%
        tierJumpRate[CollateralTier.CROSS_B] = 0.12e6; // 12%
        tierJumpRate[CollateralTier.CROSS_A] = 0.08e6; // 8%
        tierJumpRate[CollateralTier.STABLE] = 0.05e6; // 5%

        tierLiquidationFee[CollateralTier.ISOLATED] = 0.04e6; // 4%
        tierLiquidationFee[CollateralTier.CROSS_B] = 0.03e6; // 3%
        tierLiquidationFee[CollateralTier.CROSS_A] = 0.02e6; // 2%
        tierLiquidationFee[CollateralTier.STABLE] = 0.01e6; // 1%
    }

    /**
     * @dev Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     * @custom:access Restricted to UPGRADER_ROLE
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
