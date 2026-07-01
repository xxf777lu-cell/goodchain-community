// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title AirdropClaim
 * @dev Merkle Tree 空投领取合约
 * 
 * 功能：
 * 1. 管理员设置 Merkle Root
 * 2. 用户可以调用 claim() 领取空投（提供 proof）
 * 3. 每个地址只能领取一次
 * 4. 管理员可以提取剩余代币
 */
contract AirdropClaim is ReentrancyGuard {
    using MerkleProof for bytes32[];
    
    address public owner;
    IERC20 public token;
    bytes32 public merkleRoot;
    bool public claimingEnabled = false;
    
    // 记录已领取的地址
    mapping(address => bool) public hasClaimed;
    
    event Claimed(address indexed user, uint256 amount);
    event MerkleRootUpdated(bytes32 newRoot);
    event ClaimingToggled(bool enabled);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "AirdropClaim: not owner");
        _;
    }
    
    constructor(address _token, address _owner) {
        token = IERC20(_token);
        owner = _owner;
    }
    
    /**
     * @dev 设置 Merkle Root（管理员）
     */
    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
        emit MerkleRootUpdated(_merkleRoot);
    }
    
    /**
     * @dev 开启/关闭领取
     */
    function toggleClaiming() external onlyOwner {
        claimingEnabled = !claimingEnabled;
        emit ClaimingToggled(claimingEnabled);
    }
    
    /**
     * @dev 领取空投
     * @param amount 空投金额
     * @param proof Merkle Proof
     */
    function claim(uint256 amount, bytes32[] calldata proof) external nonReentrant {
        require(claimingEnabled, "AirdropClaim: claiming not enabled");
        require(!hasClaimed[msg.sender], "AirdropClaim: already claimed");
        require(merkleRoot != bytes32(0), "AirdropClaim: merkle root not set");
        
        // 验证 Merkle Proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        require(MerkleProof.verify(proof, merkleRoot, leaf), "AirdropClaim: invalid proof");
        
        // 标记已领取
        hasClaimed[msg.sender] = true;
        
        // 转账
        require(token.transfer(msg.sender, amount), "AirdropClaim: transfer failed");
        
        emit Claimed(msg.sender, amount);
    }
    
    /**
     * @dev 批量领取（gas 优化）
     */
    function batchClaim(
        address[] calldata users,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external onlyOwner nonReentrant {
        require(users.length == amounts.length && amounts.length == proofs.length, "AirdropClaim: length mismatch");
        
        for (uint i = 0; i < users.length; i++) {
            if (hasClaimed[users[i]]) continue;
            
            bytes32 leaf = keccak256(abi.encodePacked(users[i], amounts[i]));
            if (!MerkleProof.verify(proofs[i], merkleRoot, leaf)) continue;
            
            hasClaimed[users[i]] = true;
            require(token.transfer(users[i], amounts[i]), "AirdropClaim: transfer failed");
            
            emit Claimed(users[i], amounts[i]);
        }
    }
    
    /**
     * @dev 提取剩余代币（管理员）
     */
    function withdrawRemaining(address to) external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        require(token.transfer(to, balance), "AirdropClaim: withdraw failed");
    }
    
    /**
     * @dev 转移所有权
     */
    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
