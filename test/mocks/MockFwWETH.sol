// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";

/// @title Mock Few Wrapped WETH
/// @notice Mock implementation of fwWETH for testing
/// @dev Simplified version of FewWrappedToken with 1:1 exchange rate for testing
contract MockFwWETH is MockERC20, IFewWrappedToken {
    /// @notice The underlying WETH token
    WETH public immutable _token;

    /// @notice Creates a new mock fwWETH
    /// @param weth_ Address of the WETH token
    constructor(WETH weth_) MockERC20("Few Wrapped WETH", "fwWETH", 18) {
        _token = weth_;
    }

    /// @notice Returns the address of the underlying token (WETH)
    function token() external view override returns (address) {
        return address(_token);
    }

    /// @notice Wraps WETH to fwWETH at 1:1 ratio
    /// @param amount Amount of WETH to wrap
    /// @return The amount of fwWETH received
    function wrap(uint256 amount) external override returns (uint256) {
        // Transfer WETH from sender
        _token.transferFrom(msg.sender, address(this), amount);

        // Mint fwWETH to sender (1:1 ratio)
        _mint(msg.sender, amount);

        return amount;
    }

    /// @notice Unwraps fwWETH to WETH at 1:1 ratio
    /// @param amount Amount of fwWETH to unwrap
    /// @return The amount of WETH received
    function unwrap(uint256 amount) external override returns (uint256) {
        // Burn fwWETH from sender
        _burn(msg.sender, amount);

        // Transfer WETH to sender
        _token.transfer(msg.sender, amount);

        return amount;
    }
}
