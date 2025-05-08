// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {LendefiPoRFeed} from "./LendefiPoRFeed.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {LendefiConstants} from "./lib/LendefiConstants.sol";

/**
 * @title LendefiPoRFactory
 * @notice Factory for deploying and managing Proof of Reserve feeds
 * @dev Creates standardized feeds for protocol assets
 */
contract LendefiPoRFactory is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    // The Lendefi protocol contract
    address public lendefiProtocol;

    // Mapping from asset address to PoR feed address
    mapping(address => address) public feeds;

    // Events
    event FeedCreated(address indexed asset, address indexed feed);

    // Errors
    error FeedAlreadyExists();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory contract
     * @param lendefi The Lendefi protocol address
     * @param assetsModule Admin address for access control
     */
    function initialize(address lendefi, address assetsModule, address multisig) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, multisig);
        _grantRole(LendefiConstants.MANAGER_ROLE, assetsModule);
        _grantRole(LendefiConstants.UPGRADER_ROLE, multisig);

        lendefiProtocol = lendefi;
    }

    /**
     * @notice Creates a new Proof of Reserve feed for an asset
     * @param asset The asset address to create a feed for
     * @return feed Address of the newly created feed
     */
    function createFeed(address asset) external onlyRole(LendefiConstants.MANAGER_ROLE) returns (address feed) {
        // Check if feed already exists
        if (feeds[asset] != address(0)) revert FeedAlreadyExists();

        // Create new feed
        feed = address(
            new LendefiPoRFeed(
                asset,
                lendefiProtocol,
                lendefiProtocol, // Protocol is the updater
                msg.sender // Manager is the owner
            )
        );

        // Store feed address
        feeds[asset] = feed;

        emit FeedCreated(asset, feed);
        return feed;
    }

    /**
     * @notice Gets the feed address for an asset
     * @param asset The asset address
     * @return Address of the asset's feed or address(0) if none exists
     */
    function getFeed(address asset) external view returns (address) {
        return feeds[asset];
    }

    /**
     * @notice Authorizes contract upgrade
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(LendefiConstants.UPGRADER_ROLE) {}
}
