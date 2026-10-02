// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTaxFixture} from "./helpers/BurnTaxFixture.sol";
import {PrepayRouter} from "./helpers/PrepayRouter.sol";
import {BurnTaxHook} from "../src/BurnTaxHook.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Calls `burnPending` from inside its own manager unlock: the manager is already unlocked.
contract NestedRedeemer is IUnlockCallback {
    IPoolManager internal immutable manager;
    BurnTaxHook internal immutable hook;

    constructor(IPoolManager manager_, BurnTaxHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function attempt() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        hook.burnPending();
        return "";
    }
}

/// @dev Pays BTAX into the manager and mints the matching ERC-6909 claim to an arbitrary recipient.
contract ClaimGifter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function gift(address token, address to, uint256 amount) external {
        manager.unlock(abi.encode(msg.sender, token, to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, address token, address to, uint256 amount) =
            abi.decode(data, (address, address, address, uint256));
        manager.sync(Currency.wrap(token));
        IERC20(token).transferFrom(payer, address(manager), amount);
        manager.settle();
        manager.mint(to, uint256(uint160(token)), amount);
        return "";
    }
}

contract BurnTaxReservesTest is BurnTaxFixture {
    function _freshNativePool(bool tokensOnly) internal returns (PoolKey memory key) {
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = _deployHook(manager);
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(router), SUPPLY);
        token.approve(address(liquidityRouter), SUPPLY);
        vm.deal(address(this), 100_000 ether);
        key = _key(address(0), address(token), address(hook));
        manager.initialize(key, PRICE);
        liquidityRouter.modifyLiquidity{value: tokensOnly ? 0 : 100_000 ether}(
            key,
            ModifyLiquidityParams(
                tokensOnly ? int24(-600) : int24(60),
                tokensOnly ? int24(-60) : int24(600),
                LIQUIDITY,
                bytes32(0)
            ),
            ""
        );
        assertEq(address(manager).balance == 0, tokensOnly);
        assertEq(token.balanceOf(address(manager)) == 0, !tokensOnly);
    }

    function _tokenId() internal view returns (uint256) {
        return uint256(uint160(address(token)));
    }

    function test_freshTokenOnlyPoolBuyExactInputWithoutNativeReserves() public {
        _freshBuy(true);
    }

    function test_freshTokenOnlyPoolBuyExactOutputWithoutNativeReserves() public {
        _freshBuy(false);
    }

    function _freshBuy(bool exactInput) internal {
        PoolKey memory key = _freshNativePool(true);
        uint256 beforeTokens = token.balanceOf(address(this));
        BalanceDelta delta = router.swap{value: 200 ether}(
            key, _params(true, exactInput, false, 100 ether), PoolSwapTest.TestSettings(false, false), ""
        );
        uint256 burned = token.balanceOf(DEAD);
        uint256 received = token.balanceOf(address(this)) - beforeTokens;
        assertGt(burned, 0);
        assertEq(burned, (received + burned) / 100);
        assertEq(uint128(delta.amount1()), received);
        if (exactInput) assertEq(delta.amount0(), -100 ether);
        else assertEq(received, 100 ether);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(hook.pendingBurn(), 0, "a buy is funded by the pool's own BTAX output");
        _assertSettled(key);
    }

    /// @dev An ordinary swap-then-settle router sells into a manager holding no BTAX: the sell executes,
    /// the trader pays exactly the input, and the 1% waits as a hook claim until anyone redeems it.
    function test_noTokenReservesSellDefersBurnThenAnyoneRedeemsToDead() public {
        PoolKey memory key = _freshNativePool(false);
        uint256 beforeTokens = token.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;

        vm.expectEmit(address(hook));
        emit BurnTaxHook.Burned(key.toId(), false, 1 ether);
        vm.expectEmit(address(hook));
        emit BurnTaxHook.BurnDeferred(key.toId(), 1 ether);
        BalanceDelta delta = _swap(key, _params(false, true, false, 100 ether));

        assertEq(delta.amount1(), -100 ether, "trader pays exactly the specified input");
        assertGt(delta.amount0(), 90 ether);
        assertEq(beforeTokens - token.balanceOf(address(this)), 100 ether);
        assertEq(address(this).balance - ethBefore, uint128(delta.amount0()));
        assertEq(token.balanceOf(DEAD), 0, "nothing could be transferred yet");
        assertEq(hook.pendingBurn(), 1 ether);
        assertEq(manager.balanceOf(address(hook), _tokenId()), 1 ether);
        assertEq(token.balanceOf(address(manager)), 100 ether, "the full input now backs pool and claim");
        assertEq(token.balanceOf(address(hook)), 0);
        _assertSettled(key);

        address anyone = makeAddr("anyone");
        vm.expectEmit(address(hook));
        emit BurnTaxHook.DeferredBurnSettled(1 ether);
        vm.prank(anyone);
        assertEq(hook.burnPending(), 1 ether);
        assertEq(token.balanceOf(DEAD), 1 ether);
        assertEq(hook.pendingBurn(), 0);
        assertEq(token.balanceOf(address(manager)), 99 ether);
        assertEq(token.balanceOf(anyone), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        _assertSettled(key);

        vm.expectRevert(BurnTaxHook.NothingPending.selector);
        hook.burnPending();
    }

    function test_noTokenReservesExactOutputSellDefersGrossedUpTax() public {
        PoolKey memory key = _freshNativePool(false);
        uint256 beforeTokens = token.balanceOf(address(this));
        BalanceDelta delta = _swap(key, _params(false, false, false, 100 ether));
        uint256 paid = beforeTokens - token.balanceOf(address(this));
        assertEq(delta.amount0(), 100 ether, "exact paired-currency output");
        assertEq(int256(delta.amount1()), -int256(paid));
        assertEq(hook.pendingBurn(), paid / 100);
        assertGt(paid / 100, 0);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(manager)), paid);
        _assertSettled(key);
        hook.burnPending();
        assertEq(token.balanceOf(DEAD), paid / 100);
        assertEq(token.balanceOf(address(manager)), paid - paid / 100);
        _assertSettled(key);
    }

    function test_deferredBurnIsRedeemedByTheNextCoveredSwap() public {
        PoolKey memory key = _freshNativePool(false);
        _swap(key, _params(false, true, false, 100 ether));
        assertEq(hook.pendingBurn(), 1 ether);

        // The manager now holds 100 BTAX: a buy's own 1% plus the pending claim are both covered.
        vm.recordLogs();
        BalanceDelta delta = router.swap{value: 10 ether}(
            key, _params(true, true, false, 10 ether), PoolSwapTest.TestSettings(false, false), ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 buyTax = (uint128(delta.amount1()) + token.balanceOf(DEAD) - 1 ether) / 100;
        assertGt(buyTax, 0);
        assertEq(hook.pendingBurn(), 0, "earlier claim redeemed inside the swap");
        assertEq(token.balanceOf(DEAD), 1 ether + buyTax);
        bool settledSeen;
        bool burnedSeen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == keccak256("DeferredBurnSettled(uint256)")) {
                settledSeen = true;
                assertEq(abi.decode(logs[i].data, (uint256)), 1 ether);
            } else {
                assertEq(logs[i].topics[0], keccak256("Burned(bytes32,bool,uint256)"));
                assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
                assertEq(logs[i].topics[2], bytes32(uint256(1)));
                assertEq(abi.decode(logs[i].data, (uint256)), buyTax);
                burnedSeen = true;
            }
        }
        assertTrue(settledSeen && burnedSeen);
        _assertSettled(key);
    }

    /// @dev A swap's own tax is covered but the pending claim is not: the swap burns directly and leaves
    /// the claim alone. Reached only through third-party ERC-6909 gifts to the hook, which burn too.
    function test_coveredSwapKeepsClaimWhenReservesCoverOnlyItsOwnTax() public {
        PoolKey memory key = _freshNativePool(false);
        ClaimGifter gifter = new ClaimGifter(manager);
        token.approve(address(gifter), 50 ether);
        gifter.gift(address(token), address(hook), 50 ether);
        assertEq(hook.pendingBurn(), 50 ether);
        assertEq(token.balanceOf(address(manager)), 50 ether);

        _swap(key, _params(false, true, false, 100 ether));
        assertEq(token.balanceOf(DEAD), 1 ether, "own tax covered by the 50 BTAX balance");
        assertEq(hook.pendingBurn(), 50 ether, "claim stays until a swap covers both");
        _assertSettled(key);

        // 149 BTAX now backs the pool and the claim; a buy's 1% plus the 50 claim are covered.
        router.swap{value: 10 ether}(
            key, _params(true, true, false, 10 ether), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(hook.pendingBurn(), 0);
        assertGt(token.balanceOf(DEAD), 51 ether);
        _assertSettled(key);
    }

    /// @dev The reviewer's launch scenario: buyers exhaust the in-range BTAX, then a 1000 BTAX sell.
    function test_sellSucceedsAfterInRangeBtaxIsBoughtOut() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = _deployHook(manager);
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(router), SUPPLY);
        token.approve(address(liquidityRouter), SUPPLY);
        vm.deal(address(this), 10_000_000 ether);
        PoolKey memory key = _key(address(0), address(token), address(hook));
        manager.initialize(key, PRICE);
        liquidityRouter.modifyLiquidity{value: 100_000 ether}(
            key, ModifyLiquidityParams(-60, 60, LIQUIDITY, bytes32(0)), ""
        );

        router.swap{value: 1_000_000 ether}(
            key,
            SwapParams(true, -1_000_000 ether, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertLt(token.balanceOf(address(manager)), 10 ether, "manager holds under 1% of the coming sale");
        assertGt(address(manager).balance, 1_000 ether);

        uint256 deadBefore = token.balanceOf(DEAD);
        uint256 traderBefore = token.balanceOf(address(this));
        BalanceDelta delta = _swap(key, _params(false, true, false, 1_000 ether));
        assertEq(delta.amount1(), -1_000 ether);
        assertGt(delta.amount0(), 0);
        assertEq(traderBefore - token.balanceOf(address(this)), 1_000 ether);
        assertEq(hook.pendingBurn() + token.balanceOf(DEAD) - deadBefore, 10 ether);
        _assertSettled(key);

        hook.burnPending();
        assertEq(token.balanceOf(DEAD) - deadBefore, 10 ether);
        assertEq(hook.pendingBurn(), 0);
        _assertSettled(key);
    }

    function test_redemptionCallbacksRefuseOtherCallersAndNestedUnlocks() public {
        PoolKey memory key = _freshNativePool(false);
        _swap(key, _params(false, true, false, 100 ether));
        vm.expectRevert(BurnTaxHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1 ether)));
        NestedRedeemer nested = new NestedRedeemer(manager, hook);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        nested.attempt();
        assertEq(hook.pendingBurn(), 1 ether);
        assertEq(token.balanceOf(DEAD), 0);
        _assertSettled(key);
    }

    function test_prepaidSellIntoEmptyReservesBurnsImmediately() public {
        PoolKey memory key = _freshNativePool(false);
        SwapParams memory params = _params(false, true, false, 100 ether);
        uint256 beforeTokens = token.balanceOf(address(this));
        PrepayRouter prepaid = new PrepayRouter(manager);
        token.approve(address(prepaid), 100 ether);
        BalanceDelta delta = prepaid.swap(key, params, 100 ether, 90 ether);
        assertEq(token.balanceOf(DEAD), 1 ether);
        assertEq(hook.pendingBurn(), 0, "prepaid input funds the transfer directly");
        assertEq(beforeTokens - token.balanceOf(address(this)), 100 ether);
        assertEq(delta.amount1(), -100 ether);
        assertGt(delta.amount0(), 90 ether);
        assertEq(token.balanceOf(address(manager)), 99 ether);
        _assertSettled(key);
    }

    function test_emptyTokenReservesExactOutputSellWithPrepaymentAndRefund() public {
        PoolKey memory key = _freshNativePool(false);
        PrepayRouter prepaid = new PrepayRouter(manager);
        token.approve(address(prepaid), 200 ether);
        uint256 beforeTokens = token.balanceOf(address(this));
        BalanceDelta delta = prepaid.swap(key, _params(false, false, false, 100 ether), 200 ether, 100 ether);
        uint256 paid = beforeTokens - token.balanceOf(address(this));
        uint256 burned = token.balanceOf(DEAD);
        assertEq(delta.amount0(), 100 ether);
        assertEq(int256(delta.amount1()), -int256(paid));
        assertEq(burned, paid / 100);
        assertEq(hook.pendingBurn(), 0);
        assertLt(paid, 200 ether, "unused prepayment refunded");
        assertEq(token.balanceOf(address(manager)), paid - burned);
        assertEq(token.balanceOf(address(prepaid)), 0);
        _assertSettled(key);
    }

    function test_routerSlippageCheckUsesTaxedOutputAndRollsBackBurn() public {
        PoolKey memory key = _freshNativePool(true);
        PrepayRouter prepaid = new PrepayRouter(manager);
        uint256 beforeTokens = token.balanceOf(address(this));
        uint256 snapshot = vm.snapshotState();
        BalanceDelta preview =
            prepaid.swap{value: 100 ether}(key, _params(true, true, false, 100 ether), 0, 0);
        uint256 untaxedOutput = uint128(preview.amount1()) + token.balanceOf(DEAD);
        assertGt(untaxedOutput, uint128(preview.amount1()));
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.expectRevert(PrepayRouter.SlippageExceeded.selector);
        prepaid.swap{value: 100 ether}(key, _params(true, true, false, 100 ether), 0, untaxedOutput);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(this)), beforeTokens);
        assertEq(address(manager).balance, 0);
        _assertSettled(key);
    }
}
