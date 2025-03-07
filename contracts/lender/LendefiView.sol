// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title LendefiView
 * @notice View-only module for Lendefi protocol providing user-friendly data accessors
 * @dev Separating these functions reduces the main contract's size while providing
 *      convenient aggregated views of protocol state for front-end applications
 * @author Lendefi Protocol Team
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */
import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILendefiYieldToken} from "../interfaces/ILendefiYieldToken.sol";
import {IECOSYSTEM} from "../interfaces/IEcosystem.sol";
import {ILendefiAssets} from "../interfaces/ILendefiAssets.sol";
import {ILendefiView} from "../interfaces/ILendefiView.sol";

/**
 * @notice LendefiView provides consolidated view functions for the protocol's state
 * @dev This contract doesn't hold any assets or modify state, it only aggregates data
 */
contract LendefiView is ILendefiView {
    /// @notice Main protocol contract reference
    IPROTOCOL public protocol;

    /// @notice USDC token contract reference
    IERC20 public usdcInstance;

    /// @notice Yield token (LP token) contract reference
    ILendefiYieldToken public yieldTokenInstance;

    /// @notice Ecosystem contract reference for rewards calculation
    IECOSYSTEM public ecosystemInstance;

    /**
     * @notice Initializes the LendefiView contract with required contract references
     * @dev All address parameters must be non-zero to ensure proper functionality
     * @param _protocol Address of the main Lendefi protocol contract
     * @param _usdc Address of the USDC token contract
     * @param _yieldToken Address of the LP token contract
     * @param _ecosystem Address of the ecosystem contract for rewards
     */
    constructor(address _protocol, address _usdc, address _yieldToken, address _ecosystem) {
        require(
            _protocol != address(0) && _usdc != address(0) && _yieldToken != address(0) && _ecosystem != address(0),
            "ZERO_ADDRESS"
        );

        protocol = IPROTOCOL(_protocol);
        usdcInstance = IERC20(_usdc);
        yieldTokenInstance = ILendefiYieldToken(_yieldToken);
        ecosystemInstance = IECOSYSTEM(_ecosystem);
    }

    /**
     * @notice Provides a comprehensive summary of a user's position
     * @dev Aggregates multiple protocol calls into one convenient view function
     * @param user The address of the position owner
     * @param positionId The ID of the position to query
     * @return totalCollateralValue The total USD value of all collateral in the position
     * @return currentDebt The current debt amount including accrued interest
     * @return availableCredit The remaining credit available to borrow
     * @return isIsolated Whether the position is in isolation mode
     * @return status The current status of the position (Active, Liquidated, etc.)
     */
    function getPositionSummary(address user, uint256 positionId)
        external
        view
        returns (
            uint256 totalCollateralValue,
            uint256 currentDebt,
            uint256 availableCredit,
            bool isIsolated,
            IPROTOCOL.PositionStatus status
        )
    {
        IPROTOCOL.UserPosition memory position = protocol.getUserPosition(user, positionId);

        totalCollateralValue = protocol.calculateCollateralValue(user, positionId);
        currentDebt = protocol.calculateDebtWithInterest(user, positionId);
        availableCredit = protocol.calculateCreditLimit(user, positionId);
        isIsolated = position.isIsolated;
        status = position.status;
    }

    /**
     * @notice Provides detailed information about a user's liquidity provision
     * @dev Calculates the current value of LP tokens and pending rewards
     * @param user The address of the liquidity provider
     * @return lpTokenBalance The user's balance of LP tokens
     * @return usdcValue The current USDC value of the user's LP tokens
     * @return lastAccrualTime The timestamp of the last interest accrual for the user
     * @return isRewardEligible Whether the user is eligible for rewards
     * @return pendingRewards The amount of pending rewards available to the user
     */
    function getLPInfo(address user)
        external
        view
        returns (
            uint256 lpTokenBalance,
            uint256 usdcValue,
            uint256 lastAccrualTime,
            bool isRewardEligible,
            uint256 pendingRewards
        )
    {
        lpTokenBalance = yieldTokenInstance.balanceOf(user);

        // Calculate the current USDC value based on the user's share of the total LP tokens
        uint256 total = usdcInstance.balanceOf(address(protocol)) + protocol.totalBorrow();
        uint256 supply = yieldTokenInstance.totalSupply();
        usdcValue = supply > 0 ? (lpTokenBalance * total) / supply : 0;

        lastAccrualTime = protocol.getLiquidityAccrueTimeIndex(user);
        isRewardEligible = protocol.isRewardable(user);

        // Calculate pending rewards if eligible
        if (isRewardEligible) {
            uint256 duration = block.timestamp - lastAccrualTime;
            uint256 reward = (protocol.targetReward() * duration) / protocol.rewardInterval();
            uint256 maxReward = ecosystemInstance.maxReward();
            pendingRewards = reward > maxReward ? maxReward : reward;
        }
    }

    /**
     * @notice Gets a comprehensive snapshot of the entire protocol's state
     * @dev Aggregates multiple protocol metrics into a single convenient struct
     * @return A ProtocolSnapshot struct containing all key protocol metrics and parameters
     */
    function getProtocolSnapshot() external view returns (ProtocolSnapshot memory) {
        return ProtocolSnapshot({
            utilization: protocol.getUtilization(),
            borrowRate: protocol.getBorrowRate(ILendefiAssets.CollateralTier.CROSS_A),
            supplyRate: protocol.getSupplyRate(),
            totalBorrow: protocol.totalBorrow(),
            totalSuppliedLiquidity: protocol.totalSuppliedLiquidity(),
            targetReward: protocol.targetReward(),
            rewardInterval: protocol.rewardInterval(),
            rewardableSupply: protocol.rewardableSupply(),
            baseProfitTarget: protocol.baseProfitTarget(),
            liquidatorThreshold: protocol.liquidatorThreshold(),
            flashLoanFee: protocol.flashLoanFee()
        });
    }
}
