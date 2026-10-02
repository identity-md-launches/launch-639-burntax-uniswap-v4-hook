// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

/// @dev Test-only router demonstrating pre-settlement when the manager has no input token reserves.
contract PrepayRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    IPoolManager internal immutable manager;
    error SlippageExceeded();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, uint256 prepayment, uint256 minimumOutput)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            manager.unlock(abi.encode(msg.sender, key, params, prepayment, minimumOutput)), (BalanceDelta)
        );
        if (address(this).balance != 0) {
            CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, address(this).balance);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (
            address payer,
            PoolKey memory key,
            SwapParams memory params,
            uint256 prepayment,
            uint256 minimumOutput
        ) = abi.decode(data, (address, PoolKey, SwapParams, uint256, uint256));
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        if (prepayment != 0) input.settle(manager, payer, prepayment, false);
        BalanceDelta delta = manager.swap(key, params, "");
        int128 output = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (output < 0 || uint128(output) < minimumOutput) revert SlippageExceeded();
        _close(key.currency0, payer);
        _close(key.currency1, payer);
        return abi.encode(delta);
    }

    function _close(Currency currency, address payer) private {
        int256 balance = manager.currencyDelta(address(this), currency);
        if (balance < 0) currency.settle(manager, payer, uint256(-balance), false);
        if (balance > 0) currency.take(manager, payer, uint256(balance), false);
    }
}
