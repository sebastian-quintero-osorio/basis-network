# Research Unit: Proof Aggregation (RU-L10)

> Target: zkl2 | Domain: zk-proofs | Date: 2026-03-19

## Context

This unit formalizes the Scientist's research on recursive proof composition
and aggregation for the Basis Network multi-enterprise zkEVM L2.

## Hypothesis

Recursive proof composition can aggregate proofs from N enterprise batches
into a single proof verifiable on L1, reducing per-enterprise verification
gas by N-fold while maintaining soundness guarantees.

## Source Materials

| File | Description |
|------|-------------|
| `REPORT.md` | Complete research findings (27 sources, experimental results) |
| `benchmark_results.json` | Raw benchmark data (30 iterations, 4 strategies, N=1..16) |

## Key Findings

- **Hypothesis CONFIRMED**: 15.3x gas reduction at N=8 with ProtoGalaxy folding + Groth16 decider
- Primary architecture: ProtoGalaxy + CycleFold + Groth16 decider (220K gas)
- Fallback: Binary tree accumulation via halo2 snark-verifier (420K gas)
- All measurements within published benchmark ranges

## Invariants to Formalize

1. **AggregationSoundness**: Aggregated proof valid iff ALL components valid
2. **IndependencePreservation**: One enterprise's failure does not affect others
3. **OrderIndependence**: Aggregation result independent of input order
4. **GasMonotonicity**: Per-enterprise cost decreases with N
