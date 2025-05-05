// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title LendefiVault
 * @notice Minimal vault for isolating user position collateral
 */

// import {IVAULT} from "../interfaces/IVAULT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract LendefiVault {
    using SafeERC20 for IERC20;

    // Core state
    address public immutable protocol;
    address public immutable owner;

    modifier onlyProtocol() {
        require(msg.sender == protocol, "Only protocol");
        _;
    }

    constructor(address _protocol, address _owner) {
        protocol = _protocol;
        owner = _owner;
    }

    /**
     * @notice Transfers tokens from the vault to a recipient
     * @dev Only callable by protocol contract
     * @param token Address of the token to transfer
     * @param amount Amount to transfer
     */
    function withdrawToken(address token, uint256 amount) external onlyProtocol {
        IERC20(token).safeTransfer(owner, amount);
    }

    /**
     * @notice Transfer multiple token types to the liquidator
     * @dev Only callable by protocol contract during liquidation
     * @param tokens Array of token addresses to liquidate
     * @param liquidator Address receiving the tokens
     */
    function liquidate(address[] calldata tokens, address liquidator) external onlyProtocol {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                IERC20(tokens[i]).safeTransfer(liquidator, balance);
            }
        }
    }
}
