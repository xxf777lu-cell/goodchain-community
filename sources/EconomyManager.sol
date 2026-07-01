// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title EconomyManager
 * @dev GDC Autonomous Community — MET/MEC/UX economy integration
 *
 *      Tracks GoodChain's tri-token economy rates and provides a
 *      single on-chain source of truth for the frontend.
 *
 *      Exchange Rate Mechanism (sourced from uxmecswap.com):
 *      - UX Channel: baseRate = 10 UX/GDC, +10% per ~1,230,000 GDC exchanged
 *      - MEC Channel: baseRate = 10 MEC/GDC, +10% per ~1,230,000 GDC exchanged
 *      - Channels are independent
 *
 *      Total Supplies:
 *      - MET: 6,424,000,000  (not yet on-chain)
 *      - MEC:   200,000,000  (ERC-20 on GoodChain)
 *      - UX:                (originated BNB chain, migrated to GoodChain)
 *
 *      This contract is a read-only registry. Actual swaps happen off-chain
 *      or via uxmecswap.com's interface.
 */
contract EconomyManager is Ownable {
    // ─── Exchange Rate State ────────────────────────────
    struct Channel {
        string  name;        // "UX" or "MEC"
        uint256 baseRate;    // tokens per 1 GDC (e.g., 10 = 10 tokens per GDC)
        uint256 totalSwapped; // cumulative GDC swapped through this channel
        uint256 rateStepGDC; // GDC volume per 10% rate increase (~1,230,000 * 10^18)
        uint256 rateStepPct; // percentage increase per step (e.g., 10% = 1000 bps)
        uint256 lastRateUpdate;
    }

    Channel public uxChannel;
    Channel public mecChannel;

    // ─── Token Supply Info ──────────────────────────────
    uint256 public metTotalSupply = 6_424_000_000 * 10**18;
    uint256 public mecTotalSupply = 200_000_000 * 10**18;
    uint256 public mecCirculating;
    uint256 public communityTreasuryGDC;
    uint256 public communityTreasuryMEC;

    // ─── Events ─────────────────────────────────────────
    event RateUpdated(string channel, uint256 newRate);
    event SwapTracked(string channel, uint256 gdcAmount);
    event TreasuryUpdated(uint256 gdc, uint256 mec);

    constructor() Ownable(msg.sender) {
        // UX Channel: starts at 10 UX per 1 GDC
        uxChannel = Channel({
            name: "UX",
            baseRate: 10,
            totalSwapped: 0,
            rateStepGDC: 1_230_000 * 10**18,
            rateStepPct: 1000, // 10% = 1000 basis points
            lastRateUpdate: block.timestamp
        });

        // MEC Channel: starts at 10 MEC per 1 GDC
        mecChannel = Channel({
            name: "MEC",
            baseRate: 10,
            totalSwapped: 0,
            rateStepGDC: 1_230_000 * 10**18,
            rateStepPct: 1000,
            lastRateUpdate: block.timestamp
        });
    }

    // ─── Rate Calculation ───────────────────────────────
    function getCurrentRate(Channel storage ch) internal view returns (uint256) {
        if (ch.totalSwapped == 0) return ch.baseRate;
        // Each step: rate increases by rateStepPct basis points
        uint256 steps = ch.totalSwapped / ch.rateStepGDC;
        uint256 rate = ch.baseRate;
        for (uint256 i = 0; i < steps && i < 100; i++) {
            rate = rate * (10000 + ch.rateStepPct) / 10000;
        }
        return rate;
    }

    function getUXRate() external view returns (uint256 tokensPerGDC) {
        return getCurrentRate(uxChannel);
    }

    function getMECRate() external view returns (uint256 tokensPerGDC) {
        return getCurrentRate(mecChannel);
    }

    // ─── Track Swap ─────────────────────────────────────
    function trackSwap(string calldata channel, uint256 gdcAmount) external onlyOwner {
        require(gdcAmount > 0, "Zero amount");
        uint256 oldRate;
        if (keccak256(bytes(channel)) == keccak256(bytes("UX"))) {
            oldRate = getCurrentRate(uxChannel);
            uxChannel.totalSwapped += gdcAmount;
            uxChannel.lastRateUpdate = block.timestamp;
        } else if (keccak256(bytes(channel)) == keccak256(bytes("MEC"))) {
            oldRate = getCurrentRate(mecChannel);
            mecChannel.totalSwapped += gdcAmount;
            mecChannel.lastRateUpdate = block.timestamp;
        } else {
            revert("Unknown channel");
        }
        emit SwapTracked(channel, gdcAmount);
        uint256 newRate = keccak256(bytes(channel)) == keccak256(bytes("UX"))
            ? getCurrentRate(uxChannel) : getCurrentRate(mecChannel);
        if (newRate != oldRate) emit RateUpdated(channel, newRate);
    }

    // ─── Treasury ───────────────────────────────────────
    function updateTreasury(uint256 gdc, uint256 mec) external onlyOwner {
        communityTreasuryGDC = gdc;
        communityTreasuryMEC = mec;
        emit TreasuryUpdated(gdc, mec);
    }

    function updateCirculating(uint256 circulating) external onlyOwner {
        mecCirculating = circulating;
    }

    function updateMetSupply(uint256 supply) external onlyOwner {
        metTotalSupply = supply;
    }

    // ─── Full State View ────────────────────────────────
    function getEconomyState() external view returns (
        uint256 uxRate,
        uint256 uxTotalSwapped,
        uint256 mecRate,
        uint256 mecTotalSwapped,
        uint256 treasuryGDC,
        uint256 treasuryMEC,
        uint256 metSupply,
        uint256 mecCirculate
    ) {
        return (
            getCurrentRate(uxChannel),
            uxChannel.totalSwapped,
            getCurrentRate(mecChannel),
            mecChannel.totalSwapped,
            communityTreasuryGDC,
            communityTreasuryMEC,
            metTotalSupply,
            mecCirculating
        );
    }
}
