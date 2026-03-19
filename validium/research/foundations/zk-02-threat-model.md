# ZK-02: Threat Model

> Living document. Updated after every experiment that discovers new attack vectors.

## Adversary Model

### Capabilities

1. **External adversary**: Can observe all L1 transactions (public blockchain).
2. **Compromised enterprise**: A registered enterprise may attempt to submit invalid proofs.
3. **Network adversary**: Can delay or reorder L1 transactions (standard blockchain threat model).
4. **Colluding enterprises**: Multiple enterprises may collude to attack the system.

### Out of Scope (MVP)

1. Quantum adversary (post-quantum migration planned for long-term).
2. Side-channel attacks on proof generation hardware.
3. Social engineering of enterprise operators.

## Attack Vectors (Accumulated from Experiments)

### ZK Proof Attacks

- **ATK-ZK1**: Submit invalid proof (random bytes). Mitigation: on-chain verification rejects.
- **ATK-ZK2**: Replay valid proof for different batch. Mitigation: batch root in public signals.
- **ATK-ZK3**: Submit proof for wrong enterprise. Mitigation: enterprise ID in public signals.
- **ATK-ZK4**: Forge proof without valid witness. Mitigation: Groth16 soundness guarantee.

### State Machine Attacks

- **ATK-SM1**: Skip state root in chain. Mitigation: previous root validation in contract.
- **ATK-SM2**: Submit conflicting state roots. Mitigation: sequential batch numbers.
- **ATK-SM3**: Corrupt Merkle tree locally. Mitigation: ZK proof includes tree integrity.

### Data Availability Attacks

- **ATK-DA1**: Enterprise withholds data after proof submission. Mitigation: DAC attestation required before L1 state update is accepted.
- **ATK-DA2**: DAC members collude to attest unavailable data. Mitigation: With (2,3)-Shamir and AnyTrust-style fallback, adversary must corrupt ALL 3 members AND prevent on-chain fallback. A single honest member blocks fraudulent attestation.
- **ATK-DA3**: Single DAC member reconstructs full enterprise data from their share. Mitigation: Shamir (2,3)-SS provides information-theoretic privacy; a single share reveals zero bits about the original data, even with unbounded computation. Verified experimentally: share distributions for different secrets are statistically indistinguishable.
- **ATK-DA4**: DAC member signs attestation without actually storing shares (lazy attestation). Mitigation: Shares are verified against the data commitment at receive time. A future enhancement can require proof-of-custody (periodic challenge-response proving the node still holds the shares).
- **ATK-DA5**: Adversary submits corrupted shares to DAC members. Mitigation: Each DAC member receives shares derived from the same polynomial. If the disperser sends inconsistent shares, reconstruction from different k-subsets yields different results. This is detectable by reconstructing from multiple subsets. A KZG commitment scheme (future) can make this verifiable without reconstruction.
- **ATK-DA6**: DAC denial of service -- Members go offline to prevent attestation. Mitigation: AnyTrust fallback posts batch data on-chain (validium degrades to rollup mode). For enterprise-operated DAC, DoS is self-inflicted. Recovery: when nodes come back online, normal attestation resumes immediately.

### State Commitment Attacks (from RU-V3: L1 State Commitment, 2026-03-18)

- **ATK-SC1**: Root chain fork -- Enterprise submits two valid proofs with the same prevStateRoot to create a fork. Mitigation: After the first submission updates currentRoot, the second submission's prevStateRoot no longer matches currentRoot and is rejected. The atomic update makes forking impossible.
- **ATK-SC2**: Batch ID manipulation -- Adversary attempts to skip batch IDs to create gaps in the state history. Mitigation: Batch IDs are derived from an auto-incrementing counter (batchCount). There is no parameter for the caller to specify a batch ID. Sequential ordering is structural.
- **ATK-SC3**: Cross-enterprise state poisoning -- Enterprise A attempts to submit a batch that references Enterprise B's state root. Mitigation: State lookup uses msg.sender as the key. Enterprise A can only access enterprises[A].currentRoot. Even if A knows B's root value, the check `enterprises[msg.sender].currentRoot == prevStateRoot` uses A's mapping.
- **ATK-SC4**: Genesis root manipulation -- Admin sets a malicious genesis root for an enterprise, enabling invalid state chain from the start. Mitigation: initializeEnterprise is admin-only (trusted). The genesis root should be the well-known empty Sparse Merkle Tree root. In production, the genesis root could be verified against the expected empty tree hash.
- **ATK-SC5**: Proof replay across enterprises -- Enterprise A's valid proof is replayed for Enterprise B. Mitigation: The circuit's public signals include enterpriseId. The proof binds to a specific enterprise. Verification with a different enterprise's state will fail the pairing check.
- **ATK-SC6**: Timestamp manipulation -- Enterprise submits batch with manipulated block.timestamp to affect ordering analysis. Mitigation: block.timestamp is set by the L1 validator, not the submitter. On Basis Network (permissioned), the validator is trusted. Timestamp is stored for auditability but not used for security-critical logic.
- **ATK-SC7**: Gas exhaustion attack -- Adversary crafts a transaction that consumes gas up to the point of ZK verification, causing the verification to fail with out-of-gas. Mitigation: The entire transaction reverts (no partial state update). The caller wastes their own gas. On a zero-fee network, rate limiting at the node level prevents spam.

### Cross-Enterprise Verification Attacks (from RU-V7: Cross-Enterprise Verification, 2026-03-18)

- **ATK-CE1**: False cross-reference -- Enterprise A fabricates a cross-reference proof claiming an interaction with Enterprise B that never occurred. Mitigation: The cross-reference circuit verifies Merkle proofs against BOTH enterprises' state roots (which are independently verified on L1). A fabricated interaction would require forging a Merkle proof for B's tree, which requires breaking Poseidon collision resistance (128-bit security).
- **ATK-CE2**: Stale state root reference -- Adversary uses an old (but once-valid) state root for one enterprise in the cross-reference proof. Mitigation: The CrossEnterpriseVerifier contract must verify that both state roots are the CURRENT roots stored in StateCommitment.sol. Stale roots are rejected. Alternatively, a freshness window (e.g., within last N batches) can be enforced.
- **ATK-CE3**: Commitment replay -- Adversary replays a valid interaction commitment from a previous cross-reference to claim the same interaction occurred again. Mitigation: The interaction commitment binds to specific state roots (public inputs). Since state roots change with each batch, the same commitment cannot verify against new roots. Additionally, a nullifier set (set of used commitments) prevents replay.
- **ATK-CE4**: Cross-reference front-running -- Observer detects a pending cross-reference transaction and front-runs it to extract information about enterprise relationships. Mitigation: The cross-reference reveals only that A and B have a relationship (1 bit). The commitment hides all data. Front-running gains no additional information beyond timing. On Basis Network (permissioned), front-running is limited to authorized submitters.
- **ATK-CE5**: Hub coordinator manipulation -- If Batched Pairing verification is used, the hub coordinator could selectively exclude or delay certain cross-references. Mitigation: Enterprises can always fall back to Sequential (independent) submission. The hub is an optimization, not a requirement. Exclusion is detectable because both enterprises hold their own cross-reference proofs.
- **ATK-CE6**: Interaction commitment brute-force -- Adversary with knowledge of the interaction commitment attempts to brute-force the preimage to discover transaction details. Mitigation: Poseidon preimage resistance provides 128-bit security. The preimage space (4 field elements over BN128) is 2^1016, making brute force computationally infeasible.

### Bridge Attacks (Long-term)

- **ATK-BR1**: Double withdrawal. Mitigation: withdrawal nullifiers.
- **ATK-BR2**: Withdrawal with stale state proof. Mitigation: state root freshness check.

### State Management Attacks (from RU-V1: Sparse Merkle Tree, 2026-03-18)

- **ATK-SMT1**: Key collision -- Two different enterprise records map to the same leaf index. Mitigation: Poseidon key derivation distributes uniformly; depth 32 provides 2^32 slots. Collision probability < 2^(-64) for 100K entries (birthday bound). For >1M entries, monitor collision rate.
- **ATK-SMT2**: Merkle proof forgery -- Adversary constructs a valid proof for a non-existent entry. Mitigation: Poseidon collision resistance (128-bit security); finding two inputs that produce same hash requires O(2^128) work.
- **ATK-SMT3**: State root manipulation via default hash exploitation -- Adversary exploits knowledge of precomputed default hashes to craft misleading proofs. Mitigation: Leaf hashes include the key as input (H(key, value)), preventing substitution of default-value leaves for key-specific leaves.
- **ATK-SMT4**: Memory exhaustion attack -- Adversary submits enough transactions to exceed node memory. Mitigation: Production implementation must use database-backed storage (not in-memory Map) for trees beyond 100K entries. In-memory limit observed at ~234 MB for 100K entries.

### State Transition Circuit Attacks (from RU-V2: State Transition Circuit, 2026-03-18)

- **ATK-STC1**: Witness manipulation -- Adversary provides incorrect sibling hashes in the witness to make an invalid state transition appear valid. Mitigation: The circuit recomputes the root from leaf + siblings and constrains it to match the declared prevStateRoot (a public input verified on L1). Incorrect siblings produce the wrong root, failing the IsEqual constraint.
- **ATK-STC2**: Root chain gap -- Adversary submits batch N+2 without submitting batch N+1, creating a state root gap. Mitigation: The L1 contract must enforce sequential prevStateRoot matching (the prevStateRoot of batch N+1 must equal the newStateRoot of batch N). This is an L1 contract invariant, not a circuit invariant.
- **ATK-STC3**: Value substitution -- Adversary provides correct old Merkle proof but claims a different oldValue than what is actually in the tree. Mitigation: The leaf hash binds both key and value (Poseidon(key, value)). An incorrect oldValue produces a different leaf hash, which fails root verification.
- **ATK-STC4**: Batch reordering -- Adversary reorders transactions within a batch to achieve a different final state root. Mitigation: The circuit enforces a specific transaction ordering via the root chain (tx[i].newRoot = tx[i+1].oldRoot). Reordering transactions changes all intermediate roots, failing verification.
- **ATK-STC5**: Repeated key attack -- Adversary includes multiple transactions for the same key in one batch, attempting to create inconsistent intermediate states. Mitigation: Each transaction in the chain uses the correct intermediate root. If key K is updated in tx[i], then tx[j] (j > i) uses the updated state, including K's new value. The circuit correctly handles this via root chaining.
- **ATK-STC6**: Proving time DoS -- Adversary submits transactions designed to maximize proving time (e.g., keys at maximum tree depth, worst-case sibling paths). Mitigation: Proving time scales linearly with batch size (fixed per-tx constraint cost). No super-linear blowup is possible. Rate limiting at the enterprise node level prevents excessive batch submission.

### Batch Aggregation Attacks (from RU-V4: Batch Aggregation, 2026-03-18)

- **ATK-BA1**: Transaction flooding -- Adversary submits transactions faster than the node can process to exhaust memory or WAL disk space. Mitigation: Rate limiting at the API layer, WAL compaction after checkpoint, configurable max queue size with backpressure.
- **ATK-BA2**: WAL corruption -- Adversary gains file system access and corrupts WAL entries to cause transaction loss or reordering. Mitigation: SHA-256 checksum per WAL entry; corrupted entries are detected and skipped during recovery. Valid entries remain recoverable.
- **ATK-BA3**: Batch reordering attack -- Adversary attempts to reorder transactions within a batch to achieve a different final state. Mitigation: FIFO ordering enforced by WAL sequence numbers. Batch determinism (INV-BA3) guarantees same order produces same batch. Circuit root chaining (INV-ST1) rejects reordered batches.
- **ATK-BA4**: Duplicate transaction injection -- Adversary replays the same transaction to inflate batch count or create conflicting state transitions. Mitigation: Transaction deduplication by txHash at enqueue time (must be implemented in production). Circuit's leaf binding (INV-ST3) prevents duplicate state transitions.
- **ATK-BA5**: Checkpoint manipulation -- Adversary modifies checkpoint markers in the WAL to cause committed transactions to be replayed or uncommitted ones to be skipped. Mitigation: Checkpoints reference specific WAL sequence numbers. Recovery replays all entries after the last valid checkpoint. Worst case: some committed transactions are reprocessed (idempotent at the circuit level).

### Node Orchestrator Attacks (from RU-V5: Enterprise Node Orchestrator, 2026-03-18)

- **ATK-NO1**: API flooding -- Adversary sends high-rate transaction submissions to exhaust node memory or disk (WAL). Mitigation: Rate limiting at the API layer (Fastify request rate limiter), configurable max queue size with backpressure (HTTP 429), WAL compaction after checkpoint.
- **ATK-NO2**: State machine manipulation -- Adversary sends transactions during specific node states (e.g., during proving) to trigger invalid state transitions or race conditions. Mitigation: Pipelined architecture with single-writer SMT model. Transaction ingestion is decoupled from batch processing. State machine transitions are guarded with explicit transition table (invalid transitions throw).
- **ATK-NO3**: Proof pipeline stall -- Adversary submits transactions that cause the prover to hang or crash (e.g., malformed witness). Mitigation: Prover runs in isolated child process with configurable timeout. Failed proofs transition to Error state with retry. The ingestion loop is unaffected by prover failures.
- **ATK-NO4**: L1 submission front-running -- An observer detects the node's L1 transaction and submits a conflicting batch for the same enterprise. Mitigation: StateCommitment.sol enforces ChainContinuity (prevRoot must match currentRoot). Only the enterprise's authorized address can submit batches (EnterpriseRegistry check). Front-running with a different prevRoot fails the contract check.
- **ATK-NO5**: Checkpoint tampering -- Adversary gains file system access and modifies the checkpoint file to cause the node to restore an incorrect state. Mitigation: Checkpoint files should include a SHA-256 integrity hash. On restore, verify integrity before applying. WAL replay from last known-good checkpoint provides defense in depth.
- **ATK-NO6**: WebSocket event injection -- Adversary connects to the WebSocket endpoint and sends fabricated events to mislead monitoring clients. Mitigation: WebSocket endpoint is read-only (server pushes events to clients). No client-to-server commands are accepted over WebSocket. Authentication required for all API endpoints.

## Security Assumptions

1. Groth16 is sound under the q-PKE and d-PDH assumptions in the generic group model.
2. The trusted setup ceremony was performed correctly (at least one honest participant).
3. Poseidon hash is collision-resistant under the algebraic group model.
4. The Basis Network L1 provides finality (Snowman consensus assumption).
5. At least one DAC member is honest (data availability assumption). With (2,3)-Shamir and AnyTrust fallback, this means at least 1-of-3 members is honest; if all 3 are compromised, the system falls back to on-chain DA (rollup mode).
7. Shamir's Secret Sharing over BN128 scalar field provides information-theoretic privacy: k-1 shares reveal zero information about the secret. This is unconditional (not dependent on computational assumptions). (Added: RU-V6, 2026-03-18)
6. Poseidon with recommended round parameters provides 128-bit security against algebraic attacks, including Grobner basis attacks (confirmed by Ethereum Foundation Poseidon Cryptanalysis Initiative 2024-2026, but subject to ongoing review per IACR ePrint 2025/954). (Added: RU-V1, 2026-03-18)
