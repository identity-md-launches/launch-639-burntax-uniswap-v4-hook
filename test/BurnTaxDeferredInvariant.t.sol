// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PrepayRouter} from "./helpers/PrepayRouter.sol";
import {BurnTaxToken} from "../src/BurnTaxToken.sol";
import {BurnTaxHook} from "../src/BurnTaxHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MineBurnTax} from "../script/MineBurnTax.s.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev A third party that pays BTAX into the manager and mints the matching ERC-6909 claim to the
/// hook: the only way, besides a deferred swap, for the hook's claim balance to grow.
contract DeferredClaimDonor is IUnlockCallback {
    IPoolManager internal immutable manager;
    BurnTaxToken internal immutable token;

    constructor(IPoolManager manager_, BurnTaxToken token_) {
        manager = manager_;
        token = token_;
    }

    function donate(address to, uint256 amount) external {
        manager.unlock(abi.encode(msg.sender, to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address payer, address to, uint256 amount) = abi.decode(data, (address, address, uint256));
        manager.sync(Currency.wrap(address(token)));
        token.transferFrom(payer, address(manager), amount);
        manager.settle();
        manager.mint(to, uint256(uint160(address(token))), amount);
        return "";
    }
}

/// @notice Drives one native-ETH/BTAX pool on a fresh PoolManager that starts with no BTAX at all,
/// so sells through an ordinary swap-then-settle router must defer their tax as a hook claim and
/// buys, prepaid sells and `burnPending` must redeem it. Three traders, all four swap modes, a drain
/// action that buys the in-range BTAX back out so deferral recurs, claim donations and liquidity
/// changes. Every action records what the hook owes DEAD so the invariants can compare.
contract BurnTaxDeferredHandler is Test {
    using StateLibrary for IPoolManager;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 internal constant LOWER = 60;
    int24 internal constant UPPER = 600;
    uint256 internal constant MIN_LIQUIDITY_STEP = 1e12;

    BurnTaxToken internal immutable token;
    IPoolManager internal immutable manager;
    BurnTaxHook internal immutable hook;
    PoolSwapTest internal immutable router;
    PrepayRouter internal immutable prepaid;
    PoolModifyLiquidityTest internal immutable liquidityRouter;
    DeferredClaimDonor internal immutable donor;
    PoolKey internal key;
    address[3] public actors;

    // Ghost state.
    uint256 public taxedTotal; // every swap tax: at DEAD already or still a hook claim
    uint256 public donatedTotal; // claims minted to the hook by third parties
    uint256 public grossVolume; // sum of gross BTAX legs of executed swaps
    uint256 public swaps;
    uint256 public deferredSwaps;
    uint256 public redemptions; // burnPending calls that moved a claim
    uint256 public partialFillRefusals;
    uint256 public positionNonce;
    uint256[] internal openLiquidity;
    bytes32[] internal openSalts;

    constructor(
        BurnTaxToken token_,
        IPoolManager manager_,
        BurnTaxHook hook_,
        PoolSwapTest router_,
        PrepayRouter prepaid_,
        PoolModifyLiquidityTest liquidityRouter_,
        PoolKey memory key_,
        address[3] memory actors_
    ) {
        token = token_;
        manager = manager_;
        hook = hook_;
        router = router_;
        prepaid = prepaid_;
        liquidityRouter = liquidityRouter_;
        key = key_;
        actors = actors_;
        donor = new DeferredClaimDonor(manager_, token_);
        token_.approve(address(liquidityRouter_), type(uint256).max);
        for (uint256 a; a < 3; ++a) {
            vm.startPrank(actors_[a]);
            token_.approve(address(router_), type(uint256).max);
            token_.approve(address(prepaid_), type(uint256).max);
            token_.approve(address(donor), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------ actions

    /// @dev Ordinary router: input settled after afterSwap, so a sell may have to defer its tax.
    function sell(uint256 seed, bool exactInput, uint256 amount) external {
        amount = bound(amount, 1, 200 ether);
        _trade(actors[seed % 3], false, exactInput, amount, false);
    }

    /// @dev Input paid before the swap: the manager always holds the tax, so a sell burns directly.
    function prepaidSell(uint256 seed, bool exactInput, uint256 amount) external {
        amount = bound(amount, 1, 200 ether);
        _trade(actors[seed % 3], false, exactInput, amount, true);
    }

    function buy(uint256 seed, bool exactInput, uint256 amount) external {
        amount = bound(amount, 1, 200 ether);
        _trade(actors[seed % 3], true, exactInput, amount, false);
    }

    /// @dev Buys out whatever BTAX sits in range, leaving the manager with only the burn dust and
    /// claims so that the next ordinary sell has to defer again.
    function drain(uint256 seed) external {
        _trade(actors[seed % 3], true, true, 1_000_000 ether, false);
    }

    function redeem(uint256 seed) external {
        uint256 pending = hook.pendingBurn();
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(actors[seed % 3]);
        if (pending == 0) {
            vm.expectRevert(BurnTaxHook.NothingPending.selector);
            hook.burnPending();
            return;
        }
        assertEq(hook.burnPending(), pending, "burnPending reports the amount it moved");
        assertEq(hook.pendingBurn(), 0, "the whole claim is redeemed");
        assertEq(token.balanceOf(DEAD), deadBefore + pending, "the claim lands at DEAD");
        ++redemptions;
    }

    function donate(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 3];
        amount = bound(amount, 1, 50 ether);
        uint256 pendingBefore = hook.pendingBurn();
        vm.prank(actor);
        donor.donate(address(hook), amount);
        assertEq(hook.pendingBurn(), pendingBefore + amount, "a donated claim is pending tax");
        donatedTotal += amount;
    }

    function addLiquidity(uint256 amount) external {
        uint256 liquidity = bound(amount, 1 ether, 10_000 ether);
        bytes32 salt = keccak256(abi.encode(++positionNonce));
        _modify(salt, int256(liquidity));
        openSalts.push(salt);
        openLiquidity.push(liquidity);
    }

    function removeLiquidity(uint256 seed, uint256 amount) external {
        if (openSalts.length == 0) return;
        uint256 index = seed % openSalts.length;
        uint256 delta = bound(amount, MIN_LIQUIDITY_STEP, openLiquidity[index]);
        if (openLiquidity[index] - delta < MIN_LIQUIDITY_STEP) delta = openLiquidity[index];
        _modify(openSalts[index], -int256(delta));
        if (delta == openLiquidity[index]) {
            openSalts[index] = openSalts[openSalts.length - 1];
            openLiquidity[index] = openLiquidity[openLiquidity.length - 1];
            openSalts.pop();
            openLiquidity.pop();
        } else {
            openLiquidity[index] -= delta;
        }
    }

    // ------------------------------------------------------------------ internals

    function _modify(bytes32 salt, int256 delta) internal {
        uint256 deadBefore = token.balanceOf(DEAD);
        uint256 pendingBefore = hook.pendingBurn();
        vm.deal(address(this), 1_000_000 ether);
        liquidityRouter.modifyLiquidity{value: delta > 0 ? 1_000_000 ether : 0}(
            key, ModifyLiquidityParams(LOWER, UPPER, delta, salt), ""
        );
        assertEq(token.balanceOf(DEAD), deadBefore, "liquidity changes are untaxed");
        assertEq(hook.pendingBurn(), pendingBefore, "liquidity changes touch no claim");
    }

    /// @dev Price limits one spacing outside the liquidity range, so a trade can exhaust it: a taxed
    /// BTAX-specified trade that runs out of liquidity is refused atomically by the hook, every other
    /// trade fills what it can and is taxed on that. A trade whose direction the price has already
    /// exhausted is skipped, because the PoolManager itself refuses it before any hook runs.
    function _trade(address actor, bool isBuy, bool exactInput, uint256 amount, bool prepay) internal {
        // BTAX is currency1: buying BTAX is zeroForOne.
        uint160 limit = TickMath.getSqrtPriceAtTick(isBuy ? LOWER - 60 : UPPER + 60);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        if (isBuy ? price <= limit : price >= limit) return;
        SwapParams memory params = SwapParams(isBuy, exactInput ? -int256(amount) : int256(amount), limit);
        bool tokenSpecified = exactInput != isBuy;
        uint256 specifiedTax = !tokenSpecified ? 0 : exactInput ? amount / 100 : (amount - 1) / 99;

        uint256 reservesBefore = token.balanceOf(address(manager));
        uint256 pendingBefore = hook.pendingBurn();
        uint256 deadBefore = token.balanceOf(DEAD);
        uint256 actorTokensBefore = token.balanceOf(actor);

        bool ok;
        bytes memory reason;
        BalanceDelta actual;
        if (prepay) {
            // Pay the whole gross input up front; the router refunds what the swap does not use.
            uint256 prepayment = exactInput ? amount : amount * 2 + 1 ether;
            vm.prank(actor);
            try prepaid.swap(key, params, prepayment, 0) returns (BalanceDelta delta) {
                (ok, actual) = (true, delta);
            } catch (bytes memory data) {
                reason = data;
            }
        } else {
            uint256 value = isBuy ? (exactInput ? amount : amount * 2 + 1 ether) : 0;
            vm.deal(actor, value);
            vm.prank(actor);
            try router.swap{value: value}(key, params, PoolSwapTest.TestSettings(false, false), "") returns (
                BalanceDelta delta
            ) {
                (ok, actual) = (true, delta);
            } catch (bytes memory data) {
                reason = data;
            }
        }

        if (!ok) {
            bytes memory partialFill = abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(BurnTaxHook.PartialFillWithSpecifiedTax.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            );
            assertEq(keccak256(reason), keccak256(partialFill), "only the atomic partial-fill refusal");
            assertTrue(tokenSpecified && specifiedTax != 0, "only taxed specified trades may be refused");
            assertEq(token.balanceOf(DEAD), deadBefore, "a refused trade burns nothing");
            assertEq(hook.pendingBurn(), pendingBefore, "a refused trade defers nothing");
            assertEq(token.balanceOf(actor), actorTokensBefore);
            ++partialFillRefusals;
            return;
        }

        int256 traderTokens = actual.amount1();
        uint256 deadAfter = token.balanceOf(DEAD);
        uint256 pendingAfter = hook.pendingBurn();
        uint256 tax = deadAfter + pendingAfter - deadBefore - pendingBefore;
        uint256 gross = isBuy ? uint256(traderTokens) + tax : uint256(-traderTokens);

        assertEq(tax, gross / 100, "tax is 1% of the gross BTAX leg, whether burned now or deferred");
        if (tokenSpecified && specifiedTax != 0) {
            assertEq(traderTokens, params.amountSpecified, "taxed specified trades fill completely");
        }
        assertEq(
            int256(token.balanceOf(actor)) - int256(actorTokensBefore), traderTokens, "wallet matches delta"
        );

        if (isBuy || prepay) {
            // The pool's own output, or the prepaid input, always covers the tax and the whole claim.
            assertEq(pendingAfter, 0, "a covered swap redeems every pending claim");
            assertEq(deadAfter, deadBefore + pendingBefore + tax, "tax and old claim both reach DEAD");
        } else if (reservesBefore < tax) {
            assertEq(pendingAfter, pendingBefore + tax, "an uncovered sell defers exactly its tax");
            assertEq(deadAfter, deadBefore, "nothing reaches DEAD in an uncovered sell");
            ++deferredSwaps;
        } else if (reservesBefore >= tax + pendingBefore) {
            assertEq(pendingAfter, 0, "a sell that covers tax and claim redeems the claim");
            assertEq(deadAfter, deadBefore + pendingBefore + tax);
        } else {
            assertEq(pendingAfter, pendingBefore, "a sell covering only its own tax leaves the claim");
            assertEq(deadAfter, deadBefore + tax);
        }
        // The seller's input backs the pool and every claim once the router has settled.
        assertGe(token.balanceOf(address(manager)), pendingAfter, "claims are always backed");

        taxedTotal += tax;
        grossVolume += gross;
        ++swaps;
    }

    receive() external payable {}
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 40
contract BurnTaxDeferredInvariantTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant PRICE = 1 << 96;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    /// @dev Thin on purpose: the range holds roughly 800 BTAX, so a handful of 200 BTAX trades can
    /// exhaust it and reach the partial-fill refusal and the bought-out launch-pool state.
    int256 internal constant LIQUIDITY = 30_000 ether;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    BurnTaxToken internal token;
    IPoolManager internal manager;
    BurnTaxHook internal hook;
    PoolSwapTest internal router;
    PrepayRouter internal prepaid;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolKey internal key;
    BurnTaxDeferredHandler internal handler;
    address[3] internal actors = [address(0xA11CE), address(0xB0B), address(0xCA201)];

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new BurnTaxToken();
        (bytes32 salt, address predicted) =
            new MineBurnTax().run(manager, address(token), address(this), 0, 200_000);
        hook = new BurnTaxHook{salt: salt}(manager, address(token));
        assertEq(address(hook), predicted);
        assertTrue(HookFlags.matches(predicted, HookFlags.BURNTAX));

        router = new PoolSwapTest(manager);
        prepaid = new PrepayRouter(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook))
        );
        manager.initialize(key, PRICE);

        // Liquidity entirely above the current price holds ETH only: the manager starts with no BTAX.
        vm.deal(address(this), 1_000_000 ether);
        liquidityRouter.modifyLiquidity{value: 1_000_000 ether}(
            key, ModifyLiquidityParams(60, 600, LIQUIDITY, bytes32(0)), ""
        );
        assertEq(token.balanceOf(address(manager)), 0);
        assertGt(address(manager).balance, 0);

        handler =
            new BurnTaxDeferredHandler(token, manager, hook, router, prepaid, liquidityRouter, key, actors);
        for (uint256 i; i < 3; ++i) {
            token.transfer(actors[i], 10_000_000 ether);
        }
        token.transfer(address(handler), 50_000_000 ether);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = BurnTaxDeferredHandler.sell.selector;
        selectors[1] = BurnTaxDeferredHandler.prepaidSell.selector;
        selectors[2] = BurnTaxDeferredHandler.buy.selector;
        selectors[3] = BurnTaxDeferredHandler.drain.selector;
        selectors[4] = BurnTaxDeferredHandler.redeem.selector;
        selectors[5] = BurnTaxDeferredHandler.donate.selector;
        selectors[6] = BurnTaxDeferredHandler.addLiquidity.selector;
        selectors[7] = BurnTaxDeferredHandler.removeLiquidity.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @dev Everything ever taxed or donated is either at DEAD or still a hook claim; nothing else.
    function invariant_deadPlusPendingEqualsEverythingOwed() public view {
        assertEq(token.balanceOf(DEAD) + hook.pendingBurn(), handler.taxedTotal() + handler.donatedTotal());
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), hook.pendingBurn());
        assertEq(manager.balanceOf(address(hook), 0), 0, "no native claim is ever minted");
        assertEq(address(hook).balance, 0);
        assertEq(DEAD.balance, 0, "no native currency is burned");
        // Per-swap flooring loses under one unit each, so the taxes stay within `swaps` of 1%.
        assertLe(handler.taxedTotal(), handler.grossVolume() / 100);
        assertGe(handler.taxedTotal() + handler.swaps(), handler.grossVolume() / 100);
    }

    /// @dev A claim is a promise the manager can always honour: its BTAX balance covers the claim on
    /// top of whatever the pool itself holds, so `burnPending` can never fail for lack of funds.
    function invariant_pendingClaimIsBackedByManagerBalance() public {
        uint256 pending = hook.pendingBurn();
        assertGe(token.balanceOf(address(manager)), pending);
        if (pending == 0) {
            vm.expectRevert(BurnTaxHook.NothingPending.selector);
            hook.burnPending();
            return;
        }
        uint256 deadBefore = token.balanceOf(DEAD);
        assertEq(hook.burnPending(), pending);
        assertEq(token.balanceOf(DEAD), deadBefore + pending);
        assertEq(hook.pendingBurn(), 0);
    }

    function invariant_supplyFixedAndNothingStuckOutsideKnownWallets() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 held = token.balanceOf(address(this)) + token.balanceOf(address(manager))
            + token.balanceOf(DEAD) + token.balanceOf(address(handler));
        for (uint256 i; i < 3; ++i) {
            held += token.balanceOf(actors[i]);
        }
        assertEq(held, SUPPLY, "every BTAX is in a known wallet, the manager or the dead address");
        assertEq(token.balanceOf(address(hook)), 0, "the hook never custodies BTAX as ERC-20");
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(prepaid)), 0);
        assertEq(token.balanceOf(address(liquidityRouter)), 0);
        assertEq(address(router).balance, 0, "the router refunds every unused wei");
        assertEq(address(prepaid).balance, 0);
    }

    function invariant_managerFullySettledAfterEveryCall() public view {
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(manager.currencyDelta(address(prepaid), key.currency1), 0);
        (,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(protocolFee, 0);
        assertEq(lpFee, 3000, "the LP fee is the pool's own");
    }

    /// @dev The handler's branches are reachable, so the invariants above are not vacuous: an ordinary
    /// sell into an empty manager defers, the next covered sell redeems, a drain empties the range so
    /// the following sell defers again, `burnPending` redeems it, a prepaid sell burns at once, an
    /// over-sized specified trade is refused, and the bought-out range makes buys a no-op.
    function test_handlerReachesEveryBranch() public {
        handler.sell(0, true, 100 ether);
        assertEq(handler.deferredSwaps(), 1, "first sell into an empty manager defers");
        assertEq(hook.pendingBurn(), 1 ether);
        assertEq(token.balanceOf(DEAD), 0);

        handler.sell(1, true, 100 ether);
        assertEq(handler.deferredSwaps(), 1, "the second sell is covered by the first seller's input");
        assertEq(hook.pendingBurn(), 0, "and redeems the earlier claim");
        assertEq(token.balanceOf(DEAD), 2 ether);

        handler.drain(2);
        assertLt(token.balanceOf(address(manager)), 1 ether, "only LP-fee BTAX is left in the manager");
        handler.sell(0, true, 100 ether);
        assertEq(handler.deferredSwaps(), 2, "a sell after the buy-out defers");
        assertEq(hook.pendingBurn(), 1 ether);

        handler.redeem(1);
        assertEq(handler.redemptions(), 1);
        assertEq(hook.pendingBurn(), 0);
        handler.redeem(1);
        assertEq(handler.redemptions(), 1, "nothing to redeem twice");

        handler.drain(0);
        handler.prepaidSell(2, true, 100 ether);
        assertEq(handler.deferredSwaps(), 2, "a prepaid sell is covered by its own input");
        assertEq(hook.pendingBurn(), 0);

        handler.donate(0, 5 ether);
        assertEq(hook.pendingBurn(), 5 ether);
        handler.buy(1, true, 10 ether);
        assertEq(hook.pendingBurn(), 0, "a buy redeems a donated claim too");

        for (uint256 i; i < 6; ++i) {
            handler.sell(i, true, 200 ether);
        }
        assertGt(handler.partialFillRefusals(), 0, "specified sells past the range are refused");
        handler.sell(0, false, 200 ether);
        assertEq(hook.pendingBurn(), 0, "an exact-output sell past the range fills what it can");

        uint256 swapsBefore = handler.swaps();
        handler.sell(0, true, 1 ether);
        assertEq(handler.swaps(), swapsBefore, "nothing left to sell into: the action is a no-op");

        assertEq(token.balanceOf(DEAD) + hook.pendingBurn(), handler.taxedTotal() + handler.donatedTotal());
        invariant_pendingClaimIsBackedByManagerBalance();
        invariant_supplyFixedAndNothingStuckOutsideKnownWallets();
        invariant_managerFullySettledAfterEveryCall();
    }

    receive() external payable {}
}
