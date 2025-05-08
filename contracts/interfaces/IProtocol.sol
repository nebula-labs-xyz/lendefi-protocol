// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IASSETS} from "../interfaces/IASSETS.sol";

interface IPROTOCOL {
    // Enums

    /**
     * @notice Current status of a borrowing position
     * @dev Used to track position lifecycle and determine valid operations
     */
    enum PositionStatus {
        LIQUIDATED, // Position has been liquidated
        ACTIVE, // Position is active and can be modified
        CLOSED // Position has been voluntarily closed by the user

    }

    /**
     * @notice Configuration parameters for protocol operations and rewards
     * @dev Centralized storage for all adjustable protocol parameters
     */
    struct ProtocolConfig {
        uint256 profitTargetRate; // Target profit rate (min 0.25%)
        uint256 borrowRate; // Base borrow rate (min 1%)
        uint256 rewardAmount; // Target reward amount (max 10,000 tokens)
        uint256 rewardInterval; // Reward interval in seconds (min 90 days)
        uint256 rewardableSupply; // Minimum rewardable supply (min 20,000 USDC)
        uint256 liquidatorThreshold; // Minimum liquidator token threshold (min 10 tokens)
        uint256 flashLoanFee; // Fee percentage for flash loans in basis points (max 100)
    }
    /**
     * @notice User borrowing position data
     * @dev Core data structure tracking user's debt and position configuration
     */

    struct UserPosition {
        bool isIsolated; // Whether position uses isolation mode
        uint256 debtAmount; // Current debt principal without interest
        uint256 lastInterestAccrual; // Timestamp of last interest accrual
        PositionStatus status; // Current lifecycle status of the position
        address vault; // Address of the vault contract for this position
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

    /**
     * @notice Emitted when protocol is initialized
     * @param admin Address of the admin who initialized the contract
     */
    event Initialized(address indexed admin);

    /**
     * @notice Emitted when implementation contract is upgraded
     * @param admin Address of the admin who performed the upgrade
     * @param implementation Address of the new implementation
     */
    event Upgrade(address indexed admin, address indexed implementation);

    /**
     * @dev Emitted when protocol Config is updated
     */
    event ProtocolConfigUpdated(
        uint256 profitTargetRate,
        uint256 borrowRate,
        uint256 rewardAmount,
        uint256 interval,
        uint256 supplyAmount,
        uint256 liquidatorAmount,
        uint256 flashLoanFee
    );

    /**
     * @notice Emitted when a user supplies liquidity to the protocol
     * @param supplier Address of the liquidity supplier
     * @param amount Amount of USDC supplied
     */
    event SupplyLiquidity(address indexed supplier, uint256 amount);

    /**
     * @notice Emitted when LP tokens are exchanged for underlying assets
     * @param exchanger Address of the user exchanging tokens
     * @param amount Amount of LP tokens exchanged
     * @param value Value received in exchange
     */
    event Exchange(address indexed exchanger, uint256 amount, uint256 value);

    /**
     * @notice Emitted when collateral is supplied to a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param asset Address of the supplied collateral asset
     * @param amount Amount of collateral supplied
     */
    event SupplyCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);

    /**
     * @notice Emitted when collateral is withdrawn from a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param asset Address of the withdrawn collateral asset
     * @param amount Amount of collateral withdrawn
     */
    event WithdrawCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);

    /**
     * @notice Emitted when a new borrowing position is created
     * @param user Address of the position owner
     * @param positionId ID of the newly created position
     * @param isIsolated Whether the position was created in isolation mode
     */
    event PositionCreated(address indexed user, uint256 indexed positionId, bool isIsolated);

    /**
     * @notice Emitted when a position is closed
     * @param user Address of the position owner
     * @param positionId ID of the closed position
     */
    event PositionClosed(address indexed user, uint256 indexed positionId);

    /**
     * @notice Emitted when a user borrows from a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param amount Amount borrowed
     */
    event Borrow(address indexed user, uint256 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when debt is repaid
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param amount Amount repaid
     */
    event Repay(address indexed user, uint256 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when interest is accrued on a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param amount Interest amount accrued
     */
    event InterestAccrued(address indexed user, uint256 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when rewards are distributed
     * @param user Address of the reward recipient
     * @param amount Reward amount distributed
     */
    event Reward(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a flash loan is executed
     * @param initiator Address that initiated the flash loan
     * @param receiver Contract receiving the flash loan
     * @param token Address of the borrowed token
     * @param amount Amount borrowed
     * @param fee Fee charged for the flash loan
     */
    event FlashLoan(
        address indexed initiator, address indexed receiver, address indexed token, uint256 amount, uint256 fee
    );

    /**
     * @notice Emitted when a position is liquidated
     * @param user The address of the position owner
     * @param positionId The ID of the inactive position
     * @param liquidator The address of the liquidator
     */
    event Liquidated(address indexed user, uint256 indexed positionId, address liquidator);

    /**
     * @notice Emitted when an asset's total value locked (TVL) is updated
     * @param asset The address of the asset that was updated
     * @param amount The new TVL amount
     */
    event TVLUpdated(address indexed asset, uint256 amount);

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

    /**
     * @notice Event emitted when a new vault is created
     * @param user Owner of the position
     * @param positionId ID of the position
     * @param vault Address of the created vault
     */
    event VaultCreated(address indexed user, uint256 indexed positionId, address vault);
    //////////////////////////////////////////////////
    // -------------------Errors-------------------//
    /////////////////////////////////////////////////

    /// @notice Thrown when attempting to set a critical address to the zero address
    error ZeroAddressNotAllowed();

    /// @notice Thrown when attempting to execute an upgrade before timelock expires
    /// @param timeRemaining The time remaining until the upgrade can be executed
    error UpgradeTimelockActive(uint256 timeRemaining);

    /// @notice Thrown when attempting to execute an upgrade that wasn't scheduled
    error UpgradeNotScheduled();

    /// @notice Thrown when implementation address doesn't match scheduled upgrade
    /// @param scheduledImpl The address that was scheduled for upgrade
    /// @param attemptedImpl The address that was attempted to be used
    error ImplementationMismatch(address scheduledImpl, address attemptedImpl);

    /**
     * @notice Thrown when attempting to create more positions than the protocol limit
     * @dev The protocol enforces a maximum number of positions per user
     */
    error MaxPositionLimitReached();

    /**
     * @notice Thrown when attempting to interact with a non-existent position
     * @dev Functions that require a valid position ID will throw this error
     */
    error InvalidPosition();

    /**
     * @notice Thrown when attempting to modify a position that is closed or liquidated
     * @dev Operations are only allowed on positions with ACTIVE status
     */
    error InactivePosition();

    /**
     * @notice Thrown when attempting to use an asset that isn't listed in the protocol
     * @dev Assets must be configured through governance before they can be used
     */
    error NotListed();

    /**
     * @notice Thrown when an operation is attempted with a zero amount
     * @dev Used in borrow, repay, supply and withdraw operations
     */
    error ZeroAmount();

    /**
     * @notice Thrown when attempting to set an invalid flash loan fee
     * @dev Fee must be within the allowed range (0-100 basis points)
     */
    error InvalidFee();

    /**
     * @notice Thrown when the protocol does not have enough liquidity for an operation
     * @dev Used in borrow and flash loan operations
     */
    error LowLiquidity();

    /**
     * @notice Thrown when a flash loan operation fails to execute properly
     * @dev The receiver contract must return true from executeOperation
     */
    error FlashLoanFailed();

    /**
     * @notice Thrown when a flash loan isn't repaid in the same transaction
     * @dev The full amount plus fee must be returned to the protocol
     */
    error RepaymentFailed();

    /**
     * @notice Thrown when attempting to supply an asset beyond its protocol-wide capacity
     * @dev Each asset has a maximum supply limit for risk management
     */
    error AssetCapacityReached();

    /**
     * @notice Thrown when attempting to violate isolation mode rules
     * @dev Isolated assets cannot be used in cross-collateralized positions
     */
    error IsolatedAssetViolation();

    /**
     * @notice Thrown when attempting to add an incompatible asset to an isolated position
     * @dev Isolated positions can only contain one asset type
     */
    error InvalidAssetForIsolation();

    /**
     * @notice Thrown when attempting to add more assets than the position limit
     * @dev Each position has a maximum number of different asset types it can hold
     */
    error MaximumAssetsReached();

    /**
     * @notice Thrown when attempting to withdraw more than the available balance
     * @dev Used in withdrawCollateral and interpositionalTransfer operations
     */
    error LowBalance();

    /**
     * @notice Thrown when a liquidator doesn't hold enough governance tokens
     * @dev Liquidators must meet a minimum governance token threshold
     */
    error NotEnoughGovernanceTokens();

    /**
     * @notice Thrown when attempting to liquidate a healthy position
     * @dev Positions must be below liquidation threshold to be liquidated
     */
    error NotLiquidatable();

    /**
     * @notice Thrown when attempting to set an invalid profit target
     * @dev Profit target must be above the minimum threshold
     */
    error InvalidProfitTarget();

    /**
     * @notice Thrown when attempting to set an invalid borrow rate
     * @dev Borrow rate must be above the minimum threshold
     */
    error InvalidBorrowRate();

    /**
     * @notice Thrown when attempting to set an invalid reward amount
     * @dev Reward amount must be within allowed limits
     */
    error InvalidRewardAmount();

    /**
     * @notice Thrown when attempting to set an invalid reward interval
     * @dev Reward interval must be above the minimum threshold
     */
    error InvalidInterval();

    /**
     * @notice Thrown when attempting to set an invalid rewardable supply amount
     * @dev Rewardable supply must be above the minimum threshold
     */
    error InvalidSupplyAmount();

    /**
     * @notice Thrown when attempting to set an invalid liquidator threshold
     * @dev Liquidator threshold must be above the minimum value
     */
    error InvalidLiquidatorThreshold();

    /**
     * @notice Thrown when attempting to borrow beyond an isolated asset's debt cap
     * @dev Isolated assets have maximum protocol-wide debt limits
     */
    error IsolationDebtCapExceeded();

    /**
     * @notice Thrown when attempting to borrow or withdraw beyond a position's credit limit
     * @dev The operation would make the position undercollateralized
     */
    error CreditLimitExceeded();

    /**
     * @notice Thrown when a user tries to deposit a collateral asset amount greater than 3% of total uniswap pool liquidity
     * @dev Used in operations that require positions to be liquidatable
     */
    error PoolLiquidityLimitReached();
    //////////////////////////////////////////////////
    // ---------------Core functions---------------//
    /////////////////////////////////////////////////

    /**
     * @notice Initializes the protocol with core dependencies and parameters
     * @param usdc The address of the USDC stablecoin used for borrowing and liquidity
     * @param govToken The address of the governance token used for liquidator eligibility
     * @param ecosystem The address of the ecosystem contract that manages rewards
     * @param treasury_ The address of the treasury that collects protocol fees
     * @param timelock_ The address of the timelock contract for governance actions
     * @param yieldToken The address of the yield token contract
     * @param vaultFactory The address of the vault factory contract
     * @param multisig The address of the initial admin with pausing capability
     * @dev Sets up access control roles and default protocol parameters
     */
    function initialize(
        address usdc,
        address govToken,
        address ecosystem,
        address treasury_,
        address timelock_,
        address yieldToken,
        address assetsModule,
        address vaultFactory,
        address multisig
    ) external;

    /**
     * @notice Returns the total value locked for a specific asset
     * @param asset The address of the asset to query
     * @return Total amount of the asset held in the protocol
     */
    function assetTVL(address asset) external view returns (uint256);

    /**
     * @notice Pauses all protocol operations in case of emergency
     * @dev Can only be called by authorized governance roles
     */
    function pause() external;

    /**
     * @notice Unpauses the protocol to resume normal operations
     * @dev Can only be called by authorized governance roles
     */
    function unpause() external;

    // Flash loan function
    /**
     * @notice Executes a flash loan, allowing borrowing without collateral if repaid in same transaction
     * @param receiver The contract address that will receive the flash loaned tokens
     * @param amount The amount of tokens to flash loan
     * @param params Arbitrary data to pass to the receiver contract
     * @dev Receiver must implement IFlashLoanReceiver interface
     */
    function flashLoan(address receiver, uint256 amount, bytes calldata params) external;

    // Position management functions

    /**
     * @notice Allows users to supply liquidity (USDC) to the protocol
     * @param amount The amount of USDC to supply
     * @dev Mints LP tokens representing the user's share of the liquidity pool
     */
    function supplyLiquidity(uint256 amount) external;

    /**
     * @notice Allows users to withdraw liquidity by burning LP tokens
     * @param amount The amount of LP tokens to burn
     */
    function exchange(uint256 amount) external;

    /**
     * @notice Allows users to supply collateral assets to a borrowing position
     * @param asset The address of the collateral asset to supply
     * @param amount The amount of the asset to supply
     * @param positionId The ID of the position to supply collateral to
     */
    function supplyCollateral(address asset, uint256 amount, uint256 positionId) external;

    /**
     * @notice Allows users to withdraw collateral assets from a borrowing position
     * @param asset The address of the collateral asset to withdraw
     * @param amount The amount of the asset to withdraw
     * @param positionId The ID of the position to withdraw from
     * @dev Will revert if withdrawal would make position undercollateralized
     */
    function withdrawCollateral(address asset, uint256 amount, uint256 positionId) external;

    /**
     * @notice Creates a new borrowing position for the caller
     * @param asset The address of the initial collateral asset
     * @param isIsolated Whether to create the position in isolation mode
     */
    function createPosition(address asset, bool isIsolated) external;

    /**
     * @notice Allows borrowing stablecoins against collateral in a position
     * @param positionId The ID of the position to borrow against
     * @param amount The amount of stablecoins to borrow
     * @dev Will revert if borrowing would exceed the position's credit limit
     */
    function borrow(uint256 positionId, uint256 amount) external;

    /**
     * @notice Allows users to repay debt on a borrowing position
     * @param positionId The ID of the position to repay debt for
     * @param amount The amount of debt to repay
     */
    function repay(uint256 positionId, uint256 amount) external;

    /**
     * @notice Closes a position after all debt is repaid and withdraws remaining collateral
     * @param positionId The ID of the position to close
     * @dev Position must have zero debt to be closed
     */
    function exitPosition(uint256 positionId) external;

    /**
     * @notice Liquidates an undercollateralized position
     * @param user The address of the position owner
     * @param positionId The ID of the position to liquidate
     * @dev Caller must hold sufficient governance tokens to be eligible as a liquidator
     */
    function liquidate(address user, uint256 positionId) external;

    // View functions - Position information

    /**
     * @notice Gets the total number of positions created by a user
     * @param user The address of the user
     * @return The number of positions the user has created
     */
    function getUserPositionsCount(address user) external view returns (uint256);

    /**
     * @notice Gets all positions created by a user
     * @param user The address of the user
     * @return An array of UserPosition structs
     */
    function getUserPositions(address user) external view returns (UserPosition[] memory);

    /**
     * @notice Gets a specific position's data
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return UserPosition struct containing position data
     */
    function getUserPosition(address user, uint256 positionId) external view returns (UserPosition memory);

    /**
     * @notice Gets the amount of a specific asset in a position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @param asset The address of the collateral asset
     * @return The amount of the asset in the position
     */
    function getCollateralAmount(address user, uint256 positionId, address asset) external view returns (uint256);

    /**
     * @notice Calculates the current debt amount including accrued interest
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The total debt amount with interest
     */
    function calculateDebtWithInterest(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Calculates the liquidation fee for a position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The liquidation fee amount
     */
    function getPositionLiquidationFee(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Calculates the maximum amount a user can borrow against their position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The maximum borrowing capacity (credit limit)
     */
    function calculateCreditLimit(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Calculates the total USD value of all collateral in a position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The total value of all collateral assets in the position in USD terms
     * @dev Aggregates values across all collateral assets using oracle price feeds
     */
    function calculateCollateralValue(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Gets the timestamp of the last liquidity reward accrual for a user
     * @param user The address of the user
     * @return The timestamp when rewards were last accrued
     */
    function getLiquidityAccrueTimeIndex(address user) external view returns (uint256);

    /**
     * @notice Checks if a position is eligible for liquidation
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return True if the position can be liquidated, false otherwise
     */
    function isLiquidatable(address user, uint256 positionId) external view returns (bool);

    /**
     * @notice Calculates the health factor of a borrowing position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The position's health factor (scaled by WAD)
     * @dev Health factor > 1 means position is healthy, < 1 means liquidatable
     */
    function healthFactor(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Gets all collateral assets in a position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return An array of asset addresses in the position
     */
    function getPositionCollateralAssets(address user, uint256 positionId) external view returns (address[] memory);

    /**
     * @notice Calculates the current utilization rate of the protocol
     * @return u The utilization rate (scaled by WAD)
     * @dev Utilization = totalBorrow / totalSuppliedLiquidity
     */
    function getUtilization() external view returns (uint256 u);

    /**
     * @notice Gets the current supply interest rate
     * @return The supply interest rate (scaled by RAY)
     */
    function getSupplyRate() external view returns (uint256);

    /**
     * @notice Gets the current borrow interest rate for a specific tier
     * @param tier The collateral tier to query
     * @return The borrow interest rate (scaled by RAY)
     */
    function getBorrowRate(IASSETS.CollateralTier tier) external view returns (uint256);

    /**
     * @notice Checks if a user is eligible for rewards
     * @param user The address of the user
     * @return True if user is eligible for rewards, false otherwise
     */
    function isRewardable(address user) external view returns (bool);

    /**
     * @notice Gets the current protocol version
     * @return The protocol version number
     */
    function version() external view returns (uint8);

    // State view functions
    /**
     * @notice Gets the total amount borrowed from the protocol
     * @return The total borrowed amount
     */
    function totalBorrow() external view returns (uint256);

    /**
     * @notice Gets the total liquidity supplied to the protocol
     * @return The total supplied liquidity
     */
    function totalSuppliedLiquidity() external view returns (uint256);

    /**
     * @notice Gets the total interest accrued by borrowers
     * @return The total accrued borrower interest
     */
    function totalAccruedBorrowerInterest() external view returns (uint256);

    /**
     * @notice Gets the total interest accrued by suppliers
     * @return The total accrued supplier interest
     */
    function totalAccruedSupplierInterest() external view returns (uint256);

    /**
     * @notice Gets the total fees collected from flash loans
     * @return The total flash loan fees collected
     */
    function totalFlashLoanFees() external view returns (uint256);

    /**
     * @notice Gets the address of the treasury contract
     * @return The treasury contract address
     */
    function treasury() external view returns (address);

    /**
     * @notice Determines the collateral tier of a position for risk assessment
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The position's collateral tier (STABLE, CROSS_A, CROSS_B, or ISOLATED)
     * @dev For cross-collateral positions, returns the tier of the riskiest asset
     * @dev For isolated positions, returns ISOLATED tier regardless of asset
     */
    function getPositionTier(address user, uint256 positionId) external view returns (IASSETS.CollateralTier);

    /**
     * @notice Gets the current protocol config
     * @return ProtocoConfig struct containing all protocol parameters
     */
    function getConfig() external view returns (ProtocolConfig memory);

    /**
     * @notice Checks if the protocol is solvent based on total asset value and borrow amount
     * @dev Ensures that the total asset value exceeds the total borrow amount
     * @return A tuple containing:
     *   - A boolean indicating if the protocol is solvent (total assets >= total borrows)
     *   - The total asset value in USD terms
     */
    function isCollateralized() external view returns (bool, uint256);
}
