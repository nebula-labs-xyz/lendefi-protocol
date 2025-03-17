// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title ILendefiYieldToken
 * @author Lendefi Protocol Team
 * @notice Interface for the LendefiYieldToken, an ERC20 token representing shares in Lendefi's lending protocol
 * @dev This interface defines the external functions of the LP token contract that uses 6 decimals to match USDC
 * @custom:security-contact security@nebula-labs.xyz
 */
interface ILendefiYieldToken {
    /**
     * @notice Emitted when the contract is initialized
     * @param admin Address of the initial admin
     * @custom:access-control This event is emitted once during initialization
     */
    event Initialized(address indexed admin);

    /**
     * @notice Emitted when the contract is upgraded
     * @param upgrader Address that triggered the upgrade
     * @param implementation Address of the new implementation contract
     * @custom:access-control This event is emitted during authorized upgrades
     */
    event Upgrade(address indexed upgrader, address indexed implementation);

    /**
     * @notice Mints new tokens to a recipient
     * @param to Address receiving the minted tokens
     * @param amount Amount of tokens to mint
     * @dev Creates new token supply and assigns it to the recipient
     * @custom:access Restricted to PROTOCOL_ROLE (Lendefi protocol only)
     * @custom:state-changes
     *      - Increases recipient's token balance
     *      - Increases total token supply
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Burns tokens from a holder
     * @param from Address whose tokens are being burned
     * @param amount Amount of tokens to burn
     * @dev Destroys token supply from the specified account
     * @custom:access Restricted to PROTOCOL_ROLE (Lendefi protocol only)
     * @custom:state-changes
     *      - Decreases account's token balance
     *      - Decreases total token supply
     */
    function burn(address from, uint256 amount) external;

    /**
     * @notice Gets the token balance of an account
     * @param account Address to query the balance of
     * @return The amount of tokens owned by the account
     * @dev Standard ERC20 balanceOf function
     * @custom:state-changes None, view-only function
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @notice Gets the total supply of tokens in circulation
     * @return The total amount of tokens currently in circulation
     * @dev Standard ERC20 totalSupply function
     * @custom:state-changes None, view-only function
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Pauses all token transfers and minting
     * @dev Prevents all token movements in case of emergency
     * @custom:access Restricted to PAUSER_ROLE
     * @custom:state-changes Sets the paused state to true
     * @custom:events Emits a Paused event from PausableUpgradeable
     */
    function pause() external;

    /**
     * @notice Unpauses token transfers and minting
     * @dev Restores normal token operation after emergency pause
     * @custom:access Restricted to PAUSER_ROLE
     * @custom:state-changes Sets the paused state to false
     * @custom:events Emits an Unpaused event from PausableUpgradeable
     */
    function unpause() external;

    /**
     * @notice Checks if an account has a specific role
     * @param role The role identifier to check
     * @param account The address to check for role assignment
     * @return True if the account has the role, false otherwise
     * @dev From AccessControlUpgradeable
     * @custom:state-changes None, view-only function
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @notice Grants a role to an account
     * @param role The role identifier to grant
     * @param account The address receiving the role
     * @dev From AccessControlUpgradeable
     * @custom:access Restricted to accounts with DEFAULT_ADMIN_ROLE
     * @custom:state-changes Updates role assignments for the account
     * @custom:events Emits a RoleGranted event from AccessControlUpgradeable
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @notice Revokes a role from an account
     * @param role The role identifier to revoke
     * @param account The address losing the role
     * @dev From AccessControlUpgradeable
     * @custom:access Restricted to accounts with DEFAULT_ADMIN_ROLE
     * @custom:state-changes Updates role assignments for the account
     * @custom:events Emits a RoleRevoked event from AccessControlUpgradeable
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @notice Checks if the contract is currently paused
     * @return True if the contract is paused, false otherwise
     * @dev From PausableUpgradeable
     * @custom:state-changes None, view-only function
     */
    function paused() external view returns (bool);

    /**
     * @notice Returns the number of decimals used for token amounts
     * @dev Overrides the default ERC20 implementation which uses 18 decimals
     * @return The number of decimals (6 to match USDC)
     * @custom:state-changes None, view-only function
     */
    function decimals() external pure returns (uint8);

    /**
     * @notice Gets the current version of the contract
     * @return The contract version number
     * @dev Used to track implementation versions and verify successful upgrades
     * @custom:state-changes None, view-only function
     */
    function version() external view returns (uint8);

    /**
     * @notice Returns the name of the token
     * @return The name of the token
     * @dev Standard ERC20 name function
     * @custom:state-changes None, view-only function
     */
    function name() external view returns (string memory);

    /**
     * @notice Returns the symbol of the token
     * @return The symbol of the token
     * @dev Standard ERC20 symbol function
     * @custom:state-changes None, view-only function
     */
    function symbol() external view returns (string memory);

    /**
     * @notice Returns the role hash for PAUSER_ROLE
     * @return The bytes32 role identifier for PAUSER_ROLE
     * @dev Constant value defined in the contract
     * @custom:state-changes None, view-only function
     */
    function PAUSER_ROLE() external view returns (bytes32);

    /**
     * @notice Returns the role hash for PROTOCOL_ROLE
     * @return The bytes32 role identifier for PROTOCOL_ROLE
     * @dev Constant value defined in the contract
     * @custom:state-changes None, view-only function
     */
    function PROTOCOL_ROLE() external view returns (bytes32);

    /**
     * @notice Returns the role hash for UPGRADER_ROLE
     * @return The bytes32 role identifier for UPGRADER_ROLE
     * @dev Constant value defined in the contract
     * @custom:state-changes None, view-only function
     */
    function UPGRADER_ROLE() external view returns (bytes32);

    /**
     * @notice Emitted when an upgrade is scheduled
     * @param scheduler The address scheduling the upgrade
     * @param implementation The new implementation contract address
     * @param scheduledTime The timestamp when the upgrade was scheduled
     * @param effectiveTime The timestamp when the upgrade can be executed
     * @custom:access-control This event is emitted when an authorized address schedules an upgrade
     */
    event UpgradeScheduled(
        address indexed scheduler, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );

    /**
     * @notice Emitted when a scheduled upgrade is cancelled
     * @param canceller The address that cancelled the upgrade
     * @param implementation The implementation address that was cancelled
     * @custom:access-control This event is emitted when an authorized address cancels an upgrade
     */
    event UpgradeCancelled(address indexed canceller, address indexed implementation);

    /**
     * @notice Returns the timelock duration for upgrades
     * @return The duration in seconds (3 days)
     * @dev Constant value defined in the contract
     * @custom:state-changes None, view-only function
     */
    function UPGRADE_TIMELOCK_DURATION() external view returns (uint256);

    /**
     * @notice Schedules an upgrade to a new implementation with timelock
     * @param newImplementation Address of the new implementation contract
     * @dev Schedules an upgrade that can be executed after the timelock period
     * @custom:access Restricted to UPGRADER_ROLE
     * @custom:state-changes
     *      - Sets pendingUpgrade with implementation and schedule details
     *      - Emits an UpgradeScheduled event
     */
    function scheduleUpgrade(address newImplementation) external;

    /**
     * @notice Cancels a previously scheduled upgrade
     * @dev Removes a pending upgrade from the schedule
     * @custom:access Restricted to UPGRADER_ROLE
     * @custom:state-changes
     *      - Clears the pendingUpgrade data
     *      - Emits an UpgradeCancelled event
     */
    function cancelUpgrade() external;

    /**
     * @notice Returns the remaining time before a scheduled upgrade can be executed
     * @return timeRemaining The time remaining in seconds
     * @dev Returns 0 if no upgrade is scheduled or if the timelock has expired
     * @custom:state-changes None, view-only function
     */
    function upgradeTimelockRemaining() external view returns (uint256);

    /**
     * @notice Returns information about the currently pending upgrade
     * @return implementation Address of the pending implementation
     * @return scheduledTime Timestamp when the upgrade was scheduled
     * @return exists Boolean indicating if an upgrade is currently scheduled
     * @dev Use this to get detailed information about the pending upgrade
     * @custom:state-changes None, view-only function
     */
    function pendingUpgrade() external view returns (address implementation, uint64 scheduledTime, bool exists);
}
