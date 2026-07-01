// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LPMining
 * @notice GoodChain LP Mining — stake UniV2 LP tokens, earn CGC rewards.
 *
 *   ┌──────────────────────────────────────────┐
 *   │              LPMining                     │
 *   │                                           │
 *   │  stake(amountLP)  ◄─ deposit LP tokens    │
 *   │  unstake(amount)  ► withdraw LP tokens     │
 *   │  claimRewards()   ► CGC rewards            │
 *   │  exit() = unstake all + claim              │
 *   │                                           │
 *   │  rewardRate → CGC per second, pro-rata    │
 *   │  no lockup, withdraw anytime               │
 *   └──────────────────────────────────────────┘
 *
 *   ===== Integration =====
 *   LPToken: CGC V5 / WGDC Uniswap V2 pair (0x4575...e215)
 *   RewardToken: CGC V5 (0xdDe1...4Ac)
 *
 *   ===== Architecture =====
 *   Based on Synthetix StakingRewards pattern.
 *   Owner can fund rewards via fundRewards() or setRewardRate().
 *   Integrated with Treasury for auto-funding (Step 3 of the flywheel).
 */
contract LPMining is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;   // LP token
    IERC20 public immutable rewardToken;    // CGC V5

    uint256 public rewardRate;              // CGC per second
    uint256 public lastUpdateTime;          // last block timestamp
    uint256 public rewardPerTokenStored;    // accumulated reward per LP unit

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    // user → paid reward-per-token at last interaction
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // ─── Events ──────────────────────────────────────
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);

    // ─── Constructor ─────────────────────────────────
    constructor(
        address _stakingToken,
        address _rewardToken,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_stakingToken != address(0), "LP: zero staking token");
        require(_rewardToken != address(0), "LP: zero reward token");
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
    }

    // ─── View ────────────────────────────────────────
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /**
     * @notice Total CGC rewards available (not yet distributed).
     */
    function rewardBalance() external view returns (uint256) {
        return rewardToken.balanceOf(address(this));
    }

    /**
     * @notice Current reward-per-token accumulator.
     */
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((block.timestamp - lastUpdateTime) * rewardRate * 1e18) / _totalSupply;
    }

    /**
     * @notice View pending rewards for an account.
     */
    function earned(address account) public view returns (uint256) {
        return
            ((_balances[account]
                * (rewardPerToken() - userRewardPerTokenPaid[account]))
                / 1e18)
            + rewards[account];
    }

    // ─── Mutate ──────────────────────────────────────
    /**
     * @notice Update reward accumulator before any write.
     */
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /**
     * @notice Stake LP tokens.
     * @param amount  Amount of LP tokens to stake.
     */
    function stake(uint256 amount)
        external
        nonReentrant
        updateReward(msg.sender)
    {
        require(amount > 0, "LP: cannot stake 0");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Unstake LP tokens (partial).
     * @param amount  Amount of LP tokens to unstake.
     */
    function unstake(uint256 amount)
        public
        nonReentrant
        updateReward(msg.sender)
    {
        require(amount > 0, "LP: cannot unstake 0");
        require(_balances[msg.sender] >= amount, "LP: insufficient balance");
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Claim all accumulated rewards.
     */
    function claimRewards()
        public
        nonReentrant
        updateReward(msg.sender)
    {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     * @notice Exit: unstake all LP + claim all rewards.
     */
    function exit() external {
        unstake(_balances[msg.sender]);
        claimRewards();
    }

    // ─── Owner ──────────────────────────────────────
    /**
     * @notice Fund the reward pool by pulling CGC from the owner.
     *         Owner must approve this contract first.
     * @param amount  Amount of CGC to pull.
     */
    function fundRewards(uint256 amount) external onlyOwner {
        require(amount > 0, "LP: amount is 0");
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Set reward rate (CGC per second).
     *         Recalculates rewardPerTokenStored before changing.
     * @param _rewardRate  New reward rate in wei/sec.
     */
    function setRewardRate(uint256 _rewardRate)
        external
        onlyOwner
        updateReward(address(0))
    {
        emit RewardRateUpdated(rewardRate, _rewardRate);
        rewardRate = _rewardRate;
    }

    /**
     * @notice Withdraw remaining CGC rewards (emergency / ragnarok).
     * @param to  Recipient of remaining CGC.
     */
    function withdrawRemaining(address to) external onlyOwner {
        require(to != address(0), "LP: zero address");
        uint256 bal = rewardToken.balanceOf(address(this));
        if (bal > 0) {
            rewardToken.safeTransfer(to, bal);
        }
    }

    /**
     * @notice Recover non-reward, non-staking tokens accidentally sent here.
     * @param token  The ERC-20 token to recover.
     * @param to     Recipient.
     */
    function recoverToken(IERC20 token, address to) external onlyOwner {
        require(
            address(token) != address(stakingToken)
            && address(token) != address(rewardToken),
            "LP: protected token"
        );
        uint256 bal = token.balanceOf(address(this));
        if (bal > 0) {
            token.safeTransfer(to, bal);
        }
    }
}
