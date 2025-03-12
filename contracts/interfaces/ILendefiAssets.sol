// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title ILendefiAssets
 * @notice Interface for the LendefiAssets module which manages asset configurations and oracle integrations
 * @dev Contains all external facing functions, events, errors and data structures
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {ILendefiOracle} from "./ILendefiOracle.sol";

interface ILendefiAssets {
    /**
     * @notice Risk tiers for collateral assets in ascending order of risk
     * @dev Higher enum value = higher risk tier
     * @custom:values
     *  - STABLE (0): Lowest risk, stablecoins
     *  - CROSS_A (1): Low risk assets
     *  - CROSS_B (2): Medium risk assets
     *  - ISOLATED (3): High risk assets
     */
    enum CollateralTier {
        STABLE,
        CROSS_A,
        CROSS_B,
        ISOLATED
    }

    /**
     * @notice Asset configuration parameters
     * @dev Compact struct for gas efficiency using smaller uint types where possible
     */
    struct Asset {
        uint8 active; // 1 = active, 0 = inactive
        uint8 decimals; // Token decimals (e.g., 18 for most ERC20s)
        uint8 oracleDecimals; // Decimals in oracle price feed (typically 8)
        uint32 borrowThreshold; // LTV for borrowing (e.g., 800 = 80%)
        uint32 liquidationThreshold; // LTV for liquidation (e.g., 900 = 90%)
        address oracleUSD; // Price feed address for asset/USD
        uint256 maxSupplyThreshold; // Maximum amount that can be supplied to protocol
        CollateralTier tier; // Risk classification tier
        uint256 isolationDebtCap; // Maximum debt when used in isolation mode
    }

    /**
     * @notice Emitted when an asset's configuration is updated
     * @param asset The address of the asset that was updated
     */
    event UpdateAssetConfig(address indexed asset);

    /**
     * @notice Emitted when an asset's risk tier is updated
     * @param asset The address of the asset that was updated
     * @param tier The new tier assigned to the asset
     */
    event AssetTierUpdated(address indexed asset, CollateralTier tier);

    /**
     * @notice Emitted when the core protocol address is updated
     * @param newCore The address of the new core protocol contract
     */
    event CoreAddressUpdated(address indexed newCore);

    /**
     * @notice Emitted when the oracle module address is updated
     * @param newOracle The address of the new oracle module
     */
    event OracleModuleUpdated(address indexed newOracle);

    /**
     * @notice Emitted when the contract implementation is upgraded
     * @param upgrader The address that initiated the upgrade
     * @param implementation The address of the new implementation
     */
    event Upgrade(address indexed upgrader, address indexed implementation);

    /**
     * @notice Emitted when tier parameters are updated
     * @param tier The collateral tier that was updated
     * @param borrowRate The new borrow rate for the tier
     * @param liquidationFee The new liquidation fee for the tier
     */
    event TierParametersUpdated(CollateralTier tier, uint256 borrowRate, uint256 liquidationFee);

    /**
     * @notice Error thrown when a proposed interest rate exceeds maximum allowed value
     * @param provided The provided rate value
     * @param maximum The maximum allowed rate value
     */
    error RateTooHigh(uint256 provided, uint256 maximum);

    /**
     * @notice Error thrown when a proposed fee exceeds maximum allowed value
     * @param provided The provided fee value
     * @param maximum The maximum allowed fee value
     */
    error FeeTooHigh(uint256 provided, uint256 maximum);

    /**
     * @notice Error thrown when attempting to interact with an asset that is not listed in the protocol
     * @param asset The address of the non-listed asset
     */
    error AssetNotListed(address asset);

    /**
     * @notice Error thrown when attempting to set a critical address to the zero address
     */
    error ZeroAddressNotAllowed();

    /**
     * @notice Error thrown when liquidation threshold is less than borrow threshold
     * @param liquidationThreshold The liquidation threshold that was too low
     */
    error InvalidLiquidationThreshold(uint256 liquidationThreshold);

    /**
     * @notice Error thrown when liquidation threshold is less than borrow threshold
     * @param borrowThreshold The borrow threshold that was too high
     */
    error InvalidBorrowThreshold(uint256 borrowThreshold);

    /**
     * @notice Initializes the asset management module
     * @param timelock Address with MANAGER_ROLE for asset configuration
     * @param oracle_ Address of oracle module for price feeds
     * @param guardian Address with PAUSER_ROLE for emergency functions
     */
    function initialize(address timelock, address oracle_, address guardian) external;

    /**
     * @notice Pauses all module operations in case of emergency
     * @dev Can only be called by accounts with PAUSER_ROLE
     * @custom:security This is a critical emergency function that should be carefully controlled
     */
    function pause() external;

    /**
     * @notice Unpauses module operations, returning to normal functioning
     * @dev Can only be called by accounts with PAUSER_ROLE
     * @custom:security Should only be called after thorough security verification
     */
    function unpause() external;

    /**
     * @notice Gets the base liquidation bonus percentage for a specific collateral tier
     * @param tier The collateral tier to query
     * @return uint256 The liquidation bonus rate in parts per million (e.g., 0.05e6 = 5%)
     * @dev Alias of getTierLiquidationFee for backward compatibility
     */
    function getLiquidationFee(CollateralTier tier) external view returns (uint256);

    /**
     * @notice Updates the oracle module address
     * @param newOracle New oracle module address
     * @dev Only callable by accounts with MANAGER_ROLE
     */
    function updateOracleModule(address newOracle) external;

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
    ) external;

    /**
     * @notice Updates the risk tier classification for a listed asset
     * @param asset The address of the asset to update
     * @param newTier The new CollateralTier to assign to the asset
     * @dev Changes the risk classification which affects interest rates and liquidation parameters
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     */
    function updateAssetTier(address asset, CollateralTier newTier) external;

    /**
     * @notice Adds an additional oracle data source for an asset
     * @param asset Address of the asset
     * @param oracle Address of the Chainlink price feed to add
     * @param decimals_ Number of decimals in the oracle price feed
     * @dev Allows adding secondary or backup oracles to enhance price reliability
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     */
    // function addAssetOracle(address asset, address oracle, uint8 decimals_) external;

    /**
     * @notice Removes an oracle data source for an asset
     * @param asset Address of the asset
     * @param oracle Address of the Chainlink price feed to remove
     * @dev Allows removing unreliable or deprecated oracles
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     */
    // function removeAssetOracle(address asset, address oracle) external;

    /**
     * @notice Sets the primary oracle for an asset
     * @param asset Address of the asset
     * @param oracle Address of the Chainlink price feed to set as primary
     * @dev The primary oracle is used as a fallback when median calculation fails
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     */
    // function setPrimaryAssetOracle(address asset, address oracle) external;

    /**
     * @notice Updates oracle time thresholds
     * @param freshness Maximum age for all price data (in seconds)
     * @param volatility Maximum age for volatile price data (in seconds)
     * @dev Controls how old price data can be before rejection
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     */
    // function updateOracleTimeThresholds(uint256 freshness, uint256 volatility) external;

    /**
     * @notice Validates asset is listed and active
     * @param asset Address of the asset to check
     * @return True if asset exists and is active
     * @dev Core contracts should call this before accepting asset deposits
     */
    function isAssetValid(address asset) external view returns (bool);

    /**
     * @notice Checks if a given asset is at capacity
     * @param asset Address of the asset to check
     * @param additionalAmount Amount potentially being added
     * @return True if adding amount would exceed max supply threshold
     */
    function isAssetAtCapacity(address asset, uint256 additionalAmount) external view returns (bool);

    /**
     * @notice Gets the current USD price for an asset from the oracle module
     * @param asset The address of the asset to price
     * @return uint256 The asset price in USD (scaled by oracle decimals)
     * @dev Uses the oracle module to get the median price from multiple sources
     */
    function getAssetPrice(address asset) external returns (uint256);

    /**
     * @notice DEPRECATED: Direct oracle price access
     * @dev This function is maintained for backward compatibility
     * @param oracle The address of the Chainlink price feed oracle
     * @return Price from the oracle (use getAssetPrice instead)
     */
    function getAssetPriceOracle(address oracle) external view returns (uint256);

    /**
     * @notice Retrieves complete configuration details for a listed asset
     * @param asset The address of the asset to query
     * @return Asset struct containing all configuration parameters
     * @dev Returns the full Asset struct from assetInfo mapping
     */
    function getAssetInfo(address asset) external view returns (Asset memory);

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
        returns (uint256 price, uint256 totalSupplied, uint256 maxSupply, CollateralTier tier);

    /**
     * @notice Returns an array of all listed asset addresses in the protocol
     * @dev Retrieves assets from the EnumerableSet storing listed assets
     * @return Array of addresses representing all listed assets
     * @custom:complexity O(n) where n is the number of listed assets
     */
    function getListedAssets() external view returns (address[] memory);

    /**
     * @notice Checks if an asset is in isolation mode
     * @param asset Address of the asset to check
     * @return True if asset is configured for ISOLATED tier
     */
    function isIsolationAsset(address asset) external view returns (bool);

    /**
     * @notice Gets the isolation debt cap for an asset
     * @param asset Address of the asset to check
     * @return The maximum debt allowed in isolation mode
     */
    function getIsolationDebtCap(address asset) external view returns (uint256);

    /**
     * @notice Returns the current version of the contract
     * @return Current version number
     */
    function version() external view returns (uint8);

    /**
     * @notice Returns the address of the oracle module
     * @return Address of the oracle module contract
     */
    function oracleModule() external view returns (ILendefiOracle);

    /**
     * @notice Updates the core Lendefi contract address
     * @param newCore New Lendefi core address
     * @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
     */
    function setCoreAddress(address newCore) external;

    /**
     * @notice Gets the interest rate jump multiplier for a specific collateral tier
     * @param tier The collateral tier to query
     * @return Jump rate multiplier applied to base interest rate
     */
    function tierJumpRate(CollateralTier tier) external view returns (uint256);

    /**
     * @notice Gets the liquidation fee percentage for a specific collateral tier
     * @param tier The collateral tier to query
     * @return Liquidation fee as a percentage in basis points
     */
    function tierLiquidationFee(CollateralTier tier) external view returns (uint256);

    /**
     * @notice Updates the risk parameters for a specific collateral tier
     * @param tier The tier to update
     * @param jumpRate New jump rate multiplier for interest calculation
     * @param liquidationFee New liquidation fee percentage for the tier
     * @dev Only callable by accounts with MANAGER_ROLE
     */
    function updateTierParameters(CollateralTier tier, uint256 jumpRate, uint256 liquidationFee) external;

    /**
     * @notice Gets all tier rates in a single call
     * @return jumpRates Array of jump rates for all tiers
     * @return liquidationFees Array of liquidation fees for all tiers
     * @dev Returns arrays indexed by tier enum values (0=STABLE, 1=CROSS_A, etc.)
     */
    function getTierRates() external view returns (uint256[4] memory jumpRates, uint256[4] memory liquidationFees);

    /**
     * @notice Gets the liquidation fee for a specific collateral tier
     * @param tier The collateral tier to query
     * @return Liquidation fee percentage in basis points
     * @dev Main function for getting liquidation fees, preferred over getLiquidationFee
     */
    function getTierLiquidationFee(CollateralTier tier) external view returns (uint256);

    /**
     * @notice Gets the jump rate multiplier for a specific collateral tier
     * @param tier The collateral tier to query
     * @return Jump rate multiplier for interest calculations
     * @dev Used in interest rate model calculations
     */
    function getTierJumpRate(CollateralTier tier) external view returns (uint256);
}
