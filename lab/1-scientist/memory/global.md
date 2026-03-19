# Global Memory -- Cross-Experiment Patterns

> Keep under 100 lines. Index of key learnings across all experiments.

## Completed Experiments

| Date | Experiment | Target | Verdict | Key Metric |
|------|-----------|--------|---------|------------|
| 2026-03-18 | sparse-merkle-tree (RU-V1) | validium | CONFIRMED | Insert 1.8ms, Proof gen 0.02ms, Verify 1.7ms |
| 2026-03-18 | state-transition-circuit (RU-V2) | validium | PARTIAL REJECT | 100K constraints infeasible; 60s proving OK with rapidsnark |
| 2026-03-18 | batch-aggregation (RU-V4) | validium | CONFIRMED | 274K tx/min, <0.02ms batch latency, 0 tx loss, 450/450 determinism |
| 2026-03-18 | data-availability-committee (RU-V6) | validium | CONFIRMED | Attestation 163ms@500KB, 320ms@1MB, 51/51 privacy, 61/61 recovery |
| 2026-03-18 | state-commitment (RU-V3) | validium | CONFIRMED | 285,756 gas (Layout A), 32 bytes/batch, 7/7 invariant tests |
| 2026-03-18 | enterprise-node (RU-V5) | validium | PARTIAL CONFIRM | Overhead 593ms (0.66% of 90s), E2E 14.6s (b64 rapidsnark), 46/46 SM tests |
| 2026-03-18 | cross-enterprise (RU-V7) | validium | CONFIRMED | 1.41x overhead (seq), 0.64x (batched), 68,868 constraints, 4/4 privacy |

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
- circom compiler needs `-l` flag for library includes (not absolute paths in circuit files)
- snarkjs proving time: ~65 us/constraint on commodity desktop -- too slow for >500K constraints in <60s
- Powers of Tau ceremony is the bottleneck for setup (not proving) -- precompute and reuse
- Windows unlinkSync can fail with EBUSY on recently-written files -- use writeFileSync("") instead
- WAL fsync on Windows NTFS may not guarantee true durability -- benchmark on Linux for production numbers
- TIME-only batch strategy fails under burst arrivals -- always use HYBRID

## Circuit Design Patterns

- Constraint formula for state transitions: `1,038 * (depth + 1) * batchSize`
- Groth16 proof size: ~805 bytes (constant regardless of circuit complexity)
- Verification time: ~2s (constant, dominated by pairing check)
- Use MerklePathVerifier(depth) + Poseidon(2) + Mux1 per level for Merkle proofs
- Root chaining: newRoot[i] = oldRoot[i+1] for batch consistency

## Batch Aggregation Patterns

- HYBRID batch strategy (size OR time) is universal across production ZK-rollups
- WAL JSON-lines append: ~149-210 us/entry (includes SHA-256 checksum)
- Batch formation is sub-0.02ms -- negligible vs proof generation (5.8-12.8s)
- Checkpoint-based crash recovery: replay WAL entries after last checkpoint seq
- Determinism: BatchID = SHA-256(sorted tx hashes), FIFO order by (timestamp, seq)

## Data Availability Patterns

- Shamir (2,3)-SS share gen: ~9.5 us/element in JS BigInt, linear scaling, ~3.87x storage
- NO production DAC provides privacy -- Basis Network SSS approach is a genuine innovation
- ECDSA multi-sig sufficient for 3-node DAC; BLS only needed at >10 members
- Recovery time scales O(k^2): 2-of-3 is 8x faster than 3-of-3 for Lagrange interpolation
- AnyTrust fallback: post data on-chain if <k nodes available (validium -> rollup mode)
- Field element packing: 31 bytes/element (not 32) to stay within 254-bit BN128 field

## L1 State Commitment Patterns

- Integrated ZK verification saves ~56K gas vs delegated (cross-contract call)
- SSTORE 0->nonzero = 22,100 gas. This is the dominant per-batch storage cost
- ZK verification (Groth16, 4 inputs) = 205,600 gas = 72% of total submission cost
- Cold vs warm: first batch costs ~17K more than steady-state due to cold SLOAD/SSTORE
- Event logs are ~10x cheaper than storage: 8 gas/byte vs 22,100 gas/32 bytes
- Production rollups (zkSync, Polygon, Scroll): 64-96 bytes/batch; our Layout A: 32 bytes
- Single-phase submission (no commit-then-prove) works for enterprise validium
- prevRoot == currentRoot check is sufficient for gap detection + reversal prevention

## Node Orchestrator Patterns

- Pipelined architecture (3 concurrent loops) is standard: Polygon, zkSync, Scroll, push0
- Orchestration overhead is negligible: 593ms (0.66% of 90s budget) per batch
- Proving is the sole bottleneck: 85%+ of E2E latency
- Pipeline speedup increases with batch size: 1.29x at b64 (vs 1.04x at b8)
- push0 (Zircuit, March 2025): 5ms orchestration, 0.5s MTTR, 0 task loss in production
- Fastify > Express for API layer: 2-4x throughput, native TypeScript, JSON schema validation
- Single-writer SMT model prevents race conditions in pipelined architecture
- Child process for prover isolation: prevents event loop blocking during proving
- Checkpoint strategy: after each L1 submission + periodic + on graceful shutdown

## Cross-Enterprise Verification Patterns

- Sequential approach: 1.41x overhead at 2 enterprises, scales to 1.81x at 50
- Batched Pairing: 0.64x at 2 enterprises (shared pairing saves 2x per additional proof)
- Hub Aggregation (Nebra UPA): 1.16x at 2 enterprises, efficient at scale (0.47x at 50)
- Cross-ref circuit: 68,868 constraints = 2 * Merkle path (depth 32) + Poseidon-4 commitment
- Privacy: 1 bit leakage per interaction (existence only), Poseidon preimage resistance
- Dense interactions (interactions > enterprises) break Sequential; always use Batched
- Groth16 sufficient for MVP; PLONK + StarkPack for heterogeneous future aggregation

## Experiment Index

1. `validium/research/experiments/2026-03-18_sparse-merkle-tree/` -- RU-V1, Stage 2 complete
2. `validium/research/experiments/2026-03-18_state-transition-circuit/` -- RU-V2, Stage 2 complete
3. `validium/research/experiments/2026-03-18_batch-aggregation/` -- RU-V4, Stage 2 complete
4. `validium/research/experiments/2026-03-18_data-availability-committee/` -- RU-V6, Stage 2 complete
5. `validium/research/experiments/2026-03-18_state-commitment/` -- RU-V3, Stage 1 complete
6. `validium/research/experiments/2026-03-18_enterprise-node/` -- RU-V5, Stage 1 complete
7. `validium/research/experiments/2026-03-18_cross-enterprise/` -- RU-V7, Stage 1 complete
