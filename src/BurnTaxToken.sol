// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply launch token. Swap taxation belongs exclusively to the hook.
contract BurnTaxToken is ERC20 {
    constructor() ERC20("BurnTax", "BTAX") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
