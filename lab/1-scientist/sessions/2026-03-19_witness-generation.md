# Session Log: RU-L3 Witness Generation

**Date:** 2026-03-19
**Target:** zkl2 (Phase 2: ZK Proving)
**Experiment:** 2026-03-19_witness-generation
**Checklist item:** [13] Scientist | RU-L3: Witness Generation
**Stage reached:** 2 (Implementation + Baseline)

## What Was Accomplished

1. **Literature review** (17 references): Analyzed production witness generation from
   Polygon zkEVM (13 state machines, PIL, C++ executor), Scroll (bus-mapping, halo2),
   and zkSync Era (Boojum, multi-circuit STARK). Reviewed arkworks, halo2, plonky2/3
   libraries. Studied Poseidon hash, AIR/PLONKish arithmetization, and zkEVM constraint
   design (arxiv:2510.05376).

2. **Rust prototype** (6 source files, 750+ lines): Multi-table witness generator using
   ark-bn254 for BN254 field arithmetic. Three tables: arithmetic (balance/nonce),
   storage (SLOAD/SSTORE with Merkle siblings), call_context (CALL operations).
   17 unit tests all pass.

3. **Benchmarks** (30 repetitions per configuration):
   - 1000 tx: 13.37 ms (2,243x under 30s threshold)
   - Linear scaling confirmed (10.45x from 100 to 1000 tx)
   - Determinism verified (bit-for-bit identical across runs)
   - Storage table dominates: 78.4% of witness (Merkle siblings)
   - Depth sensitivity: depth 256 adds ~3x overhead vs depth 32

4. **Foundation updates**: Added 4 new invariants (I-16 through I-19) and 4 new threats
   (T-17 through T-20) to living documents.

## Key Findings

- Witness generation is I/O-bound, not compute-bound. Even at 1000x current prototype
  speed, it would be < 1% of proving time.
- Multi-table architecture is universal across all production zkEVMs.
- Storage operations dominate witness size (78.4%) due to Merkle proof paths.
- BN254 field arithmetic via arkworks is fast (~13.4 us per transaction).
- Hypothesis strongly confirmed: 13.37 ms << 30,000 ms threshold.

## Artifacts Produced

| Artifact | Path |
|----------|------|
| hypothesis.json | zkl2/research/experiments/2026-03-19_witness-generation/hypothesis.json |
| state.json | zkl2/research/experiments/2026-03-19_witness-generation/state.json |
| journal.md | zkl2/research/experiments/2026-03-19_witness-generation/journal.md |
| findings.md | zkl2/research/experiments/2026-03-19_witness-generation/findings.md |
| Rust code | zkl2/research/experiments/2026-03-19_witness-generation/code/ |
| Benchmark results | zkl2/research/experiments/2026-03-19_witness-generation/results/ |
| Session memory | zkl2/research/experiments/2026-03-19_witness-generation/memory/session.md |
| Invariants update | zkl2/research/foundations/zk-01-objectives-and-invariants.md |
| Threat model update | zkl2/research/foundations/zk-02-threat-model.md |

## Next Steps

1. **Logicist (item [14])**: Formalize witness generation in TLA+ with invariants
   Completeness, Soundness, Determinism. Model multi-table dispatch and global counter.
2. **Architect (item [15])**: Production Rust implementation with gRPC interface to Go
   state DB, additional tables (bytecode, memory, Keccak), error handling via thiserror.
3. **Future experiment**: Add Keccak witness table and measure impact on total witness
   size. Estimate constraint count for full zkEVM circuit.
