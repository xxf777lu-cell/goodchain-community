// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

/**
 * @title V4V5Migrator (flat)
 * @notice V4 CGC → V5 CGC 1:1 迁移合约
 */
contract V4V5Migrator {
    address public owner;
    address public immutable v4;
    address public immutable v5;
    address public constant BURN_ADDR = address(0xdead);
    uint256 public totalSwapped;
    
    event Swapped(address indexed user, uint256 amount);
    event Deposited(uint256 amount);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }
    
    constructor(address _v4, address _v5) {
        v4 = _v4;
        v5 = _v5;
        owner = msg.sender;
    }
    
    function _call(address t, bytes calldata data) internal returns (bool ok, bytes memory res) {
        (ok, res) = t.call(data);
        if (ok) {
            if (res.length > 0) {
                ok = abi.decode(res, (bool));
            }
        }
    }
    
    function depositV5(uint256 amount) external onlyOwner {
        (bool ok, ) = v5.call(abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), amount));
        require(ok, "deposit failed");
        emit Deposited(amount);
    }
    
    function swap(uint256 amount) external {
        require(amount > 0, "zero amount");
        // Check V5 balance
        (bool okB, bytes memory bal) = v5.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        require(okB && abi.decode(bal, (uint256)) >= amount, "insufficient V5");
        
        // Transfer V4 from user → burn
        (bool ok1, ) = v4.call(abi.encodeWithSelector(0x23b872dd, msg.sender, BURN_ADDR, amount));
        require(ok1, "v4 xfer failed");
        
        // Transfer V5 to user
        (bool ok2, ) = v5.call(abi.encodeWithSelector(0xa9059cbb, msg.sender, amount));
        require(ok2, "v5 xfer failed");
        
        totalSwapped += amount;
        emit Swapped(msg.sender, amount);
    }
    
    function withdrawV5(address to, uint256 amount) external onlyOwner {
        (bool ok, ) = v5.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        require(ok, "withdraw failed");
    }
    
    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
