// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BurnTaxToken} from "../src/BurnTaxToken.sol";

contract BurnTaxTokenTest is Test {
    BurnTaxToken internal token;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new BurnTaxToken();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "BurnTax");
        assertEq(token.symbol(), "BTAX");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferAndTransferFromHaveNoTax() public {
        assertTrue(token.transfer(ALICE, 100 ether));
        vm.prank(ALICE);
        token.approve(BOB, 40 ether);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 40 ether));
        assertEq(token.balanceOf(ALICE), 60 ether);
        assertEq(token.balanceOf(BOB), 40 ether);
        assertEq(token.allowance(ALICE, BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFailuresPreserveSupply() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_neitherDeployerNorOthersCanMintOrAdminister() public {
        string[11] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, SUPPLY);
            (bool deployerOk,) = address(token).call(data);
            assertFalse(deployerOk);
            vm.prank(ALICE);
            (bool aliceOk,) = address(token).call(data);
            assertFalse(aliceOk);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_deadTransferLocksBalanceWithoutChangingSupply() public {
        address dead = 0x000000000000000000000000000000000000dEaD;
        token.transfer(dead, 1 ether);
        assertEq(token.balanceOf(dead), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferConservesSupply(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        token.transfer(ALICE, amount);
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
