# Session Log: Sparse Merkle Tree with Poseidon Hash

**Date**: 2026-03-18
**Target**: validium (MVP)
**Experiment**: RU-V1 -- Sparse Merkle Tree with Poseidon Hash
**Stage**: 1 (Implementation) -- COMPLETE

## What Was Accomplished

1. Created full experiment structure in `validium/research/experiments/2026-03-18_sparse-merkle-tree/`
2. Conducted literature review: 18 papers and production references covering Poseidon hash,
   MiMC, Sparse Merkle Trees, and production deployments (Polygon zkEVM, Semaphore, Iden3, Scroll)
3. Implemented depth-32 SparseMerkleTree class with circomlibjs Poseidon in TypeScript
4. Ran hash comparison benchmark: Poseidon vs MiMC (1,000 hashes each with 100 warmup)
5. Ran SMT benchmark at 100, 1,000, 10,000, and 100,000 entries (50 measurement reps each)
6. Updated foundation documents with 5 new state management invariants and 4 new attack vectors

## Key Findings

- **Poseidon is 4.97x faster than MiMC** in native JavaScript (56 us vs 279 us per hash)
- **Insert latency is constant at ~1.8ms** regardless of tree size (O(depth) confirmed)
- **Proof generation is extremely fast** at 0.018ms (just a tree traversal, no hashing)
- **Proof verification at ~1.7ms** is the tightest margin (P95 = 1.87ms vs 2ms target)
- **All hypothesis targets PASS** with margin at 100K entries
- Memory at 100K entries: 234 MB (well within 2GB limit)

## Artifacts Produced

| Artifact | Path |
|----------|------|
| hypothesis.json | `validium/research/experiments/2026-03-18_sparse-merkle-tree/hypothesis.json` |
| state.json | `validium/research/experiments/2026-03-18_sparse-merkle-tree/state.json` |
| journal.md | `validium/research/experiments/2026-03-18_sparse-merkle-tree/journal.md` |
| findings.md | `validium/research/experiments/2026-03-18_sparse-merkle-tree/findings.md` |
| smt-implementation.ts | `validium/research/experiments/2026-03-18_sparse-merkle-tree/code/smt-implementation.ts` |
| smt-benchmark.ts | `validium/research/experiments/2026-03-18_sparse-merkle-tree/code/smt-benchmark.ts` |
| hash-comparison.ts | `validium/research/experiments/2026-03-18_sparse-merkle-tree/code/hash-comparison.ts` |
| smt-benchmark-results.json | `validium/research/experiments/2026-03-18_sparse-merkle-tree/results/smt-benchmark-results.json` |
| hash-comparison-results.json | `validium/research/experiments/2026-03-18_sparse-merkle-tree/results/hash-comparison-results.json` |
| Updated invariants | `validium/research/foundations/zk-01-objectives-and-invariants.md` |
| Updated threat model | `validium/research/foundations/zk-02-threat-model.md` |

## Decisions Made

1. **Poseidon over MiMC**: 4.97x faster in JS, 42% fewer R1CS constraints, production-proven
2. **Depth 32**: 2^32 slots sufficient for enterprise; deeper would add unnecessary constraint cost
3. **Binary tree over quinary**: Simpler, better R1CS fit, only 9% more constraints than quinary
4. **Custom implementation over @iden3/js-merkletree**: Full control over performance and BN128 field ops
5. **Key derivation via bit extraction**: Lower 32 bits of key for leaf index (uniform distribution)

## Next Steps

- **Stage 2 (Baseline)**: Add stochastic baseline with CI < 10% of mean, test 2+ scenarios
  (sequential vs random keys), 30+ reps per config
- **Downstream**: This experiment's findings.md is ready for The Logicist to formalize as
  TLA+ specification (ROADMAP_CHECKLIST item 02)
- **Production path**: Architect should use this SMT class as reference for
  `validium/node/src/state/sparse-merkle-tree.ts`, with LevelDB backing for persistence
