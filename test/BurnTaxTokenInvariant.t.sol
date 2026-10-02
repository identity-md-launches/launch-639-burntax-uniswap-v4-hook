// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BurnTaxToken} from "../src/BurnTaxToken.sol";

/// @notice Random transfers, approvals, pulls and would-be admin calls among five holders.
contract BurnTaxTokenHandler is Test {
    BurnTaxToken internal immutable token;
    address[5] public holders;
    uint256 public adminAttempts;

    constructor(BurnTaxToken token_, address[5] memory holders_) {
        token = token_;
        holders = holders_;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = holders[fromSeed % 5];
        address to = holders[toSeed % 5];
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer is a no-op");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
    }

    function approveAndPull(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = holders[ownerSeed % 5];
        address spender = holders[spenderSeed % 5];
        amount = bound(amount, 0, token.balanceOf(owner));
        vm.prank(owner);
        token.approve(spender, amount);
        uint256 ownerBefore = token.balanceOf(owner);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, spender, amount));
        assertEq(token.allowance(owner, spender), 0, "allowance fully consumed");
        if (owner != spender) assertEq(token.balanceOf(owner), ownerBefore - amount);
    }

    function overdraw(uint256 fromSeed, uint256 toSeed) external {
        address from = holders[fromSeed % 5];
        address to = holders[toSeed % 5];
        uint256 balance = token.balanceOf(from);
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (to, balance + 1)));
        assertFalse(ok, "cannot send more than held");
    }

    function tryAdmin(uint256 callerSeed, uint256 which) external {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(address,uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "setMinter(address)"
        ];
        address caller = holders[callerSeed % 5];
        vm.prank(caller);
        (bool ok,) =
            address(token).call(abi.encodeWithSignature(signatures[which % 6], caller, type(uint128).max));
        assertFalse(ok, "no admin surface exists");
        ++adminAttempts;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 40
contract BurnTaxTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    BurnTaxToken internal token;
    BurnTaxTokenHandler internal handler;
    address[5] internal holders;

    function setUp() public {
        token = new BurnTaxToken();
        holders = [address(this), address(0xA11CE), address(0xB0B), address(0xCA201), address(0xDA4E)];
        handler = new BurnTaxTokenHandler(token, holders);
        for (uint256 i = 1; i < 5; ++i) {
            token.transfer(holders[i], 1_000_000 ether * i);
        }
        targetContract(address(handler));
    }

    function invariant_supplyIsFixedAndFullyAccountedFor() public view {
        assertEq(token.totalSupply(), SUPPLY, "nobody can mint or burn");
        uint256 held;
        for (uint256 i; i < 5; ++i) {
            held += token.balanceOf(holders[i]);
        }
        assertEq(held, SUPPLY, "every unit sits with a holder");
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
