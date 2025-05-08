// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title LendefiPoRFactory
 * @notice Factory for deploying and managing Proof of Reserve feeds
 * @dev Creates standardized feeds for protocol assets
 */
import {LendefiPoRFeed} from "./LendefiPoRFeed.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {LendefiConstants} from "./lib/LendefiConstants.sol";

contract LendefiPoRFactory is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    // The Lendefi protocol contract
    address public manager;

    // Mapping from asset address to PoR feed address
    mapping(address => address) public feeds;

    // Events
    event FeedCreated(address indexed asset, address indexed feed);

    // Errors
    error FeedAlreadyExists();
    // Error for zero address
    error ZeroAddressNotAllowed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory contract
     * @param manager_ Admin address for access control
     * @param multisig Address of the multisig wallet
     */
    function initialize(address manager_, address multisig) external initializer {
        // Validate parameters
        if (manager_ == address(0)) revert ZeroAddressNotAllowed();
        if (multisig == address(0)) revert ZeroAddressNotAllowed();

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, multisig);
        _grantRole(LendefiConstants.MANAGER_ROLE, manager_);
        _grantRole(LendefiConstants.UPGRADER_ROLE, multisig);

        manager = manager_;
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
                manager,
                manager, // LendefiAssets is the updater
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
