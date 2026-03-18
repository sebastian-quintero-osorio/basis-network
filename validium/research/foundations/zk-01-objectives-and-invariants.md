# ZK-01: Objectives and Invariants

> Living document. Updated after every experiment that discovers new properties.

## System Objectives

1. **Privacy**: No private enterprise data is ever exposed on the L1 or to other enterprises.
2. **Correctness**: Only mathematically verified state transitions are accepted.
3. **Auditability**: An authorized auditor can verify enterprise compliance without accessing raw data.
4. **Availability**: Enterprise operations are not blocked by L1 congestion or validator downtime.
5. **Finality**: Once a batch is verified on the L1, the state transition is irreversible.

## Invariants (Accumulated from Experiments)

### Safety Invariants

- **INV-S1**: State Root Chain Integrity -- State roots form a linear chain per enterprise. No gaps, no reversals.
- **INV-S2**: Proof Before State -- A state root update on L1 occurs only after a valid ZK proof is verified.
- **INV-S3**: Enterprise Isolation -- Enterprise A's state transitions cannot be affected by Enterprise B's operations.
- **INV-S4**: Proof Soundness -- An invalid proof must be rejected with probability >= 1 - 2^(-128).

### Liveness Invariants

- **INV-L1**: Batch Progress -- If an enterprise submits transactions, they are eventually batched and proved.
- **INV-L2**: Verification Progress -- If a valid proof is submitted, it is eventually verified on the L1.

### Privacy Invariants

- **INV-P1**: Data Confidentiality -- The L1 stores only state roots and proofs, never raw transaction data.
- **INV-P2**: Proof Zero-Knowledge -- The ZK proof reveals nothing about private inputs beyond the public signals.

### State Management Invariants (from RU-V1: Sparse Merkle Tree, 2026-03-18)

- **INV-SM1**: Root Determinism -- The same set of key-value pairs MUST always produce the same Merkle root, regardless of insertion order.
- **INV-SM2**: Proof Soundness -- A Merkle proof verifies if and only if the claimed key-value pair is present in the tree at the claimed root.
- **INV-SM3**: Proof Completeness -- For every entry in the tree, a valid Merkle proof can be generated.
- **INV-SM4**: Non-Membership Soundness -- A non-membership proof (leaf = 0) verifies if and only if the key is NOT present in the tree.
- **INV-SM5**: Field Consistency -- All hash computations MUST operate within the BN128 scalar field (p = 21888242871839275222246405745257275088548364400416034343698204186575808495617). Values outside this range are reduced modulo p before any operation.

## Open Questions

(Updated as experiments discover new considerations)

- **OQ-1**: At >1M entries, in-memory storage exceeds 2GB. Production implementation
  needs database backing (LevelDB/RocksDB). Does this affect proof generation latency?
  (Discovered: RU-V1, 2026-03-18)
- **OQ-2**: Proof verification has tightest margin (P95 = 1.869ms vs 2ms target).
  WebAssembly Poseidon may be needed for production. What is the actual speedup?
  (Discovered: RU-V1, 2026-03-18)
