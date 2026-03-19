# Gas Benchmark Results -- State Commitment Layouts

Hardware: Windows 11, Node.js, Hardhat (EVM Cancun target)
Solidity: 0.8.24, optimizer 200 runs
Date: 2026-03-18
Methodology: Mock verification (ZK cost added analytically as constant 205,600 gas)

## First Batch Submission (Cold Storage)

| Layout | Storage+Logic Gas | ZK Verify Gas | Total Est | Storage/Batch | Under 300K? |
|--------|------------------:|--------------:|----------:|:-------------:|:-----------:|
| A: Minimal (roots) | 80,156 | 205,600 | 285,756 | 32 bytes | YES |
| B: Rich (metadata) | 102,799 | 205,600 | 308,399 | 64 bytes | NO |
| C: Events Only | 57,887 | 205,600 | 263,487 | 0 bytes | YES |

## Second Batch Submission (Warm Enterprise State)

| Layout | Storage+Logic Gas | ZK Verify Gas | Total Est | Under 300K? |
|--------|------------------:|--------------:|----------:|:-----------:|
| A: Minimal (roots) | 63,044 | 205,600 | 268,644 | YES |
| B: Rich (metadata) | 88,041 | 205,600 | 293,641 | YES |
| C: Events Only | 40,775 | 205,600 | 246,375 | YES |

## 10th Batch Submission (Steady State)

| Layout | Storage+Logic Gas | Total Est |
|--------|------------------:|----------:|
| A: Minimal | 63,056 | 268,656 |
| B: Rich | 88,053 | 293,653 |
| C: Events Only | 40,787 | 246,387 |

## Delta Analysis

### Rich - Minimal = Cost of On-Chain Metadata
- First batch: +22,643 gas (+28.2%)
- Second batch: +24,997 gas (+39.7%)
- Steady state delta: ~22,600-25,000 gas

### Minimal - EventsOnly = Cost of Root History Storage
- Consistent: +22,269 gas per batch (= 1 SSTORE 0->nonzero at 22,100 + overhead)

## Invariant Test Results

| Test | Layout A | Layout B | Layout C |
|------|----------|----------|----------|
| ChainContinuity (gap detection) | PASS | PASS | PASS |
| NoReversal (reversal detection) | PASS | PASS | PASS |
| Enterprise Isolation | PASS | - | - |
| History Queryability | PASS | PASS | N/A (events) |
| Event Data Recovery | - | - | PASS |
| Cumulative Tx Tracking | - | PASS | - |

## Key Findings

1. Layout A (Minimal) is the optimal choice: under 300K gas with on-chain root history.
2. Layout B (Rich) exceeds 300K on first batch (308K) but fits on subsequent batches (294K).
   The first-batch overshoot is marginal and due to cold storage access patterns.
3. Layout C (Events Only) is cheapest but sacrifices on-chain root queryability.
4. The 22,269 gas delta between A and C is exactly 1 SSTORE (new mapping entry).
5. All layouts correctly enforce ChainContinuity, NoGap, and NoReversal invariants.
6. Enterprise isolation is enforced by per-enterprise state mapping.
7. ZK verification dominates gas cost: 205,600 / 285,756 = 71.9% of total for Layout A.
