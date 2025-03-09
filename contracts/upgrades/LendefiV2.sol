// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 *      ,,       ,,  ,,    ,,,    ,,   ,,,      ,,,    ,,,   ,,,          ,,,
 *      ███▄     ██  ███▀▀▀███▄   ██▄██▀▀██▄    ██▌     ██▌  ██▌        ▄▄███▄▄
 *     █████,   ██  ██▌          ██▌     └██▌  ██▌     ██▌  ██▌        ╟█   ╙██
 *     ██ └███ ██  ██▌└██╟██   l███▀▄███╟█    ██      ╟██  ╟█i        ▐█▌█▀▄██╟
 *    ██   ╙████  ██▌          ██▌     ,██▀   ╙██    ▄█▀  ██▌        ▐█▌    ██
 *   ██     ╙██  █████▀▀▄██▀  ██▌██▌╙███▀`     ▀██▄██▌   █████▀▄██▀ ▐█▌    ██╟
 *  ¬─      ¬─   ¬─¬─  ¬─¬─'  ¬─¬─¬─¬ ¬─'       ¬─¬─    '¬─   '─¬   ¬─     ¬─'
 *
 *      ,,,          ,,     ,,,    ,,,      ,,   ,,,  ,,,      ,,,    ,,,   ,,,    ,,,   ,,,
 *      ██▌          ███▀▀▀███▄   ███▄     ██   ██▄██▀▀██▄     ███▀▀▀███▄   ██▄██▀▀██▄  ▄██╟
 *     ██▌          ██▌          █████,   ██   ██▌     └██▌   ██▌          ██▌          ██
 *    ╟█l          ███▀▄███     ██ └███  ██   l██       ██╟  ███▀▄███     ██▌└██╟██    ╟█i
 *    ██▌         ██▌          ██    ╙████    ██▌     ,██▀  ██▌          ██▌           ██
 *   █████▀▄██▀  █████▀▀▄██▀  ██      ╙██    ██▌██▌╙███▀`  █████▀▀▄██▀  ╙██           ╙██
 *  ¬─     ¬─   ¬─¬─  ¬─¬─'  ¬─¬─     ¬─'   ¬─¬─   '¬─    '─¬   ¬─      ¬─'           ¬─'
 * @title Lendefi Protocol V2 (for Upgrade tests)
 * @notice An efficient monolithic lending protocol
 * @author alexei@nebula-labs(dot)xyz
 * @dev Implements a secure and upgradeable collateralized lending protocol with Yield Token
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 *
 * Core Features:
 * - Lending and borrowing with multiple collateral tiers
 * - Isolated and cross-collateral positions
 * - Dynamic interest rates based on utilization
 * - Flash loans with configurable fees
 * - Liquidation mechanism with tier-based bonuses
 * - Liquidity provider rewards system
 * - Price oracle integration with safety checks
 *
 * Security Features:
 * - Role-based access control
 * - Pausable functionality
 * - Non-reentrant operations
 * - Upgradeable contract pattern
 * - Oracle price validation
 * - Supply and debt caps
 *
 * @custom:roles
 * - DEFAULT_ADMIN_ROLE: Contract administration
 * - PAUSER_ROLE: Emergency pause/unpause
 * - MANAGER_ROLE: Protocol parameter updates
 * - UPGRADER_ROLE: Contract upgrades
 *
 * @custom:tiers Collateral tiers in ascending order of risk:
 * - STABLE: Lowest risk, stablecoins
 * - CROSS_A: Low risk assets
 * - CROSS_B: Medium risk assets
 * - ISOLATED: High risk assets
 *
 * @custom:inheritance
 * - IPROTOCOL: Protocol interface
 * - PausableUpgradeable: Pausable token operations
 * - AccessControlUpgradeable: Role-based access
 * - ReentrancyGuardUpgradeable: Reentrancy protection
 * - UUPSUpgradeable: Upgrade pattern
 * - LendefiRates: Interest calculations
 */

import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {IECOSYSTEM} from "../interfaces/IEcosystem.sol";
import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";
import {ILendefiYieldToken} from "../interfaces/ILendefiYieldToken.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20, SafeERC20 as TH} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ILendefiAssets} from "../interfaces/ILendefiAssets.sol";
import {LendefiRates} from "../lender/lib/LendefiRates.sol";

/// @custom:oz-upgrades-from contracts/lender/Lendefi.sol:Lendefi
contract LendefiV2 is
    IPROTOCOL,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    /**
     * @dev Utility for set operations on address collections
     */
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    /**
     * @dev Standard decimals for percentage calculations (1e6 = 100%)
     */
    uint256 internal constant WAD = 1e6;

    /**
     * @dev Role identifier for users authorized to pause/unpause the protocol
     */
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /**
     * @dev Role identifier for users authorized to manage protocol parameters
     */
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /**
     * @dev Role identifier for users authorized to upgrade the contract
     */
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // State variables
    /**
     * @dev Reference to the USDC stablecoin contract used for lending/borrowing
     */
    IERC20 internal usdcInstance;

    /**
     * @dev Reference to the protocol's governance token contract
     */
    IERC20 internal tokenInstance;

    /**
     * @dev Reference to the ecosystem contract for managing rewards
     */
    IECOSYSTEM internal ecosystemInstance;

    /**
     * @dev Reference to the yield token (LP token) contract
     */
    ILendefiYieldToken internal yieldTokenInstance;

    /**
     * @dev Reference to the assets module for collateral management
     */
    ILendefiAssets internal assetsModule;

    /**
     * @notice Total amount borrowed from the protocol (in USDC)
     */
    uint256 public totalBorrow;

    /**
     * @notice Total liquidity supplied to the protocol (in USDC)
     */
    uint256 public totalSuppliedLiquidity;

    /**
     * @notice Cumulative interest accrued by borrowers since protocol inception
     */
    uint256 public totalAccruedBorrowerInterest;

    /**
     * @notice Cumulative interest earned by suppliers since protocol inception
     */
    uint256 public totalAccruedSupplierInterest;

    /**
     * @notice Target amount of governance tokens for LP rewards per interval
     */
    uint256 public targetReward;

    /**
     * @notice Time period for LP reward eligibility in seconds
     */
    uint256 public rewardInterval;

    /**
     * @notice Minimum supply amount required for reward eligibility (in USDC)
     */
    uint256 public rewardableSupply;

    /**
     * @notice Base annual interest rate for borrowing (in WAD format)
     */
    uint256 public baseBorrowRate;

    /**
     * @notice Target profit rate for the protocol (in WAD format)
     */
    uint256 public baseProfitTarget;

    /**
     * @notice Minimum governance token balance required to perform liquidations
     */
    uint256 public liquidatorThreshold;

    /**
     * @notice Fee percentage charged for flash loans (in basis points)
     */
    uint256 public flashLoanFee;

    /**
     * @notice Total fees collected from flash loans since protocol inception
     */
    uint256 public totalFlashLoanFees;

    /**
     * @notice Current contract implementation version
     */
    uint8 public version;

    /**
     * @notice Address of the treasury that receives protocol fees
     */
    address public treasury;

    // Mappings
    /**
     * @dev Stores all borrowing positions for each user
     * @dev Key: User address, Value: Array of positions
     */
    mapping(address => UserPosition[]) internal positions;

    /**
     * @dev Tracks collateral amounts for each asset in each position
     * @dev Keys: User address, Position ID, Asset address, Value: Amount
     */
    mapping(address => mapping(uint256 => mapping(address => uint256))) internal positionCollateralAmounts;

    /**
     * @dev Tracks the set of collateral assets for each position
     * @dev Keys: User address, Position ID, Value: Set of asset addresses
     */
    mapping(address => mapping(uint256 => EnumerableSet.AddressSet)) internal positionCollateralAssets;

    /**
     * @dev Tracks the last time rewards were accrued for each liquidity provider
     * @dev Key: User address, Value: Timestamp of last accrual
     */
    mapping(address src => uint256 time) internal liquidityAccrueTimeIndex;

    /**
     * @dev Reserved storage gap for future upgrades
     */
    uint256[8] private __gap;

    /**
     * @dev Ensures the position exists for the given user
     * @param user Address of the position owner
     * @param positionId ID of the position to check
     */
    modifier validPosition(address user, uint256 positionId) {
        require(positionId < positions[user].length, "IN");
        _;
    }

    /**
     * @dev Ensures the position exists and is in active status
     * @param user Address of the position owner
     * @param positionId ID of the position to check
     */
    modifier activePosition(address user, uint256 positionId) {
        require(positionId < positions[user].length, "IN");
        require(positions[user][positionId].status == PositionStatus.ACTIVE, "INA");
        _;
    }

    /**
     * @dev Ensures the asset is whitelisted in the protocol
     * @param asset Address of the asset to validate
     */
    modifier validAsset(address asset) {
        require(assetsModule.isAssetValid(asset), "NL");
        _;
    }

    /**
     * @dev Ensures the amount is greater than zero
     * @param amount The amount to check
     */
    modifier validAmount(uint256 amount) {
        require(amount > 0, "ZA"); // Zero amount check
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the Lendefi protocol with core contract references and default parameters
     * @dev Sets up roles, connects to external contracts, and initializes protocol parameters
     * @param usdc Address of the USDC token contract used for lending and borrowing
     * @param govToken Address of the governance token contract used for protocol governance
     * @param ecosystem Address of the ecosystem contract for managing rewards
     * @param treasury_ Address of the treasury for collecting protocol fees
     * @param timelock_ Address of the timelock contract for governance actions
     * @param yieldToken Address of the yield token (LP token) contract
     * @param assetsModule_ Address of the assets module for managing supported collateral
     * @param guardian Address of the protocol guardian with emergency powers
     * @custom:access-control Can only be called once during deployment
     * @custom:events Emits an Initialized event
     */
    function initialize(
        address usdc,
        address govToken,
        address ecosystem,
        address treasury_,
        address timelock_,
        address yieldToken,
        address assetsModule_,
        address guardian
    ) external initializer {
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, timelock_);
        _grantRole(PAUSER_ROLE, guardian);
        _grantRole(MANAGER_ROLE, timelock_);
        _grantRole(UPGRADER_ROLE, guardian);

        usdcInstance = IERC20(usdc);
        tokenInstance = IERC20(govToken);
        ecosystemInstance = IECOSYSTEM(payable(ecosystem));
        treasury = treasury_;
        yieldTokenInstance = ILendefiYieldToken(yieldToken);
        assetsModule = ILendefiAssets(assetsModule_);

        // Initialize default parameters
        targetReward = 2_000 ether;
        rewardInterval = 180 days;
        rewardableSupply = 100_000 * WAD;
        baseBorrowRate = 0.06e6;
        baseProfitTarget = 0.01e6;
        liquidatorThreshold = 20_000 ether;

        ++version;
        emit Initialized(msg.sender);
    }

    /**
     * @notice Pauses the protocol in an emergency situation
     * @dev When paused, all state-changing functions will revert
     * @custom:access-control Restricted to PAUSER_ROLE
     * @custom:events Emits a Paused event from PausableUpgradeable
     */
    function pause() external override onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the protocol after an emergency is resolved
     * @dev Restores full functionality to all state-changing functions
     * @custom:access-control Restricted to PAUSER_ROLE
     * @custom:events Emits an Unpaused event from PausableUpgradeable
     */
    function unpause() external override onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Executes a flash loan of USDC to the specified receiver
     * @dev This function facilitates uncollateralized loans that must be repaid within the same transaction:
     *      1. Validates available protocol liquidity
     *      2. Calculates flash loan fee
     *      3. Transfers requested amount to receiver
     *      4. Calls receiver's executeOperation function
     *      5. Verifies loan repayment plus fee
     *      6. Updates protocol fee accounting
     *
     * The receiver contract must implement IFlashLoanReceiver interface and handle the loan
     * in its executeOperation function. The loan plus fee must be repaid before the
     * transaction completes.
     *
     * @param receiver Address of the contract receiving and handling the flash loan
     * @param amount Amount of USDC to borrow
     * @param params Arbitrary data to pass to the receiver for execution context
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Amount must not exceed protocol's available liquidity
     *   - Receiver must implement IFlashLoanReceiver interface
     *   - Loan plus fee must be repaid within the same transaction
     *
     * @custom:state-changes
     *   - Temporarily reduces protocol USDC balance by amount
     *   - Increases totalFlashLoanFees by the fee amount after repayment
     *   - Final protocol USDC balance increases by fee amount
     *
     * @custom:emits
     *   - FlashLoan(msg.sender, receiver, address(usdcInstance), amount, fee)
     *
     * @custom:access-control Available to any caller when protocol is not paused
     * @custom:error-codes
     *   - "LL": Low liquidity (amount exceeds available protocol liquidity)
     *   - "FLF": Flash loan failed (executeOperation returned false)
     *   - "RPF": Repay failed (final balance less than required amount)
     */
    function flashLoan(address receiver, uint256 amount, bytes calldata params)
        external
        validAmount(amount)
        nonReentrant
        whenNotPaused
    {
        uint256 initialBalance = usdcInstance.balanceOf(address(this));
        require(amount <= initialBalance, "LL"); // Low liquidity

        // Calculate fee and record initial balance
        uint256 fee = (amount * flashLoanFee) / 10000;
        uint256 requiredBalance = initialBalance + fee;

        // Transfer flash loan amount
        TH.safeTransfer(usdcInstance, receiver, amount);

        // Execute flash loan operation
        bool success =
            IFlashLoanReceiver(receiver).executeOperation(address(usdcInstance), amount, fee, msg.sender, params);

        // Verify both the return value AND the actual balance
        require(success, "FLF"); // Flash loan failed (incorrect return value)

        uint256 currentBalance = usdcInstance.balanceOf(address(this));
        require(currentBalance >= requiredBalance, "RPF"); // Repay failed (insufficient funds returned)

        // Update protocol state only after all verifications succeed
        totalFlashLoanFees += fee;
        emit FlashLoan(msg.sender, receiver, address(usdcInstance), amount, fee);
    }

    /**
     * @notice Updates the fee percentage charged for flash loans
     * @dev Fee is expressed in basis points (e.g., 10 = 0.1%)
     * @param newFee New flash loan fee in basis points, capped at 1% (100 basis points)
     * @custom:access-control Restricted to MANAGER_ROLE
     * @custom:events Emits an UpdateFlashLoanFee event
     */
    function updateFlashLoanFee(uint256 newFee) external onlyRole(MANAGER_ROLE) {
        require(newFee <= 100, "IF"); // Fee too high

        flashLoanFee = newFee;
        emit UpdateFlashLoanFee(newFee);
    }

    /**
     * @notice Supplies USDC liquidity to the lending pool
     * @dev This function handles the process of supplying liquidity to the protocol:
     *      1. Calculating the appropriate amount of yield tokens to mint based on current exchange rate
     *      2. Updating the protocol's total supplied liquidity accounting
     *      3. Recording the timestamp for reward calculation purposes
     *      4. Minting yield tokens to the supplier
     *      5. Transferring USDC from the supplier to the protocol
     *
     * The yield token amount (value) is calculated differently based on protocol state:
     * - Normal operation: (amount * existing_yield_token_supply) / total_protocol_assets
     * - Initial supply or zero utilization: value equals amount (1:1 ratio)
     *
     * This ensures that early suppliers don't get diluted and later suppliers receive
     * tokens proportional to the current asset-to-yield-token ratio.
     *
     * @param amount Amount of USDC to supply to the protocol
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Caller must have approved sufficient USDC to the protocol
     *
     * @custom:state-changes
     *   - Increases totalSuppliedLiquidity by amount
     *   - Sets liquidityAccrueTimeIndex[msg.sender] to current timestamp
     *   - Mints yield tokens to msg.sender based on calculated exchange rate
     *   - Transfers USDC from msg.sender to the protocol
     *
     * @custom:emits
     *   - SupplyLiquidity(msg.sender, amount)
     *
     * @custom:access-control Available to any caller when protocol is not paused
     * @custom:error-codes
     *   - Reverts if protocol is paused (from whenNotPaused modifier)
     *   - Reverts on reentrancy (from nonReentrant modifier)
     *   - Reverts if USDC transfer fails
     */
    function supplyLiquidity(uint256 amount) external validAmount(amount) nonReentrant whenNotPaused {
        uint256 total = usdcInstance.balanceOf(address(this)) + totalBorrow;
        uint256 supply = yieldTokenInstance.totalSupply();
        uint256 value = (amount * supply) / (total > 0 ? total : WAD);
        uint256 utilization = getUtilization();
        if (supply == 0 || utilization == 0) value = amount;

        totalSuppliedLiquidity += amount;

        liquidityAccrueTimeIndex[msg.sender] = block.timestamp;
        yieldTokenInstance.mint(msg.sender, value);

        emit SupplyLiquidity(msg.sender, amount);
        TH.safeTransferFrom(usdcInstance, msg.sender, address(this), amount);
    }

    /**
     * @notice Exchanges yield tokens for USDC, withdrawing liquidity from the protocol
     * @dev This function handles the withdrawal of liquidity from the protocol, which includes:
     *      1. Calculating the user's proportional share of the total protocol assets
     *      2. Potentially taking protocol profit to the treasury
     *      3. Updating protocol liquidity and interest accounting
     *      4. Processing rewards if the user is eligible
     *      5. Burning the yield tokens
     *      6. Transferring USDC to the user
     *
     * The redemption value is based on the current exchange rate determined by:
     * - Total protocol assets (USDC on hand + outstanding loans)
     * - Total yield token supply
     * This ensures users receive their proportional share of interest earned since deposit.
     *
     * If the protocol has exceeded its profit target, a portion of the withdrawal amount
     * is minted as yield tokens to the treasury before calculating the user's redemption value.
     *
     * @param amount Amount of yield tokens to exchange for underlying USDC
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Caller must have sufficient yield tokens
     *   - Protocol must have sufficient USDC to fulfill the withdrawal
     *
     * @custom:state-changes
     *   - Decreases totalSuppliedLiquidity by the base amount of the withdrawal
     *   - Increases totalAccruedSupplierInterest by any interest earned
     *   - Burns yield tokens from the caller
     *   - Potentially mints yield tokens to the treasury (profit target)
     *   - May reset the caller's liquidityAccrueTimeIndex if rewards are processed
     *
     * @custom:emits
     *   - Exchange(msg.sender, amount, value) for the exchange operation
     *   - Reward(msg.sender, rewardAmount) if rewards are issued
     *
     * @custom:access-control Available to any caller when protocol is not paused
     * @custom:error-codes
     *   - "ZA": Zero amount (amount is zero) validAmount modifier
     *   - Reverts if protocol is paused (from whenNotPaused modifier)
     *   - Reverts on reentrancy (from nonReentrant modifier)
     *   - Reverts if yield token transfer or USDC transfer fails
     */
    function exchange(uint256 amount) external validAmount(amount) nonReentrant whenNotPaused {
        uint256 supply = yieldTokenInstance.totalSupply();
        uint256 baseAmount = (amount * totalSuppliedLiquidity) / supply;
        uint256 total = usdcInstance.balanceOf(address(this)) + totalBorrow;

        uint256 target = (baseAmount * baseProfitTarget) / WAD;
        if (total >= totalSuppliedLiquidity + target) {
            yieldTokenInstance.mint(treasury, target);
        }

        uint256 value = (amount * total) / yieldTokenInstance.totalSupply();

        totalSuppliedLiquidity -= baseAmount;
        totalAccruedSupplierInterest += value - baseAmount;

        yieldTokenInstance.burn(msg.sender, amount);

        emit Exchange(msg.sender, amount, value);
        TH.safeTransfer(usdcInstance, msg.sender, value);
    }

    /**
     * @notice Claims accumulated rewards for eligible liquidity providers
     * @dev Calculates time-based rewards and transfers them to the caller if eligible
     *
     * @custom:requirements
     *   - Caller must have sufficient time since last claim (>= rewardInterval)
     *   - Caller must have supplied minimum amount (>= rewardableSupply)
     *
     * @custom:state-changes
     *   - Resets liquidityAccrueTimeIndex[msg.sender] if rewards are claimed
     *
     * @custom:emits
     *   - Reward(msg.sender, rewardAmount) if rewards are issued
     *
     * @custom:access-control Available to any caller when protocol is not paused
     */
    function claimReward() external nonReentrant whenNotPaused returns (uint256 finalReward) {
        if (isRewardable(msg.sender)) {
            // Calculate reward amount based on time elapsed
            uint256 duration = block.timestamp - liquidityAccrueTimeIndex[msg.sender];
            uint256 reward = (targetReward * duration) / rewardInterval;
            // Apply maximum reward cap
            uint256 maxReward = ecosystemInstance.maxReward();
            finalReward = reward > maxReward ? maxReward : reward;
            // Reset timer for next reward period
            liquidityAccrueTimeIndex[msg.sender] = block.timestamp;
            // Emit event and issue reward
            emit Reward(msg.sender, finalReward);
            ecosystemInstance.reward(msg.sender, finalReward);
        }
    }

    /**
     * @notice Creates a new borrowing position with specified isolation mode
     * @dev This function initializes a new borrowing position for the caller.
     *      Two types of positions can be created:
     *      1. Isolated positions: Limited to one specific collateral asset
     *      2. Cross-collateral positions: Can use multiple asset types as collateral
     *
     * For isolated positions, the asset parameter is immediately registered as the position's
     * collateral asset. For cross-collateral positions, no asset is registered initially;
     * assets must be added later via supplyCollateral().
     *
     * The newly created position has no debt and is marked with ACTIVE status. The position ID
     * is implicitly the index of the position in the user's positions array (positions.length - 1).
     *
     * @param asset Address of the initial collateral asset for the position
     * @param isIsolated Whether the position uses isolation mode (true = single-asset only)
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Asset must be whitelisted in the protocol (validAsset modifier)
     *
     * @custom:state-changes
     *   - Creates new UserPosition entry in positions[msg.sender] array
     *   - Sets position.isIsolated based on parameter
     *   - Sets position.status to ACTIVE
     *   - For isolated positions: adds the asset to the position's asset set
     *
     * @custom:emits
     *   - PositionCreated(msg.sender, positionId, isIsolated)
     *
     * @custom:access-control Available to any caller when protocol is not paused
     * @custom:error-codes
     *   - "NL": Not listed (from validAsset modifier if asset is not whitelisted)
     */
    function createPosition(address asset, bool isIsolated) external validAsset(asset) nonReentrant whenNotPaused {
        UserPosition storage newPosition = positions[msg.sender].push();
        newPosition.isIsolated = isIsolated;
        newPosition.status = PositionStatus.ACTIVE;

        if (isIsolated) {
            EnumerableSet.AddressSet storage assets =
                positionCollateralAssets[msg.sender][positions[msg.sender].length - 1];
            assets.add(asset);
        }

        emit PositionCreated(msg.sender, positions[msg.sender].length - 1, isIsolated);
    }

    /**
     * @notice Supplies collateral assets to a position
     * @dev This function handles adding collateral to an existing position, which includes:
     *      1. Processing the deposit via _processDeposit (validation and state updates)
     *      2. Emitting the supply event
     *      3. Transferring the assets from the caller to the protocol
     *
     * The collateral can be used to either open new borrowing capacity or
     * strengthen the collateralization ratio of an existing debt position.
     *
     * For isolated positions, only the initial asset type can be supplied.
     * For cross-collateral positions, multiple asset types can be added
     * (up to a maximum of 20 different assets per position).
     *
     * @param asset Address of the collateral asset to supply
     * @param amount Amount of the asset to supply as collateral
     * @param positionId ID of the position to receive the collateral
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - Asset must be whitelisted in the protocol
     *   - Asset must not be at its global capacity limit
     *   - For isolated positions: asset must match the position's initial asset
     *   - For isolated assets: position must be in isolation mode
     *   - Position must have fewer than 20 different asset types (if adding a new asset type)
     *
     * @custom:state-changes
     *   - Increases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - Adds asset to positionCollateralAssets[msg.sender][positionId] if not already present
     *   - Updates protocol-wide TVL for the asset
     *   - Transfers asset tokens from msg.sender to the contract
     *
     * @custom:emits
     *   - SupplyCollateral(msg.sender, positionId, asset, amount)
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-codes
     *   - "ZA": Zero amount (amount is zero) validAmount modifier
     *   - "IN": Invalid position (from activePosition modifier)
     *   - "INA": Inactive position (from activePosition modifier)
     *   - "NL": Not listed (from validAsset modifier if asset is not whitelisted)
     *   - "AC": Asset at capacity (asset has reached global capacity limit)
     *   - "ISO": Isolated asset in cross-collateral position (supplying isolated-tier asset to a cross position)
     *   - "IA": Invalid asset for isolation (supplying an asset that doesn't match the isolated position's asset)
     *   - "MA": Maximum assets reached (position already has 20 different asset types)
     */
    function supplyCollateral(address asset, uint256 amount, uint256 positionId)
        external
        validAmount(amount)
        nonReentrant
        whenNotPaused
    {
        _processDeposit(asset, amount, positionId);
        emit SupplyCollateral(msg.sender, positionId, asset, amount);
        TH.safeTransferFrom(IERC20(asset), msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraws collateral assets from a position
     * @dev This function handles removing collateral from an existing position, which includes:
     *      1. Processing the withdrawal via _processWithdrawal (validation and state updates)
     *      2. Emitting the withdrawal event
     *      3. Transferring the assets from the protocol to the caller
     *
     * The function ensures that the position remains sufficiently collateralized
     * after the withdrawal by checking that the remaining credit limit exceeds
     * the outstanding debt.
     *
     * @param asset Address of the collateral asset to withdraw
     * @param amount Amount of the asset to withdraw
     * @param positionId ID of the position from which to withdraw
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - For isolated positions: asset must match the position's initial asset
     *   - Current balance must be greater than or equal to the withdrawal amount
     *   - Position must remain sufficiently collateralized after withdrawal
     *
     * @custom:state-changes
     *   - Decreases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - Updates protocol-wide TVL for the asset
     *   - For non-isolated positions: Removes asset from positionCollateralAssets if balance becomes zero
     *   - Transfers asset tokens from the contract to msg.sender
     *
     * @custom:emits
     *   - WithdrawCollateral(msg.sender, positionId, asset, amount)
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-codes
     *   - "ZA": Zero amount (amount is zero)
     *   - "IN": Invalid position (from activePosition modifier)
     *   - "INA": Inactive position (from activePosition modifier)
     *   - "IA": Invalid asset for isolation (withdrawing an asset that doesn't match the isolated position's asset)
     *   - "LB": Low balance (not enough collateral balance to withdraw)
     *   - "CM": Collateral minimum (withdrawal would leave position undercollateralized)
     */
    function withdrawCollateral(address asset, uint256 amount, uint256 positionId)
        external
        nonReentrant
        whenNotPaused
    {
        _processWithdrawal(asset, amount, positionId);
        emit WithdrawCollateral(msg.sender, positionId, asset, amount);
        TH.safeTransfer(IERC20(asset), msg.sender, amount);
    }

    /**
     * @notice Borrows USDC from the protocol against a collateralized position
     * @dev This function handles the borrowing process including:
     *      1. Interest accrual on any existing debt
     *      2. Multiple validation checks (liquidity, debt caps, credit limits)
     *      3. Protocol and position accounting updates
     *      4. USDC transfer to the borrower
     *
     * The function first accrues any pending interest on existing debt to ensure
     * all calculations use up-to-date values. It then validates the borrow request
     * against protocol-wide constraints (available liquidity) and position-specific
     * constraints (isolation debt caps, credit limits).
     *
     * After successful validation, it updates the position's debt, the protocol's
     * total debt accounting, and transfers the requested USDC amount to the borrower.
     *
     * @param positionId ID of the collateralized position to borrow against
     * @param amount Amount of USDC to borrow (in base units with 6 decimals)
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - Amount must be greater than zero
     *   - Protocol must have sufficient liquidity
     *   - For isolated positions: borrow must not exceed asset's isolation debt cap
     *   - Total debt must not exceed position's credit limit
     *
     * @custom:state-changes
     *   - Increases position.debtAmount by amount plus any accrued interest
     *   - Updates position.lastInterestAccrual to current timestamp
     *   - Increases totalBorrow by amount plus any accrued interest
     *   - Increases totalAccruedBorrowerInterest if interest is accrued
     *
     * @custom:emits
     *   - Borrow(msg.sender, positionId, amount)
     *   - InterestAccrued(msg.sender, positionId, accruedInterest) if interest was accrued
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-codes
     *   - "ZA": Zero amount (amount is zero)
     *   - "LL": Low liquidity (not enough protocol liquidity)
     *   - "IDC": Isolation debt cap exceeded
     *   - "CLM": Credit limit exceeded
     *   - "IN": Invalid position (from activePosition modifier)
     *   - "INA": Inactive position (from activePosition modifier)
     */
    function borrow(uint256 positionId, uint256 amount)
        external
        validAmount(amount)
        activePosition(msg.sender, positionId)
        nonReentrant
        whenNotPaused
    {
        uint256 currentDebt = 0;
        uint256 accruedInterest = 0;
        UserPosition storage position = positions[msg.sender][positionId];

        if (position.debtAmount > 0) {
            currentDebt = calculateDebtWithInterest(msg.sender, positionId);
            accruedInterest = currentDebt - position.debtAmount;

            totalAccruedBorrowerInterest += accruedInterest;
            emit InterestAccrued(msg.sender, positionId, accruedInterest);
        }

        // Check if there's enough protocol liquidity
        require(totalBorrow + accruedInterest + amount <= totalSuppliedLiquidity, "LL");

        // For isolated positions, check debt cap
        if (position.isIsolated) {
            EnumerableSet.AddressSet storage posAssets = positionCollateralAssets[msg.sender][positionId];
            address posAsset = posAssets.at(0);
            ILendefiAssets.Asset memory asset = assetsModule.getAssetInfo(posAsset);
            require(currentDebt + amount <= asset.isolationDebtCap, "IDC");
        }

        // Check credit limit
        uint256 creditLimit = calculateCreditLimit(msg.sender, positionId);
        require(currentDebt + amount <= creditLimit, "CLM");

        // Update total protocol debt (including accrued interest)
        totalBorrow += accruedInterest + amount;

        // Update position debt and interest accrual timestamp
        position.debtAmount = currentDebt + amount;
        position.lastInterestAccrual = block.timestamp;

        emit Borrow(msg.sender, positionId, amount);
        TH.safeTransfer(usdcInstance, msg.sender, amount);
    }

    /**
     * @notice Repays borrowed USDC for a position, including accrued interest
     * @dev This function handles the repayment process including:
     *      1. Validation of the position's debt status
     *      2. Processing the repayment via _processRepay (accounting updates)
     *      3. Transferring USDC from the user to the protocol
     *
     * The function supports both partial and full repayments. If the user attempts
     * to repay more than they owe, only the outstanding debt amount is taken.
     * Interest accrual is handled automatically by the _processRepay function.
     *
     * @param positionId ID of the position with debt to repay
     * @param amount Amount of USDC to repay (repays full debt if amount exceeds balance)
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - Position must have existing debt to repay
     *
     * @custom:state-changes
     *   - Decreases position.debtAmount by the repayment amount
     *   - Updates position.lastInterestAccrual to current timestamp
     *   - Updates totalBorrow to reflect repayment and accrued interest
     *   - Updates totalAccruedBorrowerInterest by adding newly accrued interest
     *
     * @custom:emits
     *   - Repay(msg.sender, positionId, actualAmount)
     *   - InterestAccrued(msg.sender, positionId, accruedInterest)
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-codes
     *   - "ZA": Zero amount (amount is zero)
     *   - "ND": No debt (position has no debt to repay)
     *   - "IN": Invalid position (from activePosition modifier)
     *   - "INA": Inactive position (from activePosition modifier)
     */
    function repay(uint256 positionId, uint256 amount)
        external
        activePosition(msg.sender, positionId)
        nonReentrant
        whenNotPaused
    {
        uint256 actualAmount = _processRepay(positionId, amount);
        if (actualAmount > 0) TH.safeTransferFrom(usdcInstance, msg.sender, address(this), actualAmount);
    }

    /**
     * @notice Closes a borrowing position by repaying all debt and withdrawing all collateral
     * @dev This function handles the complete position closure process, which includes:
     *      1. Repaying any outstanding debt with interest (if debt exists)
     *      2. Withdrawing all collateral assets back to the owner
     *      3. Marking the position as CLOSED in the protocol
     *
     * The function allows users to exit their positions with a single transaction
     * rather than calling separate repay and withdraw functions for each asset.
     * For full debt repayment, it uses the max uint256 value to signal "repay all".
     *
     * @param positionId ID of the position to close
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - If position has debt, caller must have approved sufficient USDC
     *
     * @custom:state-changes
     *   - Repays any debt in the position (position.debtAmount = 0)
     *   - Updates position.lastInterestAccrual if debt existed
     *   - Removes all collateral assets from the position
     *   - Updates protocol-wide TVL for each asset
     *   - Sets position.status to CLOSED
     *
     * @custom:emits
     *   - PositionClosed(msg.sender, positionId)
     *   - Repay(msg.sender, positionId, actualAmount) if debt existed
     *   - InterestAccrued(msg.sender, positionId, accruedInterest) if interest was accrued
     *   - WithdrawCollateral(msg.sender, positionId, asset, amount) for each collateral asset
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-codes
     *   - "ZA": Zero amount (amount is zero)
     *   - "IN": Invalid position (from activePosition modifier)
     *   - "INA": Inactive position (from activePosition modifier)
     */
    function exitPosition(uint256 positionId)
        external
        activePosition(msg.sender, positionId)
        nonReentrant
        whenNotPaused
    {
        UserPosition storage position = positions[msg.sender][positionId];
        uint256 actualAmount = _processRepay(positionId, type(uint256).max);
        if (actualAmount > 0) TH.safeTransferFrom(usdcInstance, msg.sender, address(this), actualAmount);
        _withdrawAllCollateral(msg.sender, positionId, msg.sender);
        position.status = PositionStatus.CLOSED;
        emit PositionClosed(msg.sender, positionId);
    }

    /**
     * @notice Liquidates an undercollateralized position to maintain protocol solvency
     * @dev This function handles the liquidation process including:
     *      1. Verification that the caller owns sufficient governance tokens
     *      2. Confirmation that the position's health factor is below 1.0
     *      3. Calculation of debt with accrued interest and liquidation fee
     *      4. Position state updates (marking as liquidated, clearing debt)
     *      5. Transferring debt+fee from liquidator to the protocol
     *      6. Transferring all collateral assets to the liquidator
     *
     * The liquidator receives all collateral assets in exchange for repaying
     * the position's debt plus a liquidation fee. The fee percentage varies
     * based on the collateral tier of the position's assets.
     *
     * @param user Address of the position owner being liquidated
     * @param positionId ID of the position to liquidate
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - Caller must hold at least liquidatorThreshold amount of governance tokens
     *   - Position's health factor must be below 1.0 (undercollateralized)
     *
     * @custom:state-changes
     *   - Sets position.isIsolated to false
     *   - Sets position.debtAmount to 0
     *   - Sets position.lastInterestAccrual to 0
     *   - Sets position.status to LIQUIDATED
     *   - Decreases totalBorrow by the position's debt amount
     *   - Increases totalAccruedBorrowerInterest by any accrued interest
     *   - Removes all collateral assets from the position
     *   - Updates protocol-wide TVL for each asset
     *
     * @custom:emits
     *   - Liquidated(user, positionId, msg.sender)
     *   - WithdrawCollateral(user, positionId, asset, amount) for each collateral asset
     *
     * @custom:access-control Available to any caller with sufficient governance tokens when protocol is not paused
     * @custom:error-codes
     *   - "GTL": Not a liquidator (caller doesn't have enough governance tokens)
     *   - "NLQ": Not liquidatable (position's health factor is above 1.0)
     *   - "IN": Invalid position (from activePosition modifier)
     *   - "INA": Inactive position (from activePosition modifier)
     */
    function liquidate(address user, uint256 positionId)
        external
        activePosition(user, positionId)
        nonReentrant
        whenNotPaused
    {
        require(tokenInstance.balanceOf(msg.sender) >= liquidatorThreshold, "GTL"); // Not enough governance tokens
        require(isLiquidatable(user, positionId), "NLQ"); // Not liquidatable

        UserPosition storage position = positions[user][positionId];
        uint256 debtWithInterest = calculateDebtWithInterest(user, positionId);

        uint256 interestAccrued = debtWithInterest - position.debtAmount;
        totalAccruedBorrowerInterest += interestAccrued;

        uint256 liquidationFee = getPositionLiquidationFee(user, positionId);
        uint256 fee = ((debtWithInterest * liquidationFee) / WAD);

        totalBorrow -= position.debtAmount;
        position.debtAmount = 0;
        position.status = PositionStatus.LIQUIDATED;

        emit Liquidated(user, positionId, msg.sender);

        TH.safeTransferFrom(usdcInstance, msg.sender, address(this), debtWithInterest + fee);
        _withdrawAllCollateral(user, positionId, msg.sender);
    }

    /**
     * @notice Transfers collateral between two positions owned by the same user
     * @dev Validates both the withdrawal from the source position and the deposit to the destination position.
     *      This function ensures that the collateral transfer adheres to the protocol's rules regarding
     *      isolation and cross-collateral positions.
     * @param fromPositionId The ID of the position to transfer collateral from
     * @param toPositionId The ID of the position to transfer collateral to
     * @param asset The address of the collateral asset to transfer
     * @param amount The amount of the asset to transfer
     * @custom:access-control Available to position owners when the protocol is not paused
     * @custom:events Emits an InterPositionalTransfer event
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Asset must be whitelisted in the protocol
     *   - Source position must exist and be in ACTIVE status
     *   - Destination position must exist and be in ACTIVE status
     *   - Source position must have sufficient collateral balance of the specified asset
     *   - Destination position must adhere to isolation rules if applicable
     * @custom:state-changes
     *   - Decreases the collateral amount of the specified asset in the source position
     *   - Increases the collateral amount of the specified asset in the destination position
     *   - Updates protocol-wide TVL for the asset
     * @custom:error-codes
     *   - "ZA": Zero amount (amount is zero)
     *   - "IN": Invalid position (from activePosition modifier)
     *   - "INA": Inactive position (from activePosition modifier)
     *   - "NL": Not listed (from validAsset modifier if asset is not whitelisted)
     *   - "LB": Low balance (not enough collateral balance to transfer)
     *   - "ISO": Isolated asset in cross-collateral position (transferring isolated-tier asset to a cross position)
     *   - "IA": Invalid asset for isolation (transferring an asset that doesn't match the isolated position's asset)
     *   - "MA": Maximum assets reached (destination position already has 20 different asset types)
     */
    function interpositionalTransfer(uint256 fromPositionId, uint256 toPositionId, address asset, uint256 amount)
        external
        validAsset(asset)
        whenNotPaused
        nonReentrant
    {
        _processWithdrawal(asset, amount, fromPositionId);
        _processDeposit(asset, amount, toPositionId);
        emit InterPositionalTransfer(msg.sender, asset, amount);
    }

    /**
     * @notice Updates multiple protocol parameters in a single transaction
     * @dev All parameters are validated against minimum or maximum constraints
     * @param profitTargetRate New base profit target rate (min 0.25%)
     * @param borrowRate New base borrow rate (min 1%)
     * @param rewardAmount New target reward amount (max 10,000 tokens)
     * @param interval New reward interval in seconds (min 90 days)
     * @param supplyAmount New minimum rewardable supply amount (min 20,000 USDC)
     * @param liquidatorAmount New minimum liquidator token threshold (min 10 tokens)
     * @custom:access-control Restricted to MANAGER_ROLE
     * @custom:events Emits a ProtocolMetricsUpdated event
     */
    function updateProtocolMetrics(
        uint256 profitTargetRate,
        uint256 borrowRate,
        uint256 rewardAmount,
        uint256 interval,
        uint256 supplyAmount,
        uint256 liquidatorAmount
    ) external onlyRole(MANAGER_ROLE) {
        // Validate all parameters
        require(profitTargetRate >= 0.0025e6, "I1");
        require(borrowRate >= 0.01e6, "I2");
        require(rewardAmount <= 10_000 ether, "I3");
        require(interval >= 90 days, "I4");
        require(supplyAmount >= 20_000 * WAD, "I5");
        require(liquidatorAmount >= 10 ether, "I6");

        // Update all state variables
        baseProfitTarget = profitTargetRate;
        baseBorrowRate = borrowRate;
        targetReward = rewardAmount;
        rewardInterval = interval;
        rewardableSupply = supplyAmount;
        liquidatorThreshold = liquidatorAmount;

        // Emit a single consolidated event
        emit ProtocolMetricsUpdated(
            profitTargetRate, borrowRate, rewardAmount, interval, supplyAmount, liquidatorAmount
        );
    }

    /**
     * @notice Retrieves a user's position data by ID
     * @dev Returns the full position struct including isolation status, debt, and status
     * @param user Address of the position owner
     * @param positionId ID of the position to query
     * @return UserPosition struct containing the position's details
     * @custom:access-control Available to any caller, read-only
     */
    function getUserPosition(address user, uint256 positionId)
        external
        view
        validPosition(user, positionId)
        returns (UserPosition memory)
    {
        return positions[user][positionId];
    }

    /**
     * @notice Gets the amount of a specific collateral asset in a position
     * @dev Returns zero for assets not used in the position
     * @param user Address of the position owner
     * @param positionId ID of the position to query
     * @param asset Address of the collateral asset
     * @return Amount of the specified asset used as collateral
     * @custom:access-control Available to any caller, read-only
     */
    function getCollateralAmount(address user, uint256 positionId, address asset)
        external
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        return positionCollateralAmounts[user][positionId][asset];
    }

    /**
     * @notice Gets all collateral asset addresses used in a position
     * @dev Returns an array of addresses that can be used to query amounts
     * @param user Address of the position owner
     * @param positionId ID of the position to query
     * @return Array of addresses representing all collateral assets in the position
     */
    function getPositionCollateralAssets(address user, uint256 positionId)
        external
        view
        validPosition(user, positionId)
        returns (address[] memory)
    {
        EnumerableSet.AddressSet storage posAssets = positionCollateralAssets[user][positionId];
        uint256 length = posAssets.length();
        address[] memory assets = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            assets[i] = posAssets.at(i);
        }

        return assets;
    }

    /**
     * @notice Gets the timestamp of the last liquidity reward accrual for a user
     * @dev Used to determine reward eligibility and calculate reward amounts
     * @param user The address of the user to query
     * @return The timestamp when rewards were last accrued (or 0 if never)
     */
    function getLiquidityAccrueTimeIndex(address user) external view returns (uint256) {
        return liquidityAccrueTimeIndex[user];
    }

    /**
     * @notice Calculates the current debt including accrued interest for a position
     * @dev Uses the appropriate interest rate based on the position's collateral tier
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate debt for
     * @return The total debt amount including principal and accrued interest
     */
    function calculateDebtWithInterest(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        UserPosition storage position = positions[user][positionId];
        if (position.debtAmount == 0) return 0;

        ILendefiAssets.CollateralTier tier = position.isIsolated
            ? assetsModule.getAssetInfo(positionCollateralAssets[user][positionId].at(0)).tier
            : LendefiRates.getHighestTier(
                positionCollateralAssets[user][positionId], positionCollateralAmounts[user][positionId], assetsModule
            );

        uint256 borrowRate = getBorrowRate(tier);
        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;

        return LendefiRates.calculateDebtWithInterest(position.debtAmount, borrowRate, timeElapsed);
    }

    /**
     * @notice Gets the number of positions owned by a user
     * @dev Includes all positions regardless of status (active, closed, liquidated)
     * @param user Address of the user to query
     * @return The number of positions created by the user
     */
    function getUserPositionsCount(address user) public view returns (uint256) {
        return positions[user].length;
    }

    /**
     * @notice Gets all positions owned by a user
     * @dev Returns the full array of position structs for the user
     * @param user Address of the user to query
     * @return Array of UserPosition structs for all the user's positions
     */
    function getUserPositions(address user) public view returns (UserPosition[] memory) {
        return positions[user];
    }

    /**
     * @notice Gets the liquidation fee percentage for a position
     * @dev Based on the highest risk tier among the position's collateral assets
     * @param user Address of the position owner
     * @param positionId ID of the position to query
     * @return The liquidation fee percentage in WAD format (e.g., 0.05e6 = 5%)
     */
    function getPositionLiquidationFee(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        ILendefiAssets.CollateralTier tier = LendefiRates.getHighestTier(
            positionCollateralAssets[user][positionId], positionCollateralAmounts[user][positionId], assetsModule
        );
        return assetsModule.tierLiquidationFee(tier);
    }

    /**
     * @notice Calculates the maximum borrowable amount for a position
     * @dev Based on collateral values and their respective borrow thresholds
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate limit for
     * @return The maximum amount of USDC that can be borrowed against the position
     * @custom:access-control Available to any caller, read-only
     */
    function calculateCreditLimit(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        return LendefiRates.calculateCreditLimit(
            positions[user][positionId].isIsolated,
            positionCollateralAssets[user][positionId],
            positionCollateralAmounts[user][positionId],
            assetsModule
        );
    }

    /**
     * @notice Calculates the total USD value of all collateral in a position
     * @dev Uses oracle prices to convert collateral amounts to USD value
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate value for
     * @return The total USD value of all collateral assets in the position
     */
    function calculateCollateralValue(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        return LendefiRates.calculateCollateralValue(
            positions[user][positionId].isIsolated,
            positionCollateralAssets[user][positionId],
            positionCollateralAmounts[user][positionId],
            assetsModule
        );
    }

    /**
     * @notice Determines if a position is eligible for liquidation
     * @dev Checks if health factor is below 1.0, indicating undercollateralization
     * @param user Address of the position owner
     * @param positionId ID of the position to check
     * @return True if the position can be liquidated, false otherwise
     */
    function isLiquidatable(address user, uint256 positionId)
        public
        view
        activePosition(user, positionId)
        returns (bool)
    {
        UserPosition storage position = positions[user][positionId];
        if (position.debtAmount == 0) return false;

        // Use the health factor which properly accounts for liquidation thresholds
        // Health factor < 1.0 means position is undercollateralized based on liquidation parameters
        uint256 healthFactorValue = healthFactor(user, positionId);

        // Compare against WAD (1.0 in fixed-point representation)
        return healthFactorValue < WAD;
    }

    /**
     * @notice Calculates the health factor of a position
     * @dev Health factor is the ratio of weighted collateral to debt, below 1.0 is liquidatable
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate health for
     * @return The position's health factor in WAD format (1.0 = 1e6)
     */
    function healthFactor(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        uint256 debt = calculateDebtWithInterest(user, positionId);
        return LendefiRates.healthFactor(
            positionCollateralAssets[user][positionId], positionCollateralAmounts[user][positionId], debt, assetsModule
        );
    }

    /**
     * @notice Calculates the current protocol utilization rate
     * @dev Utilization = totalBorrow / totalSuppliedLiquidity, in WAD format
     * @return u The protocol's current utilization rate (0-1e6)
     */
    function getUtilization() public view returns (uint256 u) {
        (totalSuppliedLiquidity == 0 || totalBorrow == 0) ? u = 0 : u = (WAD * totalBorrow) / totalSuppliedLiquidity;
    }

    /**
     * @notice Calculates the current supply interest rate for liquidity providers
     * @dev Based on utilization, protocol fees, and available liquidity
     * @return The current annual supply interest rate in WAD format
     */
    function getSupplyRate() public view returns (uint256) {
        return LendefiRates.getSupplyRate(
            yieldTokenInstance.totalSupply(),
            totalBorrow,
            totalSuppliedLiquidity,
            baseProfitTarget,
            usdcInstance.balanceOf(address(this))
        );
    }

    /**
     * @notice Calculates the current borrow interest rate for a specific collateral tier
     * @dev Based on utilization, base rate, supply rate, and tier-specific jump rate
     * @param tier The collateral tier to calculate the borrow rate for
     * @return The current annual borrow interest rate in WAD format
     */
    function getBorrowRate(ILendefiAssets.CollateralTier tier) public view returns (uint256) {
        return LendefiRates.getBorrowRate(
            getUtilization(), baseBorrowRate, baseProfitTarget, getSupplyRate(), assetsModule.getTierJumpRate(tier)
        );
    }

    /**
     * @notice Determines if a user is eligible for liquidity provider rewards
     * @dev Checks if the required time has passed and minimum supply amount is met
     * @param user Address of the user to check for reward eligibility
     * @return True if the user is eligible for rewards, false otherwise
     */
    function isRewardable(address user) public view returns (bool) {
        if (liquidityAccrueTimeIndex[user] == 0) return false;
        uint256 baseAmount =
            (yieldTokenInstance.balanceOf(user) * totalSuppliedLiquidity) / yieldTokenInstance.totalSupply();
        return block.timestamp - rewardInterval >= liquidityAccrueTimeIndex[user] && baseAmount >= rewardableSupply;
    }

    /**
     * @notice Determines the collateral tier of a position
     * @dev For cross-collateral positions, returns the highest risk tier among assets
     * @param user Address of the position owner
     * @param positionId ID of the position to check
     * @return The position's collateral tier (STABLE, CROSS_A, CROSS_B, or ISOLATED)
     */
    function getPositionTier(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (ILendefiAssets.CollateralTier)
    {
        return LendefiRates.getHighestTier(
            positionCollateralAssets[user][positionId], positionCollateralAmounts[user][positionId], assetsModule
        );
    }

    //////////////////////////////////////////////////
    // ---------internal functions------------------//
    //////////////////////////////////////////////////

    /**
     * @notice Processes a collateral deposit operation
     * @dev Enforces asset capacity limits, isolation mode rules, and asset count limits
     * @param asset Address of the collateral asset to deposit
     * @param amount Amount of the asset to deposit
     * @param positionId ID of the position to receive the collateral
     */
    function _processDeposit(address asset, uint256 amount, uint256 positionId)
        internal
        validAsset(asset)
        activePosition(msg.sender, positionId)
    {
        ILendefiAssets.Asset memory assetConfig = assetsModule.getAssetInfo(asset);

        require(!assetsModule.isAssetAtCapacity(asset, amount), "AC"); // Asset capacity reached

        UserPosition storage position = positions[msg.sender][positionId];
        EnumerableSet.AddressSet storage posAssets = positionCollateralAssets[msg.sender][positionId];

        require(!(assetConfig.tier == ILendefiAssets.CollateralTier.ISOLATED && !position.isIsolated), "ISO"); // Isolated asset in cross position

        require(!(position.isIsolated && posAssets.length() > 0 && asset != posAssets.at(0)), "IA"); // Isolated asset mismatch

        if (!posAssets.contains(asset)) {
            require(posAssets.length() < 20, "MA"); // Maximum assets reached
            posAssets.add(asset);
        }

        positionCollateralAmounts[msg.sender][positionId][asset] += amount;
        assetsModule.updateAssetTVL(asset, assetsModule.assetTVL(asset) + amount);
    }

    /**
     * @notice Processes a collateral withdrawal operation
     * @dev Ensures the position remains sufficiently collateralized after withdrawal
     * @param asset Address of the collateral asset to withdraw
     * @param amount Amount of the asset to withdraw
     * @param positionId ID of the position to withdraw from
     */
    function _processWithdrawal(address asset, uint256 amount, uint256 positionId)
        internal
        validAmount(amount)
        activePosition(msg.sender, positionId)
    {
        UserPosition storage position = positions[msg.sender][positionId];
        EnumerableSet.AddressSet storage posAssets = positionCollateralAssets[msg.sender][positionId];

        require(!(position.isIsolated && asset != posAssets.at(0)), "IA"); // Isolated asset mismatch
        require(positionCollateralAmounts[msg.sender][positionId][asset] >= amount, "LB"); // Insufficient balance

        positionCollateralAmounts[msg.sender][positionId][asset] -= amount;
        assetsModule.updateAssetTVL(asset, assetsModule.assetTVL(asset) - amount);

        require(calculateCreditLimit(msg.sender, positionId) >= position.debtAmount, "CM"); // Credit limit exceeded

        if (positionCollateralAmounts[msg.sender][positionId][asset] == 0 && !position.isIsolated) {
            posAssets.remove(asset);
        }
    }

    /**
     * @notice Processes a repayment for a position and handles debt accounting
     * @dev This internal function manages all debt-related state changes during repayment:
     *      1. Calculates the up-to-date debt including accrued interest
     *      2. Tracks interest accrued since last update
     *      3. Determines the actual amount to repay (capped at outstanding debt)
     *      4. Updates the protocol's total debt accounting
     *      5. Updates the position's debt and interest accrual timestamp
     *      6. Emits relevant events
     *
     * The function handles two key scenarios:
     * - Partial repayment: When proposedAmount < balance, repays that exact amount
     * - Full repayment: When proposedAmount >= balance, repays exactly the outstanding balance
     *
     * @param positionId The ID of the position being repaid
     * @param proposedAmount The amount the user is offering to repay (uncapped)
     * @return actualAmount The actual amount that should be transferred from the user,
     *         which is the lesser of proposedAmount and the outstanding debt
     *
     * @custom:accounting When calculating updated totalBorrow, the formula:
     *        totalBorrow + (balance - actualAmount) - position.debtAmount
     *        takes into account both newly accrued interest and the repayment amount
     *
     * @custom:events Emits:
     *        - Repay(msg.sender, positionId, actualAmount)
     *        - InterestAccrued(msg.sender, positionId, accruedInterest)
     */
    function _processRepay(uint256 positionId, uint256 proposedAmount)
        internal
        validAmount(proposedAmount)
        returns (uint256 actualAmount)
    {
        UserPosition storage position = positions[msg.sender][positionId];
        if (position.debtAmount > 0) {
            // Calculate current debt with interest
            uint256 balance = calculateDebtWithInterest(msg.sender, positionId);
            // Calculate interest accrued
            uint256 accruedInterest = balance - position.debtAmount;
            totalAccruedBorrowerInterest += accruedInterest;

            // Determine actual repayment amount (capped at total debt)
            actualAmount = proposedAmount > balance ? balance : proposedAmount;

            // Update total protocol debt
            // The formula ensures we account for both interest accrual and repayment
            totalBorrow = totalBorrow + (balance - actualAmount) - position.debtAmount;

            // Update position state
            position.debtAmount = balance - actualAmount;
            position.lastInterestAccrual = block.timestamp;

            // Emit events
            emit Repay(msg.sender, positionId, actualAmount);
            emit InterestAccrued(msg.sender, positionId, accruedInterest);
        }
    }

    /**
     * @notice Withdraws all collateral assets from a position
     * @dev Used in exitPosition and liquidate functions
     * @param owner Address of the position owner
     * @param positionId ID of the position to withdraw from
     * @param recipient Address to receive the withdrawn collateral
     * @custom:events Emits WithdrawCollateral events for each asset
     */
    function _withdrawAllCollateral(address owner, uint256 positionId, address recipient) internal {
        EnumerableSet.AddressSet storage posAssets = positionCollateralAssets[owner][positionId];

        while (posAssets.length() > 0) {
            address asset = posAssets.at(0);
            uint256 amount = positionCollateralAmounts[owner][positionId][asset];

            if (amount > 0) {
                positionCollateralAmounts[owner][positionId][asset] = 0;
                assetsModule.updateAssetTVL(asset, assetsModule.assetTVL(asset) - amount);
                TH.safeTransfer(IERC20(asset), recipient, amount);
                emit WithdrawCollateral(owner, positionId, asset, amount);
            }

            posAssets.remove(asset);
        }
    }

    /**
     * @notice Authorizes an upgrade to a new implementation contract
     * @dev Increments the contract version and emits an event
     * @param newImplementation Address of the new implementation contract
     * @custom:access-control Restricted to UPGRADER_ROLE
     * @custom:events Emits an Upgrade event
     */
    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
