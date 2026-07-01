// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title CommunityHub
 * @dev GDC Autonomous Community (GDC 自治社区) - Core contract
 *      Member registry, daily check-in, points system, leaderboard, activity tracking
 *      Gate: holding >= 100 GDC to register
 *
 * @notice Inspired by: Guild.xyz (tiered gating) + Zealy (XP system) + POAP (check-in badges)
 */
contract CommunityHub {
    // ============================================================
    //  Data Structures
    // ============================================================

    struct Member {
        address wallet;
        uint64  joinTimestamp;
        uint64  lastCheckIn;
        uint64  lastActivity;
        uint32  consecutiveDays;
        uint32  totalCheckIns;
        uint32  checkInStreakRecord;
        uint32  level;
        uint128 totalPoints;
        uint128 activityScore;
        uint32  questCompletions;
        uint32  badgeCount;
        bool    exists;
        string  nickname;
    }

    struct CheckInMilestone {
        uint256 milestoneDays;
        string  badgeName;
        string  badgeURI;
        uint256 bonusPoints;
    }

    // ============================================================
    //  Constants
    // ============================================================

    uint256 public constant MIN_GDC_BALANCE = 100 ether;

    // Points rules
    uint256 public constant BASE_CHECKIN_POINTS    = 10;
    uint256 public constant CONSECUTIVE_3DAY_BONUS  = 3;
    uint256 public constant CONSECUTIVE_7DAY_BONUS  = 5;
    uint256 public constant CONSECUTIVE_30DAY_BONUS = 15;
    uint256 public constant CONSECUTIVE_90DAY_BONUS = 30;
    uint256 public constant CONSECUTIVE_365DAY_BONUS = 100;
    uint256 public constant MONDAY_BONUS            = 5;
    uint256 public constant MAX_GDC_BONUS           = 50;
    uint256 public constant GDC_PER_BONUS_POINT     = 100 ether;
    uint256 public constant POINTS_PER_LEVEL        = 200;
    uint256 public constant INACTIVITY_DECAY_DAYS   = 30;
    uint256 public constant DECAY_RATE_PER_DAY      = 1;

    uint256 private constant SECONDS_PER_DAY = 86400;
    uint256 private constant UTC8_OFFSET     = 8 hours;

    // ============================================================
    //  State
    // ============================================================

    address public owner;
    mapping(address => Member) public members;
    address[] public memberList;
    uint256 public totalMembers;
    CheckInMilestone[] public checkInMilestones;
    uint256 public todayCheckInCount;
    uint256 public todayCheckInDate;

    // ============================================================
    //  Events
    // ============================================================

    event MemberJoined(address indexed member, uint256 timestamp, uint256 memberCount);
    event MemberUpdated(address indexed member, string nickname, uint256 timestamp);
    event CheckedIn(address indexed member, uint256 pointsEarned, uint256 consecutiveDays, uint256 totalPoints, uint256 newLevel, uint256 timestamp);
    event MilestoneReached(address indexed member, uint256 milestoneDays, string badgeName, uint256 bonusPoints);
    event LevelUp(address indexed member, uint256 oldLevel, uint256 newLevel);
    event PointsAwarded(address indexed member, uint256 points, string reason);
    event ActivityDecayed(address indexed member, uint256 decayedPoints, uint256 inactiveDays);
    event MilestoneAdded(uint256 milestoneDays, string badgeName, uint256 bonus);
    event MilestoneRemoved(uint256 index);
    event OwnerChanged(address oldOwner, address newOwner);

    // ============================================================
    //  Modifiers
    // ============================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyMember() {
        require(members[msg.sender].exists, "Not a member");
        _;
    }

    modifier gateCheck() {
        require(msg.sender.balance >= MIN_GDC_BALANCE || members[msg.sender].exists, "Need >=100 GDC");
        _;
    }

    // ============================================================
    //  Constructor
    // ============================================================

    constructor() {
        owner = msg.sender;

        // Default check-in milestones (names in ASCII for compiler compatibility)
        checkInMilestones.push(CheckInMilestone(1,   "First Step",      "ipfs://bronze",   5));
        checkInMilestones.push(CheckInMilestone(7,   "Persistent",      "ipfs://silver1",  20));
        checkInMilestones.push(CheckInMilestone(30,  "Unstoppable",     "ipfs://gold1",    50));
        checkInMilestones.push(CheckInMilestone(90,  "Iron Fan",        "ipfs://diamond1", 100));
        checkInMilestones.push(CheckInMilestone(180, "Legend Guardian", "ipfs://legend1",  200));
        checkInMilestones.push(CheckInMilestone(365, "Eternal Knight",  "ipfs://crown",    500));
    }

    // ============================================================
    //  Join
    // ============================================================

    function join(string calldata nickname) external gateCheck {
        require(!members[msg.sender].exists, "Already joined");
        require(bytes(nickname).length <= 32, "Nickname too long");

        members[msg.sender] = Member({
            wallet:              msg.sender,
            joinTimestamp:       uint64(block.timestamp),
            lastCheckIn:         0,
            lastActivity:        uint64(block.timestamp),
            consecutiveDays:     0,
            totalCheckIns:       0,
            checkInStreakRecord: 0,
            level:               1,
            totalPoints:         0,
            activityScore:       0,
            questCompletions:    0,
            badgeCount:          0,
            exists:              true,
            nickname:            nickname
        });

        memberList.push(msg.sender);
        totalMembers++;

        emit MemberJoined(msg.sender, block.timestamp, totalMembers);
    }

    function updateNickname(string calldata nickname) external onlyMember {
        require(bytes(nickname).length <= 32, "Nickname too long");
        members[msg.sender].nickname = nickname;
        emit MemberUpdated(msg.sender, nickname, block.timestamp);
    }

    // ============================================================
    //  Daily Check-in
    // ============================================================

    function checkIn() external onlyMember returns (uint256 pointsEarned, int256 triggeredMilestone) {
        Member storage m = members[msg.sender];

        // UTC+8 day boundary
        uint256 today   = (block.timestamp + UTC8_OFFSET) / SECONDS_PER_DAY;
        uint256 lastDay = m.lastCheckIn > 0 ? (m.lastCheckIn + UTC8_OFFSET) / SECONDS_PER_DAY : 0;
        require(today > lastDay, "Already checked in today");

        // Consecutive days
        if (lastDay > 0 && today == lastDay + 1) {
            m.consecutiveDays++;
        } else {
            m.consecutiveDays = 1;
        }
        if (m.consecutiveDays > m.checkInStreakRecord) {
            m.checkInStreakRecord = m.consecutiveDays;
        }

        // --- Points Calculation ---
        pointsEarned = BASE_CHECKIN_POINTS;
        uint256 cd = m.consecutiveDays;

        if      (cd >= 365) { pointsEarned += CONSECUTIVE_365DAY_BONUS; }
        else if (cd >= 90)  { pointsEarned += CONSECUTIVE_90DAY_BONUS; }
        else if (cd >= 30)  { pointsEarned += CONSECUTIVE_30DAY_BONUS; }
        else if (cd >= 7)   { pointsEarned += CONSECUTIVE_7DAY_BONUS; }
        else if (cd >= 3)   { pointsEarned += CONSECUTIVE_3DAY_BONUS; }

        // Monday bonus (0=Monday in UTC+8)
        uint256 dow = ((block.timestamp + UTC8_OFFSET) / SECONDS_PER_DAY + 3) % 7;
        if (dow == 0) { pointsEarned += MONDAY_BONUS; }

        // GDC holding bonus (capped at MAX_GDC_BONUS)
        uint256 gdcBonus = msg.sender.balance / GDC_PER_BONUS_POINT;
        if (gdcBonus > MAX_GDC_BONUS) { gdcBonus = MAX_GDC_BONUS; }
        pointsEarned += gdcBonus;

        // --- Update State ---
        m.totalPoints   += uint128(pointsEarned);
        m.lastCheckIn    = uint64(block.timestamp);
        m.lastActivity   = uint64(block.timestamp);
        m.totalCheckIns++;
        m.activityScore  += uint128(pointsEarned);

        // Level-up check
        uint32 newLevel = uint32((m.totalPoints / POINTS_PER_LEVEL) + 1);
        if (newLevel > m.level) {
            uint32 oldLevel = m.level;
            m.level = newLevel;
            emit LevelUp(msg.sender, oldLevel, newLevel);
        }

        // Milestone check
        triggeredMilestone = -1;
        uint256 len = checkInMilestones.length;
        for (uint256 i = 0; i < len; i++) {
            if (m.consecutiveDays == checkInMilestones[i].milestoneDays) {
                uint256 bonus = checkInMilestones[i].bonusPoints;
                m.totalPoints  += uint128(bonus);
                m.activityScore += uint128(bonus);
                triggeredMilestone = int256(i);
                emit MilestoneReached(msg.sender, checkInMilestones[i].milestoneDays, checkInMilestones[i].badgeName, bonus);
                break;
            }
        }

        // Daily count
        if (todayCheckInDate != today) {
            todayCheckInDate = today;
            todayCheckInCount = 1;
        } else {
            todayCheckInCount++;
        }

        emit CheckedIn(msg.sender, pointsEarned, m.consecutiveDays, m.totalPoints, m.level, block.timestamp);
    }

    // ============================================================
    //  Admin: Award Points
    // ============================================================

    function awardPoints(address memberAddr, uint256 pts, string calldata reason) external onlyOwner {
        require(members[memberAddr].exists, "Not a member");
        require(pts > 0 && pts <= 10000, "Invalid amount");

        members[memberAddr].totalPoints   += uint128(pts);
        members[memberAddr].activityScore += uint128(pts);
        members[memberAddr].lastActivity   = uint64(block.timestamp);

        uint32 newLevel = uint32((members[memberAddr].totalPoints / POINTS_PER_LEVEL) + 1);
        if (newLevel > members[memberAddr].level) {
            uint32 old = members[memberAddr].level;
            members[memberAddr].level = newLevel;
            emit LevelUp(memberAddr, old, newLevel);
        }

        emit PointsAwarded(memberAddr, pts, reason);
    }

    // ============================================================
    //  Queries
    // ============================================================

    function getMember(address addr) external view returns (Member memory) {
        return members[addr];
    }

    function isMember(address addr) external view returns (bool) {
        return members[addr].exists && addr.balance >= MIN_GDC_BALANCE;
    }

    function canCheckIn(address addr) external view returns (bool) {
        Member storage m = members[addr];
        if (!m.exists) return false;
        uint256 today   = (block.timestamp + UTC8_OFFSET) / SECONDS_PER_DAY;
        uint256 lastDay = m.lastCheckIn > 0 ? (m.lastCheckIn + UTC8_OFFSET) / SECONDS_PER_DAY : 0;
        return today > lastDay;
    }

    function getMemberCount() external view returns (uint256) {
        return totalMembers;
    }

    function getTodayCheckInCount() external view returns (uint256) {
        uint256 today = (block.timestamp + UTC8_OFFSET) / SECONDS_PER_DAY;
        return (todayCheckInDate == today) ? todayCheckInCount : uint256(0);
    }

    function getMilestones() external view returns (CheckInMilestone[] memory) {
        return checkInMilestones;
    }

    // ============================================================
    //  Leaderboard
    // ============================================================

    function getLeaderboardFull(
        uint256 limit,
        uint256 offset
    ) external view returns (
        address[] memory wallets,
        uint128[] memory totalPoints,
        uint128[] memory activityScores,
        uint32[] memory levels,
        uint32[] memory consecutiveDays,
        uint32[] memory totalCheckIns
    ) {
        uint256 count = memberList.length;
        if (offset >= count) {
            return (new address[](0), new uint128[](0), new uint128[](0), new uint32[](0), new uint32[](0), new uint32[](0));
        }
        uint256 remaining = count - offset;
        uint256 size = remaining < limit ? remaining : limit;

        wallets         = new address[](size);
        totalPoints     = new uint128[](size);
        activityScores  = new uint128[](size);
        levels          = new uint32[](size);
        consecutiveDays = new uint32[](size);
        totalCheckIns   = new uint32[](size);

        for (uint256 i = 0; i < size; i++) {
            Member storage m = members[memberList[offset + i]];
            wallets[i]         = m.wallet;
            totalPoints[i]     = m.totalPoints;
            activityScores[i]  = m.activityScore;
            levels[i]          = m.level;
            consecutiveDays[i] = m.consecutiveDays;
            totalCheckIns[i]   = m.totalCheckIns;
        }
    }

    // ============================================================
    //  Activity Decay
    // ============================================================

    function checkAndApplyDecay() external onlyMember {
        Member storage m = members[msg.sender];
        uint256 inactiveDays = (block.timestamp - m.lastActivity) / SECONDS_PER_DAY;
        if (inactiveDays > INACTIVITY_DECAY_DAYS) {
            uint256 decayDays = inactiveDays - INACTIVITY_DECAY_DAYS;
            uint256 decayAmount = decayDays * DECAY_RATE_PER_DAY;
            if (decayAmount > m.activityScore) { decayAmount = m.activityScore; }
            m.activityScore -= uint128(decayAmount);
            m.lastActivity = uint64(block.timestamp);
            emit ActivityDecayed(msg.sender, decayAmount, inactiveDays);
        }
    }

    // ============================================================
    //  Admin: Milestones
    // ============================================================

    function addCheckInMilestone(uint256 mDays, string calldata badgeName, string calldata badgeURI, uint256 bonusPts) external onlyOwner {
        require(mDays > 0, "Invalid days");
        require(bytes(badgeName).length > 0, "Invalid name");
        checkInMilestones.push(CheckInMilestone(mDays, badgeName, badgeURI, bonusPts));
        emit MilestoneAdded(mDays, badgeName, bonusPts);
    }

    function removeCheckInMilestone(uint256 index) external onlyOwner {
        require(index < checkInMilestones.length, "Invalid index");
        uint256 last = checkInMilestones.length - 1;
        if (index != last) { checkInMilestones[index] = checkInMilestones[last]; }
        checkInMilestones.pop();
        emit MilestoneRemoved(index);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        address old = owner;
        owner = newOwner;
        emit OwnerChanged(old, newOwner);
    }
}
