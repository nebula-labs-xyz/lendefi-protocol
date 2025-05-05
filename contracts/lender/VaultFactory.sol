// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title VaultFactory
 * @notice Simple factory for creating user vaults
 */

import {LendefiVault} from "./LendefiVault.sol";
import {IVaultFactory} from "../interfaces/IVaultFactory.sol";

contract VaultFactory is IVaultFactory {
    // Vault registry
    mapping(address user => mapping(uint256 positionId => address vault)) public getVault;

    // Protocol reference
    address public immutable multisig;
    address public protocol;

    modifier onlyMultisig() {
        require(msg.sender == multisig, "Only multisig");
        _;
    }

    constructor(address multisig_) {
        multisig = multisig_;
    }

    function setProtocol(address protocol_) external onlyMultisig {
        require(protocol == address(0), "Already set");
        protocol = protocol_;
    }

    /**
     * @notice Creates a new vault for a user position
     * @dev Only callable by the protocol contract
     * @param user Owner of the position
     * @param positionId ID of the position
     * @return vault Address of the created vault
     */
    function createVault(address user, uint256 positionId) external returns (address vault) {
        require(msg.sender == protocol, "Only protocol");
        require(getVault[user][positionId] == address(0), "Vault exists");

        // Create new vault
        vault = address(new LendefiVault(protocol, user));

        // Register vault
        getVault[user][positionId] = vault;

        emit VaultCreated(user, positionId, vault);
    }
}
