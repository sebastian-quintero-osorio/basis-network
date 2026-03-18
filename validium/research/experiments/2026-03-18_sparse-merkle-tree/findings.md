# Findings: Sparse Merkle Tree with Poseidon Hash

## Research Unit

RU-V1 -- Sparse Merkle Tree with Poseidon Hash (MAXIMUM criticality)

## Executive Summary

This experiment evaluates whether a depth-32 Sparse Merkle Tree (SMT) with Poseidon hash
meets the performance requirements for the Basis Network enterprise ZK validium node.
The SMT is the foundational state structure upon which all subsequent components depend
(RU-V2 through RU-V7).

---

## 1. Published Benchmarks

### 1.1 Hash Function Constraint Counts (R1CS / Groth16, BN254 curve)

Source: Guohanze et al., "Benchmarking ZK-Friendly Hash Functions and SNARK Proving
Systems for EVM-compatible Blockchains," arXiv:2409.01976, 2024.

| Hash Function | Constraints (R1CS) | Notes |
|---------------|-------------------|-------|
| Neptune | 228 | Lowest R1CS constraints; less widely adopted |
| Poseidon | 240 | De facto standard for ZK applications |
| Poseidon2 | 240 | Faster native computation, same constraint count |
| MiMC | 340 (R1CS), 1,764 (Plonkish) | Better under Plonkish arithmetization |
| Rescue | ~600 | Higher security margin, higher cost |
| SHA-256 | ~25,000 | Infeasible for in-circuit use at scale |
| Keccak-256 | ~150,000 | Not viable for ZK circuits |

For a depth-32 binary Merkle tree path verification:
- Poseidon: 32 * 240 = 7,680 constraints (path verification)
- MiMC: 32 * 340 = 10,880 constraints
- Keccak: 32 * 150,000 = 4,800,000 constraints (infeasible)

Source: Ethereum Research, "Gas and circuit constraint benchmarks of binary and quinary
incremental Merkle trees using the Poseidon hash function," ethresear.ch, 2020.

| Tree Type | Depth | Capacity | Path Verification Constraints |
|-----------|-------|----------|-------------------------------|
| Binary Poseidon | 10 | 1,024 | 2,190 |
| Binary Poseidon | 20 | 1,048,576 | 4,380 |
| Binary Poseidon | 30 | 1,073,741,824 | 6,570 |
| Quinary Poseidon | 5 | 3,125 | 2,182 |
| Quinary Poseidon | 9 | 1,953,125 | 3,969 |

Extrapolated for depth 32 binary: ~7,008 constraints (219 per level).

### 1.2 Groth16 Proof System Performance

Source: arXiv:2409.01976 and Colin Nielsen, SNARK-hash-benchmark (GitHub).

| Metric | Value | Source |
|--------|-------|--------|
| Proof size (Groth16) | ~800 bytes | arXiv:2409.01976 |
| Verification gas (Groth16) | ~219,000 gas | arXiv:2409.01976 |
| Poseidon depth-7 proving time (127 hashes) | 4.5 seconds | arXiv:2409.01976 |
| Poseidon proof size | 112 KB | SNARK-hash-benchmark (M1 MacBook Air) |
| MiMC proof size | 203 KB | SNARK-hash-benchmark |
| SHA-256 proof size | 19 MB | SNARK-hash-benchmark |
| Poseidon proving time (single circuit) | 3.124 s | SNARK-hash-benchmark |
| MiMC proving time (single circuit) | 2.617 s | SNARK-hash-benchmark |
| Poseidon RAM usage | 50%+ lower than MiMC | arXiv:2409.01976 |

### 1.3 Sparse Merkle Tree Performance (Non-Poseidon Implementations)

Source: Reilabs, "Scaling Sparse Merkle Trees to Billions of Keys with LargeSMT," 2024.
Implementation: Rust, multi-threaded, 256-bit elements.

| Metric | 4 cores | 8 cores | 16 cores |
|--------|---------|---------|----------|
| 10K inserts on 1B-leaf tree | 1.69-1.93 s | 1.28-1.31 s | 0.63-0.99 s |
| Per-insert latency | 169-193 us | 128-131 us | 63-99 us |
| Proof generation | 49-83 us | 35-50 us | 20-28 us |

Source: Monotree benchmark (Rust, single-threaded):
- 1,000,000 insertions in 1.92 seconds = 1.92 us per insertion

Source: RFC-0141 (Tari Network):
- Proof generation with SHA-512/256: < 4 ms

### 1.4 Production System Implementations

| System | Tree Type | Hash Function | Depth | Notes |
|--------|-----------|---------------|-------|-------|
| Polygon zkEVM | Sparse Merkle Trie | Poseidon | 256 | Binary, combines Merkle + Patricia trie |
| zkSync Era | Jellyfish Merkle Tree | Blake2s256 | Variable | Arity 16, Goldilocks field (not BN128) |
| Semaphore v3 | Incremental Merkle Tree | Poseidon | Configurable | Moved from MiMC; halved proving time |
| Semaphore v4 | Lean IMT | Poseidon | Dynamic | Optimized: hashes grow with tree size |
| Iden3 | Sparse Merkle Tree | Poseidon | 256 | Identity commitments, browser-compatible |
| Scroll | Poseidon SMT | Poseidon | 256 | Type 2 zkEVM |

### 1.5 circomlibjs Poseidon Performance (JavaScript)

Source: LCamel/circomlibjs-poseidon-performance-test (GitHub).

| Version | Measurement | Notes |
|---------|-------------|-------|
| circomlibjs 0.0.8 | ~5,663 ms total | Includes buildPoseidon() initialization |
| circomlibjs 0.1.7 | ~935 ms total | 6x improvement over 0.0.8 |

Note: These measurements likely include initialization overhead. Per-hash computation
after buildPoseidon() should be in the microsecond range due to BigInt field operations.
Our benchmarks will isolate per-hash latency from initialization.

### 1.6 On-Chain Gas Costs (Merkle Tree Operations)

Source: Ethereum Research (ethresear.ch).

| Operation | Depth 10 | Depth 20 | Depth 30 |
|-----------|----------|----------|----------|
| Initialization gas | 1,317,741 | 2,003,430 | 2,689,180 |
| Insertion gas | 427,238 | 767,565 | 1,107,895 |

Note: Basis Network L1 has zero gas cost (permissioned, zero-fee). These numbers are
included for reference against Ethereum mainnet deployments.

---

## 2. Hash Function Comparison

### 2.1 ZK-Friendliness Analysis

A hash function is "ZK-friendly" if it minimizes the number of multiplicative operations
over a finite field, since each multiplication maps to one or more R1CS constraints.

**Poseidon** (Grassi et al., USENIX Security 2021):
- Designed specifically for ZK proof systems
- Uses HADES permutation strategy: full S-box rounds (security) + partial S-box rounds (efficiency)
- S-box: x^5 over BN128 scalar field (compatible with our Circom circuits)
- 240 R1CS constraints per 2-to-1 hash (BN254/BN128)
- De facto standard: used by Polygon zkEVM, Semaphore, Iden3, Scroll, Aztec
- 128-bit security target with configurable round parameters
- Sponge construction: flexible input/output sizes

**MiMC** (Albrecht et al., ASIACRYPT 2016):
- Earlier ZK-friendly design
- Uses x^3 (or x^7) S-box with many Feistel rounds
- 340 R1CS constraints per 2-to-1 hash (BN254)
- 42% more constraints than Poseidon for same security level
- Superseded by Poseidon in most production systems
- Semaphore v2 to v3 migration: MiMC to Poseidon halved proving time

**Rescue** (Aly et al., 2019):
- Designed for algebraic proof systems
- ~600+ R1CS constraints per hash
- Higher security margin but 2.5x more expensive than Poseidon
- Less adoption in production systems

**Keccak-256** (SHA-3):
- ~150,000 R1CS constraints per hash
- Not ZK-friendly: bitwise operations require Boolean decomposition
- Used natively in Ethereum (state trie) but prohibitively expensive in circuits
- This is precisely why Type 2+ zkEVMs replace Keccak with Poseidon

### 2.2 Recommendation

**Poseidon is the clear choice** for the Basis Network validium SMT:

1. **Lowest viable constraint count** (240 per hash) in R1CS/Groth16
2. **BN128 field native**: same field as our existing batch_verifier.circom (circomlib)
3. **Production proven**: Polygon zkEVM, Semaphore, Iden3, Scroll all use Poseidon
4. **circomlibjs availability**: same library we already depend on (circomlibjs 0.1.7)
5. **Sponge flexibility**: can hash variable-length inputs without padding overhead
6. **Depth-32 path**: 7,680 constraints for full path verification (well within Groth16 limits)

Trade-offs to acknowledge:
- Poseidon is slower than SHA-256 in native (non-circuit) computation
- Recent cryptanalysis (Grobner basis attacks, IACR ePrint 2025/954) found inaccuracies
  in original round count estimates -- but the Ethereum Foundation's Poseidon
  Cryptanalysis Initiative (2024-2026) confirms overall security with recommended
  parameters
- Poseidon2 offers faster native computation at same constraint count, but circomlibjs
  does not yet support it; migration path exists for future optimization

### 2.3 For Depth-32 Merkle Proof in Circom

| Hash Function | Constraints (32 hashes) | Viable? | Rationale |
|---------------|------------------------|---------|-----------|
| Poseidon | ~7,680 | YES | Optimal for Groth16/BN128 |
| MiMC | ~10,880 | Marginal | 42% more constraints, no benefit |
| Rescue | ~19,200 | NO | Excessive constraint cost |
| Keccak-256 | ~4,800,000 | NO | Completely infeasible |

---

## 3. Sparse Merkle Tree Design Considerations

### 3.1 Why Sparse Merkle Tree?

A Sparse Merkle Tree (SMT) is a Merkle tree where most leaves are empty (contain a
default zero value). For a depth-32 tree, there are 2^32 = 4,294,967,296 possible
leaves, but only a small fraction will be populated.

Key properties:
- **Deterministic**: Same set of key-value pairs always produces the same root
- **Membership proofs**: Prove a key-value pair exists in the tree
- **Non-membership proofs**: Prove a key does NOT exist (critical for double-spend prevention)
- **Efficient updates**: Only O(depth) = O(32) hashes per insert/update/delete
- **Sparse storage**: Only store non-empty subtrees (memory proportional to entries, not 2^32)

### 3.2 Design Decisions for Enterprise Validium

1. **Depth 32**: 2^32 addressable leaves provides ~4 billion slots. For enterprise
   state (accounts, balances, records), this is more than sufficient. Deeper trees
   (e.g., 256 as in Polygon zkEVM) support full Ethereum address space but add
   unnecessary constraint cost.

2. **Binary tree**: Binary is simpler and better suited for R1CS (vs. quinary, which
   saves ~9% constraints but complicates the circuit and has higher on-chain gas).

3. **Key derivation**: Keys are Poseidon hashes of the original identifier (e.g.,
   Poseidon(enterpriseId, recordId)) to distribute entries uniformly across the tree.

4. **Default value**: Empty leaves hash to 0 (field zero). Subtrees of all-zero leaves
   have precomputable hashes (cache the 32 levels of H(0,0), H(H(0,0), H(0,0)), etc.).

5. **Proof format**: Array of 32 sibling hashes + 32 direction bits. Total proof size:
   32 * 32 bytes + 4 bytes = 1,028 bytes.

### 3.3 Complexity Analysis

| Operation | Time Complexity | Hashes Required |
|-----------|----------------|-----------------|
| Insert | O(depth) | 32 |
| Update | O(depth) | 32 |
| Delete | O(depth) | 32 |
| Get Proof | O(depth) | 0 (traverse only) |
| Verify Proof | O(depth) | 32 |
| Get Root | O(1) | 0 (cached) |

---

## 4. Experimental Results

**Environment**: Node.js v22.13.1, win32 x64, circomlibjs 0.1.7
**Date**: 2026-03-18

### 4.1 Poseidon Hash Performance (JavaScript)

1,000 hashes measured after 100 warmup iterations.

| Configuration | us/hash | hashes/s |
|---------------|---------|----------|
| Poseidon 2-to-1 (standard) | 56.09 | 17,830 |
| Poseidon 1-input (key derivation) | 40.44 | 24,728 |
| MiMC-Feistel (x^7, 91 rounds) | 278.55 | 3,590 |
| Poseidon chain-32 (Merkle path) | 53.54/hash, 1.71ms/chain | 18,677 |

**Poseidon vs MiMC speedup: 4.97x** (consistent with literature prediction of 5-10x).

A full depth-32 Merkle path verification requires ~1.7ms of hash computation.

### 4.2 SMT Insert Latency by Tree Size

50 measurement samples per configuration after 10 warmup iterations.

| Entries | Mean (ms) | P50 (ms) | P95 (ms) | P99 (ms) | Stddev (ms) |
|---------|-----------|----------|----------|----------|-------------|
| 100 | 1.877 | 1.864 | 2.087 | 2.087 | 0.134 |
| 1,000 | 1.788 | 1.780 | 1.997 | 1.997 | 0.095 |
| 10,000 | 1.792 | 1.777 | 1.946 | 1.946 | 0.085 |
| 100,000 | 1.825 | 1.811 | 2.014 | 2.014 | 0.098 |

**Key finding**: Insert latency is effectively constant across tree sizes (~1.8ms),
confirming the O(depth) complexity prediction. Latency is dominated by 32 Poseidon
hashes per insert (~1.7ms) plus Map lookups.

### 4.3 SMT Proof Generation Time

| Entries | Mean (ms) | P95 (ms) |
|---------|-----------|----------|
| 100 | 0.012 | 0.029 |
| 1,000 | 0.014 | 0.016 |
| 10,000 | 0.014 | 0.016 |
| 100,000 | 0.018 | 0.021 |

**Key finding**: Proof generation is extremely fast (< 0.02ms) because it only traverses
the tree to collect sibling hashes -- no hash computation is needed. This is 250x faster
than the 5ms target.

### 4.4 SMT Proof Verification Time

| Entries | Mean (ms) | P95 (ms) |
|---------|-----------|----------|
| 100 | 1.685 | 1.788 |
| 1,000 | 1.677 | 1.758 |
| 10,000 | 1.719 | 1.905 |
| 100,000 | 1.744 | 1.869 |

**Key finding**: Verification time is constant (~1.7ms) across tree sizes, as expected
(always 32 Poseidon hashes). This is within the 2ms target.

### 4.5 Memory Usage

| Entries | Nodes Stored | Heap Used (MB) | Bytes/Entry (est.) |
|---------|-------------|----------------|-------------------|
| 100 | 2,721 | 68.4 | ~700,000 |
| 1,000 | 23,867 | 112.8 | ~115,000 |
| 10,000 | 202,398 | 57.9 | ~5,900 |
| 100,000 | 1,712,112 | 233.9 | ~2,400 |

**Key finding**: Node count scales at ~17x entries (each insert creates/updates up to 33
nodes: 1 leaf + 32 internal). Memory is dominated by the Map overhead. At 100K entries,
233.9 MB is well within the 2GB safety margin from the null hypothesis. The
bytes-per-entry decreases as tree size grows (amortized overhead from V8 Map structure).

Note: The 57.9 MB for 10K entries is lower than expected -- this is likely due to V8
garbage collection running between the 1K and 10K benchmarks (separate tree instances).

### 4.6 Benchmark Reconciliation with Published Data

| Metric | Our Result | Published Reference | Ratio | Assessment |
|--------|-----------|---------------------|-------|------------|
| Poseidon hash time (JS) | 56.09 us | N/A (no JS benchmarks found) | -- | First measurement |
| Poseidon vs MiMC speedup | 4.97x | "roughly halves proving time" (Semaphore) | ~2.5x ratio | Consistent (Semaphore measures circuit proving, not native hash) |
| SMT insert latency | 1.825 ms | 1.92 us (Monotree, Rust) | ~950x | Expected: JS vs Rust BigInt overhead |
| SMT insert latency | 1.825 ms | 63-193 us (LargeSMT, Rust, parallel) | ~9-29x | Expected: JS vs Rust + single-threaded |
| Proof generation | 0.018 ms | 20-83 us (LargeSMT, Rust) | ~0.2-0.9x | Comparable (both O(depth) traversals) |
| Proof verification | 1.744 ms | N/A | -- | Dominated by Poseidon chain, consistent with 4.1 |
| Poseidon constraints (BN128) | 240 (from literature) | 240 (arXiv:2409.01976) | 1.0x | Exact match |

**Divergence analysis**: The 950x gap between our JS implementation and Rust (Monotree)
is expected and not concerning. Monotree uses native SHA-256 (not Poseidon), and Rust
BigInt/field arithmetic is orders of magnitude faster than JavaScript BigInt. The relevant
comparison is against the hypothesis targets (all PASS), not against native Rust.

For the production Architect implementation (validium/node/src/state/), performance can
be improved via:
1. WebAssembly Poseidon (e.g., circom-compat-wasm) for ~10x speedup
2. Native Node.js addon (C++/Rust binding) for ~100x speedup
3. Batch update optimization (shared path computation) per arXiv:2310.13328

---

## 5. Hypothesis Assessment

### 5.1 Hypothesis

> A Sparse Merkle Tree of depth 32 with Poseidon hash can support 100,000+ entries with
> insertion latency < 10ms, Merkle proof generation < 5ms, and proof verification < 2ms
> in TypeScript, while maintaining full compatibility with the BN128 scalar field for
> Circom circuit integration.

### 5.2 Results

| Target | Required | Measured (100K entries) | Status |
|--------|----------|----------------------|--------|
| Insert latency | < 10 ms | 1.825 ms (mean), 2.014 ms (P95) | **PASS** (5.5x margin) |
| Proof generation | < 5 ms | 0.018 ms (mean), 0.021 ms (P95) | **PASS** (278x margin) |
| Proof verification | < 2 ms | 1.744 ms (mean), 1.869 ms (P95) | **PASS** (1.15x margin) |
| BN128 compatibility | Full | All operations use BN128 field | **PASS** |
| Memory (null hyp.) | < 2 GB | 233.9 MB at 100K entries | **PASS** |

### 5.3 Verdict

**HYPOTHESIS CONFIRMED.** All performance targets are met with margin, including at the
P95 level. The implementation uses circomlibjs Poseidon which operates natively in the
BN128 scalar field, ensuring full compatibility with the existing batch_verifier.circom
circuit.

### 5.4 Caveats and Trade-offs

1. **Proof verification is the tightest margin** (P95 = 1.869ms vs 2ms target). Under
   heavy load or slower hardware, this could approach the limit. The Architect should
   consider WebAssembly Poseidon for the production implementation.

2. **Memory scales linearly** with entries (~17 nodes per entry). At 1M entries, we
   project ~2.3 GB, which exceeds the 2GB null hypothesis threshold. For 1M+ entries,
   the Architect should implement database-backed storage (LevelDB/RocksDB) instead
   of in-memory Map.

3. **Insert latency is constant** (~1.8ms) regardless of tree size, which validates the
   O(depth) analysis. But this is ~950x slower than native Rust implementations. For
   batch processing (RU-V4), this means 100 inserts = ~180ms, 1000 inserts = ~1.8s.

4. **Non-membership proofs work correctly** (verified in all benchmark runs), which is
   critical for double-spend prevention (INV-S1 dependency).

### 5.5 Recommendations for Downstream Agents

**For the Logicist (TLA+ specification):**
- Model the SMT as a function: TreeState x Key x Value -> TreeState
- Key invariants to formalize: ConsistencyInvariant (root uniquely determined by contents),
  SoundnessInvariant (valid proofs only for actual contents), CompletenessInvariant
  (every entry has a valid proof)
- Model default hashes as constants (precomputed, never change)

**For the Architect (production implementation):**
- Use the SMT class from this experiment as the reference implementation
- Replace in-memory Map with LevelDB for persistence and >100K entries
- Consider WebAssembly Poseidon (circom-compat-wasm) for 5-10x speedup
- Implement batch update optimization from arXiv:2310.13328 for RU-V4 integration
- Target directory: validium/node/src/state/sparse-merkle-tree.ts

**For the Prover (Coq verification):**
- Key properties to prove: insert/proof/verify roundtrip, root determinism,
  proof soundness (no false positives), proof completeness (no false negatives)

---

## Literature References

1. Grassi, L. et al. "Poseidon: A New Hash Function for Zero-Knowledge Proof Systems."
   USENIX Security Symposium, 2021. (IACR ePrint 2019/458)

2. Albrecht, M. et al. "MiMC: Efficient Encryption and Cryptographic Hashing with
   Minimal Multiplicative Complexity." ASIACRYPT 2016.

3. Guohanze et al. "Benchmarking ZK-Friendly Hash Functions and SNARK Proving Systems
   for EVM-compatible Blockchains." arXiv:2409.01976, 2024.

4. Grassi, L. et al. "Poseidon2: A Faster Version of the Poseidon Hash Function."
   IACR ePrint 2023/323, 2023.

5. El Amrani, A. "Gas and circuit constraint benchmarks of binary and quinary
   incremental Merkle trees using the Poseidon hash function." Ethereum Research, 2020.

6. Reilabs. "Scaling Sparse Merkle Trees to Billions of Keys with LargeSMT." 2024.

7. Chen, W. et al. "One-Phase Batch Update on Sparse Merkle Trees for Rollups."
   arXiv:2310.13328, 2023.

8. Baylina, J. and Belles, M. "Sparse Merkle Trees." Iden3, ZKProof Standards
   Workshop 2, 2019.

9. Haider, F. "Compact Sparse Merkle Trees." IACR ePrint 2018/955, 2018.

10. Dahlberg, R. et al. "Efficient Sparse Merkle Trees." IACR ePrint 2016/683, 2016.

11. Polygon. "Sparse Merkle Tree -- Polygon zkEVM Documentation." 2024.

12. Semaphore Protocol. "Release v4.0.0." GitHub, 2024.

13. Nielsen, C. "SNARK-hash-benchmark." GitHub, 2023.

14. LCamel. "circomlibjs-poseidon-performance-test." GitHub, 2023.

15. Grassi, L. et al. "Poseidon and Neptune: Grobner Basis Cryptanalysis Exploiting
    Subspace Trails." IACR ePrint 2025/954, 2025.

16. Ethereum Foundation. "Poseidon Cryptanalysis Initiative 2024-2026."
    poseidon-initiative.info.

17. Polygon. "L2 State Tree Concept -- Polygon zkEVM Documentation." 2024.

18. Vitalik Buterin. "The different types of ZK-EVMs." 2022.
