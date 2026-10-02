// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTaxFixture} from "./helpers/BurnTaxFixture.sol";
import {BurnTaxHook} from "../src/BurnTaxHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MineBurnTax} from "../script/MineBurnTax.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract BurnTaxDeploymentTest is BurnTaxFixture {
    function test_immutableConstructorParameters() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(Currency.unwrap(hook.launchedToken()), address(token));
        assertEq(hook.DEAD(), DEAD);
        assertEq(hook.TAX_BPS(), 100);
    }

    function test_rejectsMissingContracts() public {
        vm.expectRevert(BurnTaxHook.InvalidDeploymentParameter.selector);
        new BurnTaxHook(IPoolManager(address(0)), address(token));
        vm.expectRevert(BurnTaxHook.InvalidDeploymentParameter.selector);
        new BurnTaxHook(manager, address(0));
        vm.expectRevert(BurnTaxHook.InvalidDeploymentParameter.selector);
        new BurnTaxHook(IPoolManager(address(0xBEEF)), address(token));
        vm.expectRevert(BurnTaxHook.InvalidDeploymentParameter.selector);
        new BurnTaxHook(manager, address(0xBEEF));
        vm.expectRevert(BurnTaxHook.InvalidDeploymentParameter.selector);
        new BurnTaxHook(manager, address(manager));
    }

    function test_rejectsWrongPermissionAddress() public {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(BurnTaxHook).creationCode, abi.encode(manager, address(token))));
        bytes32 salt;
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, initHash)))));
        assertFalse(HookFlags.matches(predicted, HookFlags.BURNTAX));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new BurnTaxHook{salt: salt}(manager, address(token));
    }

    function test_minerHasBoundedFailure() public {
        MineBurnTax miner = new MineBurnTax();
        vm.expectRevert(MineBurnTax.SaltNotFound.selector);
        miner.run(manager, address(token), address(this), 0, 0);
    }

    function test_hookHasNoAdministrationOrWithdrawal() public {
        bytes[6] memory calls = [
            abi.encodeWithSignature("withdraw(address,uint256)", address(token), 1 ether),
            abi.encodeWithSignature("setTax(uint256)", 0),
            abi.encodeWithSignature("setRecipient(address)", address(this)),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("upgradeTo(address)", address(this)),
            abi.encodeWithSignature("pause()")
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(hook.TAX_BPS(), 100);
    }

    function test_runtimeHasNoEscapeHatches() public view {
        _checkRuntime(address(hook));
        _checkRuntime(address(token));
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}
