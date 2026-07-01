// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CommunityToken (CGC)
 * @dev GDC Autonomous Community Governance Token — ERC-20 with mint/burn
 *
 *      Total supply: 100,000,000 CGC
 *      Distribution:
 *      - 40% Community rewards (staking, quests, airdrops)
 *      - 30% Ecosystem treasury
 *      - 20% Team & development (vesting)
 *      - 10% Initial liquidity
 *
 *      Governance extensions (ERC20Votes, ERC20Permit) require
 *      post-Paris EVM; can be added in a future upgrade.
 */
contract CommunityToken is ERC20, ERC20Burnable, Ownable {
    uint256 public constant MAX_SUPPLY = 100_000_000 * 10**18;

    constructor() ERC20("Community Governance Coin", "CGC") Ownable(msg.sender) {}

    function mint(address to, uint256 amount) external onlyOwner {
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        _mint(to, amount);
    }
}
