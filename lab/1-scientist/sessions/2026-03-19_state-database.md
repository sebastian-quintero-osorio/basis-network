# Session Log: State Database (RU-L4)

**Date:** 2026-03-19
**Target:** zkl2
**Experiment:** state-database
**Stage:** 1 (Implementation) -- COMPLETE
**Verdict:** HYPOTHESIS CONFIRMED

---

## What Was Accomplished

1. **Literature review** of Go SMT libraries (gnark-crypto, vocdoni/arbo,
   celestiaorg/smt, iden3-go-crypto), MPT vs SMT tradeoffs for EVM state,
   and production zkEVM state DB implementations (Polygon, Scroll, zkSync).

2. **Go prototype** implementing a depth-32 SMT with Poseidon2 hash using
   gnark-crypto's BN254 field arithmetic. Two versions: big.Int-based (for
   algorithm verification) and fr.Element-based (optimized, zero-alloc hot path).

3. **Comprehensive benchmarks** comparing Go vs TypeScript (RU-V1):
   - Poseidon2 hash: 4.46 us/hash (12.6x faster than JS)
   - SMT insert: 125-183 us (10-14x faster)
   - Proof verification: 151 us (11.4x faster)
   - Batch updates: 18.77ms for 100-tx block, 46.05ms for 250-tx block

4. **Updated foundational documents:**
   - zk-01: Added invariants I-13 (state root latency), I-14 (trie isolation),
     I-15 (hash function alignment)
   - zk-02: Added threats T-14 (state root timeout), T-15 (hash mismatch),
     T-16 (deep tree degradation)

## Key Findings

- Go Poseidon2 (gnark-crypto) is 12.6x faster than JavaScript Poseidon (circomlibjs)
- Block-level state root computation passes 50ms target for up to 250 tx/block
- 500+ tx/block fails the target (91ms) -- batch optimization needed at scale
- Poseidon2 (gnark-crypto) produces DIFFERENT hashes than Poseidon (circomlibjs)
  -- Architect must align hash function with prover circuit library
- At depth 160 (EVM addresses), operations are 5x slower than depth 32 --
  compact SMT or batch optimization mandatory for production
- Memory usage is 5-8x more efficient in Go than TypeScript

## Artifacts Produced

| Artifact | Path |
|----------|------|
| hypothesis.json | `zkl2/research/experiments/2026-03-19_state-database/hypothesis.json` |
| state.json | `zkl2/research/experiments/2026-03-19_state-database/state.json` |
| findings.md | `zkl2/research/experiments/2026-03-19_state-database/findings.md` |
| journal.md | `zkl2/research/experiments/2026-03-19_state-database/journal.md` |
| Go SMT (original) | `zkl2/research/experiments/2026-03-19_state-database/code/smt.go` |
| Go SMT (optimized) | `zkl2/research/experiments/2026-03-19_state-database/code/smt_optimized.go` |
| Poseidon2 wrapper | `zkl2/research/experiments/2026-03-19_state-database/code/poseidon.go` |
| Benchmark suite | `zkl2/research/experiments/2026-03-19_state-database/code/benchmark.go` |
| Optimized benchmark | `zkl2/research/experiments/2026-03-19_state-database/code/benchmark_optimized.go` |
| Results JSON | `zkl2/research/experiments/2026-03-19_state-database/results/smt-benchmark-results.json` |
| Optimized results | `zkl2/research/experiments/2026-03-19_state-database/results/optimized-benchmark-results.json` |
| Session memory | `zkl2/research/experiments/2026-03-19_state-database/memory/session.md` |

## Next Steps

- **Logicist (item [10]):** Formalize state DB with EVM account model in TLA+.
  Key invariants: RootConsistency, AccountIntegrity, StorageIsolation.
- **Architect (item [11]):** Implement zkl2/node/statedb/ using vocdoni/arbo
  (circom-compatible) or gnark-crypto (performance-optimized).
- **Prover (item [12]):** Extend RU-V1 Coq proofs for Go model and EVM account structure.
