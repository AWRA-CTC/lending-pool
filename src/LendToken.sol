// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LendToken (aAWRA)
 * @notice Interest-bearing token that represents lender deposits in the pool
 * @dev Exchange rate increases as borrowers pay interest
 */
contract LendToken is ERC20, Ownable {
    constructor() ERC20("AWRA Lend Token", "aAWRA") Ownable(msg.sender) {}

    /**
     * @notice Mint tokens to lender when they deposit
     * @param to Address to receive tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens when lender withdraws
     * @param from Address to burn from
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
