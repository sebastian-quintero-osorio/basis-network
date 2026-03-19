# Session Log: basis-rollup

- **Date:** 2026-03-19
- **Target:** zkl2
- **Experiment:** L1 Rollup Contract for Enterprise zkEVM L2 with Block-Level State Tracking
- **Stage:** 1 (Implementation) -- COMPLETE
- **Verdict:** HYPOTHESIS CONFIRMED

## What Was Accomplished

Designed and implemented BasisRollup.sol, a Solidity L1 rollup contract extending the
validium StateCommitment.sol (RU-V3, 285K gas) to a full three-phase commit-prove-execute
lifecycle for the zkEVM L2.

### Literature Review

Surveyed production rollup contracts: zkSync Era (commit-prove-execute, 400-500K gas),
Polygon zkEVM (sequence-verify, 350-500K gas), Scroll (commit-finalize, ~370K gas),
StarkNet (STARK verify, 200-300K gas). Established gas baselines for EIP-196/197
precompiles and EIP-2929/2200 storage costs.

### Implementation

- BasisRollup.sol: 3-phase lifecycle with per-enterprise state chains, L2 block tracking,
  priority operations hash, admin revert mechanism
- BasisRollupHarness.sol: Mock Groth16 for testing
- MockEnterpriseRegistry: Minimal mock via IEnterpriseRegistry interface
- 61 comprehensive tests: deployment, commit, prove, execute, revert, isolation, views,
  gas benchmarks, adversarial scenarios

### Key Findings

| Metric | First Batch | Steady State |
|--------|------------|-------------|
| commitBatch gas | 150,118 | 116,147 |
| proveBatch gas (mock) | 67,943 | 50,855 |
| executeBatch gas | 69,712 | 52,624 |
| **Total (mock)** | **287,773** | **219,626** |
| **Projected (with Groth16)** | **493,373** | **425,226** |

All predictions confirmed. Total gas under 500K target. 10 invariants verified (5 from
validium + 5 new rollup invariants). Block range size has zero gas impact.

## Artifacts Produced

| Path | Description |
|------|-------------|
| `zkl2/research/experiments/2026-03-19_basis-rollup/hypothesis.json` | Experiment definition |
| `zkl2/research/experiments/2026-03-19_basis-rollup/state.json` | Final state (CONFIRMED) |
| `zkl2/research/experiments/2026-03-19_basis-rollup/findings.md` | Full results with benchmark reconciliation |
| `zkl2/research/experiments/2026-03-19_basis-rollup/journal.md` | Design decisions and rationale |
| `zkl2/research/experiments/2026-03-19_basis-rollup/results/gas-benchmarks.md` | Gas measurements |
| `zkl2/research/experiments/2026-03-19_basis-rollup/code/contracts/BasisRollup.sol` | Rollup contract |
| `zkl2/research/experiments/2026-03-19_basis-rollup/code/contracts/BasisRollupHarness.sol` | Test harness |
| `zkl2/research/experiments/2026-03-19_basis-rollup/code/contracts/IEnterpriseRegistry.sol` | Interface |
| `zkl2/research/experiments/2026-03-19_basis-rollup/code/contracts/MockEnterpriseRegistry.sol` | Test mock |
| `zkl2/research/experiments/2026-03-19_basis-rollup/code/test/BasisRollup.test.ts` | 61 tests |
| `zkl2/research/foundations/zk-01-objectives-and-invariants.md` | Updated: I-20 to I-24 |
| `zkl2/research/foundations/zk-02-threat-model.md` | Updated: T-21 to T-24 |

## Decisions Made

1. **Commit-prove-execute** over single-phase: enables async proving, batch revert, future proof aggregation
2. **Block-level tracking** in batch metadata: zero gas cost, needed for bridge references
3. **StoredBatchInfo with 3 storage slots**: tradeoff of 128 bytes/batch vs 32 bytes (validium) for richer lifecycle tracking
4. **Sequential proving and execution**: simpler than range-based proving (future optimization)
5. **Admin-only revert**: enterprise-grade safety mechanism for emergency batch removal

## Next Steps

1. **Logicist (lab/2-logicist/)**: TLA+ formalization of commit-prove-execute lifecycle
2. **Architect (lab/3-architect/)**: Production implementation with real Groth16 verification
3. **Measure Groth16 on Fuji**: Validate that first-batch 493K projection holds on Subnet-EVM
4. **Priority operations enforcement**: Add forced inclusion deadline checking
5. **Batch range proving**: Amortize Groth16 cost across multiple batches
