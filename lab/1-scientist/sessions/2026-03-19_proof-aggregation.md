# Session: Proof Aggregation (RU-L10)

- **Date**: 2026-03-19
- **Target**: zkl2
- **Experiment**: 2026-03-19_proof-aggregation
- **Checklist item**: [37] Scientist | RU-L10: Proof Aggregation
- **Stage completed**: 1 (Implementation)

---

## What Was Accomplished

1. **Literature review** (27 sources): Covered recursive SNARKs (Bitansky STOC 2013,
   Ben-Sasson CRYPTO 2014, Halo ePrint 2019/1021), folding schemes (Nova CRYPTO 2022,
   SuperNova, ProtoGalaxy ePrint 2023/1106, HyperNova CRYPTO 2024, CycleFold),
   batch verification (SnarkPack FC 2022, SnarkFold), and production systems
   (Polygon zkEVM, zkSync Era, Scroll Darwin, Nebra UPA, Taiko, Axiom V2).

2. **Rust prototype**: Built benchmark comparing 4 aggregation strategies across N=1-16
   enterprises using halo2-KZG inner proofs (PSE fork, BN254). Each configuration ran
   30 iterations with 2 warmup iterations.

3. **Gas analysis**: Computed per-enterprise amortized L1 verification gas for each
   strategy, validated against published EVM precompile cost formulas.

## Key Findings

- **Hypothesis CONFIRMED**: All three aggregation strategies reduce per-enterprise
  gas by approximately N-fold or better.
- **Best strategy**: ProtoGalaxy folding + Groth16 decider achieves **15.3x gas
  reduction** for N=8 enterprises (420K -> 27K gas per enterprise), with only 11.75s
  aggregation overhead and 128-byte final proof.
- **Inner proof size**: 640 bytes (halo2-KZG), consistent with RU-L9 findings.
- **Scalability**: Folding approaches maintain constant memory (1.6 GB) and constant
  proof size regardless of N.

## Recommendation

- **Phase 1 (near-term)**: Binary tree accumulation via halo2 snark-verifier (proven
  at Scroll, no additional trusted setup)
- **Phase 2 (production)**: ProtoGalaxy folding + Groth16 decider via Sonobe library
  (best gas efficiency, requires Groth16 setup for decider circuit)

## Artifacts Produced

| Artifact | Path |
|----------|------|
| hypothesis.json | zkl2/research/experiments/2026-03-19_proof-aggregation/hypothesis.json |
| state.json | zkl2/research/experiments/2026-03-19_proof-aggregation/state.json |
| findings.md | zkl2/research/experiments/2026-03-19_proof-aggregation/findings.md |
| journal.md | zkl2/research/experiments/2026-03-19_proof-aggregation/journal.md |
| Rust benchmark | zkl2/research/experiments/2026-03-19_proof-aggregation/code/ |
| Results JSON | zkl2/research/experiments/2026-03-19_proof-aggregation/results/benchmark_results.json |

## New Invariants Discovered

- **INV-AGG-1 (AggregationSoundness)**: Aggregated proof valid iff all components valid
- **INV-AGG-2 (IndependencePreservation)**: Enterprise proofs are independent
- **INV-AGG-3 (OrderIndependence)**: Aggregation is order-independent
- **INV-AGG-4 (GasMonotonicity)**: Per-enterprise cost strictly decreases with N

## Next Steps

- Handoff to Logicist (checklist item [38]) for TLA+ formalization
- Materials needed: findings.md, benchmark results, invariant definitions
- Copy to: lab/2-logicist/research-history/YYYY-MM-proof-aggregation/0-input/
