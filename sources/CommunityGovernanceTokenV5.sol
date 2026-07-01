// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title CommunityGovernanceToken V5 (CGC V5)
 *OZ v4.9.6 + solc 0.7.6 编译，EVM Istanbul 兼容（无 PUSH10+）
 *
 * 升级内容：
 * - MAX_HOLDING = 1M 单人持仓上限（合约硬编码，V5 核心）
 * - Treasury 地址豁免上限（excludedFromCap）
 * - DEFAULT_ADMIN_ROLE 转移给 Governor（去中心化）
 *
 * 继承链（OZ v4.9.6）：
 *   ERC20 → ERC20Permit → ERC20Votes → Votes
 *   AccessControl（独立）
 *
 *OZ v4 vs v5 关键差异：
 * - 使用 _mint/_burn override + _afterTokenTransfer（OZ v4 模式）
 * - 不使用 _update（OZ v5 独有）
 * - clock() 返回 block.number（EIP-5805 OZ v4 默认）
 */
contract CommunityGovernanceTokenV5 is ERC20, ERC20Permit, ERC20Votes, AccessControl {
    // ============ 角色 ============
    bytes32 public constant MINTER_ROLE        = keccak256("MINTER_ROLE");
    bytes32 public constant VESTING_ADMIN_ROLE = keccak256("VESTING_ADMIN_ROLE");

    // ============ 供应量 ============
    uint256 public constant MAX_SUPPLY  = 100_000_000 * 10**18; // 1亿枚
    uint256 public constant MAX_HOLDING  = 1_000_000 * 10**18;  // 单人持仓上限（V5 核心：1%）

    // Treasury 豁免上限映射（V5 新增）
    mapping(address => bool) public excludedFromCap;

    // ============ 归属（Vesting）============
    struct VestingSchedule {
        uint256 totalAmount;
        uint256 released;
        uint64  startTime;
        uint64  cliffDuration;
        uint64  vestingDuration;
        bool    exists;
    }

    mapping(address => VestingSchedule) public vestingSchedules;

    // ============ 时间锁铸币 ============
    uint256 public timelockMintAmount;
    uint256 public timelockMintReleaseTime;

    // ============ 事件 ============
    event VestingCreated(address indexed beneficiary, uint256 totalAmount, uint64 start, uint64 cliff, uint64 duration);
    event VestingReleased(address indexed beneficiary, uint256 amount);
    event ExcludedFromCapUpdated(address indexed account, bool excluded);
    event TimelockMintScheduled(address indexed to, uint256 amount, uint256 releaseTime);

    // ============ 构造器 ============
    constructor(
        uint256 initialSupply,
        address initialAdmin,
        address initialMinter
    )
        ERC20("GoodChain Community", "CGC")
        ERC20Permit("GoodChain Community")
        AccessControl()
    {
        require(initialSupply <= MAX_SUPPLY, "Exceeds MAX_SUPPLY");
        if (initialSupply > 0) {
            _mint(_msgSender(), initialSupply);
        }
        _setupRole(MINTER_ROLE, initialMinter);
        _setupRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    // ============ _mint override：MAX_HOLDING 上限检查（OZ v4）============
    //OZ v4 执行顺序：_mint() → ERC20._mint()（先更新余额）→ _afterTokenTransfer()
    //所以 balanceOf(to) 在这里已经含本次铸造量，可直接检查
    function _mint(address account, uint256 amount) internal virtual override(ERC20, ERC20Votes) {
        if (account != address(0) && !excludedFromCap[account]) {
            require(
                balanceOf(account) + amount <= MAX_HOLDING,
                "CGC: exceeds MAX_HOLDING"
            );
        }
        // 调用父类 _mint（OZ v4 ERC20Votes 会自动记录 checkpoints）
        ERC20Votes._mint(account, amount);
    }

    // ============ _burn override（OZ v4）============
    //OZ v4 ERC20Votes._burn 已有 override
    function _burn(address account, uint256 amount) internal virtual override(ERC20, ERC20Votes) {
        ERC20Votes._burn(account, amount);
    }

    // ============ _afterTokenTransfer：转账后无特殊操作（OZ v4）============
    //OZ v4 Votes 已在 _afterTokenTransfer 中记录 checkpoints（通过 _moveVotingPower）
    //此处仅需 super 调用即可
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override(ERC20, ERC20Votes) {
        ERC20Votes._afterTokenTransfer(from, to, amount);
    }

    //OZ v4 ERC20Votes._mint/_burn 已处理 checkpoints，本合约只需 super

    // ============ Treasury 豁免管理（V5 新增）============
    function setExcludedFromCap(address account, bool excluded) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "CGC: not admin");
        excludedFromCap[account] = excluded;
        emit ExcludedFromCapUpdated(account, excluded);
    }

    function setExcludedFromCapBatch(address[] calldata accounts, bool excluded) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "CGC: not admin");
        for (uint256 i = 0; i < accounts.length; i++) {
            excludedFromCap[accounts[i]] = excluded;
            emit ExcludedFromCapUpdated(accounts[i], excluded);
        }
    }

    // ============ 归属管理 ============
    function createVesting(
        address beneficiary,
        uint256 totalAmount,
        uint64  startTime,
        uint64  cliffDuration,
        uint64  vestingDuration
    ) external {
        require(hasRole(VESTING_ADMIN_ROLE, _msgSender()), "CGC: not vesting admin");
        require(!vestingSchedules[beneficiary].exists, "CGC: vesting exists");
        require(totalAmount <= MAX_SUPPLY, "CGC: exceeds supply");

        vestingSchedules[beneficiary] = VestingSchedule({
            totalAmount:     totalAmount,
            released:        0,
            startTime:       startTime,
            cliffDuration:   cliffDuration,
            vestingDuration: vestingDuration,
            exists:          true
        });

        emit VestingCreated(beneficiary, totalAmount, startTime, cliffDuration, vestingDuration);
    }

    function releasableAmount(address beneficiary) public view returns (uint256) {
        if (!vestingSchedules[beneficiary].exists) return 0;
        VestingSchedule storage vs = vestingSchedules[beneficiary];
        if (block.timestamp < vs.startTime + vs.cliffDuration) return 0;
        if (block.timestamp >= vs.startTime + vs.vestingDuration) return vs.totalAmount - vs.released;
        uint256 vested = (vs.totalAmount * (block.timestamp - vs.startTime)) / vs.vestingDuration;
        return vested - vs.released;
    }

    function release(address beneficiary) external {
        uint256 releasable = releasableAmount(beneficiary);
        require(releasable > 0, "CGC: nothing to release");
        vestingSchedules[beneficiary].released += releasable;
        _mint(beneficiary, releasable); // 触发 MAX_HOLDING 检查
        emit VestingReleased(beneficiary, releasable);
    }

    // ============ 铸币接口 ============
    // 时间锁铸币（Governor 提案触发）
    function scheduleTimelockMint(
        address to,
        uint256 amount,
        uint256 releaseTimestamp
    ) external {
        require(hasRole(MINTER_ROLE, _msgSender()), "CGC: not minter");
        require(to != address(0), "CGC: zero address");
        require(totalSupply() + amount <= MAX_SUPPLY, "CGC: exceeds MAX_SUPPLY");
        timelockMintAmount = amount;
        timelockMintReleaseTime = releaseTimestamp;
        emit TimelockMintScheduled(to, amount, releaseTimestamp);
    }

    function executeTimelockMint(address to) external {
        require(block.timestamp >= timelockMintReleaseTime, "CGC: not yet");
        require(timelockMintAmount > 0, "CGC: nothing to mint");
        uint256 amount = timelockMintAmount;
        timelockMintAmount = 0;
        timelockMintReleaseTime = 0;
        _mint(to, amount); // 触发 MAX_HOLDING 检查
    }

    // 直接铸币（Bot 等持续性铸造）
    function mint(address to, uint256 amount) external {
        require(hasRole(MINTER_ROLE, _msgSender()), "CGC: not minter");
        require(totalSupply() + amount <= MAX_SUPPLY, "CGC: exceeds MAX_SUPPLY");
        _mint(to, amount); // 触发 MAX_HOLDING 检查
    }

    // ============ 烧币 ============
    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }

    // ============ 视图函数（兼容前端 V4 接口）============
    function maxHoldingPercent() external pure returns (uint256) {
        return 1; // 1% = 1M / 100M
    }
}
