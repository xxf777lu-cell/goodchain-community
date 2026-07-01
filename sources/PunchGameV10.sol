// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PunchGame V10 — Fix claimBounty to pay native GDC + add prune + ERC20 sweep
 * @notice
 *   ONLY CHANGES from V9:
 *     • claimBounty(): payout changed from IERC20(WGDC).safeTransfer → native GDC call{value}
 *     • Added pruneBounty(bytes32): remove depleted bounty entries from bountyTargetHashes
 *     • Added emergencyWithdrawERC20(address): sweep stuck ERC20 tokens to treasury
 *     • _claimFree(bool): removed unused bool parameter (backward compat wrapper kept)
 *
 *   Everything else is identical to V9:
 *     • Weekly Bounty Pool: 10% bounty fees → weekPool[sweek], shared by
 *       weighted punches (golden=3, regular=1) every 7 days
 *     • Punch fees: 1% → BUILDER, 99% → TREASURY (auto-swept)
 *     • Multi-token pricing: WGDC (1:1), CGC (DEX), UX (11:1), MEC (1.5:1)
 *     • Max combo: 99, max punches per user: 10000
 *     • rolloverWeek(): public with 7-day time lock
 */

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

contract PunchGameV10 is Ownable {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════
    //  PRICE SOURCE
    // ══════════════════════════════════════════════════════
    enum PriceSource { DISABLED, IDENTITY, FIXED_RATE, DEX_PAIR }

    struct TokenConfig {
        PriceSource source;
        uint256 rate;         // for FIXED_RATE: tokens per 1 GDC (18 dec)
        address pair;         // for DEX_PAIR: UniswapV2Pair
        bool supported;
    }

    // ── Constants ──────────────────────────────────────────
    uint256 public constant PCT_DENOM       = 100;
    uint256 public constant BUILDER_PCT     = 1;
    uint256 public constant BOUNTY_FEE_PCT  = 10;
    uint256 public constant MAX_COMBO       = 99;
    uint256 public constant WEEK_SECONDS    = 7 days;

    // Pricing tiers
    uint256 public constant TIER1_MAX  = 0.1 ether;
    uint256 public constant TIER1_RATE = 10;
    uint256 public constant TIER2_MAX  = 5 ether;
    uint256 public constant TIER2_RATE = 12;
    uint256 public constant TIER3_RATE = 15;

    // Golden punch: flat 3x base price
    uint256 public constant GOLDEN_PRICE_GDC = 0.3 ether;
    uint256 public constant MAX_TRACKED_TARGETS = 50;

    uint256 public maxPunchesPerUser = 10000;

    // ── Bounty target names ────────────────────────────────
    mapping(bytes32 => string) public bountyNames;

    // ── Immutables ─────────────────────────────────────────
    address public immutable WGDC;
    address public immutable CGC;
    address public immutable PAIR;
    address public immutable BUILDER;
    address public immutable TREASURY;

    // ── Multi-token support ────────────────────────────────
    mapping(address => TokenConfig) public tokenConfigs;
    address[] public supportedTokenList;

    // ── Punch state ────────────────────────────────────────
    mapping(address => uint256) private _punches;
    mapping(address => uint256) private _goldenPunches;
    uint256 public totalPunchesBought;
    uint256 public totalGoldenPunchesBought;

    // ── Free punch ─────────────────────────────────────────
    mapping(address => uint256) public lastFreeClaimDay;

    // ── Weekly ─────────────────────────────────────────────
    uint256 public weekNumber;
    uint256 public weekStartTimestamp;
    bytes32 public weeklyTargetHash;
    string   public weeklyTargetName;

    // ── WEEKLY BOUNTY POOL (V7+) ───────────────────────────
    mapping(uint256 => uint256) public weekPool;
    mapping(uint256 => uint256) public weekTotalPunches;
    mapping(uint256 => mapping(address => uint256)) public weekUserPunches;
    mapping(uint256 => mapping(address => bool)) public weekClaimed;

    // ── Fighter stats ──────────────────────────────────────
    mapping(address => uint256) public totalPunchesThrown;
    mapping(address => uint256) public totalGoldenPunchesThrown;
    mapping(address => uint256) public totalGdcSpent;
    mapping(address => mapping(bytes32 => uint256)) public userTargetHits;
    mapping(address => bytes32[]) private _userTargetList;

    // ── Bounty ─────────────────────────────────────────────
    mapping(bytes32 => BountyInfo) public bounties;
    mapping(bytes32 => mapping(address => uint256)) public bountyPunchCount;
    bytes32[] public bountyTargetHashes;

    struct BountyInfo {
        uint256 pool;
        uint256 totalPunches;
        bool exists;
    }

    // ── Events ─────────────────────────────────────────────
    event PunchedEvent(address indexed user, string target, uint256 timestamp, uint256 weekNumber);
    event GoldenPunchEvent(address indexed user, string target, uint256 timestamp, uint256 weekNumber);
    event PunchesBought(address indexed user, uint256 amount, address token, uint256 punches, uint256 tier);
    event GoldenPunchesBought(address indexed user, uint256 count, address token, uint256 amount);
    event FreePunchClaimed(address indexed user);
    event TokenConfigAdded(address indexed token, PriceSource source);
    event TokenConfigRemoved(address indexed token);
    event TokenRateUpdated(address indexed token, uint256 newRate);
    event WeekRolledOver(uint256 newWeek, uint256 ts);
    event MaxPunchesUpdated(uint256 oldVal, uint256 newVal);
    event BountyPlaced(string target, uint256 amount, uint256 pool, uint256 fee);
    event BountyClaimed(address indexed caller, string target, address indexed puncher, uint256 amount);
    event BountyDepleted(string target, bytes32 indexed targetHash);
    event WeeklyTargetSet(string target);
    event ComboPunched(address indexed user, string[] targets, uint256 weekNumber);
    event BountyFeeToWeekPool(uint256 indexed week, uint256 amount);
    event WeekRewardClaimed(address indexed user, uint256 week, uint256 amount);
    event BountyPruned(bytes32 indexed targetHash, string target);

    // ── Errors ─────────────────────────────────────────────
    error NoPunchesLeft(); error NoGoldenPunchesLeft(); error EmptyTarget();
    error InsufficientPayment(); error ZeroReserves();
    error AlreadyClaimedFree(); error PunchCapExceeded();
    error NoBounty(); error NoPunchesToClaim();
    error ComboTooLong(); error BountyEmpty();
    error TokenNotSupported(); error AmountZero();
    error WeekNotEnded(); error AlreadyClaimed(); error NoWeekPunches();

    // ── Constructor ────────────────────────────────────────
    constructor(
        address _wgdc, address _cgc, address _pair,
        address _builder, address _treasury, address _initialOwner
    ) Ownable(_initialOwner) {
        WGDC = _wgdc; CGC = _cgc; PAIR = _pair;
        BUILDER = _builder; TREASURY = _treasury;
        weekStartTimestamp = block.timestamp;
        weekNumber = 1;
    }

    // ══════════════════════════════════════════════════════
    //  TOKEN CONFIGURATION (Owner only)
    // ══════════════════════════════════════════════════════
    function addTokenConfig(address token, PriceSource source, uint256 rate, address pair) external onlyOwner {
        require(source != PriceSource.DISABLED, "Use removeTokenConfig");
        if (source == PriceSource.DEX_PAIR) require(pair != address(0), "Pair required");
        if (source == PriceSource.FIXED_RATE) require(rate > 0, "Rate required");
        if (source == PriceSource.IDENTITY) { rate = 1e18; pair = address(0); }

        if (!tokenConfigs[token].supported) {
            supportedTokenList.push(token);
        }
        tokenConfigs[token] = TokenConfig({ source: source, rate: rate, pair: pair, supported: true });
        emit TokenConfigAdded(token, source);
    }

    function removeTokenConfig(address token) external onlyOwner {
        if (!tokenConfigs[token].supported) revert TokenNotSupported();
        tokenConfigs[token].supported = false;
        delete tokenConfigs[token];
        for (uint256 i = 0; i < supportedTokenList.length; i++) {
            if (supportedTokenList[i] == token) {
                supportedTokenList[i] = supportedTokenList[supportedTokenList.length - 1];
                supportedTokenList.pop();
                break;
            }
        }
        emit TokenConfigRemoved(token);
    }

    function setTokenRate(address token, uint256 newRate) external onlyOwner {
        require(tokenConfigs[token].supported, "Not supported");
        require(tokenConfigs[token].source == PriceSource.FIXED_RATE, "Not fixed rate");
        require(newRate > 0, "Rate required");
        tokenConfigs[token].rate = newRate;
        emit TokenRateUpdated(token, newRate);
    }

    function supportedTokenCount() external view returns (uint256) { return supportedTokenList.length; }
    function getSupportedToken(uint256 i) external view returns (address) { return supportedTokenList[i]; }

    // ══════════════════════════════════════════════════════
    //  BUY PUNCHES — FULLY AUTOMATIC FUND FLOW
    // ══════════════════════════════════════════════════════

    function buyPunches(address token, uint256 amount) external {
        _buyPunches(token, amount, false);
    }

    function buyGoldenPunches(address token, uint256 count) external {
        _buyGoldenPunches(token, count);
    }

    function buyPunches() external payable { _buyNative(false); }
    function buyGoldenPunches() external payable { _buyNative(true); }

    function buyPunchesWithGDC(uint256 amount) external { _buyPunches(WGDC, amount, false); }
    function buyPunchesWithCGC(uint256 amount) external { _buyPunches(CGC, amount, false); }
    function buyGoldenPunchesWithGDC(uint256 count) external { _buyGoldenPunches(WGDC, count); }
    function buyGoldenPunchesWithCGC(uint256 count) external { _buyGoldenPunches(CGC, count); }

    // ── Internal: native GDC ───────────────────────────────
    function _buyNative(bool golden) internal {
        if (msg.value == 0) revert InsufficientPayment();
        uint256 gdcValue = msg.value;
        totalGdcSpent[msg.sender] += gdcValue;

        if (golden) {
            uint256 count = gdcValue / GOLDEN_PRICE_GDC;
            if (count == 0) revert InsufficientPayment();
            _addGoldenPunches(msg.sender, count);
            totalGoldenPunchesBought += count;
            emit GoldenPunchesBought(msg.sender, count, address(0), msg.value);
        } else {
            uint256 _p = _calcPunchesFromGDC(gdcValue);
            if (_p == 0) revert InsufficientPayment();
            _addPunches(msg.sender, _p);
            totalPunchesBought += _p;
            emit PunchesBought(msg.sender, msg.value, address(0), _p, _tierForGdc(gdcValue));
        }

        _splitNativeGDC(gdcValue);
    }

    // ── Internal: ERC20 ────────────────────────────────────
    function _buyPunches(address token, uint256 amount, bool golden) internal {
        if (amount == 0) revert InsufficientPayment();
        TokenConfig memory cfg = _requireSupported(token);
        uint256 gdcValue = _tokenToGDC(token, amount, cfg);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        totalGdcSpent[msg.sender] += gdcValue;

        if (golden) {
            uint256 count = gdcValue / GOLDEN_PRICE_GDC;
            if (count == 0) revert InsufficientPayment();
            _addGoldenPunches(msg.sender, count);
            totalGoldenPunchesBought += count;
            emit GoldenPunchesBought(msg.sender, count, token, amount);
        } else {
            uint256 _p = _calcPunchesFromGDC(gdcValue);
            if (_p == 0) revert InsufficientPayment();
            _addPunches(msg.sender, _p);
            totalPunchesBought += _p;
            emit PunchesBought(msg.sender, amount, token, _p, _tierForGdc(gdcValue));
        }

        _splitERC20(token, amount);
    }

    function _buyGoldenPunches(address token, uint256 count) internal {
        if (count == 0) revert InsufficientPayment();
        TokenConfig memory cfg = _requireSupported(token);
        uint256 gdcValue = count * GOLDEN_PRICE_GDC;
        uint256 amount = _gdcToToken(token, gdcValue, cfg);
        if (amount == 0) revert InsufficientPayment();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        totalGdcSpent[msg.sender] += gdcValue;

        _addGoldenPunches(msg.sender, count);
        totalGoldenPunchesBought += count;
        _splitERC20(token, amount);

        emit GoldenPunchesBought(msg.sender, count, token, amount);
    }

    // ══════════════════════════════════════════════════════
    //  AUTO-SPLIT ENGINE
    // ══════════════════════════════════════════════════════
    function _splitNativeGDC(uint256 total) internal {
        uint256 builderShare = (total * BUILDER_PCT) / PCT_DENOM;
        uint256 treasuryShare = total - builderShare;

        if (builderShare > 0) {
            (bool sent, ) = BUILDER.call{value: builderShare}("");
            require(sent, "Builder transfer failed");
        }
        if (treasuryShare > 0) {
            (bool sent, ) = TREASURY.call{value: treasuryShare}("");
            require(sent, "Treasury transfer failed");
        }
    }

    function _splitERC20(address token, uint256 total) internal {
        uint256 builderShare = (total * BUILDER_PCT) / PCT_DENOM;
        uint256 treasuryShare = total - builderShare;

        if (builderShare > 0) {
            IERC20(token).safeTransfer(BUILDER, builderShare);
        }
        if (treasuryShare > 0) {
            IERC20(token).safeTransfer(TREASURY, treasuryShare);
        }
    }

    // ── V10: Emergency sweep for native GDC + ERC20 ────────
    /// @notice Withdraw all native GDC from contract to treasury
    function emergencyWithdraw() external onlyOwner {
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool sent, ) = TREASURY.call{value: bal}("");
            require(sent);
        }
    }

    /// @notice Sweep stuck ERC20 tokens to treasury
    function emergencyWithdrawERC20(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(TREASURY, bal);
        }
    }

    // ══════════════════════════════════════════════════════
    //  FREE PUNCH
    // ══════════════════════════════════════════════════════
    function claimFreePunch() external { _claimFree(); }
    function claimAndPunch(string calldata target) external {
        if (bytes(target).length == 0) revert EmptyTarget();
        _claimFree();
        _applyPunch(msg.sender, target);
        _punches[msg.sender] -= 1;
        _recordWeekPunch(msg.sender, 1);
        emit PunchedEvent(msg.sender, target, block.timestamp, weekNumber);
        emit FreePunchClaimed(msg.sender);
    }

    // ══════════════════════════════════════════════════════
    //  SINGLE PUNCH
    // ══════════════════════════════════════════════════════
    function punch(string calldata target) external {
        if (_punches[msg.sender] == 0) revert NoPunchesLeft();
        if (bytes(target).length == 0) revert EmptyTarget();
        _punches[msg.sender] -= 1;
        _trackPunch(msg.sender, target);
        _recordWeekPunch(msg.sender, 1);
        emit PunchedEvent(msg.sender, target, block.timestamp, weekNumber);
    }

    function goldenPunch(string calldata target) external {
        if (_goldenPunches[msg.sender] == 0) revert NoGoldenPunchesLeft();
        if (bytes(target).length == 0) revert EmptyTarget();
        _goldenPunches[msg.sender] -= 1;
        _trackPunch(msg.sender, target);
        _recordWeekPunch(msg.sender, 3);
        totalGoldenPunchesThrown[msg.sender]++;
        emit GoldenPunchEvent(msg.sender, target, block.timestamp, weekNumber);
    }

    function comboPunch(string[] calldata targets) external {
        uint256 len = targets.length;
        if (len == 0) revert EmptyTarget();
        if (len > MAX_COMBO) revert ComboTooLong();
        uint256 available = _punches[msg.sender] + _goldenPunches[msg.sender];
        if (available < len) revert NoPunchesLeft();
        for (uint256 i = 0; i < len; i++) {
            if (bytes(targets[i]).length == 0) revert EmptyTarget();
        }
        uint256 goldenConsumed = _goldenPunches[msg.sender] >= len ? len : _goldenPunches[msg.sender];
        _goldenPunches[msg.sender] -= goldenConsumed;
        _punches[msg.sender] -= (len - goldenConsumed);
        for (uint256 i = 0; i < len; i++) {
            _trackPunch(msg.sender, targets[i]);
            if (i < goldenConsumed) {
                totalGoldenPunchesThrown[msg.sender]++;
                emit GoldenPunchEvent(msg.sender, targets[i], block.timestamp, weekNumber);
            } else {
                emit PunchedEvent(msg.sender, targets[i], block.timestamp, weekNumber);
            }
        }
        uint256 totalWeight = goldenConsumed * 3 + (len - goldenConsumed);
        _recordWeekPunch(msg.sender, totalWeight);
        emit ComboPunched(msg.sender, targets, weekNumber);
    }

    // ══════════════════════════════════════════════════════
    //  BOUNTY
    // ══════════════════════════════════════════════════════
    function placeBountyNative(string calldata target) external payable {
        if (bytes(target).length == 0) revert EmptyTarget();
        if (msg.value == 0) revert InsufficientPayment();

        uint256 poolAmount = (msg.value * (PCT_DENOM - BOUNTY_FEE_PCT)) / PCT_DENOM;
        uint256 feeAmount = msg.value - poolAmount;

        if (feeAmount > 0) {
            weekPool[weekNumber] += feeAmount;
            emit BountyFeeToWeekPool(weekNumber, feeAmount);
        }

        bytes32 h = keccak256(bytes(target));
        if (!bounties[h].exists) {
            bounties[h] = BountyInfo({ pool: poolAmount, totalPunches: 0, exists: true });
            bountyTargetHashes.push(h);
            bountyNames[h] = target;
        } else {
            bounties[h].pool += poolAmount;
        }
        emit BountyPlaced(target, msg.value, bounties[h].pool, feeAmount);
    }

    function placeBounty(string calldata target, uint256 amount) external {
        if (bytes(target).length == 0) revert EmptyTarget();
        if (amount == 0) revert InsufficientPayment();
        IERC20(WGDC).safeTransferFrom(msg.sender, address(this), amount);

        uint256 poolAmount = (amount * (PCT_DENOM - BOUNTY_FEE_PCT)) / PCT_DENOM;
        uint256 feeAmount = amount - poolAmount;
        if (feeAmount > 0) IERC20(WGDC).safeTransfer(TREASURY, feeAmount);

        bytes32 h = keccak256(bytes(target));
        if (!bounties[h].exists) {
            bounties[h] = BountyInfo({ pool: poolAmount, totalPunches: 0, exists: true });
            bountyTargetHashes.push(h);
            bountyNames[h] = target;
        } else {
            bounties[h].pool += poolAmount;
        }
        emit BountyPlaced(target, amount, bounties[h].pool, feeAmount);
    }

    /// @notice [V10] Claim bounty — pays in native GDC (was WGDC in V9)
    function claimBounty(address puncher, string memory target) public {
        bytes32 h = keccak256(bytes(target));
        if (!bounties[h].exists || bounties[h].pool == 0) revert NoBounty();
        uint256 uc = bountyPunchCount[h][puncher];
        if (uc == 0 || bounties[h].totalPunches == 0) revert NoPunchesToClaim();

        uint256 reward = (uc * bounties[h].pool) / bounties[h].totalPunches;
        if (reward == 0) revert NoPunchesToClaim();

        bounties[h].pool -= reward;
        if (bounties[h].totalPunches >= uc) {
            bounties[h].totalPunches -= uc;
        } else {
            bounties[h].totalPunches = 0;
        }
        bountyPunchCount[h][puncher] = 0;

        // V10: native GDC instead of WGDC
        (bool sent, ) = puncher.call{value: reward}("");
        require(sent, "GDC transfer failed");

        emit BountyClaimed(msg.sender, target, puncher, reward);

        if (bounties[h].pool == 0) {
            emit BountyDepleted(target, h);
        }
    }

    function claimMyBounty(string calldata target) external {
        claimBounty(msg.sender, target);
    }

    function claimMyBountyByHash(bytes32 targetHash) external {
        string memory name = bountyNames[targetHash];
        if (bytes(name).length == 0) revert BountyEmpty();
        claimBounty(msg.sender, name);
    }

    /// @notice [V10] Remove a depleted bounty entry from the target tracking array
    function pruneBounty(bytes32 targetHash) external onlyOwner {
        BountyInfo memory b = bounties[targetHash];
        if (b.pool > 0) revert NoBounty(); // still has funds, can't prune
        if (!b.exists) revert BountyEmpty();
        if (bytes(bountyNames[targetHash]).length == 0) revert BountyEmpty();

        string memory name = bountyNames[targetHash];
        uint256 len = bountyTargetHashes.length;
        for (uint256 i = 0; i < len; i++) {
            if (bountyTargetHashes[i] == targetHash) {
                bountyTargetHashes[i] = bountyTargetHashes[len - 1];
                bountyTargetHashes.pop();
                break;
            }
        }
        delete bounties[targetHash];
        delete bountyNames[targetHash];
        emit BountyPruned(targetHash, name);
    }

    function getAllBountyTargets() external view returns (
        string[] memory names,
        uint256[] memory pools,
        uint256[] memory totalPunches_
    ) {
        uint256 len = bountyTargetHashes.length;
        names = new string[](len);
        pools = new uint256[](len);
        totalPunches_ = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            bytes32 h = bountyTargetHashes[i];
            BountyInfo memory b = bounties[h];
            if (b.exists && b.pool > 0) {
                names[i] = bountyNames[h];
                pools[i] = b.pool;
                totalPunches_[i] = b.totalPunches;
            }
        }
    }

    function getMyBountyPunchCounts(address user) external view returns (
        bytes32[] memory hashes,
        uint256[] memory counts,
        string[] memory names
    ) {
        uint256 len = bountyTargetHashes.length;
        uint256 active;
        for (uint256 i = 0; i < len; i++) {
            bytes32 h = bountyTargetHashes[i];
            if (bounties[h].exists && bounties[h].pool > 0 && bountyPunchCount[h][user] > 0) {
                active++;
            }
        }
        hashes = new bytes32[](active);
        counts = new uint256[](active);
        names = new string[](active);
        uint256 idx;
        for (uint256 i = 0; i < len; i++) {
            bytes32 h = bountyTargetHashes[i];
            if (bounties[h].exists && bounties[h].pool > 0 && bountyPunchCount[h][user] > 0) {
                hashes[idx] = h;
                counts[idx] = bountyPunchCount[h][user];
                names[idx] = bountyNames[h];
                idx++;
            }
        }
    }

    // ══════════════════════════════════════════════════════
    //  WEEKLY
    // ══════════════════════════════════════════════════════
    function setWeeklyTarget(string calldata target) external onlyOwner {
        weeklyTargetName = target;
        weeklyTargetHash = keccak256(bytes(target));
        emit WeeklyTargetSet(target);
    }

    function rolloverWeek() external {
        require(block.timestamp >= weekStartTimestamp + WEEK_SECONDS, "Week not ended yet (7 days)");
        weekNumber++;
        weekStartTimestamp = block.timestamp;
        emit WeekRolledOver(weekNumber, block.timestamp);
    }

    function setMaxPunchesPerUser(uint256 n) external onlyOwner {
        emit MaxPunchesUpdated(maxPunchesPerUser, n);
        maxPunchesPerUser = n;
    }

    // ══════════════════════════════════════════════════════
    //  V7+: WEEKLY BOUNTY POOL — CLAIM FUNCTIONS
    // ══════════════════════════════════════════════════════
    function claimWeekReward(uint256 week) external {
        if (week >= weekNumber) revert WeekNotEnded();
        if (weekClaimed[week][msg.sender]) revert AlreadyClaimed();
        uint256 userWeight = weekUserPunches[week][msg.sender];
        uint256 totalWeight = weekTotalPunches[week];
        if (userWeight == 0 || totalWeight == 0) revert NoWeekPunches();

        uint256 reward = (userWeight * weekPool[week]) / totalWeight;
        if (reward == 0) revert NoWeekPunches();

        weekClaimed[week][msg.sender] = true;

        (bool sent, ) = msg.sender.call{value: reward}("");
        require(sent, "Reward transfer failed");

        emit WeekRewardClaimed(msg.sender, week, reward);
    }

    function claimableWeekReward(uint256 week, address user) external view returns (uint256) {
        if (week >= weekNumber) return 0;
        if (weekClaimed[week][user]) return 0;
        uint256 userWeight = weekUserPunches[week][user];
        uint256 totalWeight = weekTotalPunches[week];
        if (userWeight == 0 || totalWeight == 0) return 0;
        return (userWeight * weekPool[week]) / totalWeight;
    }

    function getClaimableWeeks(address user) external view returns (uint256[] memory weeks_, uint256[] memory rewards) {
        uint256 count;
        uint256 start = weekNumber > 52 ? weekNumber - 52 : 1;
        for (uint256 w = start; w < weekNumber; w++) {
            if (!weekClaimed[w][user] && weekUserPunches[w][user] > 0 && weekTotalPunches[w] > 0) {
                count++;
            }
        }
        weeks_ = new uint256[](count);
        rewards = new uint256[](count);
        uint256 idx;
        for (uint256 w = start; w < weekNumber; w++) {
            if (!weekClaimed[w][user] && weekUserPunches[w][user] > 0 && weekTotalPunches[w] > 0) {
                weeks_[idx] = w;
                rewards[idx] = (weekUserPunches[w][user] * weekPool[w]) / weekTotalPunches[w];
                idx++;
            }
        }
    }

    // ══════════════════════════════════════════════════════
    //  VIEW: BALANCES
    // ══════════════════════════════════════════════════════
    function punches(address u) external view returns (uint256) { return _punches[u]; }
    function goldenPunches(address u) external view returns (uint256) { return _goldenPunches[u]; }
    function canClaimFreePunch(address u) external view returns (bool) {
        return lastFreeClaimDay[u] < block.timestamp / 1 days;
    }

    // ══════════════════════════════════════════════════════
    //  VIEW: FIGHTER STATS
    // ══════════════════════════════════════════════════════
    function getFighterStats(address user) external view returns (
        uint256 totalPunches_, uint256 goldenPunches_, uint256 totalSpentGDC_
    ) {
        return (totalPunchesThrown[user], totalGoldenPunchesThrown[user], totalGdcSpent[user]);
    }

    function getTopTargets(address user, uint256 limit) external view returns (
        bytes32[] memory targets, uint256[] memory counts
    ) {
        bytes32[] storage list = _userTargetList[user];
        uint256 l = list.length;
        if (limit > l) limit = l;
        if (limit > 10) limit = 10;

        bytes32[] memory sorted = new bytes32[](l);
        uint256[] memory cnts = new uint256[](l);
        for (uint256 i = 0; i < l; i++) {
            sorted[i] = list[i];
            cnts[i] = userTargetHits[user][list[i]];
        }
        for (uint256 i = 0; i < l; i++) {
            for (uint256 j = i + 1; j < l; j++) {
                if (cnts[j] > cnts[i]) {
                    (cnts[i], cnts[j]) = (cnts[j], cnts[i]);
                    (sorted[i], sorted[j]) = (sorted[j], sorted[i]);
                }
            }
        }
        targets = new bytes32[](limit);
        counts = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            targets[i] = sorted[i];
            counts[i] = cnts[i];
        }
    }

    // ══════════════════════════════════════════════════════
    //  VIEW: PRICING
    // ══════════════════════════════════════════════════════
    function getGDCValue(address token, uint256 amount) external view returns (uint256) {
        return _tokenToGDC(token, amount, _requireSupported(token));
    }

    function gdcFromCGC(uint256 cgcAmount) public view returns (uint256) {
        return _tokenToGDC(CGC, cgcAmount, _requireSupported(CGC));
    }
    function getGCDFromCGC(uint256 a) external view returns (uint256) { return gdcFromCGC(a); }

    function getTokenAmount(address token, uint256 gdcWei) external view returns (uint256) {
        return _gdcToToken(token, gdcWei, _requireSupported(token));
    }

    function estimatePunchesFromGDC(uint256 a) external pure returns (uint256) {
        return _calcPunchesFromGDC(a);
    }

    function estimatePunchesFromToken(address token, uint256 amount) external view returns (uint256) {
        TokenConfig memory cfg = _requireSupported(token);
        uint256 gdcValue = _tokenToGDC(token, amount, cfg);
        return _calcPunchesFromGDC(gdcValue);
    }

    function tierForGDC(uint256 a) external pure returns (uint256) { return _tierForGdc(a); }

    // ══════════════════════════════════════════════════════
    //  VIEW: BOUNTY
    // ══════════════════════════════════════════════════════
    function getBountyInfo(string calldata target) external view returns (uint256 pool, uint256 totalPunches_) {
        BountyInfo memory b = bounties[keccak256(bytes(target))];
        return (b.pool, b.totalPunches);
    }
    function hasActiveBounty(string calldata target) external view returns (bool) {
        BountyInfo memory b = bounties[keccak256(bytes(target))];
        return b.exists && b.pool > 0;
    }
    function getBountyPunchCount(string calldata target, address user) external view returns (uint256) {
        return bountyPunchCount[keccak256(bytes(target))][user];
    }

    function getWeeklyTarget() external view returns (string memory name, bool active) {
        return (weeklyTargetName, bytes(weeklyTargetName).length > 0);
    }
    function isWeeklyTarget(string calldata target) external view returns (bool) {
        if (bytes(weeklyTargetName).length == 0) return false;
        return keccak256(bytes(target)) == weeklyTargetHash;
    }

    // ══════════════════════════════════════════════════════
    //  INTERNAL
    // ══════════════════════════════════════════════════════
    function _requireSupported(address token) internal view returns (TokenConfig memory) {
        TokenConfig memory cfg = tokenConfigs[token];
        if (!cfg.supported) revert TokenNotSupported();
        return cfg;
    }

    function _tokenToGDC(address token, uint256 amount, TokenConfig memory cfg) internal view returns (uint256) {
        if (cfg.source == PriceSource.IDENTITY) {
            return amount;
        } else if (cfg.source == PriceSource.FIXED_RATE) {
            return (amount * 1e18) / cfg.rate;
        } else if (cfg.source == PriceSource.DEX_PAIR) {
            (uint112 r0, uint112 r1, ) = IUniswapV2Pair(cfg.pair).getReserves();
            address t0 = IUniswapV2Pair(cfg.pair).token0();
            uint256 wr = t0 == token ? uint256(r0) : uint256(r1);
            uint256 tr = t0 == token ? uint256(r1) : uint256(r0);
            if (wr == 0) return 0;
            return (amount * tr) / wr;
        }
        return 0;
    }

    function _gdcToToken(address token, uint256 gdcWei, TokenConfig memory cfg) internal view returns (uint256) {
        if (cfg.source == PriceSource.IDENTITY) {
            return gdcWei;
        } else if (cfg.source == PriceSource.FIXED_RATE) {
            return (gdcWei * cfg.rate) / 1e18;
        } else if (cfg.source == PriceSource.DEX_PAIR) {
            (uint112 r0, uint112 r1, ) = IUniswapV2Pair(cfg.pair).getReserves();
            address t0 = IUniswapV2Pair(cfg.pair).token0();
            uint256 wr = t0 == token ? uint256(r0) : uint256(r1);
            uint256 tr = t0 == token ? uint256(r1) : uint256(r0);
            if (wr == 0) return 0;
            return (gdcWei * wr) / tr;
        }
        return 0;
    }

    function _recordWeekPunch(address user, uint256 weight) internal {
        weekTotalPunches[weekNumber] += weight;
        weekUserPunches[weekNumber][user] += weight;
    }

    // V10: removed unused bool parameter
    function _claimFree() internal {
        uint256 today = block.timestamp / 1 days;
        if (lastFreeClaimDay[msg.sender] >= today) revert AlreadyClaimedFree();
        lastFreeClaimDay[msg.sender] = today;
        _punches[msg.sender] += 1;
        if ((_punches[msg.sender] + _goldenPunches[msg.sender]) > maxPunchesPerUser) revert PunchCapExceeded();
    }

    function _applyPunch(address user, string calldata target) internal {
        _trackPunch(user, target);
    }

    function _trackPunch(address user, string calldata target) internal {
        bytes32 h = keccak256(bytes(target));
        totalPunchesThrown[user]++;

        if (bounties[h].exists) {
            bountyPunchCount[h][user]++;
            bounties[h].totalPunches++;
        }

        if (userTargetHits[user][h] == 0) {
            bytes32[] storage list = _userTargetList[user];
            if (list.length < MAX_TRACKED_TARGETS) list.push(h);
        }
        userTargetHits[user][h]++;
    }

    function _addPunches(address u, uint256 c) internal {
        _punches[u] += c;
        if ((_punches[u] + _goldenPunches[u]) > maxPunchesPerUser) revert PunchCapExceeded();
    }

    function _addGoldenPunches(address u, uint256 c) internal {
        _goldenPunches[u] += c;
        if ((_punches[u] + _goldenPunches[u]) > maxPunchesPerUser) revert PunchCapExceeded();
    }

    function _calcPunchesFromGDC(uint256 g) internal pure returns (uint256) {
        uint256 r;
        if (g <= TIER1_MAX) r = TIER1_RATE;
        else if (g <= TIER2_MAX) r = TIER2_RATE;
        else r = TIER3_RATE;
        return (g * r) / 1e18;
    }

    function _tierForGdc(uint256 g) internal pure returns (uint256) {
        if (g <= TIER1_MAX) return 1;
        if (g <= TIER2_MAX) return 2;
        return 3;
    }

    // ── receive ────────────────────────────────────────────
    receive() external payable {
        if (msg.value > 0) {
            (bool sent, ) = TREASURY.call{value: msg.value}("");
            require(sent);
        }
    }
}
