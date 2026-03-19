# Experiment Journal: Witness Generation from EVM Execution Traces

## 2026-03-19 -- Experiment Creation

**Target:** zkl2 (Phase 2: ZK Proving, RU-L3)
**Checklist item:** [13] Scientist | RU-L3: Witness Generation

### Context

Phase 1 is complete. We have:
- EVM Executor (Go): produces ExecutionTrace with TraceEntry (SLOAD, SSTORE, CALL, BALANCE_CHANGE, NONCE_CHANGE, LOG)
- State Database (Go): Poseidon2 SMT over BN254 scalar field (gnark-crypto), two-level trie
- Sequencer (Go): FIFO mempool, forced inclusion, 1-second blocks

The witness generator bridges the Go executor and the Rust ZK prover.
It must consume execution traces and produce structured witness data (field element vectors)
that the PLONK circuit (RU-L9, future) will use.

### Design Decisions Informing This Experiment

- TD-002: Rust for ZK Prover (no GC pauses during proof generation)
- TD-003: PLONK as target proof system (universal SRS, custom gates, lookup tables)
- TD-008: Poseidon hash for state tree (BN254 scalar field)
- I-08: Trace-Witness Bijection (deterministic mapping, no information loss)

### What Would Change My Mind

- If witness generation for 1000 tx takes > 60 seconds in Rust, the multi-table architecture
  may need to be simplified or the trace format redesigned.
- If memory usage exceeds 4 GB for 1000 tx, streaming/incremental witness generation is needed.
- If determinism requires sorted containers everywhere, the performance overhead may push us
  toward a different trace format.

## 2026-03-19 -- Stage 1-2 Complete (Implementation + Baseline)

### Literature Review (17 references)

Reviewed production witness generation architectures from Polygon zkEVM (13 state machines,
PIL, C++ executor), Scroll (bus-mapping crate, halo2 circuits, Rust), and zkSync Era
(Boojum, STARK-based, multi-circuit Rust). All use multi-table architecture where each
table corresponds to an EVM operation category.

Key insight: witness generation is I/O-bound (trace parsing, field conversion), not
compute-bound. The proving step (MSM, FFT, FRI) dominates total time by 100-1000x.

### Prototype Implementation

Built Rust witness generator with:
- 3 witness tables: arithmetic, storage, call_context
- BN254 Fr field arithmetic via ark-bn254 0.4.0
- Deterministic processing (BTreeMap, sequential, no randomness)
- 256-bit limb decomposition (hi/lo 128-bit split)
- Simulated Merkle siblings (deterministic PRNG from slot hash)
- 17 unit tests (all pass)

### Benchmark Results

1000 tx witness generation: **13.37 ms** (2,243x under 30s threshold).
- Scaling: linear (10.45x from 100 to 1000 tx)
- Determinism: PASS (bit-for-bit identical across runs)
- 95% CI: 4.4% of mean (n=30)
- Witness size: 3.0 MB (96,400 field elements)
- Storage table dominates: 78.4% of total witness

### What Would Change My Mind (Updated)

- If adding real Merkle proof retrieval via gRPC adds > 100x overhead, we may need
  to batch DB queries or cache siblings.
- If Keccak witness table adds > 50x to total witness size, preimage oracle with
  lookup tables becomes mandatory (not optional).
- Results are so far under threshold that even 1000x overhead from missing components
  would still pass. The hypothesis is strongly confirmed.
