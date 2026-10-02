// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Sends 1% of the gross BTAX leg of each swap to DEAD using v4 return deltas.
/// @dev Implements only the three advertised callbacks. No fallback, custody, admin or upgrade path.
contract BurnTaxHook {
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

    /// @param isBuy True when the trader receives BTAX, irrespective of its currency ordering.
    /// @param amount Actual BTAX minor units transferred to DEAD; may round to zero.
    event Burned(PoolId indexed poolId, bool indexed isBuy, uint256 amount);

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

    /// @dev Accepts the pool's own fee and unrelated pools. Also prevents initialization before code exists.
    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
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

        // Creates a debit exactly canceled by the positive hook return delta. Never holds BTAX.
        // The manager needs this much BTAX before the router settles (see README).
        if (fee != 0) poolManager.take(launchedToken, DEAD, fee);
        emit Burned(key.toId(), isBuy, fee);
        return (IHooks.afterSwap.selector, returnedFee);
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
