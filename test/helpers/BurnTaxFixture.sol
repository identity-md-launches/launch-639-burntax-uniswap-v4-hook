// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BurnTaxToken} from "../../src/BurnTaxToken.sol";
import {BurnTaxHook} from "../../src/BurnTaxHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MineBurnTax} from "../../script/MineBurnTax.s.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

abstract contract BurnTaxFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant PRICE = 1 << 96;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    int256 internal constant LIQUIDITY = 1_000_000 ether;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    BurnTaxToken internal token;
    MockERC20 internal low;
    MockERC20 internal high;
    IPoolManager internal manager;
    BurnTaxHook internal hook;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolKey internal token0Key;
    PoolKey internal token1Key;

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new BurnTaxToken();
        low = MockERC20(address(0x1000));
        high = MockERC20(address(type(uint160).max - 1));
        _deployMockAt(address(low), "Low", "LOW");
        _deployMockAt(address(high), "High", "HIGH");
        assertLt(uint160(address(low)), uint160(address(token)));
        assertLt(uint160(address(token)), uint160(address(high)));

        hook = _deployHook(manager);
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(router), SUPPLY);
        token.approve(address(liquidityRouter), SUPPLY);
        low.approve(address(router), SUPPLY);
        low.approve(address(liquidityRouter), SUPPLY);
        high.approve(address(router), SUPPLY);
        high.approve(address(liquidityRouter), SUPPLY);

        token0Key = _key(address(token), address(high), address(hook));
        token1Key = _key(address(low), address(token), address(hook));
        _seed(token0Key);
        _seed(token1Key);
        _seed(_control(token0Key));
        _seed(_control(token1Key));
    }

    /// @dev Runs the mock's constructor in place at a fixed address so both currency orderings exist.
    /// Uses the compiled creation code directly: no artifact lookup, so no filesystem permission is needed.
    function _deployMockAt(address at, string memory name_, string memory symbol_) internal {
        bytes memory creation =
            abi.encodePacked(type(MockERC20).creationCode, abi.encode(name_, symbol_, SUPPLY));
        vm.etch(at, creation);
        (bool ok, bytes memory runtime) = at.call("");
        require(ok, "mock constructor reverted");
        vm.etch(at, runtime);
    }

    function _deployHook(IPoolManager atManager) internal returns (BurnTaxHook deployed) {
        (bytes32 salt, address predicted) =
            new MineBurnTax().run(atManager, address(token), address(this), 0, 200_000);
        deployed = new BurnTaxHook{salt: salt}(atManager, address(token));
        assertEq(address(deployed), predicted);
        assertTrue(HookFlags.matches(predicted, HookFlags.BURNTAX));
    }

    function _key(address a, address b, address atHook) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(atHook));
    }

    function _control(PoolKey memory key) internal pure returns (PoolKey memory) {
        return PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, IHooks(address(0)));
    }

    function _seed(PoolKey memory key) internal {
        manager.initialize(key, PRICE);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, LIQUIDITY, bytes32(0)), "");
    }

    function _params(bool isBuy, bool exactInput, bool tokenIs0, uint256 amount)
        internal
        pure
        returns (SwapParams memory)
    {
        bool zeroForOne = isBuy != tokenIs0;
        return SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _swap(PoolKey memory key, SwapParams memory params) internal returns (BalanceDelta) {
        return router.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
    }

    function _assertSettled(PoolKey memory key) internal view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertFalse(manager.isUnlocked());
    }

    receive() external payable {}
}
