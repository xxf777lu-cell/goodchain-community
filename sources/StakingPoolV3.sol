// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title GDCStakingPoolV3
 * @dev Fixed V2 rewardDebt bug (stake/unstake were scaling rewardDebt by amount,
 *      causing underflow on subsequent operations). This version uses the standard
 *      MasterChef pattern: rewardDebt stores the raw accRewardPerToken checkpoint.
 */
contract GDCStakingPoolV3 is Ownable, ReentrancyGuard {
    IERC20 public communityToken;

    uint256 public gdcRewardRate;
    uint256 public cgcRewardRate;
    uint256 public minStakeDuration;
    uint256 public totalGdcStaked;
    uint256 public totalCgcStaked;
    bool public paused;

    struct Stake {
        uint256 amount;
        uint256 since;
        uint256 rewardDebt;   // raw accRewardPerToken at last checkpoint
    }
    mapping(address => Stake) public gdcStakes;
    mapping(address => Stake) public cgcStakes;

    uint256 public gdcAccRewardPerToken;
    uint256 public cgcAccRewardPerToken;
    uint256 public lastUpdateTime;
    uint256 public rewardPool;

    event StakedGDC(address indexed user, uint256 amount);
    event UnstakedGDC(address indexed user, uint256 amount);
    event StakedCGC(address indexed user, uint256 amount);
    event UnstakedCGC(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardPoolFunded(uint256 amount);
    event PoolPaused(bool paused);

    modifier whenNotPaused() { require(!paused, "Pool paused"); _; }

    constructor(address _communityToken) Ownable(msg.sender) {
        communityToken = IERC20(_communityToken);
        minStakeDuration = 7 days;
        lastUpdateTime = block.timestamp;
    }

    // ─── Admin ─────────────────────────────────────────
    function fundRewardPool(uint256 amount) external onlyOwner {
        require(communityToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        rewardPool += amount;
        emit RewardPoolFunded(amount);
    }

    function setRewardRates(uint256 _gdcRate, uint256 _cgcRate) external onlyOwner {
        updateAccumulators();
        gdcRewardRate = _gdcRate;
        cgcRewardRate = _cgcRate;
    }

    function setMinStakeDuration(uint256 _duration) external onlyOwner {
        minStakeDuration = _duration;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PoolPaused(_paused);
    }

    // ─── Core Logic ────────────────────────────────────
    function updateAccumulators() public {
        if (block.timestamp <= lastUpdateTime) return;
        uint256 dt = block.timestamp - lastUpdateTime;

        if (totalGdcStaked > 0) {
            uint256 reward = dt * gdcRewardRate;
            gdcAccRewardPerToken += (reward * 1e18) / totalGdcStaked;
        }
        if (totalCgcStaked > 0) {
            uint256 reward = dt * cgcRewardRate;
            cgcAccRewardPerToken += (reward * 1e18) / totalCgcStaked;
        }
        lastUpdateTime = block.timestamp;
    }

    function _pendingGdcRewards(address user) internal view returns (uint256) {
        Stake storage s = gdcStakes[user];
        if (s.amount == 0) return 0;
        uint256 acc = gdcAccRewardPerToken;
        if (totalGdcStaked > 0 && block.timestamp > lastUpdateTime) {
            uint256 dt = block.timestamp - lastUpdateTime;
            uint256 reward = dt * gdcRewardRate;
            acc += (reward * 1e18) / totalGdcStaked;
        }
        return (s.amount * (acc - s.rewardDebt)) / 1e18;
    }

    function _pendingCgcRewards(address user) internal view returns (uint256) {
        Stake storage s = cgcStakes[user];
        if (s.amount == 0) return 0;
        uint256 acc = cgcAccRewardPerToken;
        if (totalCgcStaked > 0 && block.timestamp > lastUpdateTime) {
            uint256 dt = block.timestamp - lastUpdateTime;
            uint256 reward = dt * cgcRewardRate;
            acc += (reward * 1e18) / totalCgcStaked;
        }
        return (s.amount * (acc - s.rewardDebt)) / 1e18;
    }

    function pendingRewards(address user) external view returns (uint256 gdc, uint256 cgc) {
        return (_pendingGdcRewards(user), _pendingCgcRewards(user));
    }

    // ─── GDC Staking ───────────────────────────────────
    /// @dev FIXED: rewardDebt = raw acc (not scaled by amount)
    function stakeGDC() external payable whenNotPaused nonReentrant {
        require(msg.value > 0, "Zero stake");
        updateAccumulators();

        Stake storage s = gdcStakes[msg.sender];
        if (s.amount > 0) {
            uint256 pending = (s.amount * (gdcAccRewardPerToken - s.rewardDebt)) / 1e18;
            if (pending > 0) _payReward(msg.sender, pending);
        }
        s.amount += msg.value;
        s.since = block.timestamp;
        s.rewardDebt = gdcAccRewardPerToken;                        // ← FIXED
        totalGdcStaked += msg.value;
        emit StakedGDC(msg.sender, msg.value);
    }

    /// @dev FIXED: rewardDebt = raw acc
    function unstakeGDC(uint256 amount) external nonReentrant {
        Stake storage s = gdcStakes[msg.sender];
        require(s.amount >= amount, "Insufficient stake");
        require(block.timestamp >= s.since + minStakeDuration, "Locked");
        updateAccumulators();

        uint256 pending = (s.amount * (gdcAccRewardPerToken - s.rewardDebt)) / 1e18;
        if (pending > 0) _payReward(msg.sender, pending);

        s.amount -= amount;
        s.rewardDebt = gdcAccRewardPerToken;                        // ← FIXED
        totalGdcStaked -= amount;

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Transfer failed");
        emit UnstakedGDC(msg.sender, amount);
    }

    // ─── CGC Staking ───────────────────────────────────
    /// @dev FIXED: rewardDebt = raw acc
    function stakeCGC(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "Zero stake");
        updateAccumulators();

        Stake storage s = cgcStakes[msg.sender];
        if (s.amount > 0) {
            uint256 pending = (s.amount * (cgcAccRewardPerToken - s.rewardDebt)) / 1e18;
            if (pending > 0) _payReward(msg.sender, pending);
        }
        communityToken.transferFrom(msg.sender, address(this), amount);
        s.amount += amount;
        s.since = block.timestamp;
        s.rewardDebt = cgcAccRewardPerToken;                        // ← FIXED
        totalCgcStaked += amount;
        emit StakedCGC(msg.sender, amount);
    }

    /// @dev FIXED: rewardDebt = raw acc
    function unstakeCGC(uint256 amount) external nonReentrant {
        Stake storage s = cgcStakes[msg.sender];
        require(s.amount >= amount, "Insufficient stake");
        require(block.timestamp >= s.since + minStakeDuration, "Locked");
        updateAccumulators();

        uint256 pending = (s.amount * (cgcAccRewardPerToken - s.rewardDebt)) / 1e18;
        if (pending > 0) _payReward(msg.sender, pending);

        s.amount -= amount;
        s.rewardDebt = cgcAccRewardPerToken;                        // ← FIXED
        totalCgcStaked -= amount;

        communityToken.transfer(msg.sender, amount);
        emit UnstakedCGC(msg.sender, amount);
    }

    // ─── Rewards ───────────────────────────────────────
    function claimRewards() external nonReentrant {
        updateAccumulators();
        uint256 gdcPending = 0;
        uint256 cgcPending = 0;

        Stake storage gs = gdcStakes[msg.sender];
        if (gs.amount > 0) {
            gdcPending = (gs.amount * (gdcAccRewardPerToken - gs.rewardDebt)) / 1e18;
            gs.rewardDebt = gdcAccRewardPerToken;
        }

        Stake storage cs = cgcStakes[msg.sender];
        if (cs.amount > 0) {
            cgcPending = (cs.amount * (cgcAccRewardPerToken - cs.rewardDebt)) / 1e18;
            cs.rewardDebt = cgcAccRewardPerToken;
        }

        uint256 total = gdcPending + cgcPending;
        require(total > 0, "No rewards");
        _payReward(msg.sender, total);
    }

    function _payReward(address to, uint256 amount) internal {
        require(rewardPool >= amount, "Reward pool exhausted");
        rewardPool -= amount;
        communityToken.transfer(to, amount);
        emit RewardsClaimed(to, amount);
    }

    // ─── Views ─────────────────────────────────────────
    function getUserStakes(address user) external view returns (
        uint256 gdcAmount, uint256 gdcSince, uint256 cgcAmount, uint256 cgcSince
    ) {
        return (gdcStakes[user].amount, gdcStakes[user].since,
                cgcStakes[user].amount, cgcStakes[user].since);
    }

    receive() external payable {}
}
