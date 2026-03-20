# Research Unit: PLONK Migration (RU-L9)

> Target: zkl2 | Domain: zk-proofs | Date: 2026-03-19

## Context

This unit formalizes the migration from Groth16 to halo2-KZG (PLONK) for the Basis Network
zkEVM L2 prover system. The Scientist (RU-L9) has confirmed via literature review (31 sources)
and benchmarking that halo2-KZG meets all performance targets.

## Objective

Formally verify that the migration protocol preserves proof system invariants (Soundness,
Completeness, Zero-Knowledge) and that the dual verification transition period introduces
no verification gaps.

## Input Materials

| File | Description |
|------|-------------|
| `REPORT.md` | Full research findings: literature review, benchmarks, architecture decision |
| `analysis.md` | Benchmark analysis: Groth16 vs halo2-KZG performance comparison |
| `benchmark_results.json` | Raw benchmark data (30 iterations, 14 configurations) |

## Properties to Verify

1. **MigrationSafety**: No batch goes unverified during the migration period
2. **BackwardCompatibility**: Groth16 proofs remain verifiable during dual verification
3. **Soundness**: Changing proof system does not introduce false positive verifications
4. **Completeness**: Valid proofs are accepted by both verifiers during dual period
5. **DualPeriodTermination** (liveness): The dual verification period eventually terminates

## Upstream

- Scientist: RU-L9 (PLONK Migration research, halo2-KZG selected)
- Prior spec: RU-L4 (Basis Rollup), RU-L8 (Production DAC)

## Downstream

- Architect: Item [35] -- Implement halo2-KZG prover in zkl2/prover/
- Prover: Item [36] -- Coq verification of soundness preservation
