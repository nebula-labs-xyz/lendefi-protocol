// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title IVaultFactory
 * @notice Interface for creating and managing user vaults
 */
interface IVaultFactory {
    /**
     * @notice Event emitted when a new vault is created
     * @param user Owner of the position
     * @param positionId ID of the position
     * @param vault Address of the created vault
     */
    event VaultCreated(address indexed user, uint256 indexed positionId, address vault);

    /**
     * @notice Retrieves the vault address for a user's position
     * @param user Owner of the position
     * @param positionId ID of the position
     * @return Address of the vault
     */
    function getVault(address user, uint256 positionId) external view returns (address);

    /**
     * @notice Returns the address of the protocol contract
     * @return Protocol address
     */
    function protocol() external view returns (address);

    /**
     * @notice Creates a new vault for a user position
     * @param user Owner of the position
     * @param positionId ID of the position
     * @return vault Address of the created vault
     */
    function createVault(address user, uint256 positionId) external returns (address vault);
}
