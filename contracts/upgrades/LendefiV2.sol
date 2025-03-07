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
import {LendefiRates} from "../lender/lib/LendefiRates.sol";

/// @custom:oz-upgrades-from contracts/lender/Lendefi.sol:Lendefi
contract LendefiV2 is
    IPROTOCOL,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    uint256 internal constant WAD = 1e6;
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // State variables
    IERC20 internal usdcInstance;
    IERC20 internal tokenInstance;
    IECOSYSTEM internal ecosystemInstance;
    ILendefiOracle internal oracleModule;
    ILendefiYieldToken internal yieldTokenInstance;
    ILendefiAssets internal assetsModule;

    uint256 public totalBorrow;
    uint256 public totalSuppliedLiquidity;
    uint256 public totalAccruedBorrowerInterest;
    uint256 public totalAccruedSupplierInterest;
    uint256 public targetReward;
    uint256 public rewardInterval;
    uint256 public rewardableSupply;
    uint256 public baseBorrowRate;
    uint256 public baseProfitTarget;
    uint256 public liquidatorThreshold;
    uint256 public flashLoanFee;
    uint256 public totalFlashLoanFees;
    uint8 public version;
    address public treasury;

    // Mappings
    mapping(address => UserPosition[]) internal positions;
    mapping(address => mapping(uint256 => mapping(address => uint256))) internal positionCollateralAmounts;
    mapping(address => mapping(uint256 => EnumerableSet.AddressSet)) internal positionCollateralAssets;
    mapping(address src => uint256 time) internal liquidityAccrueTimeIndex;

    uint256[20] private __gap;

    modifier validPosition(address user, uint256 positionId) {
        require(positionId < positions[user].length, "IN");
        _;
    }

    modifier activePosition(address user, uint256 positionId) {
        require(positionId < positions[user].length, "IN");
        require(positions[user][positionId].status == PositionStatus.ACTIVE, "INA");
        _;
    }

    modifier validAsset(address asset) {
        require(assetsModule.isAssetValid(asset), "NL");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

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

    function pause() external override onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external override onlyRole(PAUSER_ROLE) {
        _unpause();
    }

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

    function updateFlashLoanFee(uint256 newFee) external onlyRole(MANAGER_ROLE) {
        require(newFee <= 100, "IF"); // Fee too high

        flashLoanFee = newFee;
        emit UpdateFlashLoanFee(newFee);
    }

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

    function supplyCollateral(address asset, uint256 amount, uint256 positionId) external nonReentrant whenNotPaused {
        _validateDeposit(asset, amount, positionId);
        emit SupplyCollateral(msg.sender, positionId, asset, amount);
        TH.safeTransferFrom(IERC20(asset), msg.sender, address(this), amount);
    }

    function withdrawCollateral(address asset, uint256 amount, uint256 positionId)
        external
        nonReentrant
        whenNotPaused
    {
        _validateWithdrawal(asset, amount, positionId);
        emit WithdrawCollateral(msg.sender, positionId, asset, amount);
        TH.safeTransfer(IERC20(asset), msg.sender, amount);
    }

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

    function interpositionalTransfer(uint256 fromPositionId, uint256 toPositionId, address asset, uint256 amount)
        external
        validAsset(asset)
        whenNotPaused
    {
        _validateWithdrawal(asset, amount, fromPositionId);
        _validateDeposit(asset, amount, toPositionId);
        emit InterPositionalTransfer(msg.sender, asset, amount);
    }

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

    function getUserPosition(address user, uint256 positionId)
        external
        view
        validPosition(user, positionId)
        returns (UserPosition memory)
    {
        return positions[user][positionId];
    }

    function getCollateralAmount(address user, uint256 positionId, address asset)
        external
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        return positionCollateralAmounts[user][positionId][asset];
    }

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
     * @param user The address of the user
     * @return The timestamp when rewards were last accrued
     */
    function getLiquidityAccrueTimeIndex(address user) external view returns (uint256) {
        return liquidityAccrueTimeIndex[user];
    }

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

    function getUserPositionsCount(address user) public view returns (uint256) {
        return positions[user].length;
    }

    function getUserPositions(address user) public view returns (UserPosition[] memory) {
        return positions[user];
    }

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

    function getUtilization() public view returns (uint256 u) {
        (totalSuppliedLiquidity == 0 || totalBorrow == 0) ? u = 0 : u = (WAD * totalBorrow) / totalSuppliedLiquidity;
    }

    function getSupplyRate() public view returns (uint256) {
        return LendefiRates.getSupplyRate(
            yieldTokenInstance.totalSupply(),
            totalBorrow,
            totalSuppliedLiquidity,
            baseProfitTarget,
            usdcInstance.balanceOf(address(this))
        );
    }

    function getBorrowRate(ILendefiAssets.CollateralTier tier) public view returns (uint256) {
        uint256 utilization = getUtilization();
        return LendefiRates.getBorrowRate(
            utilization, baseBorrowRate, baseProfitTarget, getSupplyRate(), assetsModule.getTierJumpRate(tier)
        );
    }

    function isRewardable(address user) public view returns (bool) {
        if (liquidityAccrueTimeIndex[user] == 0) return false;
        uint256 supply = yieldTokenInstance.totalSupply(); // Call yield token
        uint256 baseAmount = (yieldTokenInstance.balanceOf(user) * totalSuppliedLiquidity) / supply; // Call yield token

        return block.timestamp - rewardInterval >= liquidityAccrueTimeIndex[user] && baseAmount >= rewardableSupply;
    }

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
     * @dev Internal function to withdraw all collateral from a position
     * @param owner The address of the position owner
     * @param positionId The position ID
     * @param recipient The address to receive the withdrawn collateral
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

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
