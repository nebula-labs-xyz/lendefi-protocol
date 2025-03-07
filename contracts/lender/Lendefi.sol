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
 * @title Lendefi Protocol
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
 * - STABLE: Lowest risk, stablecoins (5% liquidation bonus)
 * - CROSS_A: Low risk assets (8% liquidation bonus)
 * - CROSS_B: Medium risk assets (10% liquidation bonus)
 * - ISOLATED: High risk assets (15% liquidation bonus)
 *
 * @custom:inheritance
 * - IPROTOCOL: Protocol interface
 * - ERC20Upgradeable: Base token functionality
 * - ERC20PausableUpgradeable: Pausable token operations
 * - AccessControlUpgradeable: Role-based access
 * - ReentrancyGuardUpgradeable: Reentrancy protection
 * - UUPSUpgradeable: Upgrade pattern
 * - YodaMath: Interest calculations
 */

import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {IECOSYSTEM} from "../interfaces/IEcosystem.sol";
import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";
import {ILendefiOracle} from "../interfaces/ILendefiOracle.sol";
import {ILendefiYieldToken} from "../interfaces/ILendefiYieldToken.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20, SafeERC20 as TH} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ILendefiAssets} from "../interfaces/ILendefiAssets.sol";
import {LendefiRates} from "./lib/LendefiRates.sol";

/// @custom:oz-upgrades
contract Lendefi is
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
     * @dev Reference to the oracle module for asset price feeds
     */
    ILendefiOracle internal oracleModule;

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
    uint256[20] private __gap;

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
     * @param oracle_ Address of the oracle module for price feeds
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
        address oracle_,
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
        oracleModule = ILendefiOracle(oracle_);
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
     * @dev The borrower must return the borrowed amount plus fee before the transaction ends
     * @param receiver Address of the contract receiving and handling the flash loan
     * @param amount Amount of USDC to borrow
     * @param params Arbitrary data to pass to the receiver for execution context
     * @custom:access-control Available to any caller when protocol is not paused
     * @custom:events Emits a FlashLoan event
     */
    function flashLoan(address receiver, uint256 amount, bytes calldata params) external nonReentrant whenNotPaused {
        uint256 availableLiquidity = usdcInstance.balanceOf(address(this));
        require(amount <= availableLiquidity, "LL"); // Low liquidity

        uint256 fee = (amount * flashLoanFee) / 10000;
        TH.safeTransfer(usdcInstance, receiver, amount);

        bool success =
            IFlashLoanReceiver(receiver).executeOperation(address(usdcInstance), amount, fee, msg.sender, params);

        require(success, "FLF"); // Flash loan failed

        uint256 requiredBalance = availableLiquidity + fee;
        uint256 currentBalance = usdcInstance.balanceOf(address(this));

        require(currentBalance >= requiredBalance, "RPF"); //repay failed

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
     * @dev Mints yield tokens to the supplier based on the current exchange rate
     * @param amount Amount of USDC to supply
     * @custom:access-control Available to any caller when protocol is not paused
     * @custom:events Emits a SupplyLiquidity event
     */
    function supplyLiquidity(uint256 amount) external nonReentrant whenNotPaused {
        uint256 total = usdcInstance.balanceOf(address(this)) + totalBorrow;
        if (total == 0) total = WAD;
        uint256 supply = yieldTokenInstance.totalSupply();
        uint256 value = (amount * supply) / total;
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
     * @dev Burns yield tokens and returns USDC plus accrued interest to the caller
     * @param amount Amount of yield tokens to exchange
     * @custom:access-control Available to any caller when protocol is not paused
     * @custom:events Emits an Exchange event and potentially reward-related events
     */
    function exchange(uint256 amount) external nonReentrant whenNotPaused {
        uint256 fee;
        uint256 supply = yieldTokenInstance.totalSupply();
        uint256 baseAmount = (amount * totalSuppliedLiquidity) / supply;
        uint256 target = (baseAmount * baseProfitTarget) / WAD;
        uint256 total = usdcInstance.balanceOf(address(this)) + totalBorrow;

        if (total >= totalSuppliedLiquidity + target) {
            fee = target;
            yieldTokenInstance.mint(treasury, fee);
        }

        uint256 value = (amount * total) / yieldTokenInstance.totalSupply();

        totalSuppliedLiquidity -= baseAmount;

        totalAccruedSupplierInterest += value - baseAmount;

        _rewardInternal(baseAmount);
        yieldTokenInstance.burn(msg.sender, amount);

        emit Exchange(msg.sender, amount, value);
        TH.safeTransfer(usdcInstance, msg.sender, value);
    }

    /**
     * @notice Supplies collateral assets to a position
     * @dev Validates the deposit against position constraints and asset limits
     * @param asset Address of the collateral asset to supply
     * @param amount Amount of the asset to supply as collateral
     * @param positionId ID of the position to receive the collateral
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:events Emits a SupplyCollateral event
     */
    function supplyCollateral(address asset, uint256 amount, uint256 positionId) external nonReentrant whenNotPaused {
        _validateDeposit(asset, amount, positionId);
        emit SupplyCollateral(msg.sender, positionId, asset, amount);
        TH.safeTransferFrom(IERC20(asset), msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraws collateral assets from a position
     * @dev Ensures the position remains sufficiently collateralized after withdrawal
     * @param asset Address of the collateral asset to withdraw
     * @param amount Amount of the asset to withdraw
     * @param positionId ID of the position from which to withdraw
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:events Emits a WithdrawCollateral event
     */
    function withdrawCollateral(address asset, uint256 amount, uint256 positionId)
        external
        nonReentrant
        whenNotPaused
    {
        _validateWithdrawal(asset, amount, positionId);
        emit WithdrawCollateral(msg.sender, positionId, asset, amount);
        TH.safeTransfer(IERC20(asset), msg.sender, amount);
    }

    /**
     * @notice Creates a new borrowing position with specified isolation mode
     * @dev For isolated positions, the initial asset is recorded immediately
     * @param asset Address of the initial collateral asset for the position
     * @param isIsolated Whether the position uses isolation mode (single-asset)
     * @custom:access-control Available to any caller when protocol is not paused
     * @custom:events Emits a PositionCreated event
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
     * @notice Borrows USDC from the protocol against a collateralized position
     * @dev Checks credit limit, isolation debt cap, and protocol liquidity before lending
     * @param positionId ID of the collateralized position
     * @param amount Amount of USDC to borrow
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:events Emits a Borrow event
     */
    function borrow(uint256 positionId, uint256 amount)
        external
        activePosition(msg.sender, positionId)
        nonReentrant
        whenNotPaused
    {
        require(totalBorrow + amount <= totalSuppliedLiquidity, "LL");

        UserPosition storage position = positions[msg.sender][positionId];

        if (position.isIsolated) {
            EnumerableSet.AddressSet storage posAssets = positionCollateralAssets[msg.sender][positionId];
            address posAsset = posAssets.at(0);
            ILendefiAssets.Asset memory asset = assetsModule.getAssetInfo(posAsset);
            require(position.debtAmount + amount <= asset.isolationDebtCap, "IDC");
        }

        uint256 creditLimit = calculateCreditLimit(msg.sender, positionId);
        require(position.debtAmount + amount <= creditLimit, "CLM");

        position.debtAmount += amount;
        position.lastInterestAccrual = block.timestamp;
        totalBorrow += amount;

        emit Borrow(msg.sender, positionId, amount);
        TH.safeTransfer(usdcInstance, msg.sender, amount);
    }

    /**
     * @notice Repays borrowed USDC for a position, including accrued interest
     * @dev Updates interest accrual time and decreases debt amount
     * @param positionId ID of the position with debt to repay
     * @param amount Amount of USDC to repay (repays full debt if amount exceeds balance)
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:events Emits Repay and InterestAccrued events
     */
    function repay(uint256 positionId, uint256 amount)
        external
        activePosition(msg.sender, positionId)
        nonReentrant
        whenNotPaused
    {
        UserPosition storage position = positions[msg.sender][positionId];

        uint256 balance = calculateDebtWithInterest(msg.sender, positionId);
        require(balance > 0, "ND");

        uint256 accruedInterest = balance - position.debtAmount;
        totalAccruedBorrowerInterest += accruedInterest;
        amount = amount > balance ? balance : amount;
        totalBorrow = totalBorrow + (balance - amount) - position.debtAmount;

        position.debtAmount = balance - amount;
        position.lastInterestAccrual = block.timestamp;

        emit Repay(msg.sender, positionId, amount);
        emit InterestAccrued(msg.sender, positionId, accruedInterest);

        TH.safeTransferFrom(usdcInstance, msg.sender, address(this), amount);
    }

    /**
     * @notice Closes a borrowing position by repaying all debt and withdrawing all collateral
     * @dev Repays any outstanding debt and withdraws all collateral assets to the owner
     * @param positionId ID of the position to close
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:events Emits PositionClosed and potentially Repay and WithdrawCollateral events
     */
    function exitPosition(uint256 positionId)
        external
        activePosition(msg.sender, positionId)
        nonReentrant
        whenNotPaused
    {
        UserPosition storage position = positions[msg.sender][positionId];

        if (position.debtAmount > 0) {
            uint256 debt = calculateDebtWithInterest(msg.sender, positionId);

            position.debtAmount = 0;
            position.lastInterestAccrual = 0;
            totalBorrow -= debt;

            TH.safeTransferFrom(usdcInstance, msg.sender, address(this), debt);
            emit Repay(msg.sender, positionId, debt);
        }

        _withdrawAllCollateral(msg.sender, positionId, msg.sender);

        position.status = PositionStatus.CLOSED;
        emit PositionClosed(msg.sender, positionId);
    }

    /**
     * @notice Liquidates an undercollateralized position
     * @dev Repays the position's debt and receives all collateral plus a liquidation bonus
     * @param user Address of the position owner
     * @param positionId ID of the position to liquidate
     * @custom:access-control Available to any caller with sufficient governance tokens when protocol is not paused
     * @custom:events Emits a Liquidated event and WithdrawCollateral events for each asset
     */
    function liquidate(address user, uint256 positionId)
        external
        activePosition(user, positionId)
        nonReentrant
        whenNotPaused
    {
        require(tokenInstance.balanceOf(msg.sender) >= liquidatorThreshold, "NLQDR");
        require(isLiquidatable(user, positionId), "NLQ");

        UserPosition storage position = positions[user][positionId];
        uint256 debtWithInterest = calculateDebtWithInterest(user, positionId);

        uint256 interestAccrued = debtWithInterest - position.debtAmount;
        totalAccruedBorrowerInterest += interestAccrued;

        uint256 liquidationFee = getPositionLiquidationFee(user, positionId);

        uint256 fee = ((debtWithInterest * liquidationFee) / WAD);
        uint256 total = debtWithInterest + fee;

        position.isIsolated = false;
        position.debtAmount = 0;
        position.lastInterestAccrual = 0;
        position.status = PositionStatus.LIQUIDATED;
        totalBorrow -= debtWithInterest;

        emit Liquidated(user, positionId, msg.sender);

        TH.safeTransferFrom(usdcInstance, msg.sender, address(this), total);
        _withdrawAllCollateral(user, positionId, msg.sender);
    }

    /**
     * @notice Transfers collateral between two positions owned by the same user
     * @dev Validates both the withdrawal from source and deposit to destination
     * @param fromPositionId The ID of the position to transfer collateral from
     * @param toPositionId The ID of the position to transfer collateral to
     * @param asset The address of the collateral asset to transfer
     * @param amount The amount of the asset to transfer
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:events Emits an InterPositionalTransfer event
     */
    function interpositionalTransfer(uint256 fromPositionId, uint256 toPositionId, address asset, uint256 amount)
        external
        validAsset(asset)
        whenNotPaused
    {
        _validateWithdrawal(asset, amount, fromPositionId);
        _validateDeposit(asset, amount, toPositionId);
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
        // Validate all parameters using require statements instead of custom errors
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
        uint256 utilization = getUtilization();
        return LendefiRates.getBorrowRate(
            utilization, baseBorrowRate, baseProfitTarget, getSupplyRate(), assetsModule.getTierJumpRate(tier)
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
        uint256 supply = yieldTokenInstance.totalSupply(); // Call yield token
        uint256 baseAmount = (yieldTokenInstance.balanceOf(user) * totalSuppliedLiquidity) / supply; // Call yield token

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
     * @notice Validates a collateral deposit operation
     * @dev Enforces asset capacity limits, isolation mode rules, and asset count limits
     * @param asset Address of the collateral asset to deposit
     * @param amount Amount of the asset to deposit
     * @param positionId ID of the position to receive the collateral
     */
    function _validateDeposit(address asset, uint256 amount, uint256 positionId)
        internal
        activePosition(msg.sender, positionId)
        validAsset(asset)
    {
        ILendefiAssets.Asset memory assetConfig = assetsModule.getAssetInfo(asset);

        require(!assetsModule.isAssetAtCapacity(asset, amount), "AC");

        UserPosition storage position = positions[msg.sender][positionId];
        EnumerableSet.AddressSet storage posAssets = positionCollateralAssets[msg.sender][positionId];

        require(!(assetConfig.tier == ILendefiAssets.CollateralTier.ISOLATED && !position.isIsolated), "ISO");

        require(!(position.isIsolated && posAssets.length() > 0 && asset != posAssets.at(0)), "IA");

        if (!posAssets.contains(asset)) {
            require(posAssets.length() < 20, "MA");
            posAssets.add(asset);
        }

        positionCollateralAmounts[msg.sender][positionId][asset] += amount;
        assetsModule.updateAssetTVL(asset, assetsModule.assetTVL(asset) + amount);
    }

    /**
     * @notice Validates a collateral withdrawal operation
     * @dev Ensures the position remains sufficiently collateralized after withdrawal
     * @param asset Address of the collateral asset to withdraw
     * @param amount Amount of the asset to withdraw
     * @param positionId ID of the position to withdraw from
     */
    function _validateWithdrawal(address asset, uint256 amount, uint256 positionId)
        internal
        activePosition(msg.sender, positionId)
    {
        UserPosition storage position = positions[msg.sender][positionId];
        EnumerableSet.AddressSet storage posAssets = positionCollateralAssets[msg.sender][positionId];

        require(!(position.isIsolated && asset != posAssets.at(0)), "IA");

        uint256 currentBalance = positionCollateralAmounts[msg.sender][positionId][asset];
        require(currentBalance >= amount, "LB");

        positionCollateralAmounts[msg.sender][positionId][asset] -= amount;
        assetsModule.updateAssetTVL(asset, assetsModule.assetTVL(asset) - amount);

        uint256 creditLimit = calculateCreditLimit(msg.sender, positionId);
        require(creditLimit >= position.debtAmount, "CM");

        if (positionCollateralAmounts[msg.sender][positionId][asset] == 0 && !position.isIsolated) {
            posAssets.remove(asset);
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
     * @notice Processes rewards for eligible liquidity providers
     * @dev Calculates time-based rewards and triggers ecosystem reward issuance
     * @param amount The liquidity amount to check against the rewardable minimum
     * @custom:events Emits a Reward event if rewards are issued
     */
    function _rewardInternal(uint256 amount) internal {
        bool rewardable =
            block.timestamp - rewardInterval >= liquidityAccrueTimeIndex[msg.sender] && amount >= rewardableSupply;

        if (rewardable) {
            uint256 duration = block.timestamp - liquidityAccrueTimeIndex[msg.sender];
            uint256 reward = (targetReward * duration) / rewardInterval;
            uint256 maxReward = ecosystemInstance.maxReward();
            uint256 target = reward > maxReward ? maxReward : reward;
            delete liquidityAccrueTimeIndex[msg.sender];
            emit Reward(msg.sender, target);
            ecosystemInstance.reward(msg.sender, target);
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
