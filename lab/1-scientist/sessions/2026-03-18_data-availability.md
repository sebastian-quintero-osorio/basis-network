# Session Log: RU-V6 Data Availability Committee

- **Date**: 2026-03-18
- **Target**: validium (MVP)
- **Experiment**: data-availability-committee
- **Agent**: The Scientist (lab/1-scientist)
- **Stage**: 1-2 (Implementation + Baseline)

## What Was Accomplished

### Literature Review (Stage 0)
- Comprehensive review of 24 references from production systems and academic papers
- Surveyed: StarkEx, Polygon CDK, Arbitrum Nova, EigenDA, Celestia, Espresso, zkPorter
- Key academic papers: Semi-AVID-PR (Nazirkhanova 2021), Shamir 1979, Boneh BLS 2018
- Critical finding: NO production DAC provides data privacy -- our SSS approach is a genuine innovation

### Implementation (Stage 1)
- Implemented Shamir (k,n)-SS over BN128 scalar field in TypeScript
- Built DACNode (share storage, attestation signing, retrieval) and DACProtocol (orchestration)
- ECDSA multi-sig attestation with AnyTrust fallback mechanism
- 51 privacy tests and 61 recovery/failure tests -- all passing

### Baseline Benchmarks (Stage 2)
- 4 batch sizes (10KB, 100KB, 500KB, 1MB) x 2 configs (2-of-3, 3-of-3)
- Failure scenario: 1-node offline (30 reps), 2-node offline (fallback)
- Scaling test: 1KB to 500KB linear scaling confirmed
- All 95% CI widths < 5% of mean

## Key Findings

| Metric | Value | Target | Verdict |
|--------|-------|--------|---------|
| Attestation P95 @ 500KB | 175ms | <2000ms | PASS (11x margin) |
| Attestation P95 @ 1MB | 346ms | <2000ms | PASS (5.8x margin) |
| Privacy (single share) | 0 bits leaked | 0 bits | PASS |
| Recovery (1 node down) | 30/30 match | >0 | PASS |
| Fallback (2 nodes down) | triggers | triggers | PASS |
| Storage overhead | 3.87x | <5x | PASS |

**HYPOTHESIS: CONFIRMED with significant margins.**

## Artifacts Produced

| File | Path |
|------|------|
| hypothesis.json | validium/research/experiments/2026-03-18_data-availability-committee/hypothesis.json |
| state.json | validium/research/experiments/2026-03-18_data-availability-committee/state.json |
| findings.md | validium/research/experiments/2026-03-18_data-availability-committee/findings.md |
| journal.md | validium/research/experiments/2026-03-18_data-availability-committee/journal.md |
| session memory | validium/research/experiments/2026-03-18_data-availability-committee/memory/session.md |
| types.ts | .../code/src/types.ts |
| shamir.ts | .../code/src/shamir.ts |
| dac-node.ts | .../code/src/dac-node.ts |
| dac-protocol.ts | .../code/src/dac-protocol.ts |
| stats.ts | .../code/src/stats.ts |
| benchmark.ts | .../code/src/benchmark.ts |
| test-privacy.ts | .../code/src/test-privacy.ts |
| test-recovery.ts | .../code/src/test-recovery.ts |
| benchmark-results.json | validium/research/experiments/2026-03-18_data-availability-committee/results/benchmark-results.json |
| zk-01 (updated) | validium/research/foundations/zk-01-objectives-and-invariants.md |
| zk-02 (updated) | validium/research/foundations/zk-02-threat-model.md |
| global memory (updated) | lab/1-scientist/memory/global.md |

## Decisions Made

1. **(2,3)-Shamir over (3,3)**: 8x recovery speed, same privacy guarantee
2. **ECDSA over BLS**: native EVM, sufficient for 3 nodes
3. **SHA-256 for data commitment**: faster; Poseidon only if in-circuit verification needed
4. **AnyTrust fallback**: on-chain DA when <k nodes available

## Next Steps

This experiment output feeds to the downstream pipeline:
1. **Logicist** (lab/2-logicist): TLA+ formalization of DAC protocol invariants (INV-DA1 through INV-DA5)
2. **Architect** (lab/3-architect): Production implementation of DAC module + DACAttestation.sol
3. **Prover** (lab/4-prover): Coq proof of DAC protocol properties
