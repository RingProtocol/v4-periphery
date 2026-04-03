// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";

/// @title Mock Few Wrapped Token
/// @notice Generic mock implementation of Few Wrapped Token for testing
/// @dev Simplified version of FewWrappedToken with 1:1 exchange rate for testing
contract MockFewWrappedToken is MockERC20, IFewWrappedToken {
    /// @notice The underlying token
    ERC20 public immutable _token;

    /// @notice Creates a new mock Few Wrapped Token
    /// @param token_ Address of the underlying token
    constructor(ERC20 token_) MockERC20(
        string(abi.encodePacked("Few Wrapped ", token_.name())),
        string(abi.encodePacked("fw", token_.symbol())),
        token_.decimals()
    ) {
        _token = token_;
    }

    /// @notice Returns the address of the underlying token
    function token() external view override returns (address) {
        return address(_token);
    }

    /// @notice Wraps the underlying token to Few Wrapped Token at 1:1 ratio
    /// @param amount Amount of underlying token to wrap
    /// @return The amount of Few Wrapped Token received
    function wrap(uint256 amount) external override returns (uint256) {
        // Transfer underlying token from sender
        _token.transferFrom(msg.sender, address(this), amount);

        // Mint Few Wrapped Token to sender (1:1 ratio)
        _mint(msg.sender, amount);

        return amount;
    }

    /// @notice Unwraps Few Wrapped Token to the underlying token at 1:1 ratio
    /// @param amount Amount of Few Wrapped Token to unwrap
    /// @return The amount of underlying token received
    function unwrap(uint256 amount) external override returns (uint256) {
        // Burn Few Wrapped Token from sender
        _burn(msg.sender, amount);

        // Transfer underlying token to sender
        _token.transfer(msg.sender, amount);

        return amount;
    }
}
