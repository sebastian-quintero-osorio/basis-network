# Findings: Witness Generation from EVM Execution Traces

## Published Benchmarks

### Production zkEVM Witness/Proof Performance

| System | Batch Size | Proof Time | Hardware | Year | Source |
|--------|-----------|------------|----------|------|--------|
| Polygon zkEVM | 500 tx | ~120s | 224-thread GCP | 2024 | Irreducible/Polygon |
| Polygon zkEVM | 500 tx | 84s | FPGA-accelerated | 2024 | Irreducible/Polygon |
| Polygon 2.0 | various | 40% faster vs baseline | optimized prover | 2025 | Polygon blog |
| Scroll | per block | target < 30s | GPU prover (10x CPU) | 2025 | Scroll roadmap |
| zkSync Era (Boojum) | batch | consumer GPU (16GB VRAM) | STARK-based | 2024 | zkSync docs |

Note: Witness generation is a fraction of total proof time. Polygon's executor + witness
generation runs in seconds; the proving step (MSM, FFT, FRI) dominates total time.

### Constraint Counts per EVM Operation (Literature Consensus)

| Operation | R1CS Constraints | Source |
|-----------|-----------------|--------|
| 256-bit ADD | 200-300 (R1CS) / ~30 (PLONKish) | arxiv:2510.05376, Polygon zkEVM |
| 256-bit MUL | 300-500 (R1CS) / ~50 (PLONKish) | arxiv:2510.05376 |
| SLOAD/SSTORE | ~255 Poseidon ops (Merkle traversal) | Polygon cnt_poseidon_g, RU-L1 |
| KECCAK256 | ~150,000 R1CS constraints | Polygon zkEVM, multiple sources |
| CALL | ~20,000+ R1CS constraints | RU-L1 opcode analysis |
| Poseidon hash (2 inputs) | ~150-200 constraints | Grassi et al. 2021 (USENIX) |
| Byte decomposition | ~33 (PLONKish + lookup) vs ~3233 (R1CS) | arxiv:2510.05376 |

### Proof Sizes and Verification Costs

| System | Proof Size | Verification Gas | Source |
|--------|-----------|-----------------|--------|
| Groth16 (BN254) | ~256 bytes | ~200-250K gas | Production data |
| PLONK (BN254) | ~400-1000 bytes | ~300-500K gas | arxiv:2510.05376 |
| STARK (FRI) | tens of KB | ~6M gas | arxiv:2510.05376 |
| Polygon (STARK->SNARK) | ~256 bytes final | ~350K gas | Polygon docs |

### Field Arithmetic Performance

| Library | Field | Operation | Throughput | Source |
|---------|-------|-----------|-----------|--------|
| gnark-crypto (Go) | BN254 Fr | Poseidon hash | 4.46 us/hash | RU-L4 experiment |
| arkworks (Rust) | BN254 Fr | field mul | ~30% slower than gnark | zk-Bench (IACR 2023/1503) |
| plonky2 (Rust) | Goldilocks (64-bit) | field mul | ~40x faster than BN254 | Plonky2 paper |
| plonky3 (Rust) | Mersenne31 (31-bit) | field mul | faster than Goldilocks | Polygon blog |

## Literature Review

### 1. Production Witness Generation Architectures

**[L01] Polygon zkEVM -- PIL + State Machine Architecture**
- 13 state machines: 1 Main SM + 7 secondary (Binary, Storage, Memory, Arithmetic,
  Keccak, PoseidonG, Padding) + 5 auxiliary
- Executor generates committed polynomials via PIL (Polynomial Identity Language)
- Main SM dispatches "Actions" to secondary SMs
- Witness = committed polynomial values across all SM cycles
- C++ executor; PIL2 in development
- Source: docs.polygon.technology/zkEVM/architecture/zkprover/

**[L02] Scroll -- bus-mapping + Halo2 Multi-Circuit Architecture**
- bus-mapping crate: parses EVM execution traces -> structured witness inputs
- Multiple circuits: EVM Circuit, State Circuit, Bytecode Circuit, Copy Circuit, Keccak Circuit
- ExecutionStep struct: memory, stack, instruction, gas_info, depth, pc, global_counter
- gen_associated_ops() dispatches per-opcode witness generation
- BusMapping acts as data bus between circuits (like hardware bus)
- Rust (halo2), GPU prover 10x faster than CPU
- Source: github.com/scroll-tech/zkevm-circuits, HackerNoon guide

**[L03] zkSync Era -- Boojum Multi-Circuit STARK Architecture**
- Boojum: Rust STARK-based, PLONK-style arithmetization + FRI commitment
- Multiple circuits: MainVM, CodeDecommitter, StorageSorter, EventsSorter, etc.
- Witness generation phases: BasicCircuits -> LeafAggregation -> NodeAggregation -> Scheduler
- 16 GB GPU RAM (down from 80 GB x 100 GPUs in previous system)
- Source: docs.zksync.io, github.com/matter-labs/era-boojum

**[L04] Constraint-Level Design of zkEVMs (Hassanzadeh-Nazarabadi & Taheri-Boshrooyeh, 2025)**
- Comprehensive survey: Polygon, Scroll, zkSync, Linea, Taiko
- Trace tables: T in F_p^(l x k), l = execution steps, k = VM variables
- PLONKish achieves 99x fewer constraints than R1CS for byte decomposition
- Custom gates capture complex EVM opcodes in single constraints
- Dispatch mechanisms: selector-based, ROM-based instruction dispatch
- arxiv:2510.05376

**[L05] Performance Bottlenecks in ZK Rollups (2025)**
- Proof generation time increases superlinearly with batch size
- Per-tx cost decreases with larger batches (economies of scale)
- Power of Tau n=20: system crash due to memory exhaustion
- Primary bottleneck: proving (MSM, FFT), not witness generation
- arxiv:2503.22709

### 2. Witness Format and Data Requirements

**[L06] Witness Table Structure (Consensus Across Implementations)**
All production zkEVMs use a multi-table witness architecture:

| Table | Data Per Entry | Approx Field Elements | Source |
|-------|---------------|----------------------|--------|
| Arithmetic | opcode, operands (a, b), result (c), carry | ~7-10 FE | Polygon Arith SM |
| Storage (SLOAD) | key, value, Merkle siblings (depth d) | 3 + 2d FE | Polygon Storage SM |
| Storage (SSTORE) | key, old_val, new_val, 2 Merkle paths | 5 + 4d FE | Polygon Storage SM |
| Memory | address, value, rw_flag, global_counter | ~5 FE | Scroll Memory Circuit |
| Bytecode | pc, opcode, push_data | ~4 FE | Scroll Bytecode Circuit |
| Call Context | caller, callee, value, gas, depth | ~8 FE | Scroll EVM Circuit |
| Keccak | input_bytes, output_hash | varies (huge) | All implementations |
| Balance | account, old_balance, new_balance | ~5 FE | Extension for completeness |
| Nonce | account, old_nonce, new_nonce | ~3 FE | Extension for completeness |

**[L07] Field Element Representation**
- BN254 scalar field: p ~ 2^254 (254-bit prime)
- EVM word: 256 bits (exceeds field modulus)
- Limb decomposition: split 256-bit value into 2 x 128-bit limbs
- Each limb fits in BN254 Fr (254 bits > 128 bits)
- Alternative: high-low split (hi: upper 128 bits, lo: lower 128 bits)
- Poseidon hash output: 1 field element (native, no decomposition needed)

### 3. Rust ZK Libraries Assessment

**[L08] arkworks (ark-ff, ark-bn254)**
- BN254 field arithmetic (Fr, Fq)
- R1CS constraint system
- Groth16 prover/verifier
- circom-compat: bindings to Circom R1CS/witness
- Mature, well-audited, production-used
- Source: arkworks.rs

**[L09] halo2 (zcash/halo2)**
- PLONKish arithmetization with lookup arguments
- Multi-threaded witness generation (rayon)
- Used by Scroll in production
- halo2-base: circuit tuning, parallel witness generation via multiple Contexts
- Source: github.com/zcash/halo2

**[L10] plonky2/plonky3 (Polygon)**
- Plonky2: Goldilocks field (64-bit), 40x faster than BN254 field arithmetic
- Plonky3: toolkit, supports Mersenne31/Goldilocks/BN254-fr
- FRI-based commitment (STARK-style)
- Plonky2 deprecated in favor of Plonky3
- Source: github.com/Plonky3/Plonky3

**[L11] RISC Zero / SP1 (zkVM approach)**
- SP1: up to 28x faster than circuit-based approaches for certain programs
- RISC Zero: GPU proving, 4x improvement with full GPU pipeline
- zkVM approach: compile Rust to RISC-V, prove execution
- Not directly applicable (we need custom EVM witness), but informs performance targets
- Source: risczero.com, succinct.xyz

### 4. Poseidon Hash Function

**[L12] Poseidon: Hash Function for ZK Proof Systems (Grassi et al., USENIX Security 2021)**
- Algebraic hash over prime field, ~150-200 constraints per 2-input hash
- HADES design: full rounds + partial rounds (S-box on 1 element)
- BN254-native: operates directly on field elements
- ~500x cheaper than Keccak in ZK circuits
- Source: USENIX Security 2021, eprint.iacr.org/2019/458

**[L13] Poseidon2 (Grassi et al., 2023)**
- Improved version: faster outside circuits (better linear layer)
- Same security margin (128-bit)
- Used by gnark-crypto (our State DB)
- Source: eprint.iacr.org/2023/323

### 5. EVM-Specific Witness Challenges

**[L14] KECCAK256 Dominance**
- ~150K R1CS constraints per invocation
- EVM mappings (balanceOf, allowance) use Keccak for slot computation
- Typical ERC20 transfer: 2-4 Keccak invocations
- Mitigation: preimage oracle with lookup tables
- Source: Polygon zkEVM, RU-L1

**[L15] 256-bit Arithmetic in Finite Fields**
- Native EVM word (256 bits) exceeds BN254 field (254 bits)
- Every arithmetic operation needs range checks and limb decomposition
- PLONKish custom gates reduce this to single-constraint operations
- Source: arxiv:2510.05376

**[L16] Storage Proof Explosion**
- Each SLOAD/SSTORE needs full Merkle path (~d siblings at depth d)
- Depth 32: 32 siblings x 2 FE = 64 FE per storage proof
- Depth 160 (EVM address space): 160 siblings = 320+ FE per proof
- Storage operations dominate witness size
- Source: RU-L4 experiment, Polygon Storage SM

### 6. Determinism Requirements

**[L17] Deterministic Witness Generation (I-08)**
- Same trace MUST produce same witness (bit-for-bit)
- HashMap ordering is non-deterministic in Rust -- use BTreeMap
- Floating-point: not used (all field arithmetic is exact)
- Trace processing order: sequential (preserve execution order)
- Global counter ensures consistent ordering across tables
- Source: System invariant I-08, Scroll bus-mapping design

## Witness Size Estimation

### Per-Transaction Estimates (depth-32 SMT)

| Transaction Type | SLOADs | SSTOREs | Arith Ops | Balance Changes | Est. FE |
|-----------------|--------|---------|-----------|-----------------|---------|
| Simple transfer | 0 | 0 | 2 | 2 | ~30 |
| ERC20 transfer | 2 | 2 | 5 | 0 | ~300 |
| Storage write | 0 | 1 | 1 | 0 | ~80 |
| Complex contract | 5 | 3 | 20 | 1 | ~700 |

### Batch Estimates

| Batch Size | Avg FE/tx | Total FE | Est. Size (32B/FE) | Est. Generation Time |
|-----------|-----------|----------|--------------------|--------------------|
| 100 tx | ~200 | ~20,000 | ~640 KB | < 1s (projected) |
| 500 tx | ~200 | ~100,000 | ~3.2 MB | < 5s (projected) |
| 1000 tx | ~200 | ~200,000 | ~6.4 MB | < 15s (projected) |

Projections based on: field element operations are O(1), Merkle path reconstruction
is O(depth), and BTreeMap insertion is O(log n). Witness generation is I/O-bound
(trace parsing + field conversion), not compute-bound.

## Key Design Decisions for Prototype

1. **Multi-table architecture**: Separate tables for arithmetic, storage, memory, call context,
   balance, nonce (following Scroll/Polygon pattern)
2. **BN254 Fr field elements**: Using ark-ff for field arithmetic (matches state DB field)
3. **Limb decomposition**: 256-bit EVM words split into 2 x 128-bit limbs
4. **Deterministic processing**: BTreeMap for all maps, sequential trace processing
5. **Modular design**: One Rust module per witness table category
6. **JSON input**: Consume ExecutionTrace from Go executor via JSON serialization
7. **Flat output**: Witness as vector of field elements per table (PLONK-compatible)

---

## Experimental Results (Stage 1-2: Implementation + Baseline)

### Benchmark Results: Witness Generation Time

| TX Count | Time (ms) | 95% CI (ms) | Total FE | Size (KB) | Arith Rows | Storage Rows | Call Rows |
|----------|-----------|-------------|----------|-----------|------------|-------------|-----------|
| 10 | 0.13 | -- | 964 | 30.1 | 25 | 18 | 1 |
| 50 | 0.66 | -- | 4,820 | 150.6 | 125 | 90 | 5 |
| 100 | 1.28 | +/- 0.02 | 9,640 | 301.2 | 250 | 180 | 10 |
| 250 | 3.20 | -- | 24,100 | 753.1 | 625 | 450 | 25 |
| 500 | 6.35 | +/- 0.18 | 48,200 | 1,506.2 | 1,250 | 900 | 50 |
| 1000 | 13.37 | +/- 0.59 | 96,400 | 3,012.5 | 2,500 | 1,800 | 100 |

Configuration: BN254 Fr (ark-bn254 0.4.0), SMT depth 32, release build, 30 repetitions.

### Hypothesis Evaluation

**Hypothesis**: 1000 tx in < 30 seconds with deterministic output.

**Result: STRONGLY CONFIRMED.**
- 1000 tx: 13.37 ms (2,243x faster than 30-second threshold)
- Determinism: PASS (bit-for-bit identical across runs)
- 95% CI / mean = 4.4% (< 10% threshold)

The hypothesis was conservative. Witness generation is orders of magnitude faster than
the proving step (which dominates at minutes, not milliseconds). This aligns with
literature: Polygon's executor + witness runs in seconds; proving takes 84-120 seconds.

### Scaling Analysis

Witness generation time scales linearly with transaction count:
- 500/100 ratio: 4.96 (expected: 5.0)
- 1000/100 ratio: 10.45 (expected: 10.0)
- Per-transaction cost: ~13.4 us at 1000 tx

Linear scaling is expected because each trace entry is processed independently with
O(1) field conversions and O(depth) sibling generation.

### Per-Table Witness Distribution (1000 tx)

| Table | Rows | Columns | Field Elements | Percentage |
|-------|------|---------|---------------|------------|
| storage | 1,800 | 42 | 75,600 | 78.4% |
| arithmetic | 2,500 | 8 | 20,000 | 20.7% |
| call_context | 100 | 8 | 800 | 0.8% |
| **Total** | **4,400** | -- | **96,400** | **100%** |

**Storage dominates** (78.4%) because each SLOAD/SSTORE requires 32 Merkle siblings
(at depth 32). This matches production observations: Polygon's Storage SM and Scroll's
State Circuit are the largest witness contributors.

### Depth Sensitivity Analysis (100 tx)

| SMT Depth | Time (ms) | Total FE | Size (KB) |
|-----------|-----------|----------|-----------|
| 16 | 1.09 | 6,760 | 211.2 |
| 32 | 1.27 | 9,640 | 301.2 |
| 64 | 1.56 | 15,400 | 481.2 |
| 128 | 2.17 | 26,920 | 841.2 |
| 160 | 2.46 | 32,680 | 1,021.2 |
| 256 | 3.88 | 49,960 | 1,561.2 |

Witness size scales linearly with depth (as expected: each storage op adds `depth`
field elements for siblings). At depth 256 (full EVM storage space), witness generation
for 100 tx is still only 3.88 ms.

**Extrapolation for 1000 tx at depth 256**: ~38.8 ms (still far below 30s threshold).

### Benchmark Validation Against Published Data

| Metric | Our Result | Published Benchmark | Ratio | Status |
|--------|-----------|-------------------|-------|--------|
| Witness gen 1000 tx | 13.37 ms | Polygon executor+witness: seconds | ~100-1000x faster | EXPECTED (we skip trace parsing from RPC) |
| Witness size 1000 tx | 3.0 MB | Polygon: ~2 GB full witness | ~700x smaller | EXPECTED (we have 3 tables vs 13 SMs) |
| Storage % of witness | 78.4% | Polygon/Scroll: ~60-80% | consistent | OK |
| Linear scaling | confirmed | Expected from O(n) design | -- | OK |
| Determinism | PASS | Required by all zkEVMs | -- | OK |

The 100-1000x speed difference vs Polygon is expected:
1. We process pre-structured JSON traces, not raw Geth execution
2. We have 3 tables, not 13 state machines
3. We skip Keccak witness (the most expensive component)
4. We use simulated Merkle siblings (not actual tree traversals)

The 700x size difference is also expected: a full zkEVM witness includes bytecode,
memory, stack, Keccak, and padding tables that we have not yet implemented.

### Threats and Caveats

**T-17: Witness Completeness Gap**
This prototype generates witness for 3 of the ~10+ tables needed for a production zkEVM.
Missing tables: bytecode, memory (MLOAD/MSTORE), stack, Keccak, copy, padding.
Adding these will increase witness size by 3-10x and generation time by similar factors.
Even at 10x, 1000 tx would take ~134 ms (still far below 30s).

**T-18: Simulated vs Real Merkle Siblings**
The prototype uses deterministic pseudo-random siblings. In production, the witness
generator must query the state DB (Go) for actual Merkle proof paths. This adds IPC
latency (gRPC) and I/O cost. Expected overhead: 10-50x for the storage table.

**T-19: JSON Serialization Bottleneck**
JSON parsing of execution traces will be a bottleneck at scale. Production should use
protobuf or flatbuffers (binary serialization). JSON overhead: ~5-10x vs binary.

### Recommendations for Downstream Agents

1. **Logicist (item [14])**: Formalize WitnessExtract(trace) -> witness as a function with
   multi-table output. Invariants: Completeness (all trace entries produce witness rows),
   Soundness (witness rows satisfy circuit constraints), Determinism (I-08).

2. **Architect (item [15])**: Implement in Rust using this prototype as reference.
   Priority additions: bytecode table, memory table, Keccak table, gRPC interface
   to Go state DB for real Merkle siblings. Use `thiserror` for error types.

3. **Performance budget**: Witness generation will be < 1% of total proving time.
   Focus optimization efforts on the prover (MSM, FFT), not the witness generator.
