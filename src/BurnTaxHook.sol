// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Sends 1% of the gross BTAX leg of each swap to DEAD using v4 return deltas.
/// @dev Implements only the three advertised callbacks plus a permissionless redemption of deferred
/// burns. No fallback, admin or upgrade path. The hook never holds BTAX as ERC-20; while the
/// PoolManager's BTAX balance cannot fund an immediate burn, the tax is held as an ERC-6909 claim
/// that anyone can redeem to DEAD and that the next covered swap redeems on its own.
contract BurnTaxHook is IUnlockCallback {
    using LPFeeLibrary for uint24;

    IPoolManager public immutable poolManager;
    Currency public immutable launchedToken;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant TAX_BPS = 100;
    uint256 private constant TAX_DENOMINATOR = 100;
    uint256 private constant MAX_DELTA = uint256(uint128(type(int128).max));

    error OnlyPoolManager();
    error InvalidDeploymentParameter();
    error AmountTooLarge();
    error PartialFillWithSpecifiedTax();
    error UnsupportedPoolFee();
    error NothingPending();

    /// @param isBuy True when the trader receives BTAX, irrespective of its currency ordering.
    /// @param amount BTAX minor units taken from the trader's side for burning; may round to zero.
    /// Delivered to DEAD in the same swap unless a `BurnDeferred` event follows for this swap.
    event Burned(PoolId indexed poolId, bool indexed isBuy, uint256 amount);
    /// @notice The swap's tax is held as a hook ERC-6909 claim because the PoolManager's BTAX balance
    /// could not fund the transfer yet (ordinary routers settle the seller's input after afterSwap).
    event BurnDeferred(PoolId indexed poolId, uint256 amount);
    /// @notice Previously deferred tax was transferred to DEAD.
    event DeferredBurnSettled(uint256 amount);

    constructor(IPoolManager manager, address token) {
        if (address(manager).code.length == 0 || token.code.length == 0 || token == address(manager)) {
            revert InvalidDeploymentParameter();
        }
        poolManager = manager;
        launchedToken = Currency.wrap(token);
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    /// @notice Deferred tax (BTAX minor units) held as the hook's ERC-6909 claim, not yet at DEAD.
    function pendingBurn() public view returns (uint256) {
        return poolManager.balanceOf(address(this), launchedToken.toId());
    }

    /// @notice Transfers every deferred tax claim to DEAD. Anyone may call; reverts when nothing is pending.
    function burnPending() external returns (uint256 amount) {
        amount = pendingBurn();
        if (amount == 0) revert NothingPending();
        poolManager.unlock(abi.encode(amount));
    }

    /// @dev Reached only through this contract's own `burnPending` unlock.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        _settleDeferred(abi.decode(data, (uint256)));
        return "";
    }

    /// @dev Accepts the launch fee tiers and unrelated pools. Refuses the dynamic-fee flag, which this hook
    /// could never set (the LP fee would stay 0 forever), and static fees outside the launch tiers.
    /// Also prevents initialization before the hook has code.
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (key.fee.isDynamicFee() || (key.fee != 500 && key.fee != 3000 && key.fee != 10_000)) {
            revert UnsupportedPoolFee();
        }
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        int128 fee;
        if (_containsToken(key) && _tokenIsSpecified(key, params)) {
            fee = int128(int256(_specifiedFee(params.amountSpecified)));
        }
        // Positive specified delta reserves tax from exact input, or adds tax to exact output.
        // The LP fee override is always zero: retain PoolManager's own LP fee.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (!_containsToken(key)) return (IHooks.afterSwap.selector, 0);

        bool tokenIs0 = key.currency0 == launchedToken;
        bool isBuy = params.zeroForOne != tokenIs0;
        int256 tokenDelta = tokenIs0 ? int256(delta.amount0()) : int256(delta.amount1());
        uint256 fee;
        int128 returnedFee;

        if (_tokenIsSpecified(key, params)) {
            fee = _specifiedFee(params.amountSpecified);
            // afterSwap cannot revise the specified delta. Refuse a taxed partial fill atomically
            // instead of charging the requested amount's tax on a smaller executed trade.
            if (fee != 0 && tokenDelta != params.amountSpecified + int256(fee)) {
                revert PartialFillWithSpecifiedTax();
            }
        } else {
            uint256 amount = uint256(tokenDelta < 0 ? -tokenDelta : tokenDelta);
            // Buy: deduct 1% of pool output. Sell: gross up pool input so 1% of total paid burns.
            fee = isBuy ? amount / TAX_DENOMINATOR : _taxOnNet(amount);
            if (!isBuy && amount + fee > MAX_DELTA) revert AmountTooLarge();
            returnedFee = int128(int256(fee));
        }

        _burn(key, isBuy, fee);
        return (IHooks.afterSwap.selector, returnedFee);
    }

    /// @dev Both `take` and `mint` debit the hook by `fee`; the positive return delta cancels that debit
    /// exactly, so the hook ends every swap with zero currency delta and never holds BTAX as ERC-20.
    /// `take` is an immediate ERC-20 transfer out of the manager's balance, and an ordinary router
    /// settles the seller's BTAX only after this callback, so it is used only when that balance already
    /// covers the transfer; otherwise the tax is minted as a hook claim (redeemable by anyone).
    function _burn(PoolKey calldata key, bool isBuy, uint256 fee) private {
        uint256 reserves = launchedToken.balanceOf(address(poolManager));
        emit Burned(key.toId(), isBuy, fee);
        if (reserves < fee) {
            poolManager.mint(address(this), launchedToken.toId(), fee);
            emit BurnDeferred(key.toId(), fee);
            return;
        }
        // A covered swap also redeems earlier deferred tax once the balance covers both.
        uint256 pending = pendingBurn();
        if (pending != 0 && reserves >= fee + pending) _settleDeferred(pending);
        if (fee != 0) poolManager.take(launchedToken, DEAD, fee);
    }

    /// @dev Burning the claim credits the hook by `amount`; taking it to DEAD debits the same amount.
    function _settleDeferred(uint256 amount) private {
        poolManager.burn(address(this), launchedToken.toId(), amount);
        poolManager.take(launchedToken, DEAD, amount);
        emit DeferredBurnSettled(amount);
    }

    function _containsToken(PoolKey calldata key) private view returns (bool) {
        return key.currency0 == launchedToken || key.currency1 == launchedToken;
    }

    function _tokenIsSpecified(PoolKey calldata key, SwapParams calldata params) private view returns (bool) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIs0 == (key.currency0 == launchedToken);
    }

    function _specifiedFee(int256 specified) private pure returns (uint256 fee) {
        if (specified < -int256(MAX_DELTA) || specified > int256(MAX_DELTA)) revert AmountTooLarge();
        if (specified < 0) return uint256(-specified) / TAX_DENOMINATOR;
        fee = _taxOnNet(uint256(specified));
        if (uint256(specified) + fee > MAX_DELTA) revert AmountTooLarge();
    }

    /// @dev Smallest G with G - floor(G / 100) == net has tax floor((net - 1) / 99).
    function _taxOnNet(uint256 net) private pure returns (uint256) {
        return net == 0 ? 0 : (net - 1) / (TAX_DENOMINATOR - 1);
    }
}
