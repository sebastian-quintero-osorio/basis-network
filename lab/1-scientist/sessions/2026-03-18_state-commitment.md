# Session Log: State Commitment Protocol (RU-V3)

- **Date**: 2026-03-18
- **Target**: validium (MVP)
- **Experiment**: 2026-03-18_state-commitment
- **Stage**: 1 (Implementation) -- COMPLETE
- **Pipeline item**: [17] Scientist | RU-V3

## What Was Accomplished

1. **Literature review**: Analyzed state commitment patterns from zkSync Era (commit-prove-execute,
   3-phase), Polygon zkEVM (sequenceBatches + verifyBatches, 2-phase), and Scroll (commitBatch +
   finalizeBatch, 2-phase). Documented EVM storage gas costs (SSTORE, SLOAD, precompiles) and
   production per-batch storage requirements (64-96 bytes).

2. **Prototype implementation**: Three StateCommitment.sol variants:
   - Layout A (Minimal): Roots in mapping + metadata in events. 1 new storage slot per batch.
   - Layout B (Rich): Roots + packed BatchInfo struct. 2 new storage slots per batch.
   - Layout C (Events Only): No per-batch storage. All metadata in events.

3. **Benchmarks**: 16/16 Hardhat tests passing. Measured gas costs for all three layouts across
   first-batch (cold) and steady-state (warm) patterns.

4. **Invariant verification**: Tested ChainContinuity (gap detection), NoReversal, Enterprise
   Isolation, History Queryability, and Event Data Recovery.

5. **Foundational document updates**: Added 5 new invariants (INV-SC1 through INV-SC5), 4 new
   properties (PROP-SC1 through PROP-SC4), 7 new attack vectors (ATK-SC1 through ATK-SC7),
   and 3 new open questions (OQ-12 through OQ-14).

## Key Findings

| Layout | Total Gas (1st batch) | Total Gas (steady) | Storage/Batch | Under 300K? |
|--------|----------------------:|-------------------:|:-------------:|:-----------:|
| A: Minimal | 285,756 | 268,656 | 32 bytes | YES |
| B: Rich | 308,399 | 293,653 | 64 bytes | First: NO, Steady: YES |
| C: Events Only | 263,487 | 246,387 | 0 bytes | YES |

- ZK verification dominates gas: 205,600 / 285,756 = 72% of Layout A total.
- Integrated verification saves ~56K gas vs delegated (cross-contract to ZKVerifier).
- Single-phase submission is viable for enterprise validium (unlike public rollups).
- prevRoot == currentRoot check is sufficient for gap detection and reversal prevention.

## Verdict

**CONFIRMED.** Layout A (Minimal, integrated verification) meets all targets:
- 285,756 gas < 300K (first batch)
- 32 bytes < 500 bytes (per batch)
- 100% gap and reversal detection
- Full enterprise isolation

## Artifacts Produced

| Artifact | Path |
|----------|------|
| hypothesis.json | validium/research/experiments/2026-03-18_state-commitment/hypothesis.json |
| state.json | validium/research/experiments/2026-03-18_state-commitment/state.json |
| journal.md | validium/research/experiments/2026-03-18_state-commitment/journal.md |
| findings.md | validium/research/experiments/2026-03-18_state-commitment/findings.md |
| StateCommitmentV1.sol | validium/research/experiments/2026-03-18_state-commitment/code/StateCommitmentV1.sol |
| StateCommitmentV2.sol | validium/research/experiments/2026-03-18_state-commitment/code/StateCommitmentV2.sol |
| StateCommitmentBenchmark.sol | validium/research/experiments/2026-03-18_state-commitment/code/StateCommitmentBenchmark.sol |
| benchmark.test.ts | validium/research/experiments/2026-03-18_state-commitment/code/benchmark.test.ts |
| gas-benchmark.md | validium/research/experiments/2026-03-18_state-commitment/results/gas-benchmark.md |
| session.md | validium/research/experiments/2026-03-18_state-commitment/memory/session.md |
| zk-01 (updated) | validium/research/foundations/zk-01-objectives-and-invariants.md |
| zk-02 (updated) | validium/research/foundations/zk-02-threat-model.md |

## Next Steps

- **[18] Logicist | RU-V3**: Formalize StateCommitment as TLA+ specification. Key properties:
  ChainContinuity, NoGap, NoReversal, ProofBeforeState, EnterpriseIsolation. Model-check
  with multiple enterprises and concurrent submissions.
- **[19] Architect | RU-V3**: Implement production StateCommitment.sol in l1/contracts/contracts/core/
  using Layout A pattern. Integrate with EnterpriseRegistry.sol. Test suite with >85% coverage.
- **[20] Prover | RU-V3**: Coq proofs for ChainContinuity and ProofBeforeState invariants.
