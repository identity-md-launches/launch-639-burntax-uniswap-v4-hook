// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTaxFixture} from "./helpers/BurnTaxFixture.sol";
import {PrepayRouter} from "./helpers/PrepayRouter.sol";
import {Vm} from "forge-std/Vm.sol";
import {BurnTaxHook} from "../src/BurnTaxHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

/// @notice Edge cases and failure paths beyond the matched-execution checks in BurnTaxHook.t.sol:
/// exact event payloads, dead-address accumulation, pools at other fee tiers, protocol fees, zero
/// liquidity, hookData, dust, and the callbacks driven directly with crafted deltas.
contract BurnTaxHookEdgesTest is BurnTaxFixture {
    using StateLibrary for IPoolManager;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    event Burned(PoolId indexed poolId, bool indexed isBuy, uint256 amount);

    // ---------------------------------------------------------------- events and dead address

    /// @dev Exact event payloads for every mode in both currency orderings. The expected amount is
    /// derived from the unhooked control pool, so the assertion is "1% of the pool's gross BTAX leg".
    function test_burnEventsCarryPoolDirectionAndExactAmount() public {
        for (uint256 i; i < 8; ++i) {
            bool tokenIs0 = i < 4;
            bool isBuy = i % 2 == 0;
            bool exactInput = (i / 2) % 2 == 0;
            PoolKey memory key = tokenIs0 ? token0Key : token1Key;
            uint256 expectedBurn = _expectedBurn(key, isBuy, exactInput, tokenIs0, 100 ether);
            assertGt(expectedBurn, 0);
            uint256 deadBefore = token.balanceOf(DEAD);

            vm.expectEmit(true, true, false, true, address(hook));
            emit Burned(key.toId(), isBuy, expectedBurn);
            _swap(key, _params(isBuy, exactInput, tokenIs0, 100 ether));

            assertEq(
                token.balanceOf(DEAD) - deadBefore, expectedBurn, "dead address receives the event amount"
            );
        }
    }

    function test_sellExactInputBurnsExactlyOnePercent() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit Burned(token0Key.toId(), false, 1 ether);
        BalanceDelta delta = _swap(token0Key, _params(false, true, true, 100 ether));
        assertEq(delta.amount0(), -100 ether, "trader pays the full specified amount");
        assertEq(token.balanceOf(DEAD), 1 ether);
    }

    function test_buyExactOutputDeliversNetAndBurnsSmallestGross() public {
        uint256 net = 100 ether;
        uint256 fee = (net - 1) / 99;
        uint256 before = token.balanceOf(address(this));
        vm.expectEmit(true, true, false, true, address(hook));
        emit Burned(token1Key.toId(), true, fee);
        BalanceDelta delta = _swap(token1Key, _params(true, false, false, net));
        assertEq(delta.amount1(), int256(net), "trader receives exactly the requested net");
        assertEq(token.balanceOf(address(this)) - before, net);
        assertEq(token.balanceOf(DEAD), fee);
        assertEq((net + fee) / 100, fee, "burn is 1% of gross");
        assertEq(
            (net + fee - 1) - (net + fee - 1) / 100, net - 1, "one unit less gross would short the trader"
        );
    }

    function test_deadBalanceOnlyGrowsAndOnlyInBtax() public {
        uint256 last;
        uint256 sum;
        for (uint256 i; i < 8; ++i) {
            bool tokenIs0 = i % 2 == 0;
            uint256 before = token.balanceOf(DEAD);
            _swap(tokenIs0 ? token0Key : token1Key, _params(i % 4 < 2, i % 3 == 0, tokenIs0, 50 ether + i));
            uint256 after_ = token.balanceOf(DEAD);
            assertGt(after_, before, "every taxed swap adds to the dead address");
            assertGe(after_, last);
            sum += after_ - before;
            last = after_;
        }
        assertEq(token.balanceOf(DEAD), sum);
        assertEq(low.balanceOf(DEAD), 0, "the paired currency is never burned");
        assertEq(high.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_sameSwapTwiceBurnsTwice() public {
        _swap(token0Key, _params(false, true, true, 100 ether));
        _swap(token0Key, _params(false, true, true, 100 ether));
        assertEq(token.balanceOf(DEAD), 2 ether);
        _assertSettled(token0Key);
    }

    // ---------------------------------------------------------------- scope of the rule

    /// @dev The fixture's control pools contain BTAX but select no hook: the tax is a property of the
    /// hooked pool, not of the token.
    function test_btaxPoolWithoutThisHookIsUntaxed() public {
        for (uint256 i; i < 4; ++i) {
            vm.recordLogs();
            _swap(_control(i < 2 ? token0Key : token1Key), _params(i % 2 == 0, i < 2, i < 2, 100 ether));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j; j < logs.length; ++j) {
                assertNotEq(logs[j].emitter, address(hook));
            }
        }
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_otherFeeTiersWithThisHookAreTaxed() public {
        uint24[2] memory fees = [uint24(500), uint24(10_000)];
        int24[2] memory spacings = [int24(10), int24(200)];
        for (uint256 i; i < 2; ++i) {
            PoolKey memory key = token0Key;
            key.fee = fees[i];
            key.tickSpacing = spacings[i];
            _seed(key);
            uint256 deadBefore = token.balanceOf(DEAD);
            vm.expectEmit(true, true, false, true, address(hook));
            emit Burned(key.toId(), false, 1 ether);
            _swap(key, _params(false, true, true, 100 ether));
            assertEq(token.balanceOf(DEAD) - deadBefore, 1 ether);
            (,,, uint24 lpFee) = manager.getSlot0(key.toId());
            assertEq(lpFee, fees[i], "LP fee is the pool's own");
            _assertSettled(key);
        }
    }

    /// @dev A dynamic-fee pool would start at a 0 LP fee that nothing could ever raise: only the hook
    /// may call `updateDynamicLPFee` and it has no such function. `beforeInitialize` therefore refuses
    /// the flag, so a permanently zero-fee taxed pool cannot come into existence, and a swap aimed at
    /// one fails in the PoolManager before any hook callback runs.
    function test_dynamicFeePoolCannotBeCreatedWithThisHook() public {
        PoolKey memory key = token0Key;
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;

        vm.expectRevert(IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector);
        manager.updateDynamicLPFee(key, 3000);

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
        (uint160 price,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(price, 0, "the pool was never created");
        assertEq(lpFee, 0);

        vm.recordLogs();
        vm.expectRevert(Pool.PoolNotInitialized.selector);
        _swap(key, _params(false, true, true, 100 ether));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(hook), "no hook callback ran");
        }
        assertEq(token.balanceOf(DEAD), 0);
        _assertSettled(key);
    }

    function test_protocolFeeDoesNotChangeTheTaxRule() public {
        manager.setProtocolFeeController(address(this));
        uint24 protocolFee = 1000 | (1000 << 12);
        manager.setProtocolFee(token0Key, protocolFee);
        manager.setProtocolFee(_control(token0Key), protocolFee);

        for (uint256 i; i < 4; ++i) {
            bool isBuy = i % 2 == 0;
            bool exactInput = i < 2;
            uint256 expectedBurn = _expectedBurn(token0Key, isBuy, exactInput, true, 100 ether);
            uint256 deadBefore = token.balanceOf(DEAD);
            vm.expectEmit(true, true, false, true, address(hook));
            emit Burned(token0Key.toId(), isBuy, expectedBurn);
            BalanceDelta delta = _swap(token0Key, _params(isBuy, exactInput, true, 100 ether));
            assertEq(token.balanceOf(DEAD) - deadBefore, expectedBurn);
            bool zeroForOne = !isBuy; // BTAX is currency0 in token0Key
            int256 specified = exactInput == zeroForOne ? delta.amount0() : delta.amount1();
            assertEq(specified, exactInput ? -int256(100 ether) : int256(100 ether));
        }
        assertGt(
            manager.protocolFeesAccrued(token0Key.currency0)
                + manager.protocolFeesAccrued(token0Key.currency1),
            0
        );
        (,, uint24 slotProtocolFee, uint24 lpFee) = manager.getSlot0(token0Key.toId());
        assertEq(slotProtocolFee, protocolFee);
        assertEq(lpFee, 3000);
    }

    function test_hookDataCannotChangeRateOrDirection() public {
        uint256 snapshot = vm.snapshotState();
        BalanceDelta plain = _swap(token0Key, _params(true, true, true, 100 ether));
        uint256 plainBurn = token.balanceOf(DEAD);
        assertTrue(vm.revertToStateAndDelete(snapshot));

        bytes memory data = abi.encode(address(this), uint256(0), false, "exempt me");
        BalanceDelta withData = router.swap(
            token0Key, _params(true, true, true, 100 ether), PoolSwapTest.TestSettings(false, false), data
        );
        assertEq(BalanceDelta.unwrap(withData), BalanceDelta.unwrap(plain));
        assertEq(token.balanceOf(DEAD), plainBurn);
    }

    // ---------------------------------------------------------------- zero, dust, and the extremes

    /// @dev With no liquidity the pool fills nothing. A taxed specified trade must then revert
    /// atomically; a zero-tax or unspecified trade executes as a no-op and reports a zero burn.
    function test_zeroLiquidityPool() public {
        liquidityRouter.modifyLiquidity(
            token0Key, ModifyLiquidityParams(-600, 600, -LIQUIDITY, bytes32(0)), ""
        );
        assertEq(manager.getLiquidity(token0Key.toId()), 0);

        _expectHookRevert(abi.encodeWithSelector(BurnTaxHook.PartialFillWithSpecifiedTax.selector));
        _swap(token0Key, _params(false, true, true, 100 ether));

        PrepayRouter prepaid = new PrepayRouter(manager);
        uint256 tokensBefore = token.balanceOf(address(this));
        uint256 highBefore = high.balanceOf(address(this));

        vm.expectEmit(true, true, false, true, address(hook));
        emit Burned(token0Key.toId(), true, 0);
        BalanceDelta buy = prepaid.swap(token0Key, _params(true, true, true, 100 ether), 0, 0);
        assertEq(BalanceDelta.unwrap(buy), 0);

        vm.expectEmit(true, true, false, true, address(hook));
        emit Burned(token0Key.toId(), false, 0);
        BalanceDelta dustSell = prepaid.swap(token0Key, _params(false, true, true, 50), 0, 0);
        assertEq(BalanceDelta.unwrap(dustSell), 0);

        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(this)), tokensBefore);
        assertEq(high.balanceOf(address(this)), highBefore);
        _assertSettled(token0Key);
    }

    /// @dev Rounding limit stated in the README: any BTAX leg under 100 minor units burns nothing, so
    /// a trade split into 99-wei pieces pays no tax. Economically irrelevant at 18 decimals; recorded
    /// here so the behaviour is pinned rather than assumed.
    function test_dustSplittingAvoidsTheTax() public {
        for (uint256 i; i < 50; ++i) {
            _swap(token0Key, _params(false, true, true, 99));
        }
        assertEq(token.balanceOf(DEAD), 0, "fifty 99-wei sells burn nothing");
        _swap(token0Key, _params(false, true, true, 4950));
        assertEq(token.balanceOf(DEAD), 49, "one 4950-wei sell burns 49");
    }

    function test_hookRejectsEtherAndUnknownSelectors() public {
        vm.deal(address(this), 1 ether);
        (bool okValue,) = address(hook).call{value: 1}("");
        assertFalse(okValue, "no receive or fallback");
        (bool okSelector,) = address(hook).call(abi.encodeWithSignature("collect(address)", address(this)));
        assertFalse(okSelector);
        assertEq(address(hook).balance, 0);
    }

    /// @dev One unit over the int128 range in either specified direction is refused by the hook
    /// before v4's own cast would catch it, and the boundary values themselves pass.
    function test_specifiedAmountBoundary() public {
        int256 max = int256(uint256(uint128(type(int128).max)));
        vm.startPrank(address(manager));
        SwapParams memory sellIn = _params(false, true, true, 1);
        sellIn.amountSpecified = -max;
        (, BeforeSwapDelta delta,) = hook.beforeSwap(address(this), token0Key, sellIn, "");
        assertEq(delta.getSpecifiedDelta(), int128(max / 100));

        sellIn.amountSpecified = -max - 1;
        vm.expectRevert(BurnTaxHook.AmountTooLarge.selector);
        hook.beforeSwap(address(this), token0Key, sellIn, "");

        // Largest net request whose grossed-up amount still fits: gross(n) = n + floor((n - 1) / 99).
        int256 net = max * 99 / 100;
        while (net + 1 + net / 99 <= max) ++net;
        SwapParams memory buyOut = _params(true, false, true, 1);
        buyOut.amountSpecified = net;
        (, delta,) = hook.beforeSwap(address(this), token0Key, buyOut, "");
        assertEq(
            int256(delta.getSpecifiedDelta()) + net, max, "largest request grosses up to exactly int128.max"
        );

        buyOut.amountSpecified = net + 1;
        vm.expectRevert(BurnTaxHook.AmountTooLarge.selector);
        hook.beforeSwap(address(this), token0Key, buyOut, "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- callbacks driven directly

    function test_beforeSwapReturnsTaxOnlyWhenBtaxIsSpecified() public {
        vm.startPrank(address(manager));
        PoolKey memory unrelated = _key(address(low), address(high), address(hook));
        (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) =
            hook.beforeSwap(address(this), unrelated, _params(false, true, true, 100 ether), "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "unrelated pool: no delta");
        assertEq(feeOverride, 0);

        (, delta,) = hook.beforeSwap(address(this), token0Key, _params(false, true, true, 100 ether), "");
        assertEq(delta.getSpecifiedDelta(), 1 ether, "exact-input sell reserves 1%");
        assertEq(delta.getUnspecifiedDelta(), 0);

        (, delta,) = hook.beforeSwap(address(this), token1Key, _params(true, false, false, 100 ether), "");
        assertEq(
            delta.getSpecifiedDelta(), int128(int256((100 ether - 1) / 99)), "exact-output buy grosses up"
        );

        (, delta,) = hook.beforeSwap(address(this), token0Key, _params(true, true, true, 100 ether), "");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "paired input specified: nothing before the swap");
        (, delta,) = hook.beforeSwap(address(this), token1Key, _params(false, false, false, 100 ether), "");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "paired output specified: nothing before the swap");
        (, delta,) = hook.beforeSwap(address(this), token0Key, _params(false, true, true, 99), "");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "99 wei sell: tax rounds to zero");
        vm.stopPrank();
    }

    function test_afterSwapDirectCalls() public {
        vm.startPrank(address(manager));
        PoolKey memory unrelated = _key(address(low), address(high), address(hook));
        vm.recordLogs();
        (bytes4 selector, int128 returned) = hook.afterSwap(
            address(this),
            unrelated,
            _params(true, true, true, 100 ether),
            toBalanceDelta(-100 ether, 99 ether),
            ""
        );
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(returned, 0);
        assertEq(vm.getRecordedLogs().length, 0, "unrelated pool: silent");

        // Pool output of 99 wei on a buy: tax rounds to zero, no take, event still emitted.
        vm.expectEmit(true, true, false, true, address(hook));
        emit Burned(token0Key.toId(), true, 0);
        (, returned) = hook.afterSwap(
            address(this), token0Key, _params(true, true, true, 100), toBalanceDelta(99, -100), ""
        );
        assertEq(returned, 0);

        // Specified sell that the pool under-filled: refused before any take.
        vm.expectRevert(BurnTaxHook.PartialFillWithSpecifiedTax.selector);
        hook.afterSwap(
            address(this),
            token0Key,
            _params(false, true, true, 100 ether),
            toBalanceDelta(-98 ether, 97 ether),
            ""
        );

        // Unspecified sell whose grossed-up input would exceed int128: refused before any take.
        int128 max = type(int128).max;
        vm.expectRevert(BurnTaxHook.AmountTooLarge.selector);
        hook.afterSwap(
            address(this), token0Key, _params(false, false, true, 1 ether), toBalanceDelta(-max, 1 ether), ""
        );

        // A real tax is paid through `take`, which only works inside an unlock: the hook never
        // transfers from its own balance or anywhere else.
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        hook.afterSwap(
            address(this),
            token0Key,
            _params(true, true, true, 100 ether),
            toBalanceDelta(100 ether, -100 ether),
            ""
        );
        vm.stopPrank();
        assertEq(token.balanceOf(DEAD), 0);
    }

    // ---------------------------------------------------------------- properties

    /// forge-config: default.fuzz.runs = 2000
    /// @dev The exact-output gross-up is the smallest gross whose net after a 1% floor tax equals the
    /// request, read from the hook's own beforeSwap return rather than restated here.
    function testFuzz_exactOutputGrossUpIsMinimal(uint128 rawNet) public {
        uint256 net = bound(uint256(rawNet), 1, uint256(uint128(type(int128).max)) / 2);
        SwapParams memory params = _params(true, false, true, net);
        vm.prank(address(manager));
        (, BeforeSwapDelta delta,) = hook.beforeSwap(address(this), token0Key, params, "");
        uint256 fee = uint256(uint128(delta.getSpecifiedDelta()));
        uint256 gross = net + fee;
        assertEq(gross - gross / 100, net, "net after tax is exactly the request");
        assertEq(gross / 100, fee, "the burn is 1% of gross");
        if (gross > 1) assertLt((gross - 1) - (gross - 1) / 100, net, "no smaller gross nets the request");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exactInputSellBurnsFloorOnePercent(uint128 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, uint256(uint128(type(int128).max)));
        SwapParams memory params = _params(false, true, false, amount);
        vm.prank(address(manager));
        (, BeforeSwapDelta delta,) = hook.beforeSwap(address(this), token1Key, params, "");
        assertEq(uint256(uint128(delta.getSpecifiedDelta())), amount / 100);
        assertLt(
            uint256(uint128(delta.getSpecifiedDelta())), amount, "the tax can never consume the whole input"
        );
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Runs the equivalent untaxed trade on the control pool and returns 1% of the gross BTAX leg.
    function _expectedBurn(PoolKey memory key, bool isBuy, bool exactInput, bool tokenIs0, uint256 amount)
        internal
        returns (uint256)
    {
        SwapParams memory untaxedParams = _params(isBuy, exactInput, tokenIs0, amount);
        if (!isBuy && exactInput) untaxedParams.amountSpecified += int256(amount / 100);
        if (isBuy && !exactInput) untaxedParams.amountSpecified += int256((amount - 1) / 99);
        BalanceDelta delta = _swap(_control(key), untaxedParams);
        int256 tokens = tokenIs0 ? delta.amount0() : delta.amount1();
        uint256 poolLeg = uint256(tokens < 0 ? -tokens : tokens);
        if (isBuy) return poolLeg / 100;
        if (exactInput) return amount / 100;
        return (poolLeg - 1) / 99;
    }

    function _expectHookRevert(bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}
