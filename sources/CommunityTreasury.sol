// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CommunityTreasury
 * @dev 简单国库合约：只有 owner 可以提取资金
 * 
 * 功能：
 * 1. 接收 GDC（原生币）和 CGC（ERC20 代币）
 * 2. owner 可以提取资金（withdraw() / withdrawToken()）
 * 3. 后续将 owner 转为 TimelockController，实现去中心化提取
 */
contract CommunityTreasury is Ownable {
    using SafeERC20 for IERC20;

    event Withdraw(address indexed to, uint256 amount, uint256 timestamp);
    event WithdrawToken(address indexed token, address indexed to, uint256 amount, uint256 timestamp);

    constructor(address initialOwner) Ownable(initialOwner) {}

    // 接收原生币（GDC）
    receive() external payable {}

    // 提取原生币（GDC）
    function withdraw(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Treasury: zero address");
        require(amount <= address(this).balance, "Treasury: insufficient balance");
        payable(to).transfer(amount);
        emit Withdraw(to, amount, block.timestamp);
    }

    // 提取 ERC20 代币（CGC）
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "Treasury: zero token address");
        require(to != address(0), "Treasury: zero address");
        IERC20(token).safeTransfer(to, amount);
        emit WithdrawToken(token, to, amount, block.timestamp);
    }

    // 查询余额
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
