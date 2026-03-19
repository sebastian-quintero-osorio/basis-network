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

### State Transition Invariants (from RU-V2: State Transition Circuit, 2026-03-18)

- **INV-ST1**: Root Chain Consistency -- For a batch of N state transitions, the new root of transaction i MUST equal the old root of transaction i+1. No intermediate roots may be skipped or reordered.
- **INV-ST2**: Transition Determinism -- Given the same (key, oldValue, newValue, siblings, pathBits), the circuit MUST always produce the same (oldRoot, newRoot). Non-deterministic witnesses are rejected.
- **INV-ST3**: Leaf Binding -- The leaf hash MUST bind both key and value: leafHash = Poseidon(key, value). A proof for key K with value V must not verify for key K with value V' (or vice versa).
- **INV-ST4**: Sibling Integrity -- The sibling hashes provided as witnesses MUST be the actual sibling nodes in the tree. The circuit verifies this by reconstructing the root from the leaf through the siblings.
- **INV-ST5**: Public Signal Completeness -- The public signals (prevStateRoot, newStateRoot, batchNum, enterpriseId) MUST be sufficient to identify the exact state transition on the L1. No additional context should be needed for verification.

### Batch Aggregation Invariants (from RU-V4: Batch Aggregation, 2026-03-18)

- **INV-BA1**: Transaction Persistence -- Every transaction enqueued to the persistent queue MUST be written to the WAL before the enqueue operation returns. No transaction may exist only in memory.
- **INV-BA2**: Crash Recovery Completeness -- After a crash and restart, all transactions written to the WAL but not yet checkpointed MUST be recovered and re-enqueued. Zero transaction loss under any crash scenario.
- **INV-BA3**: Batch Determinism -- Given the same set of transactions in the same arrival order, the batch aggregator MUST produce identical batches (same batch ID, same transaction ordering, same contents). BatchID = SHA-256(tx hashes in order).
- **INV-BA4**: Checkpoint Atomicity -- A WAL checkpoint marks the exact boundary between committed and uncommitted transactions. Transactions with WAL sequence numbers <= checkpoint sequence are committed; those > checkpoint sequence are uncommitted and must be recovered.
- **INV-BA5**: Ordering Preservation -- Transactions within a batch MUST maintain their FIFO arrival order (by timestamp, with WAL sequence number as tiebreaker). This ordering must be preserved through crash recovery.
- **INV-BA6**: Batch-Circuit Alignment -- Batch size MUST be compatible with the circuit's batch size parameter. A batch of N transactions produces inputs for a state_transition circuit with batchSize=N.

### Circuit Scaling Properties (from RU-V2: State Transition Circuit, 2026-03-18)

- **PROP-CS1**: Constraint Linearity -- Total constraints scale linearly with both tree depth and batch size: `total = 1,038 * (depth + 1) * batchSize`. No superlinear blowup.
- **PROP-CS2**: Proof Size Constancy -- Groth16 proof size is constant (~805 bytes) regardless of circuit size. Verification cost on L1 is independent of batch size.
- **PROP-CS3**: Proving Time Sublinearity -- Groth16 proving time scales sublinearly with constraint count (due to FFT/NTT efficiency at larger sizes).

### Batch Aggregation Properties (from RU-V4: Batch Aggregation, 2026-03-18)

- **PROP-BA1**: Throughput Headroom -- The batch aggregation layer processes transactions at 14K-274K tx/min (depending on configuration), providing 141x-2,744x headroom over the 100 tx/min enterprise target. The bottleneck is proof generation (5.8-12.8s per batch from RU-V2), not batch formation.
- **PROP-BA2**: WAL Write Cost -- JSON-lines WAL append with SHA-256 checksum costs ~149-210 us per entry (group commit vs per-entry fsync). This is 300x slower than binary WAL (529ns) due to JSON serialization overhead, but sufficient for MVP throughput targets.
- **PROP-BA3**: Batch Formation Speed -- Batch formation (dequeue + hash + checkpoint) completes in <0.02ms regardless of batch size (4-64). This is negligible compared to proof generation time.

### Data Availability Invariants (from RU-V6: Data Availability Committee, 2026-03-18)

- **INV-DA1**: Share Privacy -- No individual DAC member can reconstruct the complete batch data from their share alone. With (k,n)-Shamir secret sharing where k >= 2, any k-1 shares reveal zero information about the original data (information-theoretic security).
- **INV-DA2**: Data Recoverability -- If at least k of n DAC members are available and hold valid shares, the complete batch data can be reconstructed exactly (byte-perfect). Recovery from any k-subset produces identical output.
- **INV-DA3**: Attestation Soundness -- A batch is attested as available on-chain only if at least k of n committee members have signed the data commitment hash. The on-chain contract verifies each signature and rejects duplicates.
- **INV-DA4**: Liveness Fallback -- If fewer than k members are available for attestation, the system falls back to on-chain data availability (posting batch data directly to L1). This converts validium to rollup mode temporarily, preserving liveness.
- **INV-DA5**: Commitment Binding -- The data commitment hash (SHA-256 of original batch data) committed on-chain binds to the exact batch data. Shares are generated from the original data and the commitment is computed before sharing.

### Data Availability Properties (from RU-V6: Data Availability Committee, 2026-03-18)

- **PROP-DA1**: Attestation Latency -- The full attestation pipeline (share generation + distribution + signature collection) completes in <350ms at 1MB batch size in JavaScript BigInt. With native field arithmetic, estimated <10ms. Well within the 2-second enterprise target.
- **PROP-DA2**: Storage Overhead -- (2,3)-Shamir produces ~3.87x total storage overhead (3 nodes x ~1.03x per-node encoding). Each node stores approximately the same volume as the original data. For 500KB enterprise batches: ~1.9MB total across 3 nodes.
- **PROP-DA3**: Recovery Independence -- Data recovery via Lagrange interpolation is deterministic and independent of which k-subset is used. Any 2-of-3 subset produces identical reconstruction.
- **PROP-DA4**: Linear Scaling -- Share generation scales linearly with data size at ~9.5us/field-element in JavaScript (~0.32ms/KB). No superlinear blowup.

### State Commitment Invariants (from RU-V3: L1 State Commitment, 2026-03-18)

- **INV-SC1**: Chain Continuity -- For every batch submission, the submitted prevStateRoot MUST equal the enterprise's currentRoot stored on-chain. This prevents gaps, forks, and out-of-order submissions. Enforced by: `require(enterprises[enterprise].currentRoot == prevStateRoot)`.
- **INV-SC2**: Proof Before State -- The ZK proof MUST be verified BEFORE any state mutation occurs. The contract verifies the Groth16 proof and reverts the entire transaction if verification fails. No partial state update is possible.
- **INV-SC3**: Sequential Batch IDs -- Batch IDs are derived from an auto-incrementing counter (batchCount) per enterprise. There is no mechanism to skip or choose a batch ID. NoGap is structural, not checked.
- **INV-SC4**: Atomic Submission -- Proof verification and state root update occur in a single transaction. There is no window between proof acceptance and state update where the state could be inconsistent.
- **INV-SC5**: Enterprise State Independence -- Each enterprise's state (currentRoot, batchCount, batchRoots) is stored in per-enterprise mappings. No shared state exists between enterprises except the global totalBatchesCommitted counter, which is informational only.

### State Commitment Properties (from RU-V3: L1 State Commitment, 2026-03-18)

- **PROP-SC1**: Gas Budget Distribution -- ZK verification consumes ~72% of total gas (205,600 / 285,756). Storage operations consume ~28%. This means gas optimization should focus on verification efficiency, not storage layout.
- **PROP-SC2**: Storage Efficiency -- The minimal layout stores 32 bytes per batch (1 storage slot = 1 state root). This is 2-3x more efficient than production rollups (zkSync: 64-96 bytes, Scroll: 96 bytes) due to the single-phase submission model.
- **PROP-SC3**: Cold vs Warm Gas -- First batch submission costs ~17K more gas than steady-state (80,156 vs 63,056) due to cold storage access patterns. Steady-state gas is 268,656 (with ZK verification).
- **PROP-SC4**: Integrated vs Delegated -- Integrated verification saves ~56K gas per submission compared to delegating to a separate ZKVerifier contract. This is the difference between fitting under 300K and exceeding it.

### Node Orchestrator Invariants (from RU-V5: Enterprise Node Orchestrator, 2026-03-18)

- **INV-NO1**: Liveness -- If pendingTxCount > 0 and state = Idle, then eventually state = Proving. No transaction remains indefinitely queued.
- **INV-NO2**: Safety -- If state = Submitting, then the proof's public signals match the actual state roots: proof.prevRoot = batch.prevStateRoot AND proof.newRoot = batch.newStateRoot. No proof is submitted with incorrect roots.
- **INV-NO3**: Privacy -- The only data transmitted outside the node are: (1) ZK proof (a, b, c points), (2) public signals (prevRoot, newRoot, batchNum, enterpriseId), and (3) Shamir shares to DAC nodes. Raw enterprise data never leaves the node boundary.
- **INV-NO4**: Crash Recovery -- After crash and restart, walReplayedTxCount + committedTxCount = totalEnqueuedTxCount. Zero transaction loss under any crash scenario.
- **INV-NO5**: State Root Continuity -- For batch N, the submitted prevStateRoot equals batch(N-1).newStateRoot. Enforced by both the node's local state tracking and the L1 StateCommitment contract (INV-SC1).
- **INV-NO6**: Single Writer -- Only the batch processing loop modifies the Sparse Merkle Tree. No concurrent writes are permitted. This prevents state corruption from race conditions in the pipelined architecture.

### Node Orchestrator Properties (from RU-V5: Enterprise Node Orchestrator, 2026-03-18)

- **PROP-NO1**: Orchestration Overhead -- The node's orchestration overhead (batch formation + witness generation, excluding proving, DAC, and L1 submission) is 593 ms for batch size 8 at depth 32. This represents 0.66% of the 90-second E2E budget. The overhead scales linearly with batch size (~72ms per transaction for witness generation).
- **PROP-NO2**: Pipeline Speedup -- Pipelined architecture (concurrent ingestion + batching + proving) provides 1.29x throughput improvement over sequential processing at batch 64 with rapidsnark. The speedup increases with batch size because preparation time (witness gen) grows relative to proving phase, enabling more overlap.
- **PROP-NO3**: Proving Dominance -- Proof generation accounts for >85% of end-to-end latency in all configurations. Orchestration, DAC, and L1 submission combined are <15% of total time. Optimization effort should focus on prover performance, not orchestration overhead.
- **PROP-NO4**: Memory Footprint -- The orchestrator process requires ~85 MB baseline (state machine, queues, API server). With production SMT (100K entries from RU-V1: 234 MB), total estimated memory is ~320 MB. This fits comfortably on commodity hardware.

### Cross-Enterprise Verification Invariants (from RU-V7: Cross-Enterprise Verification, 2026-03-18)

- **INV-CE1**: Enterprise Isolation -- A cross-enterprise proof for enterprises A and B reveals nothing about A's data to B or vice versa, beyond the interaction commitment (a Poseidon hash). The zero-knowledge property of Groth16 guarantees that private inputs (keys, values, Merkle proofs) are not exposed.
- **INV-CE2**: Cross-Reference Consistency -- A cross-enterprise interaction is verified as valid if and only if both enterprises' individual proofs are valid AND the interaction commitment matches the claimed relationship. An invalid proof from either enterprise causes the cross-reference to fail.
- **INV-CE3**: Interaction Commitment Binding -- The interaction commitment Poseidon(keyA, leafA, keyB, leafB) binds to the exact data from both enterprises. Changing any input (key or value) produces a different commitment, preventing commitment reuse across different interactions.
- **INV-CE4**: State Root Independence -- Cross-enterprise verification uses state roots that are already verified and public on L1 (from individual enterprise submissions). The cross-reference proof does not modify or depend on the state root verification process.

### Cross-Enterprise Properties (from RU-V7: Cross-Enterprise Verification, 2026-03-18)

- **PROP-CE1**: Overhead Bound -- Sequential cross-enterprise verification (N enterprises, N-1 linear interactions) achieves < 2x gas overhead over individual verification for N <= 50. Measured: 1.41x at N=2, 1.81x at N=50. The overhead approaches 2x asymptotically but never reaches it in the linear interaction model.
- **PROP-CE2**: Batched Efficiency -- Batched pairing verification achieves < 1x total gas overhead by sharing the pairing computation across all proofs in a single transaction. Measured: 0.64x at N=2, 0.37x at N=50. This requires a hub coordinator to collect and submit proofs together.
- **PROP-CE3**: Privacy Leakage Minimality -- Cross-enterprise verification leaks exactly 1 bit per interaction: the existence of a relationship between two enterprises. No data content (keys, values, amounts) is leaked. This is the information-theoretic minimum for any system that proves cross-enterprise interactions.
- **PROP-CE4**: Cross-Reference Circuit Efficiency -- The cross-reference circuit requires 68,868 constraints (2 Merkle path verifications + interaction predicate). Proving time is ~4.5s (snarkjs) / ~0.45s (rapidsnark). This is approximately equal to a single enterprise batch proof (same depth), confirming that cross-enterprise verification does not introduce superlinear constraint growth.
- **PROP-CE5**: Dense Interaction Limitation -- When the number of cross-enterprise interactions exceeds the number of enterprises (dense graph), Sequential verification exceeds 2x overhead. Measured: 3.06x for 2 enterprises with 5 interactions. Batched Pairing handles dense graphs gracefully (0.95x for same scenario).

## Open Questions

(Updated as experiments discover new considerations)

- **OQ-1**: At >1M entries, in-memory storage exceeds 2GB. Production implementation
  needs database backing (LevelDB/RocksDB). Does this affect proof generation latency?
  (Discovered: RU-V1, 2026-03-18)
- **OQ-2**: Proof verification has tightest margin (P95 = 1.869ms vs 2ms target).
  WebAssembly Poseidon may be needed for production. What is the actual speedup?
  (Discovered: RU-V1, 2026-03-18)
- **OQ-3**: Batch 64 at depth 32 requires ~2.2M constraints. snarkjs cannot prove this
  in <60s. Production requires rapidsnark (C++) or GPU-accelerated prover. What is the
  actual rapidsnark proving time on the target deployment hardware?
  (Discovered: RU-V2, 2026-03-18)
- **OQ-4**: The circuit currently handles UPDATE-only operations. INSERT and DELETE
  operations require different constraint patterns (circomlib SMTProcessor). Should the
  production circuit support all three operations or specialize?
  (Discovered: RU-V2, 2026-03-18)
- **OQ-5**: When multiple transactions in a batch touch the same key, the intermediate
  state must be correctly chained. Does the circuit correctly handle repeated keys within
  a single batch? (Edge case to verify in adversarial testing.)
  (Discovered: RU-V2, 2026-03-18)
- **OQ-6**: The WAL benchmark ran on Windows with NTFS, which may not guarantee true
  fdatasync semantics. Production on Linux (ext4/XFS with O_DIRECT) will show different
  WAL write latencies. What is the actual fsync cost on the target deployment hardware?
  (Discovered: RU-V4, 2026-03-18)
- **OQ-7**: Multiple enterprises submitting concurrently need either per-enterprise WAL
  partitioning or a lock-free concurrent queue. Which approach provides better throughput
  under 10+ concurrent enterprise writers?
  (Discovered: RU-V4, 2026-03-18)
- **OQ-8**: JSON WAL format adds ~300B per entry overhead vs ~50B binary. At >10K tx/min,
  should the production WAL use a binary format (protobuf, msgpack) for throughput?
  (Discovered: RU-V4, 2026-03-18)
- **OQ-9**: Recovery time for (3,3)-Shamir at 500KB is ~9.7s in JavaScript due to O(k^2)
  Lagrange interpolation. For interactive recovery (e.g., withdrawal proof generation),
  native implementation is required. What is the actual native recovery latency?
  (Discovered: RU-V6, 2026-03-18)
- **OQ-10**: Multi-enterprise DAC with shared committee: how does per-enterprise privacy
  interact with shared committee membership? Each enterprise's data must remain isolated
  even if the same 3 nodes serve multiple enterprises.
  (Discovered: RU-V6, 2026-03-18)
- **OQ-11**: Should the data commitment use Poseidon (BN128-compatible, for potential
  in-circuit verification) or SHA-256 (faster, standard)? If a future circuit must verify
  the data commitment, Poseidon is required; otherwise SHA-256 suffices.
  (Discovered: RU-V6, 2026-03-18)
- **OQ-12**: The 300K gas budget leaves only ~14K margin for Layout A (Minimal). If the
  production contract requires additional features (admin pause, upgrade proxy, DAC
  attestation check), will it still fit under 300K? May need to optimize verification
  or accept a higher budget.
  (Discovered: RU-V3, 2026-03-18)
- **OQ-13**: Event-based metadata (Layout A) requires reliable event log queries on
  Avalanche nodes. Do Avalanche Fuji/mainnet nodes retain full event history, or is
  there a pruning horizon that could affect auditability?
  (Discovered: RU-V3, 2026-03-18)
- **OQ-14**: The current prototype uses msg.sender for enterprise identification. In
  production, enterprises may operate through multisig or contract wallets. How does
  this affect the authorization model (EnterpriseRegistry.isAuthorized)?
  (Discovered: RU-V3, 2026-03-18)
- **OQ-15**: The pipelined architecture allows transaction ingestion during proving, but
  the SMT is modified by the batch loop (single writer). If the next batch starts forming
  before the previous batch's proof is submitted, does the witness remain valid if the
  L1 submission fails and the state must roll back?
  (Discovered: RU-V5, 2026-03-18)
- **OQ-16**: Witness generation at batch 64 takes ~4.6s (72ms/tx from BatchBuilder). This
  is 3x larger than batch formation (0.12s). Can witness generation be parallelized
  across transactions, or does the sequential SMT update dependency prevent this?
  (Discovered: RU-V5, 2026-03-18)
- **OQ-17**: The node prototype uses child process for snarkjs proving. On Linux with
  rapidsnark, the prover runs as a native binary invoked via CLI. What is the IPC overhead
  (input serialization + output parsing) for a 2.2M constraint circuit witness?
  (Discovered: RU-V5, 2026-03-18)
- **OQ-18**: Avalanche Fuji L1 submission latency is estimated at 2s. What is the actual
  distribution? Avalanche Snowman consensus provides sub-second finality for well-connected
  validators, but network latency from the node to the validator may dominate.
  (Discovered: RU-V5, 2026-03-18)
- **OQ-19**: Cross-enterprise verification with dense interaction graphs (interactions >>
  enterprises) exceeds 2x gas overhead with Sequential approach. Should the production
  system enforce a maximum interaction density per batch, or always use Batched Pairing?
  (Discovered: RU-V7, 2026-03-18)
- **OQ-20**: The cross-reference circuit requires a separate trusted setup (new Groth16
  key pair for the 68,868-constraint circuit). Can this setup be combined with the existing
  state transition circuit setup via a shared Powers of Tau ceremony, or must they be
  independent? (Discovered: RU-V7, 2026-03-18)
- **OQ-21**: The Batched Pairing approach requires a hub coordinator that collects proofs
  from multiple enterprises and submits them in a single L1 transaction. Who operates
  this coordinator? If it is the L1 operator (Basis Network), does this introduce a
  centralization risk? If enterprises coordinate independently, how is proof collection
  synchronized? (Discovered: RU-V7, 2026-03-18)
- **OQ-22**: The interaction commitment reveals that a cross-enterprise relationship
  EXISTS (1 bit leakage). For highly sensitive enterprises, even the existence of a
  business relationship may be confidential. Can the cross-reference be submitted via
  a privacy-preserving channel (e.g., encrypted mempool) to hide the submitter identity?
  (Discovered: RU-V7, 2026-03-18)
