// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title LendefiVault
 * @notice Minimal vault for isolating user position collateral
 */
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract LendefiVault {
    using SafeERC20 for IERC20;

    // Custom errors are more gas-efficient than require statements
    error OnlyProtocol();

    // Keep immutable storage variables
    address public immutable protocol;
    address public immutable owner;

    constructor(address _protocol, address _owner) {
        protocol = _protocol;
        owner = _owner;
    }

    /**
     * @notice Transfers tokens from the vault to a recipient
     * @param token Address of the token to transfer
     * @param amount Amount to transfer
     */
    function withdrawToken(address token, uint256 amount) external {
        // Replace modifier with inline check using custom error
        if (msg.sender != protocol) revert OnlyProtocol();
        IERC20(token).safeTransfer(owner, amount);
    }

    /**
     * @notice Transfer multiple token types to the liquidator
     * @param tokens Array of token addresses to liquidate
     * @param liquidator Address receiving the tokens
     */
    function liquidate(address[] calldata tokens, address liquidator) external {
        // Replace modifier with inline check using custom error
        if (msg.sender != protocol) revert OnlyProtocol();

        // Optimize the loop
        uint256 length = tokens.length;
        for (uint256 i = 0; i < length; i++) {
            address token = tokens[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).safeTransfer(liquidator, balance);
            }
        }
    }
}
