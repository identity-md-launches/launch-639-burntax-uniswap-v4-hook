// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTaxFixture} from "./helpers/BurnTaxFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BurnTaxHook} from "../src/BurnTaxHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract BurnTaxHookTest is BurnTaxFixture {
    using StateLibrary for IPoolManager;

    function test_buyExactInputToken0() public {
        _checkTrade(true, true, true, 100 ether);
    }

    function test_buyExactOutputToken0() public {
        _checkTrade(true, false, true, 100 ether);
    }

    function test_sellExactInputToken0() public {
        _checkTrade(false, true, true, 100 ether);
    }

    function test_sellExactOutputToken0() public {
        _checkTrade(false, false, true, 100 ether);
    }

    function test_buyExactInputToken1() public {
        _checkTrade(true, true, false, 100 ether);
    }

    function test_buyExactOutputToken1() public {
        _checkTrade(true, false, false, 100 ether);
    }

    function test_sellExactInputToken1() public {
        _checkTrade(false, true, false, 100 ether);
    }

    function test_sellExactOutputToken1() public {
        _checkTrade(false, false, false, 100 ether);
    }

    function testFuzz_swapAccounting(bool isBuy, bool exactInput, bool tokenIs0, uint96 rawAmount) public {
        _checkTrade(isBuy, exactInput, tokenIs0, bound(uint256(rawAmount), 1, 1_000 ether));
    }

    function test_roundingBoundaries() public {
        uint256[8] memory amounts = [uint256(1), 98, 99, 100, 101, 197, 198, 199];
        // Roll both matched pools forward in the same order; exercise integer fee discontinuities.
        for (uint256 i; i < amounts.length; ++i) {
            _checkTrade(true, false, true, amounts[i]);
            _checkTrade(false, true, true, amounts[i]);
            _checkTrade(true, true, false, amounts[i]);
            _checkTrade(false, false, false, amounts[i]);
        }
    }

    function _checkTrade(bool isBuy, bool exactInput, bool tokenIs0, uint256 amount) internal {
        PoolKey memory key = tokenIs0 ? token0Key : token1Key;
        PoolKey memory control = _control(key);
        SwapParams memory params = _params(isBuy, exactInput, tokenIs0, amount);
        SwapParams memory referenceParams = _params(isBuy, exactInput, tokenIs0, amount);
        if (!isBuy && exactInput) referenceParams.amountSpecified += int256(amount / 100);
        if (isBuy && !exactInput) referenceParams.amountSpecified += int256((amount - 1) / 99);
        BalanceDelta referenceDelta = _swap(control, referenceParams);

        uint256 userBefore = token.balanceOf(address(this));
        uint256 managerBefore = token.balanceOf(address(manager));
        uint256 deadBefore = token.balanceOf(DEAD);
        Currency paired = tokenIs0 ? key.currency1 : key.currency0;
        uint256 pairedBefore = paired.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta actual = _swap(key, params);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 burned = token.balanceOf(DEAD) - deadBefore;
        int256 coreTokens = tokenIs0 ? referenceDelta.amount0() : referenceDelta.amount1();
        int256 userTokens = tokenIs0 ? actual.amount0() : actual.amount1();
        int256 userPair = tokenIs0 ? actual.amount1() : actual.amount0();
        uint256 gross = uint256(isBuy ? coreTokens : -userTokens);

        assertEq(burned, gross / 100, "tax is exactly floor(gross BTAX / 100)");
        assertEq(userTokens, coreTokens - int256(burned), "BTAX return delta includes tax");
        assertEq(userPair, tokenIs0 ? referenceDelta.amount1() : referenceDelta.amount0(), "pair unchanged");
        assertEq(int256(token.balanceOf(address(this))) - int256(userBefore), userTokens, "wallet BTAX");
        assertEq(int256(paired.balanceOf(address(this))) - int256(pairedBefore), userPair, "wallet pair");
        assertEq(
            int256(token.balanceOf(address(manager))) - int256(managerBefore) + userTokens + int256(burned), 0
        );
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.totalSupply(), SUPPLY);
        int256 specifiedDelta = exactInput == params.zeroForOne ? actual.amount0() : actual.amount1();
        assertEq(specifiedDelta, params.amountSpecified, "exact amount is trader-facing");
        _assertBurnEvent(logs, key, isBuy, burned);
        (uint160 actualPrice,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint160 referencePrice,,,) = manager.getSlot0(control.toId());
        assertEq(actualPrice, referencePrice, "same AMM execution");
        assertEq(protocolFee, 0);
        assertEq(lpFee, 3000);
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 controlFee0, uint256 controlFee1) = manager.getFeeGrowthGlobals(control.toId());
        assertEq(fee0, controlFee0, "LP fee growth0 unchanged");
        assertEq(fee1, controlFee1, "LP fee growth1 unchanged");
        _assertSettled(key);
    }

    function _assertBurnEvent(Vm.Log[] memory logs, PoolKey memory key, bool isBuy, uint256 amount)
        internal
        view
    {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            ++count;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[0], keccak256("Burned(bytes32,bool,uint256)"));
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
            assertEq(logs[i].topics[2], bytes32(uint256(isBuy ? 1 : 0)));
            assertEq(abi.decode(logs[i].data, (uint256)), amount);
        }
        assertEq(count, 1, "one burn event per target-pool swap");
    }

    function test_unrelatedPoolUnaffectedAllModes() public {
        PoolKey memory key = _key(address(low), address(high), address(hook));
        PoolKey memory control = _control(key);
        _seed(key);
        _seed(control);
        uint256 deadBefore = token.balanceOf(DEAD);
        for (uint256 i; i < 4; ++i) {
            SwapParams memory params = _params(i % 2 == 0, i < 2, true, 100 ether);
            BalanceDelta expected = _swap(control, params);
            vm.recordLogs();
            BalanceDelta actual = _swap(key, params);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected));
            for (uint256 j; j < logs.length; ++j) {
                assertNotEq(logs[j].emitter, address(hook));
            }
            _assertSettled(key);
        }
        assertEq(token.balanceOf(DEAD), deadBefore);
        assertEq(low.balanceOf(DEAD), 0);
        assertEq(high.balanceOf(DEAD), 0);
    }

    function test_permissionsAndInitialization() public {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        Hooks.validateHookPermissions(IHooks(address(hook)), permissions);
        assertEq(HookFlags.flagsOf(address(hook)), 0x20cc);
        assertTrue(permissions.beforeInitialize);
        assertTrue(permissions.beforeSwap && permissions.afterSwap);
        assertTrue(permissions.beforeSwapReturnDelta && permissions.afterSwapReturnDelta);
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(address(this), token0Key, PRICE), IHooks.beforeInitialize.selector);
        for (uint256 i; i < 3; ++i) {
            PoolKey memory key = token0Key;
            key.fee = i == 0 ? 500 : i == 1 ? 3000 : 10_000;
            key.tickSpacing = 10;
            manager.initialize(key, PRICE);
            (uint160 price,,, uint24 fee) = manager.getSlot0(key.toId());
            assertEq(price, PRICE);
            assertEq(fee, key.fee);
        }
    }

    function test_rejectsDynamicFeeAndNonTierFees() public {
        uint24[5] memory fees = [LPFeeLibrary.DYNAMIC_FEE_FLAG, 0, 100, 2999, LPFeeLibrary.MAX_LP_FEE];
        for (uint256 i; i < fees.length; ++i) {
            // Pools containing BTAX and unrelated pools are refused alike.
            for (uint256 j; j < 2; ++j) {
                PoolKey memory key = j == 0 ? token0Key : _key(address(low), address(high), address(hook));
                key.fee = fees[i];
                key.tickSpacing = 10;
                vm.expectRevert(
                    abi.encodeWithSelector(
                        CustomRevert.WrappedError.selector,
                        address(hook),
                        IHooks.beforeInitialize.selector,
                        abi.encodeWithSelector(BurnTaxHook.UnsupportedPoolFee.selector),
                        abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                    )
                );
                manager.initialize(key, PRICE);
                (uint160 price,,,) = manager.getSlot0(key.toId());
                assertEq(price, 0, "pool stays uninitialized");
            }
        }
    }

    function test_allCallbacksRejectUnauthorizedCalls() public {
        SwapParams memory params = _params(true, true, true, 1 ether);
        vm.expectRevert(BurnTaxHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(manager), token0Key, PRICE);
        vm.expectRevert(BurnTaxHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(manager), token0Key, params, "");
        vm.expectRevert(BurnTaxHook.OnlyPoolManager.selector);
        hook.afterSwap(address(manager), token0Key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(BurnTaxHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
    }

    function test_burnPendingRevertsWhenNothingIsDeferred() public {
        assertEq(hook.pendingBurn(), 0);
        vm.expectRevert(BurnTaxHook.NothingPending.selector);
        hook.burnPending();
        _checkTrade(false, true, true, 100 ether);
        assertEq(hook.pendingBurn(), 0, "funded pools burn directly");
        vm.expectRevert(BurnTaxHook.NothingPending.selector);
        hook.burnPending();
    }

    function test_predeploymentPoolInitializationFails() public {
        PoolKey memory key = token0Key;
        key.hooks = IHooks(address(uint160(0x4000 | HookFlags.BURNTAX)));
        assertEq(address(key.hooks).code.length, 0);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(key, PRICE);
    }

    function test_zeroSwapFailsWithoutBurn() public {
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        _swap(token0Key, _params(true, true, true, 0));
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_extremeSpecifiedAmountsRefuseOverflow() public {
        int256[3] memory amounts = [type(int256).min, type(int256).max, int256(type(int128).max)];
        for (uint256 i; i < amounts.length; ++i) {
            SwapParams memory params = _params(i != 0, i == 0, true, 1);
            params.amountSpecified = amounts[i];
            vm.prank(address(manager));
            vm.expectRevert(BurnTaxHook.AmountTooLarge.selector);
            hook.beforeSwap(address(this), token0Key, params, "");
        }
    }

    function test_taxedSpecifiedPartialFillsRevertAtomically() public {
        for (uint256 i; i < 4; ++i) {
            bool tokenIs0 = i < 2;
            bool isBuy = i % 2 == 0;
            PoolKey memory key = tokenIs0 ? token0Key : token1Key;
            SwapParams memory params = _params(isBuy, !isBuy, tokenIs0, 10_000 ether);
            params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-60) : int24(60));
            uint256 balanceBefore = token.balanceOf(address(this));
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.afterSwap.selector,
                    abi.encodeWithSelector(BurnTaxHook.PartialFillWithSpecifiedTax.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            _swap(key, params);
            assertEq(token.balanceOf(DEAD), 0);
            assertEq(token.balanceOf(address(this)), balanceBefore);
            (uint160 price,,,) = manager.getSlot0(key.toId());
            assertEq(price, PRICE);
            _assertSettled(key);
        }
    }

    function test_unspecifiedPartialFillsTaxOnlyActualExecution() public {
        for (uint256 i; i < 4; ++i) {
            bool tokenIs0 = i < 2;
            bool isBuy = i % 2 == 0;
            PoolKey memory key = tokenIs0 ? token0Key : token1Key;
            SwapParams memory params = _params(isBuy, isBuy, tokenIs0, 10_000 ether);
            params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-60) : int24(60));
            uint256 beforeDead = token.balanceOf(DEAD);
            BalanceDelta delta = _swap(key, params);
            uint256 burn = token.balanceOf(DEAD) - beforeDead;
            int256 tokenDelta = tokenIs0 ? delta.amount0() : delta.amount1();
            uint256 gross = isBuy ? uint256(tokenDelta) + burn : uint256(-tokenDelta);
            assertEq(burn, gross / 100);
            assertGt(burn, 0);
            int256 specified =
                (params.amountSpecified < 0) == params.zeroForOne ? delta.amount0() : delta.amount1();
            assertLt(uint256(specified < 0 ? -specified : specified), 10_000 ether);
            _assertSettled(key);
        }
    }

    function test_insufficientAllowanceRollsBackBurnAndPool() public {
        token.approve(address(router), 0);
        uint256 balanceBefore = token.balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, 100 ether
            )
        );
        _swap(token0Key, _params(false, true, true, 100 ether));
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(this)), balanceBefore);
        (uint160 price,,,) = manager.getSlot0(token0Key.toId());
        assertEq(price, PRICE);
        _assertSettled(token0Key);
    }

    function test_liquidityLifecycleIsUntaxed() public {
        uint256 deadBefore = token.balanceOf(DEAD);
        liquidityRouter.modifyLiquidity(
            token0Key, ModifyLiquidityParams(-600, 600, -LIQUIDITY, bytes32(0)), ""
        );
        assertEq(manager.getLiquidity(token0Key.toId()), 0);
        assertEq(token.balanceOf(DEAD), deadBefore);
        _assertSettled(token0Key);
    }
}
