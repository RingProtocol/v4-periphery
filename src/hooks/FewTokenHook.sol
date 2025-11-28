// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BaseHook} from "../utils/BaseHook.sol";
import {DeltaResolver} from "../base/DeltaResolver.sol";
import {IFewWrappedToken} from "../interfaces/external/IFewWrappedToken.sol";

/// @title Wrapped Few Token Hook
/// @notice Hook for wrapping/unwrapping few token in Uniswap V4 pools
/// @dev Implements 1:1 wrapping/unwrapping between token and few token
/// @dev Generic implementation for standard ERC20 tokens
/// @dev Includes comprehensive input validation and security measures
contract FewTokenHook is BaseHook, DeltaResolver, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using SafeCast for int256;
    using SafeCast for uint256;
    
    /// @notice Custom errors for better gas efficiency and clarity
    error InvalidAddress();
    error WrapFailed(uint256 expectedAmount, uint256 actualAmount);
    error UnwrapFailed(uint256 expectedAmount, uint256 actualAmount);

    /// @notice The fewToken contract used for wrapping/unwrapping operations
    IFewWrappedToken public immutable fewToken;

    /// @notice The wrapped token currency (fewToken)
    Currency public immutable wrapperCurrency;
    /// @notice The underlying token currency (token)
    Currency public immutable underlyingCurrency;
    /// @notice Indicates whether wrapping occurs when swapping from token0 to token1
    bool public immutable wrapZeroForOne;

    /// @notice Creates a new fewToken wrapper hook
    /// @param _manager The Uniswap V4 pool manager
    /// @param _fewToken The fewToken contract address
    /// @dev Initializes with fewToken as wrapper token and token as underlying token
    /// @dev Sets up approval for token to fewToken wrapping operations
    /// @dev Determines wrapping direction based on token address ordering
    constructor(IPoolManager _manager, IFewWrappedToken _fewToken)
        BaseHook(_manager)
    {
        // Input validation
        if (address(_manager) == address(0)) revert InvalidAddress();
        if (address(_fewToken) == address(0)) revert InvalidAddress();
        
        fewToken = _fewToken;
        wrapperCurrency = Currency.wrap(address(_fewToken));
        underlyingCurrency = Currency.wrap(_fewToken.token());
        wrapZeroForOne = underlyingCurrency < wrapperCurrency;
        IERC20(Currency.unwrap(underlyingCurrency)).approve(address(fewToken), type(uint256).max);
    }

    /// @notice Returns hook permissions
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            beforeAddLiquidity: true,
            beforeSwap: true,
            beforeSwapReturnDelta: true,
            afterSwap: false,
            afterInitialize: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Validates pool initialization parameters
    /// @dev Ensures pool contains only wrapper and underlying tokens with zero fee
    /// @param poolKey The pool configuration including tokens and fee
    /// @return The function selector if validation passes
    function _beforeInitialize(address, PoolKey calldata poolKey, uint160) internal view override returns (bytes4) {
        // ensure pool tokens are the wrapper currency and underlying currency
        bool isValidPair = wrapZeroForOne
            ? (poolKey.currency0 == underlyingCurrency && poolKey.currency1 == wrapperCurrency)
            : (poolKey.currency0 == wrapperCurrency && poolKey.currency1 == underlyingCurrency);

        if (!isValidPair) revert("InvalidPoolToken");
        if (poolKey.fee != 0) revert("InvalidPoolFee");

        return IHooks.beforeInitialize.selector;
    }

    /// @notice Allow liquidity operations
    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Handles token wrapping and unwrapping during swaps
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool isExactInput = params.amountSpecified < 0;

        if (wrapZeroForOne == params.zeroForOne) {
            // we are wrapping
            uint256 inputAmount =
                isExactInput ? uint256(-params.amountSpecified) : _getWrapInputRequired(uint256(params.amountSpecified));
            _take(underlyingCurrency, address(this), inputAmount);
            uint256 wrappedAmount = _deposit(inputAmount);
            _settle(wrapperCurrency, address(this), wrappedAmount);
            int128 amountUnspecified =
                isExactInput ? -wrappedAmount.toInt256().toInt128() : inputAmount.toInt256().toInt128();
            BeforeSwapDelta swapDelta = toBeforeSwapDelta(-params.amountSpecified.toInt128(), amountUnspecified);
            return (IHooks.beforeSwap.selector, swapDelta, 0);
        } else {
            // we are unwrapping
            uint256 inputAmount = isExactInput
                ? uint256(-params.amountSpecified)
                : _getUnwrapInputRequired(uint256(params.amountSpecified));
            _take(wrapperCurrency, address(this), inputAmount);
            uint256 unwrappedAmount = _withdraw(inputAmount);
            _settle(underlyingCurrency, address(this), unwrappedAmount);
            int128 amountUnspecified =
                isExactInput ? -unwrappedAmount.toInt256().toInt128() : inputAmount.toInt256().toInt128();
            BeforeSwapDelta swapDelta = toBeforeSwapDelta(-params.amountSpecified.toInt128(), amountUnspecified);
            return (IHooks.beforeSwap.selector, swapDelta, 0);
        }
    }

    /// @notice Transfers tokens to the pool manager
    function _pay(Currency token, address, uint256 amount) internal override {
        token.transfer(address(poolManager), amount);
    }

    /// @notice Wraps token to fewToken
    /// @dev Direct wrapping operation for standard ERC20 tokens
    /// @dev Includes reentrancy protection and balance validation
    /// @param underlyingAmount Amount of token to wrap
    /// @return Amount of fewToken received
    function _deposit(uint256 underlyingAmount) internal nonReentrant returns (uint256) {
        // Check if contract has sufficient token balance
        uint256 balance = IERC20(Currency.unwrap(underlyingCurrency)).balanceOf(address(this));
        if (balance < underlyingAmount) revert InsufficientBalance();
        
        uint256 wrappedAmount = fewToken.wrap(underlyingAmount);
        if (wrappedAmount != underlyingAmount) revert WrapFailed(underlyingAmount, wrappedAmount);
        
        return wrappedAmount;
    }

    /// @notice Unwraps fewToken to token
    /// @dev Direct unwrapping operation for standard ERC20 tokens
    /// @dev Includes reentrancy protection and balance validation
    /// @param wrapperAmount Amount of fewToken to unwrap
    /// @return Amount of token received
    function _withdraw(uint256 wrapperAmount) internal nonReentrant returns (uint256) {
        // Check if contract has sufficient fewToken balance
        uint256 balance = IERC20(Currency.unwrap(wrapperCurrency)).balanceOf(address(this));
        if (balance < wrapperAmount) revert InsufficientBalance();
        
        uint256 unwrappedAmount = fewToken.unwrap(wrapperAmount);
        if (unwrappedAmount != wrapperAmount) revert UnwrapFailed(wrapperAmount, unwrappedAmount);
        
        return unwrappedAmount;
    }

    /// @notice Calculates underlying tokens needed to receive desired wrapper tokens
    function _getWrapInputRequired(uint256 wrappedAmount) internal pure returns (uint256) {
        return wrappedAmount;
    }

    /// @notice Calculates wrapper tokens needed to receive desired underlying tokens
    function _getUnwrapInputRequired(uint256 underlyingAmount) internal pure returns (uint256) {
        return underlyingAmount;
    }
}
