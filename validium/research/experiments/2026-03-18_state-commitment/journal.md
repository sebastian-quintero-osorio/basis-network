# Journal -- State Commitment Protocol (RU-V3)

## 2026-03-18 -- Iteration 1: Initial Implementation

### Context

RU-V3 is the bridge between the off-chain ZK validium system and the on-chain L1. Prior
research units have established:
- RU-V1: Sparse Merkle Tree with Poseidon hash (insert 1.8ms, proof 0.02ms)
- RU-V2: State Transition Circuit with formula `1,038 * (depth + 1) * batchSize` constraints
- RU-V4: Batch Aggregation with 274K tx/min throughput, WAL crash recovery
- RU-V6: Data Availability Committee with (2,3)-Shamir, 163ms attestation

The circuit from RU-V2 produces public signals: [prevStateRoot, newStateRoot, batchNum,
enterpriseId]. These are the inputs the L1 contract must validate and anchor.

### Design Decisions

**D1: Integrated vs Delegated Verification**

Three architecture options considered:
- A) StateCommitment calls ZKVerifier externally (delegated)
- B) StateCommitment includes verification logic (integrated)
- C) StateCommitment uses ZKVerifier as a library (hybrid)

Hypothesis: Option B (integrated) will be under 300K gas because it avoids the cross-contract
CALL overhead and redundant storage in ZKVerifier. Option A may exceed 300K due to ZKVerifier
storing its own BatchVerification struct (3-4 extra SSTORE operations).

**D2: Storage Layout Variants**

Three storage layouts to benchmark:
- Minimal: Only roots in mapping + metadata in events
- Rich: Roots + packed BatchInfo struct (batchSize, timestamp, txCount in one slot)
- Full: Roots + full struct with prevRoot stored explicitly

**D3: Per-Enterprise State Model**

Each enterprise maintains its own independent state chain. The key insight is that
prevStateRoot of batch N+1 must equal newStateRoot of batch N. This is enforced by
storing currentRoot per enterprise and checking it on each submission.

### What would change my mind?

- If Groth16 verification costs more than ~210K gas on Subnet-EVM (vs Ethereum mainnet),
  the 300K budget becomes infeasible regardless of storage layout.
- If Subnet-EVM has different SSTORE pricing than Ethereum mainnet, all gas estimates need
  recalculation.
- If event log storage is unreliable for historical queries on Avalanche nodes, the minimal
  layout (events for metadata) becomes impractical.
