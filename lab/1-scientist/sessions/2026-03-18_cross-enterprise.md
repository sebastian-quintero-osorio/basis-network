# Session Log: Cross-Enterprise Verification (RU-V7)

- **Date**: 2026-03-18
- **Target**: validium (MVP)
- **Research Unit**: RU-V7 (Cross-Enterprise Verification)
- **Stage**: 1 (Implementation) -- COMPLETE

## What Was Accomplished

1. **Literature review** (15+ sources): SnarkPack (FC 2022), Nebra UPA (2024), aPlonK,
   Nova/SuperNova, Polygon AggLayer, zkSync Gateway, Rayls, ZKsync Prividium, zkCross,
   StarkPack, ZK-InterChain, Chainlink CCIP, Groth16/PLONK gas cost analyses.

2. **Prototype implementation**: Cross-enterprise verification system with three approaches:
   - Sequential: independent proof verification (simplest)
   - Batched Pairing: shared pairing computation in single transaction
   - Hub Aggregation: Nebra UPA-style universal aggregation

3. **Benchmark execution**: 50 repetitions, 5 enterprise scenarios (2-50 enterprises),
   5 interaction densities, 4 adversarial privacy tests.

4. **Foundation updates**: Added 4 invariants (INV-CE1 to INV-CE4), 5 properties
   (PROP-CE1 to PROP-CE5), 6 attack vectors (ATK-CE1 to ATK-CE6), 4 open questions
   (OQ-19 to OQ-22).

## Key Findings

- **Hypothesis CONFIRMED**: 1.41x overhead (Sequential), 0.64x (Batched Pairing), 1.16x (Hub)
- Cross-reference circuit: 68,868 constraints, ~4.5s snarkjs / ~0.45s rapidsnark
- Privacy leakage: 1 bit per interaction (existence only), 4/4 adversarial tests PASS
- Dense interaction edge case: Sequential exceeds 2x at interactions > enterprises
- Batched Pairing is optimal across all tested scales (2-50 enterprises)
- Groth16 sufficient for MVP; PLONK migration path for heterogeneous aggregation

## Artifacts Produced

- `validium/research/experiments/2026-03-18_cross-enterprise/hypothesis.json`
- `validium/research/experiments/2026-03-18_cross-enterprise/state.json`
- `validium/research/experiments/2026-03-18_cross-enterprise/journal.md`
- `validium/research/experiments/2026-03-18_cross-enterprise/findings.md`
- `validium/research/experiments/2026-03-18_cross-enterprise/code/cross-enterprise-benchmark.ts`
- `validium/research/experiments/2026-03-18_cross-enterprise/code/package.json`
- `validium/research/experiments/2026-03-18_cross-enterprise/code/tsconfig.json`
- `validium/research/experiments/2026-03-18_cross-enterprise/results/benchmark-results.json`
- `validium/research/experiments/2026-03-18_cross-enterprise/memory/session.md`
- Updated: `validium/research/foundations/zk-01-objectives-and-invariants.md`
- Updated: `validium/research/foundations/zk-02-threat-model.md`

## Decisions Made

1. **Three-approach evaluation** rather than single approach -- provides clear recommendation
   for both MVP (Sequential) and scale-out (Hub/Batched).
2. **Groth16 for MVP** -- already deployed, proven, no additional trusted setup complexity
   beyond the cross-reference circuit itself.
3. **Interaction commitment design**: Poseidon(keyA, leafA, keyB, leafB) as the privacy-
   preserving binding commitment.

## Next Steps

1. **Stage 2 (Baseline)**: Stochastic baseline with 30+ repetitions across varied
   enterprise counts and interaction densities.
2. **Downstream**: Logicist formalizes CrossEnterpriseVerification in TLA+ with Isolation
   and Consistency invariants.
3. **Architect**: Implement CrossEnterpriseVerifier.sol with batched pairing support.
