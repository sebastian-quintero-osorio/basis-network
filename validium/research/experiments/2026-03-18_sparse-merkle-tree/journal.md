# Experiment Journal: Sparse Merkle Tree with Poseidon Hash

## 2026-03-18 -- Session 1: Initial Implementation

### Objective

Evaluate whether a depth-32 Sparse Merkle Tree with Poseidon hash meets the performance
requirements for enterprise ZK validium state management on Basis Network.

### Context

This is RU-V1 (Research Unit V1) of the validium MVP pipeline. The SMT will serve as the
core state structure for the enterprise validium node. It must:
1. Store enterprise state (accounts, balances, transaction records)
2. Generate Merkle proofs that can be verified inside Circom circuits
3. Maintain BN128 field compatibility for Groth16 proof generation
4. Scale to 100,000+ entries with sub-10ms operations

### Pre-experiment Predictions

1. Poseidon will outperform MiMC by 5-10x in native JS (fewer field multiplications)
2. Insert latency governed by tree depth (32 hashes), not entry count
3. Memory sublinear -- only non-empty branches stored
4. Proof size = 32 sibling hashes = 32 * 32 bytes = 1024 bytes

### What would change my mind?

- If Poseidon in circomlibjs is significantly slower than expected due to BigInt overhead
- If memory grows linearly with entries despite sparse storage (implementation issue)
- If BN128 field arithmetic in JavaScript introduces unexpected bottlenecks
- If a production system (Polygon Hermez, Iden3) reports fundamentally different numbers

### Literature Review Findings

See findings.md for the comprehensive review.

### Decisions

1. Use circomlibjs Poseidon (same library as our batch_verifier.circom) for field compatibility
2. Depth 32 provides 2^32 = ~4 billion addressable leaves (sufficient for enterprise)
3. Implement from scratch rather than using @iden3/js-merkletree to understand internals
   and ensure optimal performance for our specific use case
4. Benchmark at 100, 1,000, 10,000, and 100,000 entries

### Anti-confirmation Bias Check

- Alternative hash (MiMC) will be benchmarked under identical conditions
- Will actively seek scenarios where Poseidon underperforms
- If all benchmarks confirm hypothesis, will increase adversarial testing
