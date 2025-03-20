// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title ILendefiView
 * @notice Interface for the LendefiView contract providing user-friendly data accessors
 * @dev This interface defines view functions for aggregated protocol state data
 * @author Lendefi Protocol Team
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {IPROTOCOL} from "./IProtocol.sol";

interface ILENDEFIVIEW {
    /**
     * @notice Structure containing a comprehensive snapshot of the protocol's state
     * @param utilization Current utilization rate of the protocol (WAD format)
     * @param borrowRate Current borrow rate for CROSS_A tier assets (WAD format)
     * @param supplyRate Current supply rate for liquidity providers (WAD format)
     * @param totalBorrow Total amount borrowed from the protocol (in USDC)
     * @param totalSuppliedLiquidity Total liquidity supplied to the protocol (in USDC)
     * @param targetReward Target reward amount for LPs (per reward interval)
     * @param rewardInterval Time interval for LP rewards (in seconds)
     * @param rewardableSupply Minimum supply amount to be eligible for rewards (in USDC)
     * @param baseProfitTarget Base profit target percentage (WAD format)
     * @param liquidatorThreshold Minimum token balance required for liquidators
     * @param flashLoanFee Fee percentage charged for flash loans (WAD format)
     */
    struct ProtocolSnapshot {
        uint256 utilization;
        uint256 borrowRate;
        uint256 supplyRate;
        uint256 totalBorrow;
        uint256 totalSuppliedLiquidity;
        uint256 targetReward;
        uint256 rewardInterval;
        uint256 rewardableSupply;
        uint256 baseProfitTarget;
        uint256 liquidatorThreshold;
        uint256 flashLoanFee;
    }

    /**
     * @notice Structure containing complete position data
     * @param totalCollateralValue Total USD value of collateral
     * @param currentDebt Current debt with interest
     * @param availableCredit Remaining borrowing capacity
     * @param healthFactor Position health factor
     * @param isIsolated Whether position is isolated
     * @param status Current position status
     */
    struct PositionSummary {
        uint256 totalCollateralValue;
        uint256 currentDebt;
        uint256 availableCredit;
        uint256 healthFactor;
        bool isIsolated;
        IPROTOCOL.PositionStatus status;
    }

    /**
     * @notice Gets a summary of a user's position
     * @param user The address of the position owner
     * @param positionId The ID of the position to query
     * @return Summary struct containing all position data
     */
    function getPositionSummary(address user, uint256 positionId) external view returns (PositionSummary memory);

    /**
     * @notice Provides detailed information about a user's liquidity provision
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
        );

    /**
     * @notice Gets a comprehensive snapshot of the entire protocol's state
     * @return A ProtocolSnapshot struct containing all key protocol metrics and parameters
     */
    function getProtocolSnapshot() external view returns (ProtocolSnapshot memory);
}
