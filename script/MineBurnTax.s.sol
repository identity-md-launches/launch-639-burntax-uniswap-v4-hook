// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTaxHook} from "../src/BurnTaxHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Offline CREATE2 salt search. No environment reads, filesystem access or transactions.
contract MineBurnTax {
    error SaltNotFound();

    function run(
        IPoolManager manager,
        address token,
        address create2Deployer,
        uint256 start,
        uint256 attempts
    ) public pure returns (bytes32 salt, address predicted) {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(BurnTaxHook).creationCode, abi.encode(manager, token))
        );
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(hex"ff", create2Deployer, salt, initHash))))
            );
            if (HookFlags.matches(predicted, HookFlags.BURNTAX)) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
