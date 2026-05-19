// SPDX-License-Identifier: MIT
//https://x.com/BasedBurnfi
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract BurnToken is ERC20Burnable {
    constructor(address initialHolder, uint256 initialSupply) ERC20("BURN", "BURN") {
        _mint(initialHolder, initialSupply);
    }
}
