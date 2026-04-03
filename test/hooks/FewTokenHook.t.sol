// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTokenWrapperHook} from "../../src/base/hooks/BaseTokenWrapperHook.sol";
import {FewTokenHook} from "../../src/hooks/FewTokenHook.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";
import {MockFewWrappedToken} from "../mocks/MockFewWrappedToken.sol";

contract FewTokenHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FewTokenHook public hook;
    MockFewWrappedToken public fwToken;
    MockERC20 public underlyingToken;
    PoolKey poolKey;
    uint160 initSqrtPriceX96;

    // Users
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy mock underlying token and fwToken
        underlyingToken = new MockERC20("Mock Token", "MTK", 18);
        fwToken = new MockFewWrappedToken(underlyingToken);

        // Deploy FewTokenHook
        hook = FewTokenHook(
            payable(
                address(
                    uint160(
                        type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG
                            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                            | Hooks.BEFORE_INITIALIZE_FLAG
                    )
                )
            )
        );
        deployCodeTo("FewTokenHook", abi.encode(manager, fwToken), address(hook));

        // Create pool key for underlyingToken/fwToken
        poolKey = PoolKey({
            currency0: Currency.wrap(address(underlyingToken)),
            currency1: Currency.wrap(address(fwToken)),
            fee: 0, // Must be 0 for wrapper pools
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at 1:1 price
        initSqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(0));
        manager.initialize(poolKey, initSqrtPriceX96);

        // Give users some tokens
        underlyingToken.mint(alice, 100 ether);
        underlyingToken.mint(bob, 100 ether);
        underlyingToken.mint(address(this), 200 ether);
        underlyingToken.mint(address(fwToken), 200 ether);

        fwToken.mint(alice, 100 ether);
        fwToken.mint(bob, 100 ether);
        fwToken.mint(address(this), 200 ether);

        _addUnrelatedLiquidity();
    }

    function test_initialization() public view {
        assertEq(address(hook.fewToken()), address(fwToken));
        assertEq(Currency.unwrap(hook.wrapperCurrency()), address(fwToken));
        assertEq(Currency.unwrap(hook.underlyingCurrency()), address(underlyingToken));
    }

    function test_wrap_exactInput() public {
        uint256 wrapAmount = 1 ether;
        uint256 expectedOutput = wrapAmount;

        vm.startPrank(alice);
        underlyingToken.approve(address(swapRouter), type(uint256).max);

        uint256 aliceUnderlyingBefore = underlyingToken.balanceOf(alice);
        uint256 aliceFwTokenBefore = fwToken.balanceOf(alice);
        uint256 managerUnderlyingBefore = underlyingToken.balanceOf(address(manager));
        uint256 managerFwTokenBefore = fwToken.balanceOf(address(manager));

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, // underlyingToken (0) to fwToken (1)
                amountSpecified: -int256(wrapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        assertEq(aliceUnderlyingBefore - underlyingToken.balanceOf(alice), wrapAmount);
        assertEq(fwToken.balanceOf(alice) - aliceFwTokenBefore, expectedOutput);
        assertEq(managerUnderlyingBefore, underlyingToken.balanceOf(address(manager)));
        assertEq(managerFwTokenBefore, fwToken.balanceOf(address(manager)));
    }

    function test_unwrap_exactInput() public {
        uint256 unwrapAmount = 1 ether;
        uint256 expectedOutput = unwrapAmount;

        vm.startPrank(alice);
        fwToken.approve(address(swapRouter), type(uint256).max);

        uint256 aliceUnderlyingBefore = underlyingToken.balanceOf(alice);
        uint256 aliceFwTokenBefore = fwToken.balanceOf(alice);
        uint256 managerUnderlyingBefore = underlyingToken.balanceOf(address(manager));
        uint256 managerFwTokenBefore = fwToken.balanceOf(address(manager));

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, // fwToken (1) to underlyingToken (0)
                amountSpecified: -int256(unwrapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        assertEq(underlyingToken.balanceOf(alice) - aliceUnderlyingBefore, expectedOutput);
        assertEq(aliceFwTokenBefore - fwToken.balanceOf(alice), unwrapAmount);
        assertEq(managerUnderlyingBefore, underlyingToken.balanceOf(address(manager)));
        assertEq(managerFwTokenBefore, fwToken.balanceOf(address(manager)));
    }

    function test_wrap_exactOutput() public {
        uint256 wrapAmount = 1 ether;
        uint256 expectedInput = wrapAmount;

        vm.startPrank(alice);
        underlyingToken.approve(address(swapRouter), type(uint256).max);

        uint256 aliceUnderlyingBefore = underlyingToken.balanceOf(alice);
        uint256 aliceFwTokenBefore = fwToken.balanceOf(alice);
        uint256 managerUnderlyingBefore = underlyingToken.balanceOf(address(manager));
        uint256 managerFwTokenBefore = fwToken.balanceOf(address(manager));

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, // underlyingToken (0) to fwToken (1)
                amountSpecified: int256(wrapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        assertEq(aliceUnderlyingBefore - underlyingToken.balanceOf(alice), expectedInput);
        assertEq(fwToken.balanceOf(alice) - aliceFwTokenBefore, wrapAmount);
        assertEq(managerUnderlyingBefore, underlyingToken.balanceOf(address(manager)));
        assertEq(managerFwTokenBefore, fwToken.balanceOf(address(manager)));
    }

    function test_unwrap_exactOutput() public {
        uint256 unwrapAmount = 1 ether;
        uint256 expectedInput = unwrapAmount;

        vm.startPrank(alice);
        fwToken.approve(address(swapRouter), type(uint256).max);

        uint256 aliceUnderlyingBefore = underlyingToken.balanceOf(alice);
        uint256 aliceFwTokenBefore = fwToken.balanceOf(alice);
        uint256 managerUnderlyingBefore = underlyingToken.balanceOf(address(manager));
        uint256 managerFwTokenBefore = fwToken.balanceOf(address(manager));

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, // fwToken (1) to underlyingToken (0)
                amountSpecified: int256(unwrapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        assertEq(underlyingToken.balanceOf(alice) - aliceUnderlyingBefore, unwrapAmount);
        assertEq(aliceFwTokenBefore - fwToken.balanceOf(alice), expectedInput);
        assertEq(managerUnderlyingBefore, underlyingToken.balanceOf(address(manager)));
        assertEq(managerFwTokenBefore, fwToken.balanceOf(address(manager)));
    }

    function test_revertAddLiquidity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_revertInvalidPoolInitialization() public {
        // Try to initialize with non-zero fee
        PoolKey memory invalidKey = PoolKey({
            currency0: Currency.wrap(address(underlyingToken)),
            currency1: Currency.wrap(address(fwToken)),
            fee: 3000, // Invalid: must be 0
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.InvalidPoolFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(invalidKey, initSqrtPriceX96);

        // Try to initialize with wrong token pair
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        // sort tokens
        (Currency currency0, Currency currency1) = address(randomToken) < address(fwToken)
            ? (Currency.wrap(address(randomToken)), Currency.wrap(address(fwToken)))
            : (Currency.wrap(address(fwToken)), Currency.wrap(address(randomToken)));
        invalidKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.InvalidPoolToken.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(invalidKey, initSqrtPriceX96);
    }

    function _addUnrelatedLiquidity() internal {
        // Create a hookless pool key for underlyingToken/fwToken
        PoolKey memory unrelatedPoolKey = PoolKey({
            currency0: Currency.wrap(address(underlyingToken)),
            currency1: Currency.wrap(address(fwToken)),
            fee: 100,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        manager.initialize(unrelatedPoolKey, uint160(TickMath.getSqrtPriceAtTick(0)));

        underlyingToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        fwToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            unrelatedPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }
}
