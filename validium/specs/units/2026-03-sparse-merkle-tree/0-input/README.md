# RU-V1: Sparse Merkle Tree with Poseidon Hash -- Logicist Input

## Context

This unit contains the experimental results from the Scientist's investigation of Sparse
Merkle Trees with Poseidon hash for the Basis Network enterprise ZK validium node.

The SMT is the foundational data structure for all state management in the validium system.
Every subsequent research unit (RU-V2 through RU-V7) depends on this component.

## Hypothesis (CONFIRMED)

A Sparse Merkle Tree of depth 32 with Poseidon hash can support 100,000+ entries with
insert latency < 10ms, proof generation < 5ms, and verification < 2ms in TypeScript,
maintaining BN128 field compatibility for Circom circuits.

## Key Results

| Metric | Target | Measured (100K entries) | Status |
|--------|--------|----------------------|--------|
| Insert latency | < 10 ms | 1.825 ms (P95: 2.014 ms) | PASS |
| Proof generation | < 5 ms | 0.018 ms (P95: 0.021 ms) | PASS |
| Proof verification | < 2 ms | 1.744 ms (P95: 1.869 ms) | PASS |
| BN128 compatibility | Full | All operations use BN128 field | PASS |

## Objectives for Formalization

The Logicist must formalize:

1. **Operations**: Insert, Update, Delete, GetProof, VerifyProof
2. **Invariants**:
   - ConsistencyInvariant: root always reflects actual tree content
   - SoundnessInvariant: invalid proof is never accepted
   - CompletenessInvariant: existing entry always has a valid proof
3. **Model check**: Tree depth 4, 8 entries (finite but sufficient to expose bugs)

## Materials

- `REPORT.md` -- Full findings with literature review (18 references)
- `code/smt-implementation.ts` -- Working SMT implementation (reference)
- `code/smt-benchmark.ts` -- Benchmark suite
- `code/hash-comparison.ts` -- Hash function comparison
- `results/smt-benchmark-results.json` -- SMT performance data
- `results/hash-comparison-results.json` -- Hash comparison data
