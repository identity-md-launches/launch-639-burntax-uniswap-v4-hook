// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BurnTaxFixture} from "./helpers/BurnTaxFixture.sol";
import {BurnTaxToken} from "../src/BurnTaxToken.sol";
import {BurnTaxHook} from "../src/BurnTaxHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BurnTaxHandler is Test {
    BurnTaxToken internal immutable token;
    PoolSwapTest internal immutable router;
    IPoolManager internal immutable manager;
    BurnTaxHook internal immutable hook;
    PoolKey internal key;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public burned;
    uint256 public swaps;

    constructor(
        BurnTaxToken token_,
        PoolSwapTest router_,
        IPoolManager manager_,
        BurnTaxHook hook_,
        PoolKey memory key_
    ) {
        token = token_;
        router = router_;
        manager = manager_;
        hook = hook_;
        key = key_;
        token.approve(address(router), 1_000_000 ether);
        IERC20(Currency.unwrap(key.currency0)).approve(address(router), 1_000_000 ether);
    }

    function trade(bool isBuy, bool exactInput, uint256 amount) external {
        amount = bound(amount, 100, 100 ether);
        uint256 beforeUser = token.balanceOf(address(this));
        uint256 beforeManager = token.balanceOf(address(manager));
        uint256 beforeDead = token.balanceOf(DEAD) + hook.pendingBurn();
        SwapParams memory params = SwapParams(
            isBuy,
            exactInput ? -int256(amount) : int256(amount),
            isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        BalanceDelta delta = router.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        uint256 tax = token.balanceOf(DEAD) + hook.pendingBurn() - beforeDead;
        int256 userChange = int256(token.balanceOf(address(this))) - int256(beforeUser);
        uint256 gross = isBuy ? uint256(userChange) + tax : uint256(-userChange);
        assertEq(tax, gross / 100);
        assertEq(userChange, delta.amount1());
        assertEq(
            int256(token.balanceOf(address(manager))) - int256(beforeManager) + userChange + int256(tax), 0
        );
        assertEq(exactInput == isBuy ? delta.amount0() : delta.amount1(), params.amountSpecified);
        burned += tax;
        ++swaps;
    }
}

contract BurnTaxInvariantTest is BurnTaxFixture {
    BurnTaxHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new BurnTaxHandler(token, router, manager, hook, token1Key);
        token.transfer(address(handler), 1_000_000 ether);
        low.transfer(address(handler), 1_000_000 ether);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = BurnTaxHandler.trade.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_supplyAndBalancesConserved() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(manager))
                + token.balanceOf(address(handler)) + token.balanceOf(DEAD),
            SUPPLY
        );
        assertEq(
            low.balanceOf(address(this)) + low.balanceOf(address(manager)) + low.balanceOf(address(handler)),
            SUPPLY
        );
        assertEq(token.balanceOf(DEAD) + hook.pendingBurn(), handler.burned());
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        _assertSettled(token1Key);
    }
}
