// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IECOSYSTEM} from "../interfaces/IEcosystem.sol";
import {IASSETS} from "../interfaces/IASSETS.sol";
import {ILendefiYieldToken} from "../interfaces/ILendefiYieldToken.sol";

/**
 * @title ILendefiView
 * @notice Interface for the LendefiView contract that provides user-friendly data accessors
 * @dev This interface defines all the view functions available in the LendefiView module
 * @author Lendefi Protocol
 */
interface ILendefiView {
    /**
     * @notice Structure containing a comprehensive snapshot of the protocol's state
     * @param utilization The current utilization rate of the protocol (WAD format)
     * @param borrowRate The current borrow rate for CROSS_A tier assets (WAD format)
     * @param supplyRate The current supply rate for liquidity providers (WAD format)
     * @param totalBorrow The total amount borrowed from the protocol (in USDC)
     * @param totalSuppliedLiquidity The total liquidity supplied to the protocol (in USDC)
     * @param targetReward The target reward amount for LPs (per reward interval)
     * @param rewardInterval The time interval for LP rewards (in seconds)
     * @param rewardableSupply The minimum supply amount to be eligible for rewards (in USDC)
     * @param baseProfitTarget The base profit target percentage (WAD format)
     * @param liquidatorThreshold The minimum token balance required for liquidators
     * @param flashLoanFee The fee percentage charged for flash loans (WAD format)
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
     * @dev Consolidates all position-related information
     */
    struct PositionSummary {
        uint256 totalCollateralValue; // Total USD value of collateral
        uint256 currentDebt; // Current debt with interest
        uint256 availableCredit; // Remaining borrowing capacity
        uint256 healthFactor; // Position health factor
        bool isIsolated; // Whether position is isolated
        IPROTOCOL.PositionStatus status; // Current position status
    }

    /**
     * @notice Returns the protocol contract address
     * @return The address of the main protocol contract
     */
    function protocol() external view returns (IPROTOCOL);

    /**
     * @notice Returns the USDC token contract address
     * @return The address of the USDC token contract
     */
    function usdcInstance() external view returns (IERC20);

    /**
     * @notice Returns the yield token contract address
     * @return The address of the yield token contract
     */
    function yieldTokenInstance() external view returns (ILendefiYieldToken);

    /**
     * @notice Returns the ecosystem contract address
     * @return The address of the ecosystem contract
     */
    function ecosystemInstance() external view returns (IECOSYSTEM);

    /**
     * @notice Gets a summary of a user's position
     * @param user The address of the user
     * @param positionId The ID of the position to query
     * @return PositionSummary struct containing all position data
     */
    function getPositionSummary(address user, uint256 positionId) external view returns (PositionSummary memory);

    /**
     * @notice Gets information about a user's liquidity provider (LP) status
     * @param user The address of the user
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
     * @notice Gets a snapshot of the entire protocol's state
     * @return A ProtocolSnapshot struct containing protocol-wide metrics and parameters
     */
    function getProtocolSnapshot() external view returns (ProtocolSnapshot memory);
}
