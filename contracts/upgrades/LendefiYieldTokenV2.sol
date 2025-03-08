// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title LendefiYieldToken (for testing Upgrades)
 * @author alexei@nebula-labs(dot)xyz
 * @notice LP token representing shares in the Lendefi lending protocol's liquidity pool, using 6 decimals to match USDC
 * @dev This contract implements an ERC20 token that represents a user's share of the Lendefi protocol's
 *      lending pool. It's designed to be controlled exclusively by the main Lendefi protocol.
 *      The token uses 6 decimals to maintain consistency with USDC.
 * @custom:security-contact security@nebula-labs.xyz
 */

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC20PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";

/// @custom:oz-upgrades-from contracts/lender/LendefiYieldToken.sol:LendefiYieldToken
contract LendefiYieldTokenV2 is
    Initializable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    /// @notice Role for pausing and unpausing token transfers in emergency situations
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role for the main Lendefi protocol to control token minting and burning
    bytes32 internal constant PROTOCOL_ROLE = keccak256("PROTOCOL_ROLE");

    /// @notice Role for authorizing contract upgrades
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @notice Current version of the contract, incremented on each upgrade
    /// @dev Used to track implementation versions and verify successful upgrades
    uint8 public version;

    /// @dev Reserved storage slots for future upgrades to maintain storage layout compatibility
    uint256[50] private __gap;
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the token with name, symbol, and key roles
     * @param protocol Address of the Lendefi protocol contract (receives PROTOCOL_ROLE)
     * @param guardian Address with pausing capability (receives PAUSER_ROLE)
     * @dev Sets up token details and access control roles
     * @custom:oz-upgrades-unsafe initializer is used instead of constructor for proxy pattern
     * @custom:access Only callable once during initialization
     * @custom:validation-rules
     *      - All addresses must be non-zero
     *      - Sets initial version to 1
     */
    function initialize(address protocol, address guardian) external initializer {
        __ERC20_init("Lendefi Yield Token", "LYT");
        __ERC20Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(protocol != address(0) && guardian != address(0), "ZERO_ADDRESS_DETECTED");

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(PROTOCOL_ROLE, protocol);
        _grantRole(PAUSER_ROLE, guardian);
        _grantRole(UPGRADER_ROLE, guardian);

        // Set initial version
        version = 1;

        emit Initialized(msg.sender);
    }

    /**
     * @notice Mints new tokens to a recipient
     * @param to Address receiving the minted tokens
     * @param amount Amount of tokens to mint
     * @dev Creates new token supply and assigns it to the recipient
     * @custom:access Restricted to PROTOCOL_ROLE (Lendefi protocol only)
     * @custom:security Non-reentrant pattern prevents potential reentrancy attacks
     * @custom:state-changes
     *      - Increases recipient's token balance
     *      - Increases total token supply
     */
    function mint(address to, uint256 amount) external onlyRole(PROTOCOL_ROLE) whenNotPaused nonReentrant {
        _mint(to, amount);
    }

    /**
     * @notice Burns tokens from a holder
     * @param from Address whose tokens are being burned
     * @param amount Amount of tokens to burn
     * @dev Destroys token supply from the specified account
     * @custom:access Restricted to PROTOCOL_ROLE (Lendefi protocol only)
     * @custom:security Non-reentrant pattern prevents potential reentrancy attacks
     * @custom:state-changes
     *      - Decreases account's token balance
     *      - Decreases total token supply
     */
    function burn(address from, uint256 amount) external onlyRole(PROTOCOL_ROLE) whenNotPaused nonReentrant {
        _burn(from, amount);
    }

    /**
     * @notice Pauses all token transfers and minting
     * @dev Prevents all token movements in case of emergency
     * @custom:access Restricted to PAUSER_ROLE
     * @custom:state-changes Sets the paused state to true
     * @custom:events Emits a Paused event from PausableUpgradeable
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses token transfers and minting
     * @dev Restores normal token operation after emergency pause
     * @custom:access Restricted to PAUSER_ROLE
     * @custom:state-changes Sets the paused state to false
     * @custom:events Emits an Unpaused event from PausableUpgradeable
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Returns the number of decimals used for token amounts
     * @dev Overrides the default ERC20 implementation which uses 18 decimals
     * @return The number of decimals (6 to match USDC)
     * @custom:state-changes None, view-only function
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    /**
     * @dev Override to enforce pause state during transfers
     * @param from Address sending tokens
     * @param to Address receiving tokens
     * @param value Token amount
     * @custom:state-changes None, modifies underlying token transfer behavior
     * @custom:validation-rules Reverts if contract is paused
     */

    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        super._update(from, to, value);
    }

    /**
     * @dev Authorizes an upgrade to a new implementation
     * @param newImplementation Address of new implementation contract
     * @custom:access Restricted to UPGRADER_ROLE
     * @custom:state-changes
     *      - Increments the contract version
     *      - Upgrades implementation contract (via UUPSUpgradeable)
     * @custom:events Emits Upgrade event with upgrader and new implementation addresses
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
