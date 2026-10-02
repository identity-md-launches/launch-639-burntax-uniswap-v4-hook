// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BurnTaxFixture} from "./helpers/BurnTaxFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BurnTaxToken} from "../src/BurnTaxToken.sol";
import {BurnTaxHook} from "../src/BurnTaxHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice Drives both hooked pools (BTAX as currency0 and as currency1) with three traders, in all
/// four swap modes, with and without tight price limits, plus liquidity changes. Every hooked swap is
/// mirrored on an unhooked control pool with the gross amount, so the AMM execution itself can be
/// compared state-for-state after any sequence.
contract BurnTaxSequenceHandler is Test {
    using StateLibrary for IPoolManager;

    event Burned(PoolId indexed poolId, bool indexed isBuy, uint256 amount);

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 internal constant LOWER = -600;
    int24 internal constant UPPER = 600;
    /// @dev Smallest liquidity moved in one step: keeps every add/remove at non-zero token amounts,
    /// which v4's PoolModifyLiquidityTest router asserts on.
    uint256 internal constant MIN_LIQUIDITY_STEP = 1e12;

    struct Position {
        bytes32 salt;
        uint256 liquidity;
    }

    BurnTaxToken internal immutable token;
    IPoolManager internal immutable manager;
    BurnTaxHook internal immutable hook;
    PoolSwapTest internal immutable router;
    PoolModifyLiquidityTest internal immutable liquidityRouter;
    PoolKey[2] internal keys;
    PoolKey[2] internal controls;
    address[3] public actors;

    // Ghost state.
    uint256 public burned; // sum of every Burned amount, each matched against the dead address
    uint256 public grossVolume; // sum of gross BTAX legs
    uint256 public swaps;
    uint256 public partialFillRefusals;
    uint256 public liquidityOps;
    uint256 internal positionNonce;
    mapping(uint256 pool => Position[]) internal positions;

    constructor(
        BurnTaxToken token_,
        IPoolManager manager_,
        BurnTaxHook hook_,
        PoolSwapTest router_,
        PoolModifyLiquidityTest liquidityRouter_,
        PoolKey memory token0Key,
        PoolKey memory token1Key,
        address[3] memory actors_
    ) {
        token = token_;
        manager = manager_;
        hook = hook_;
        router = router_;
        liquidityRouter = liquidityRouter_;
        keys[0] = token0Key;
        keys[1] = token1Key;
        controls[0] = PoolKey(
            token0Key.currency0, token0Key.currency1, token0Key.fee, token0Key.tickSpacing, IHooks(address(0))
        );
        controls[1] = PoolKey(
            token1Key.currency0, token1Key.currency1, token1Key.fee, token1Key.tickSpacing, IHooks(address(0))
        );
        actors = actors_;
    }

    function approveAll() external {
        for (uint256 p; p < 2; ++p) {
            for (uint256 c; c < 2; ++c) {
                address currency = Currency.unwrap(c == 0 ? keys[p].currency0 : keys[p].currency1);
                MockERC20(currency).approve(address(liquidityRouter), type(uint256).max);
                for (uint256 a; a < 3; ++a) {
                    vm.prank(actors[a]);
                    MockERC20(currency).approve(address(router), type(uint256).max);
                }
            }
        }
    }

    // ------------------------------------------------------------------ actions

    function swap(uint256 seed, bool tokenIs0, bool isBuy, bool exactInput, uint256 amount) external {
        amount = bound(amount, 1, 200 ether);
        uint160 limit = (isBuy != tokenIs0) ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        _trade(actors[seed % 3], tokenIs0 ? 0 : 1, isBuy, exactInput, amount, limit);
    }

    /// @dev A price limit a few ticks away. Taxed specified trades either fill completely or are
    /// refused atomically; everything else partially fills and is taxed on what executed.
    function swapWithLimit(
        uint256 seed,
        bool tokenIs0,
        bool isBuy,
        bool exactInput,
        uint256 amount,
        uint8 ticks
    ) external {
        amount = bound(amount, 1, 200 ether);
        uint256 p = tokenIs0 ? 0 : 1;
        bool zeroForOne = isBuy != tokenIs0;
        (, int24 tick,,) = manager.getSlot0(keys[p].toId());
        int24 away = int24(uint24(bound(ticks, 1, 120)));
        int24 target = zeroForOne ? tick - away : tick + away;
        if (target <= TickMath.MIN_TICK + 1 || target >= TickMath.MAX_TICK - 1) return;
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        _trade(actors[seed % 3], p, isBuy, exactInput, amount, limit);
    }

    /// @dev Every add opens a fresh position, so accrued fees never offset a later deposit's principal.
    function addLiquidity(bool tokenIs0, uint256 amount) external {
        uint256 p = tokenIs0 ? 0 : 1;
        uint256 liquidity = bound(amount, 1 ether, 10_000 ether);
        bytes32 salt = keccak256(abi.encode(p, ++positionNonce));
        _modify(p, salt, int256(liquidity));
        positions[p].push(Position(salt, liquidity));
    }

    /// @dev Partial removals leave at least MIN_LIQUIDITY_STEP behind; otherwise the position is closed.
    function removeLiquidity(bool tokenIs0, uint256 seed, uint256 amount) external {
        uint256 p = tokenIs0 ? 0 : 1;
        Position[] storage open = positions[p];
        if (open.length == 0) return;
        uint256 index = seed % open.length;
        Position storage position = open[index];
        uint256 delta = bound(amount, MIN_LIQUIDITY_STEP, position.liquidity);
        if (position.liquidity - delta < MIN_LIQUIDITY_STEP) delta = position.liquidity;
        _modify(p, position.salt, -int256(delta));
        if (delta == position.liquidity) {
            open[index] = open[open.length - 1];
            open.pop();
        } else {
            position.liquidity -= delta;
        }
    }

    function openPositions(uint256 p) external view returns (uint256) {
        return positions[p].length;
    }

    // ------------------------------------------------------------------ internals

    function _modify(uint256 p, bytes32 salt, int256 delta) internal {
        uint256 deadBefore = token.balanceOf(DEAD);
        liquidityRouter.modifyLiquidity(keys[p], ModifyLiquidityParams(LOWER, UPPER, delta, salt), "");
        liquidityRouter.modifyLiquidity(controls[p], ModifyLiquidityParams(LOWER, UPPER, delta, salt), "");
        assertEq(token.balanceOf(DEAD), deadBefore, "liquidity changes are untaxed");
        ++liquidityOps;
    }

    function _trade(address actor, uint256 p, bool isBuy, bool exactInput, uint256 amount, uint160 limit)
        internal
    {
        PoolKey memory key = keys[p];
        bool tokenIs0 = p == 0;
        bool zeroForOne = isBuy != tokenIs0;
        SwapParams memory params =
            SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit);
        bool tokenSpecified = exactInput != isBuy;
        uint256 specifiedTax = !tokenSpecified ? 0 : exactInput ? amount / 100 : (amount - 1) / 99;

        uint256 deadBefore = token.balanceOf(DEAD);
        uint256 actorTokensBefore = token.balanceOf(actor);
        uint256 managerTokensBefore = token.balanceOf(address(manager));

        vm.prank(actor);
        try router.swap(key, params, PoolSwapTest.TestSettings(false, false), "") returns (
            BalanceDelta actual
        ) {
            int256 walletMove = int256(token.balanceOf(actor)) - int256(actorTokensBefore);
            // Mirror on the control pool with the gross BTAX amount.
            SwapParams memory untaxedParams = SwapParams(
                params.zeroForOne, params.amountSpecified + int256(specifiedTax), params.sqrtPriceLimitX96
            );
            vm.prank(actor);
            BalanceDelta expected =
                router.swap(controls[p], untaxedParams, PoolSwapTest.TestSettings(false, false), "");

            int256 poolTokens = tokenIs0 ? expected.amount0() : expected.amount1();
            int256 actualTokens = tokenIs0 ? actual.amount0() : actual.amount1();
            uint256 tax = token.balanceOf(DEAD) - deadBefore;
            uint256 gross = isBuy ? uint256(poolTokens) : uint256(-actualTokens);

            assertEq(tax, gross / 100, "burn is 1% of the gross BTAX leg");
            assertEq(actualTokens, poolTokens - int256(tax), "trader delta is the pool leg net of the burn");
            assertEq(
                tokenIs0 ? actual.amount1() : actual.amount0(),
                tokenIs0 ? expected.amount1() : expected.amount0(),
                "paired currency identical to the untaxed trade"
            );
            if (tokenSpecified && specifiedTax != 0) {
                assertEq(actualTokens, params.amountSpecified, "taxed specified trades fill completely");
            }
            assertEq(walletMove, actualTokens, "wallet matches delta");
            // Hooked swap: manager moves -(trader delta) and pays the tax out to DEAD.
            // Control swap: manager moves -(pool leg). Both happened since `managerTokensBefore`.
            assertEq(
                int256(token.balanceOf(address(manager))) - int256(managerTokensBefore),
                -actualTokens - int256(tax) - poolTokens,
                "manager BTAX moves by the trader delta plus the burn"
            );

            burned += tax;
            grossVolume += gross;
            ++swaps;
        } catch (bytes memory reason) {
            bytes memory partialFill = abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(BurnTaxHook.PartialFillWithSpecifiedTax.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            );
            assertEq(
                keccak256(reason),
                keccak256(partialFill),
                "the only accepted revert is the atomic partial-fill refusal"
            );
            assertTrue(tokenSpecified && specifiedTax != 0, "only taxed specified trades may be refused");
            assertEq(token.balanceOf(DEAD), deadBefore, "a refused trade burns nothing");
            assertEq(token.balanceOf(actor), actorTokensBefore);
            ++partialFillRefusals;
        }
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 32
contract BurnTaxSequenceInvariantTest is BurnTaxFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    BurnTaxSequenceHandler internal handler;
    address[3] internal actors = [address(0xA11CE), address(0xB0B), address(0xCA201)];

    function setUp() public override {
        super.setUp();
        handler = new BurnTaxSequenceHandler(
            token, manager, hook, router, liquidityRouter, token0Key, token1Key, actors
        );
        for (uint256 i; i < 3; ++i) {
            token.transfer(actors[i], 10_000_000 ether);
            low.transfer(actors[i], 10_000_000 ether);
            high.transfer(actors[i], 10_000_000 ether);
        }
        token.transfer(address(handler), 50_000_000 ether);
        low.transfer(address(handler), 50_000_000 ether);
        high.transfer(address(handler), 50_000_000 ether);
        handler.approveAll();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = BurnTaxSequenceHandler.swap.selector;
        selectors[1] = BurnTaxSequenceHandler.swapWithLimit.selector;
        selectors[2] = BurnTaxSequenceHandler.addLiquidity.selector;
        selectors[3] = BurnTaxSequenceHandler.removeLiquidity.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @dev The hooked pool and its untaxed control execute identically: same price, tick, liquidity
    /// and LP fee growth after any sequence. The tax never leaks into AMM state.
    function invariant_hookedPoolTracksUntaxedControl() public view {
        PoolKey[2] memory hooked = [token0Key, token1Key];
        for (uint256 p; p < 2; ++p) {
            PoolKey memory control = _control(hooked[p]);
            (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(hooked[p].toId());
            (uint160 controlPrice, int24 controlTick,,) = manager.getSlot0(control.toId());
            assertEq(price, controlPrice, "price");
            assertEq(tick, controlTick, "tick");
            assertEq(protocolFee, 0);
            assertEq(lpFee, 3000, "the LP fee is the pool's own");
            assertEq(
                manager.getLiquidity(hooked[p].toId()), manager.getLiquidity(control.toId()), "liquidity"
            );
            (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(hooked[p].toId());
            (uint256 c0, uint256 c1) = manager.getFeeGrowthGlobals(control.toId());
            assertEq(g0, c0, "fee growth 0");
            assertEq(g1, c1, "fee growth 1");
        }
    }

    function invariant_deadAddressHoldsExactlyWhatWasBurned() public view {
        assertEq(token.balanceOf(DEAD), handler.burned());
        assertEq(low.balanceOf(DEAD), 0);
        assertEq(high.balanceOf(DEAD), 0);
        // Per-swap flooring loses less than one unit each, so the total stays within swaps of 1%.
        assertLe(handler.burned(), handler.grossVolume() / 100);
        assertGe(handler.burned() + handler.swaps(), handler.grossVolume() / 100);
    }

    function invariant_supplyFixedAndNothingStuckInHookOrRouter() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 held = token.balanceOf(address(this)) + token.balanceOf(address(manager))
            + token.balanceOf(DEAD) + token.balanceOf(address(handler));
        for (uint256 i; i < 3; ++i) {
            held += token.balanceOf(actors[i]);
        }
        assertEq(held, SUPPLY, "every BTAX is in a known wallet, the manager or the dead address");
        assertEq(token.balanceOf(address(hook)), 0, "the hook never custodies BTAX");
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "no ERC-6909 claims either"
        );
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(liquidityRouter)), 0);
    }

    function invariant_managerFullySettledAfterEveryCall() public view {
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        _assertSettled(token0Key);
        _assertSettled(token1Key);
    }
}
