// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title V4V5Migrator
 * @notice 1:1 V4 CGC → V5 CGC swap contract
 * Users approve V4 tokens, then call swap(amount)
 * V4 tokens are burned (sent to 0xdead), V5 tokens sent to user
 * Owner deposits V5 tokens via depositV5(amount) before swaps
 */
contract V4V5Migrator {
    address public constant BURN_ADDR = address(0x000000000000000000000000000000000000dEaD);
    address public immutable v4;
    address public immutable v5;
    address public owner;
    uint256 public totalSwapped;

    event Deposited(uint256 amount);
    event Swapped(address indexed user, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _v4, address _v5) {
        v4 = _v4;
        v5 = _v5;
        owner = msg.sender;
    }

    /// @notice Owner deposits V5 liquidity for swaps
    function depositV5(uint256 amount) external onlyOwner {
        require(IERC20(v5).transferFrom(msg.sender, address(this), amount), "deposit failed");
        emit Deposited(amount);
    }

    /// @notice Swap V4 → V5 (1:1). User must approve V4 first.
    function swap(uint256 amount) external {
        require(amount > 0, "zero amount");
        // Check we have enough V5
        require(IERC20(v5).balanceOf(address(this)) >= amount, "insufficient V5");
        // Pull V4 from user and send to burn
        require(IERC20(v4).transferFrom(msg.sender, BURN_ADDR, amount), "v4 transfer failed");
        // Send V5 to user
        require(IERC20(v5).transfer(msg.sender, amount), "v5 transfer failed");
        totalSwapped += amount;
        emit Swapped(msg.sender, amount);
    }

    /// @notice Owner withdraws unused V5
    function withdrawV5(address to, uint256 amount) external onlyOwner {
        require(IERC20(v5).transfer(to, amount), "withdraw failed");
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
