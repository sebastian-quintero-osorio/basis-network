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
| 2026-03-19 | sequencer (RU-L2) | zkl2 | CONFIRMED | 0.14ms@500tx, 2.8M tx/s insert, 100% FIFO, 100% forced inclusion |
| 2026-03-19 | state-database (RU-L4) | zkl2 | CONFIRMED | Poseidon2 4.46us/hash, 125us insert, 18.77ms@100tx batch, 46ms@250tx |
| 2026-03-19 | witness-generation (RU-L3) | zkl2 | CONFIRMED | 13.37ms@1000tx, 3.0MB witness, 78.4% storage, determinism PASS |
| 2026-03-19 | e2e-pipeline (RU-L6) | zkl2 | CONFIRMED | 14s@100tx E2E, prove=71.3% bottleneck, 100% retry reliability |
| 2026-03-19 | production-dac (RU-L8) | zkl2 | CONFIRMED | 4.5ms@500KB attest, 1.40x storage, <1ms recovery, 7.5 nines@p=0.999 |
| 2026-03-19 | plonk-migration (RU-L9) | zkl2 | CONFIRMED | halo2-KZG selected, 672-800B proof, 290-420K gas, 1.2x prove@500step |

## Key Patterns

- circomlibjs Poseidon (v0.1.7): ~56 us/hash in Node.js v22 (BN128 field, BigInt)
- Poseidon is 4.97x faster than MiMC in native JavaScript
- JavaScript BigInt field arithmetic is ~950x slower than native Rust implementations
- In-memory Map storage: ~160 bytes/node overhead in V8, ~17 nodes per SMT entry
- Depth-32 Merkle path (32 sequential Poseidon hashes): ~1.7ms in JS

## E2E Pipeline Patterns (zkL2)

- Proof generation is 71.3% of E2E latency; execute+witness combined <0.2%
- Enterprise circuits: ~500 constraints/tx (4-5x simpler than full zkEVM)
- Max batch under 5min: 5,791 tx (default), 2,761 tx (pessimistic)
- Pipeline parallelism (concurrency=2): 2.42x speedup, near-100% prover utilization
- JSON IPC sufficient for Go-Rust boundary when computation >> serialization
- Exponential backoff (5 retries, 1s-30s): 100% reliability at 30% failure rate
- push0 architecture: stateless dispatchers, persistent queues, partition-affine routing
- L1 submission: 4s for 3 Avalanche txs (commit+prove+execute), 287K gas total

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

## Production DAC Patterns (zkL2)

- Hybrid AES+RS+Shamir: AES-256-GCM for data, RS (5,7) for redundancy, Shamir (5,7) for key
- klauspost/reedsolomon: SIMD-optimized Go RS, used by MinIO/Storj/CockroachDB, ~8 GB/s
- Attestation: 4.5ms@500KB, 8.9ms@1MB in Go (36x faster than JS BigInt Shamir)
- Storage: 1.40x overhead (RS) vs 3.87x (Shamir) -- 2.77x improvement
- Recovery: <1ms at 1MB (RS decode) vs 2.5s (Lagrange) -- 2,600x faster
- AES key must be reduced mod BN254 prime before Shamir (32 bytes > 254-bit field)
- Availability (5,7): 99.997% at p=0.99, 99.99999% at p=0.999
- Honest minority: 3 honest nodes block false attestation (7-5+1=3)
- AnyTrust fallback: on-chain DA when <5 nodes available

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

## EVM Execution Patterns (zkL2)

- Import Geth as Go module (Strategy A) over forking (Strategy B) -- op-geth changed only 34 EVM lines
- core/tracing hooks API for ZK trace generation: OnStorageChange, OnBalanceChange, OnNonceChange, OnLog
- Selective tracing (state changes only) = 10-30% overhead; full opcode trace = 40-70% overhead
- KECCAK256 = ~150K R1CS constraints (1000x Poseidon) -- use preimage oracle with lookup table
- SLOAD/SSTORE = 255 Poseidon ops in Polygon zkEVM -- dominates proving cost for state-heavy contracts
- No production zkEVM proves execution inline -- all separate execution layer from proving layer
- Scroll moving from custom zktrie to MPT + OpenVM (2025) -- validates Strategy A (interface, not fork)

## Sequencer Patterns (zkL2)

- Single-operator sequencer is standard (zkSync, Polygon, Scroll, Arbitrum all centralized)
- Block production is NOT the bottleneck: 0.14ms at 500 tx/block, 0.89ms at 5000 tx/block
- Mempool insert: 2.8M tx/s (365 ns/op), 168 bytes/insert in Go
- FIFO ordering is trivial for single-operator: 100% accuracy, no complex fair ordering needed
- Arbitrum DelayedInbox = gold standard for forced inclusion: FIFO queue, can't skip front
- Forced inclusion deadlines: Arbitrum 24h, Polygon CDK 5 days, OP Stack 12h
- Block lifecycle: pending -> sealed -> committed -> proved -> finalized
- Go 1.22.10 installed at /c/Users/BASSEE/go-sdk/go/ (zip extraction, not MSI)

## State Database Patterns (zkL2)

- gnark-crypto Poseidon2: 4.46 us/hash in Go (12.6x faster than JS circomlibjs)
- Poseidon2 (gnark-crypto) != Poseidon (circomlibjs) -- different hash values, MUST align with prover
- Go SMT insert: 125-183 us at depth 32 (10-14x faster than TypeScript)
- Batch update cost is linear: ~183 us/update regardless of tree size or batch size
- Depth scaling is linear: depth-160 operations are 5x slower than depth-32
- At depth 32: 100-tx block = 18.77ms, 250-tx block = 46.05ms (both < 50ms target)
- At depth 160 (EVM addresses): 100-tx block = ~94ms (FAILS 50ms) -- need compact SMT
- vocdoni/arbo: best Go SMT library with circom-compatible Poseidon (production: Vocdoni)
- gnark-crypto: best for Poseidon2 performance (assembly-optimized BN254 field ops)
- Memory: ~2.9 KB/entry at depth 32, persistent storage needed for >100K entries
- Two-level trie for EVM: AccountTrie (address -> accountHash) + StorageTrie per contract

## Witness Generation Patterns (zkL2)

- Multi-table architecture is universal: Polygon (13 SMs), Scroll (bus-mapping), zkSync (Boojum)
- Witness gen is I/O-bound (field conversions, Merkle retrieval), NOT compute-bound
- Storage table dominates witness: 78.4% at depth 32 (Merkle siblings per SLOAD/SSTORE)
- BN254 Fr via ark-bn254: 13.37 ms for 1000 tx witness generation (Rust, release)
- 256-bit EVM word: split into 2 x 128-bit limbs (both fit in 254-bit Fr)
- Determinism: BTreeMap, sequential processing, no HashMap, no floating-point
- Witness gen is < 0.01% of total proving time -- optimize prover, not witness gen
- Depth sensitivity: linear (depth 256 = ~3x vs depth 32 for time and size)
- Production witness sizes: Polygon ~2 GB (full), our prototype ~3 MB (3 tables of ~10)

## PLONK Migration Patterns (zkL2)

- halo2-KZG (Axiom fork) is the selected proof system for Basis Network zkEVM L2
- plonky2 eliminated: proof size 43-130KB, Goldilocks field incompatible with BN254, DEPRECATED
- halo2-IPA eliminated: Pallas/Vesta curves have no EVM precompile support
- halo2-KZG proving time overhead: 4.7x at 10 steps, converges to 1.2x at 500 steps
- halo2-KZG proof size: 672-800 bytes (< 1KB target)
- halo2-KZG verification gas: 290-420K (< 500K target; Axiom production: 420K)
- Groth16 proof size: 128 bytes (constant, smallest SNARK)
- Groth16 verification gas: ~220K (207K + 7.16K per public input)
- FFLONK (Polygon): ~200K gas (cheapest, but requires specialized implementation)
- Custom gate row reduction: 2.4x for x^5 gate, projected 17x for full Poseidon
- R1CS to PLONKish naive transpilation: 2.35x constraint inflation; benefit is from NATIVE custom gates
- PLONKish additions are NOT free (unlike R1CS); 50-70% of gates in hash circuits
- PSE halo2 fork is in maintenance mode (Jan 2025); use Axiom fork for active development
- Universal SRS: PSE perpetual-powers-of-tau (71+ participants), k=20 for enterprise circuits
- Scroll migrating from halo2 to OpenVM (RISC-V zkVM); does NOT invalidate halo2 for enterprise
- Every production zkEVM uses PLONKish arithmetization (not R1CS)
- Every production zkEVM verifies on L1 via KZG-based SNARK (Groth16/PLONK/FFLONK)

## Experiment Index

1. `validium/research/experiments/2026-03-18_sparse-merkle-tree/` -- RU-V1, Stage 2 complete
2. `validium/research/experiments/2026-03-18_state-transition-circuit/` -- RU-V2, Stage 2 complete
3. `validium/research/experiments/2026-03-18_batch-aggregation/` -- RU-V4, Stage 2 complete
4. `validium/research/experiments/2026-03-18_data-availability-committee/` -- RU-V6, Stage 2 complete
5. `validium/research/experiments/2026-03-18_state-commitment/` -- RU-V3, Stage 1 complete
6. `validium/research/experiments/2026-03-18_enterprise-node/` -- RU-V5, Stage 1 complete
7. `validium/research/experiments/2026-03-18_cross-enterprise/` -- RU-V7, Stage 1 complete
8. `zkl2/research/experiments/2026-03-19_evm-executor/` -- RU-L1, Stage 1 (benchmarks pending Go)
9. `zkl2/research/experiments/2026-03-19_sequencer/` -- RU-L2, Stage 1 complete, CONFIRMED
10. `zkl2/research/experiments/2026-03-19_state-database/` -- RU-L4, Stage 1 complete, CONFIRMED
11. `zkl2/research/experiments/2026-03-19_witness-generation/` -- RU-L3, Stage 2 complete, CONFIRMED
12. `zkl2/research/experiments/2026-03-19_e2e-pipeline/` -- RU-L6, Stage 2 complete, CONFIRMED
13. `zkl2/research/experiments/2026-03-19_production-dac/` -- RU-L8, Stage 1 complete, CONFIRMED
14. `zkl2/research/experiments/2026-03-19_plonk-migration/` -- RU-L9, Stage 1 complete, CONFIRMED
