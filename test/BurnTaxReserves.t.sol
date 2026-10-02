// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTaxFixture} from "./helpers/BurnTaxFixture.sol";
import {PrepayRouter} from "./helpers/PrepayRouter.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

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
        _assertSettled(key);
    }

    function test_noTokenReservesSellFailsAtomicallyThenSucceedsWithPrepayment() public {
        PoolKey memory key = _freshNativePool(false);
        SwapParams memory params = _params(false, true, false, 100 ether);
        uint256 beforeTokens = token.balanceOf(address(this));
        // Direct burn precedes ordinary router settlement: no BTAX yet exists in this fresh manager.
        bytes memory transferFailure = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(token),
            IERC20.transfer.selector,
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(manager), 0, 1 ether
            ),
            abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                transferFailure,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _swap(key, params);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(this)), beforeTokens);
        _assertSettled(key);

        PrepayRouter prepaid = new PrepayRouter(manager);
        token.approve(address(prepaid), 100 ether);
        BalanceDelta delta = prepaid.swap(key, params, 100 ether, 90 ether);
        assertEq(token.balanceOf(DEAD), 1 ether);
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
