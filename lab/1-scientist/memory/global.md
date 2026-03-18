# Global Memory -- Cross-Experiment Patterns

> Keep under 100 lines. Index of key learnings across all experiments.

## Completed Experiments

| Date | Experiment | Target | Verdict | Key Metric |
|------|-----------|--------|---------|------------|
| 2026-03-18 | sparse-merkle-tree (RU-V1) | validium | CONFIRMED | Insert 1.8ms, Proof gen 0.02ms, Verify 1.7ms |

## Key Patterns

- circomlibjs Poseidon (v0.1.7): ~56 us/hash in Node.js v22 (BN128 field, BigInt)
- Poseidon is 4.97x faster than MiMC in native JavaScript
- JavaScript BigInt field arithmetic is ~950x slower than native Rust implementations
- In-memory Map storage: ~160 bytes/node overhead in V8, ~17 nodes per SMT entry
- Depth-32 Merkle path (32 sequential Poseidon hashes): ~1.7ms in JS

## Known Pitfalls

- circomlibjs 0.0.8 is 6x slower than 0.1.7 -- always use 0.1.7+
- Memory grows ~17 nodes per SMT entry -- at >100K entries, consider LevelDB backing
- Proof verification is the tightest perf target (P95=1.87ms vs 2ms target)
- V8 GC can cause misleading memory readings between benchmark runs -- use fresh process per measurement

## Experiment Index

1. `validium/research/experiments/2026-03-18_sparse-merkle-tree/` -- RU-V1, Stage 1 complete
