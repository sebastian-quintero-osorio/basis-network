# zkL2 Objectives and Invariants

> Living document. Updated after each completed experiment.
> Source of truth for system-wide invariants that all components must satisfy.

## System Objective

Build a per-enterprise zkEVM L2 on Basis Network (Avalanche L1) that provides full EVM
compatibility with ZK validity proofs, enterprise data privacy, and sub-5-minute batch
finality.

## Core Invariants

### I-01: EVM Determinism

For any transaction T and state S:
```
execute(T, S) = (S', trace, receipt)
```
The same T applied to the same S MUST always produce the same S', trace, and receipt,
regardless of which machine executes it.

**Source:** RU-L1 (EVM Executor)
**Why:** The prover must be able to independently verify execution. Non-determinism
would allow the sequencer to produce unprovable state transitions.

### I-02: Trace Completeness

The execution trace MUST capture ALL state-modifying operations:
- Every SLOAD and SSTORE (slot, old value, new value)
- Every balance change (address, old balance, new balance, reason)
- Every nonce change (address, old nonce, new nonce)
- Every contract creation (address, code hash)
- Every log emission (address, topics, data)
- Every self-destruct (address, beneficiary)

**Source:** RU-L1 (EVM Executor)
**Why:** Incomplete traces produce incomplete witnesses, which produce invalid proofs.

### I-03: Opcode Correctness

Every EVM opcode execution MUST produce output identical to the Ethereum Yellow Paper
specification for the Cancun hard fork. No opcode may be omitted, modified, or
reinterpreted.

**Source:** RU-L1 (EVM Executor)
**Why:** EVM compatibility is a hard requirement. Enterprise Solidity contracts must
execute identically on L2 as they would on Ethereum mainnet.

### I-04: Cancun EVM Target

The execution engine MUST target Cancun EVM (not Pectra). This includes:
- EIP-1153: Transient storage (TLOAD, TSTORE)
- EIP-4844: Blob transactions (BLOBHASH, BLOBBASEFEE)
- EIP-5656: MCOPY
- EIP-6780: SELFDESTRUCT restriction (same-tx only)

**Source:** TD-009 (Technical Decisions), Avalanche constraint
**Why:** Avalanche Subnet-EVM does not support Pectra. All L1 verification contracts
target Cancun.

### I-05: Zero-Fee Gas Model

The L2 gas price is 0. The execution engine MUST NOT reject transactions based on
insufficient gas payment. Gas metering is still used for execution limits but not
for fee collection.

**Source:** L1 configuration, enterprise model
**Why:** Enterprise L2 chains are permissioned and privately funded.

### I-06: State Root Integrity

After executing a batch of transactions, the state root MUST be computed as:
```
stateRoot = PoseidonSMT.root(accounts)
```
where PoseidonSMT is a Sparse Merkle Tree with Poseidon hash function.

**Source:** TD-008 (Poseidon Hash), RU-V1 (Validium SMT research)
**Why:** Poseidon is ~500x cheaper than Keccak in ZK circuits. State proofs must be
efficiently provable.

### I-07: Proof Soundness

A valid ZK proof for a batch MUST guarantee that:
1. Every transaction in the batch was correctly executed (per EVM spec)
2. The state transition from oldRoot to newRoot is valid
3. All storage reads returned the correct values from the pre-state
4. All storage writes are reflected in the post-state

**Source:** System-level requirement
**Why:** This is the fundamental security guarantee of a ZK rollup.

## Performance Targets

| Metric | Target | Source |
|--------|--------|--------|
| L2 TPS (execution only) | > 1,000 tx/s | RU-L1 hypothesis |
| Trace generation overhead | < 30% vs vanilla | RU-L1 experiment |
| Batch proving time | < 5 minutes | Architecture doc |
| L1 verification gas | < 500K gas | Architecture doc |
| State root computation | < 50ms for 10K accounts | RU-L4 hypothesis |
| Block production latency | < 1ms at 500 tx/block | RU-L2 experiment (measured: 0.14ms) |
| Mempool insertion rate | > 1M tx/s | RU-L2 experiment (measured: 2.8M tx/s) |
| FIFO ordering accuracy | 100% | RU-L2 experiment (measured: 100%) |
| Forced inclusion latency | < 1 block interval | RU-L2 experiment (measured: ~1s) |
| L2 block time | 1 second | RU-L2 design decision |

### I-09: Transaction Inclusion

Every valid transaction submitted to the sequencer mempool MUST eventually be included
in an L2 block, provided the mempool does not overflow.

**Source:** RU-L2 (Sequencer)
**Why:** Users must have certainty that submitted transactions will be executed. A sequencer
that silently drops transactions would violate enterprise service guarantees.

### I-10: Forced Inclusion Guarantee

Any transaction submitted to the L1 forced inclusion queue MUST be included in an L2
block within the configured deadline (default: 24 hours). The sequencer CANNOT selectively
skip forced transactions -- they must be processed in FIFO order.

**Source:** RU-L2 (Sequencer), Arbitrum DelayedInbox model
**Why:** This is the primary censorship resistance mechanism. Without forced inclusion, a
malicious or failed sequencer could permanently block user transactions.

### I-11: FIFO Transaction Ordering

Within each transaction source (mempool, forced queue), transactions MUST be ordered by
arrival time (sequence number). The sequencer CANNOT reorder transactions for MEV or
censorship.

**Source:** RU-L2 (Sequencer)
**Why:** Zero-fee model (I-05) eliminates priority-fee ordering. FIFO provides deterministic
fairness without complex fair-ordering protocols.

### I-12: Block Production Liveness

The sequencer MUST produce L2 blocks at the configured interval (default: 1 second),
even if no transactions are pending (empty blocks are valid). Block production must not
stall due to mempool state, forced queue state, or prover backpressure.

**Source:** RU-L2 (Sequencer)
**Why:** Block liveness is a prerequisite for forced inclusion guarantees. If block production
stops, the deadline-based forced inclusion mechanism breaks.

## Component Interaction Invariants

### I-08: Trace-Witness Bijection

For every valid execution trace, the witness generator MUST produce exactly one valid
witness. For every valid witness, the prover MUST produce exactly one valid proof.

```
trace --(witness_gen)--> witness --(prove)--> proof
```

No information is lost or added in these transformations.

**Source:** RU-L1 + RU-L3
**Why:** The pipeline must be deterministic end-to-end.

### I-13: State Root Computation Latency

State root computation after a block of transactions MUST complete within the block
time budget. For default 1-second blocks with up to 250 transactions:
- Batch update (100 tx): < 50ms (measured: 18.77ms at depth 32)
- Batch update (250 tx): < 50ms (measured: 46.05ms at depth 32)

**Source:** RU-L4 (State Database)
**Why:** If state root computation exceeds the block production interval, the sequencer
cannot keep up with transaction throughput. The ZK prover also depends on correct and
timely state roots.

### I-14: Two-Level State Trie Isolation

The L2 state is organized as a two-level Poseidon SMT:
- Account Trie: address -> Poseidon(nonce, balance, codeHash, storageRoot)
- Storage Trie (per contract): slot -> value

Operations on one account's storage trie MUST NOT affect any other account's storage
trie or the account trie state of unrelated accounts.

**Source:** RU-L4 (State Database), EVM specification
**Why:** Violation of storage isolation between contracts would be a critical security
vulnerability enabling cross-contract state corruption.

### I-15: Hash Function Alignment

The hash function used in the state trie MUST match the hash function used in the ZK
prover circuit. A mismatch would make state proofs unverifiable.

**Source:** RU-L4 (State Database)
**Why:** If the state DB uses Poseidon2 but the circuit expects original Poseidon (or
vice versa), all state transition proofs would be invalid.

### I-16: Witness Completeness

The witness generator MUST produce a witness row for EVERY state-modifying trace entry.
No trace entry may be silently dropped. The total witness row count across all tables
MUST equal the total trace entry count (accounting for entries that produce multiple rows,
e.g., SSTORE produces 2 storage rows for old and new Merkle paths).

**Source:** RU-L3 (Witness Generation)
**Why:** A missing witness row means a state transition goes unproven. The circuit would
either reject the proof (safe) or accept an incomplete proof (catastrophic).

### I-17: Witness Determinism

For any execution trace T, the witness generator MUST produce the same witness W:
```
witness_gen(T) = W  (deterministic, bit-for-bit identical)
```
This applies across runs, machines, and compiler versions.

**Source:** RU-L3 (Witness Generation), extends I-08
**Why:** The prover and verifier must agree on the witness. Non-determinism (e.g., from
HashMap ordering or floating-point arithmetic) would produce different witnesses on
different machines, making proofs non-reproducible.

### I-18: Multi-Table Witness Architecture

The witness MUST be organized as separate tables per EVM operation category:
- Arithmetic table: balance changes, nonce changes, value arithmetic
- Storage table: SLOAD/SSTORE with Merkle proof paths
- Call context table: CALL/CREATE context switches
- (Future: bytecode, memory, stack, Keccak, copy, padding tables)

Each table has a fixed column schema. The global counter field provides cross-table ordering.

**Source:** RU-L3 (Witness Generation), validated by Polygon/Scroll/zkSync architectures
**Why:** Multi-table design enables: (a) independent circuit verification per table,
(b) parallel witness generation per table (future optimization), (c) modular circuit
development (one circuit per table).

### I-19: Witness Generation Performance Budget

Witness generation MUST complete within 1% of total batch proving time. For the target
of < 5 minute batch proving, witness generation must complete in < 3 seconds for any
batch size up to 1000 transactions.

**Source:** RU-L3 (Witness Generation)
**Why:** Witness generation is I/O-bound (field conversions, Merkle proof retrieval).
If it exceeds 1% of proving time, the architecture needs optimization (batch DB queries,
binary serialization, parallel table generation).
Measured: 13.37 ms for 1000 tx (0.004% of 5-minute budget). Margin is 22,000x.

## Performance Targets (Updated)

| Metric | Target | Source |
|--------|--------|--------|
| Witness gen time (1000 tx) | < 3s (1% of 5min) | RU-L3 experiment (measured: 13.37 ms) |
| Witness gen per-tx cost | < 3 ms | RU-L3 experiment (measured: 13.4 us) |
| Witness size (1000 tx, depth 32) | < 10 MB | RU-L3 experiment (measured: 3.0 MB) |
| Witness determinism | 100% | RU-L3 experiment (verified: PASS) |
| Storage table share | ~60-80% | RU-L3 experiment (measured: 78.4%) |

### I-20: L1 Rollup Chain Continuity

The L1 rollup contract MUST enforce that for each enterprise, batch execution advances
the state root chain without gaps, reversals, or forks:
- Batches execute in strict sequential order (no skipping)
- Each batch's new state root becomes the current root atomically
- Committed but unexecuted batches can be reverted; executed batches cannot

**Source:** RU-L5 (Basis Rollup), extends validium INV-S1
**Why:** The three-phase commit-prove-execute model separates state commitment from
finalization. Without sequential execution enforcement, a malicious sequencer could skip
batches or fork the state chain.

### I-21: Proof Before State Finalization

The L1 rollup contract MUST verify a ZK validity proof before finalizing any state root
transition. The three-phase lifecycle enforces: Committed -> Proven -> Executed.
No batch may skip the Proven state.

**Source:** RU-L5 (Basis Rollup), extends validium INV-S2
**Why:** The commit-prove-execute pattern adds a window between commitment and finalization.
If execution could occur without proof verification, invalid state transitions could be finalized.

### I-22: Monotonic L2 Block Ranges

Each batch committed to the L1 rollup MUST declare an L2 block range [l2BlockStart, l2BlockEnd]
where l2BlockStart[N+1] = l2BlockEnd[N] + 1. Block ranges must be non-overlapping and
contiguous.

**Source:** RU-L5 (Basis Rollup)
**Why:** L2 block numbers are used for bridge withdrawal references and forced inclusion
verification. Overlapping or gapped block ranges would break cross-reference integrity.

### I-23: Enterprise Batch Isolation

Each enterprise maintains an independent batch lifecycle (commit/prove/execute counters,
state root chain, L2 block range). Operations on one enterprise's batches MUST NOT affect
any other enterprise's state.

**Source:** RU-L5 (Basis Rollup), extends validium EnterpriseIsolation
**Why:** Per-enterprise L2 chains are the core privacy model. Cross-contamination of batch
state would violate enterprise data boundaries.

### I-24: Batch Revert Safety

Only batches in Committed or Proven status can be reverted. Executed batches MUST NOT be
revertible. Reverting a batch restores all counters and block ranges to their pre-commit
state.

**Source:** RU-L5 (Basis Rollup)
**Why:** Finalized state transitions must be permanent. Allowing revert of executed batches
would break bridge withdrawal guarantees and cross-enterprise references.

### I-25: Bridge No Double Spend

Each withdrawal from L2 can be claimed on L1 exactly once. The bridge contract MUST
maintain a nullifier mapping: once a withdrawal hash is marked as claimed, subsequent
claims with the same hash MUST revert.

**Source:** RU-L7 (Bridge)
**Why:** Double-spend is the most critical bridge vulnerability. If an attacker can claim
the same withdrawal twice, the bridge becomes insolvent (more value leaves than entered).

### I-26: Bridge Balance Conservation

For each enterprise, the total ETH locked in the bridge contract MUST equal:
```
address(bridge).balance >= totalDeposited[enterprise] - totalWithdrawn[enterprise]
```
The bridge MUST NOT release more ETH than was deposited.

**Source:** RU-L7 (Bridge)
**Why:** Balance conservation is the solvency guarantee. Violation means the bridge
cannot honor all withdrawal requests.

### I-27: Escape Hatch Liveness

If no batch is executed on BasisRollup for an enterprise within the configured timeout
(default: 24 hours), ANY user MUST be able to withdraw their funds by providing a Merkle
proof of their balance against the last finalized state root on L1.

**Source:** RU-L7 (Bridge), arxiv 2503.23986
**Why:** The escape hatch is the primary censorship resistance mechanism for the bridge.
Without it, a failed sequencer permanently locks user funds. Enterprise context mitigates
but does not eliminate this risk (hardware failure, natural disaster, legal seizure).

### I-28: Withdrawal Proof Finality

A withdrawal can ONLY be claimed after the batch containing the withdrawal transaction
has reached Executed status on BasisRollup. The bridge MUST verify that the withdraw
trie root corresponds to an executed batch before releasing funds.

**Source:** RU-L7 (Bridge)
**Why:** Claiming against a non-finalized batch would allow the sequencer to revert the
batch after funds are released, creating a double-spend opportunity.

### I-29: Deposit Ordering

Deposits MUST be assigned monotonically increasing IDs per enterprise. The deposit
counter MUST be strictly increasing and never reset.

**Source:** RU-L7 (Bridge)
**Why:** Deposit IDs are used by the relayer to track which deposits have been credited
on L2. Out-of-order or duplicate IDs would cause double-crediting or missed deposits.

### I-30: Escape No Double Spend

In escape mode, each account can withdraw from a given enterprise exactly once. The
escape nullifier is tracked separately from the withdrawal nullifier to prevent
cross-contamination between normal and escape withdrawal paths.

**Source:** RU-L7 (Bridge), arxiv 2503.23986
**Why:** During escape mode, the L2 state is frozen. Users must claim their full balance
in a single transaction. Partial claims would require tracking remaining balances, which
the frozen state cannot support.

### I-31: Withdraw Trie Integrity

The withdraw trie is a keccak256 binary Merkle tree separate from the L2 Poseidon state
trie. The withdraw trie MUST contain exactly the L2->L1 withdrawal messages for a given
batch, and nothing else. The root is submitted to BasisBridge after batch execution.

**Source:** RU-L7 (Bridge), Scroll architecture
**Why:** Using keccak256 (not Poseidon) for the withdraw trie enables gas-efficient
verification on L1 (~48K gas for depth 32 vs ~160K for Poseidon without precompile).
Separating from the state trie prevents coupling between state management and bridge.

## Performance Targets (Updated with Bridge)

| Metric | Target | Source |
|--------|--------|--------|
| L1 rollup commit gas | < 120K (steady) | RU-L5 experiment (measured: 116,147) |
| L1 rollup prove gas (with Groth16) | < 275K | RU-L5 projected (256,455 steady) |
| L1 rollup execute gas | < 80K | RU-L5 experiment (measured: 52,624 steady) |
| L1 rollup total gas/batch | < 500K | RU-L5 projected (425,226 steady with Groth16) |
| Bridge deposit gas | < 70K | RU-L7 experiment (estimated: 61,500) |
| Bridge withdrawal gas | < 100K | RU-L7 experiment (estimated: 82,000) |
| Bridge escape gas | < 150K | RU-L7 experiment (estimated: 118,500) |
| Deposit latency | < 5 min | RU-L7 experiment (estimated: 4.6s default) |
| Withdrawal latency | < 30 min | RU-L7 experiment (estimated: 21.1s default) |
| Escape hatch timeout | 24 hours | RU-L7 design (configurable) |

### I-32: DAC Verifiable Encoding

Every erasure-coded chunk distributed to DAC members MUST be verifiable against a
polynomial commitment (KZG). A node receiving an invalid chunk MUST reject it and
not attest to data availability.

**Source:** RU-L8 (Production DAC)
**Why:** Without verifiable encoding, a malicious disperser could send invalid RS chunks.
Nodes would attest to "available" data that is actually irrecoverable.

### I-33: DAC Data Recoverability

If at least k=5 of n=7 DAC nodes store valid chunks, the complete batch data MUST be
recoverable by: (a) collecting any 5 RS chunks, (b) RS-decoding to ciphertext,
(c) collecting 5 Shamir key shares, (d) recovering AES key, (e) decrypting.

**Source:** RU-L8 (Production DAC)
**Why:** This is the fundamental availability guarantee. If data cannot be recovered
from k nodes, the DAC fails its purpose.

### I-34: DAC Enterprise Privacy

No individual DAC node (or coalition of fewer than k=5 nodes) can reconstruct the
batch data. Each chunk is AES-256-GCM encrypted ciphertext, and each Shamir key share
reveals zero information about the AES key (information-theoretic guarantee).

**Source:** RU-L8 (Production DAC), extends validium INV-DA1
**Why:** Enterprise data must remain private from individual DAC operators. The hybrid
AES+Shamir approach provides computational data privacy with perfect key secrecy.

### I-35: DAC Attestation Liveness

If at least 5 of 7 DAC nodes are online and the batch data is correctly encoded,
attestation MUST complete within 1 second. If fewer than 5 nodes are available,
the system MUST fall back to on-chain DA.

**Source:** RU-L8 (Production DAC)
**Why:** The 1-second target ensures attestation does not become a bottleneck in the
batch proving pipeline. Measured: 8.9 ms at 1 MB (96x margin).

### I-36: DAC Availability Guarantee

With per-node availability p >= 0.99 (enterprise-grade infrastructure), the probability
that batch data is available (at least k=5 of n=7 nodes online) MUST exceed 99.99%.

**Source:** RU-L8 (Production DAC)
**Why:** Enterprise SLAs require high availability. Measured: 99.997% (4.5 nines) at p=0.99.

## Performance Targets (Updated with Production DAC)

| Metric | Target | Source |
|--------|--------|--------|
| DAC attestation latency (500 KB) | < 1s | RU-L8 experiment (measured: 4.5 ms) |
| DAC attestation latency (1 MB) | < 1s | RU-L8 experiment (measured: 8.9 ms) |
| DAC storage overhead | < 2x | RU-L8 experiment (measured: 1.40x) |
| DAC recovery time (1 MB) | < 100 ms | RU-L8 experiment (measured: 0.95 ms) |
| DAC availability (p=0.99) | > 99.9% | RU-L8 experiment (measured: 99.997%) |
| DAC failure tolerance | 2 nodes | RU-L8 experiment (verified: 2 of 7) |

### I-37: Proof System Agnosticism

The L1 rollup verification infrastructure MUST support multiple proof systems via a
verifier router pattern. During migration periods, BasisRollup.sol accepts both legacy
(Groth16) and target (PLONK/halo2-KZG) proof formats. A batch is valid if ANY accepted
verifier confirms the proof.

**Source:** RU-L9 (PLONK Migration)
**Why:** Circuit evolution is frequent during active development. Per-circuit trusted setup
(Groth16) creates a hard dependency between circuit changes and ceremony execution.
Universal SRS (PLONK/halo2-KZG) eliminates this, but the migration itself requires a
dual verification period to prevent gaps.

### I-38: Universal SRS Reuse

The ZK prover MUST use a proof system with a universal Structured Reference String (SRS)
that is reusable across all circuit configurations. Per-circuit trusted setup ceremonies
are not acceptable for production deployment due to operational overhead and security
ceremony coordination requirements.

**Source:** RU-L9 (PLONK Migration), TD-003
**Why:** Enterprise circuits evolve as new EVM opcodes are supported, batch sizes change,
and optimizations are applied. A universal SRS (one ceremony) enables circuit changes
without re-running setup ceremonies.

### I-39: Proof Size Bound

ZK proofs submitted to the L1 rollup contract MUST be < 1KB in size. This ensures
reasonable calldata costs and storage efficiency for on-chain proof archives.

**Source:** RU-L9 (PLONK Migration)
**Why:** Measured: Groth16 proofs are 128 bytes (constant). halo2-KZG proofs are 672-800
bytes. FRI/STARK proofs are 43-130KB (rejected). The 1KB bound eliminates FRI-based
systems from consideration for direct on-chain verification.

## Performance Targets (Updated with PLONK Migration)

| Metric | Target | Source |
|--------|--------|--------|
| Proof size (PLONK/halo2-KZG) | < 1KB | RU-L9 experiment (measured: 672-800 bytes) |
| L1 verification gas (PLONK) | < 500K | RU-L9 literature (Axiom: 420K, general: 290-300K) |
| Proving time ratio (PLONK/Groth16) | < 2x at production scale | RU-L9 experiment (measured: 1.2x at 500 steps) |
| Custom gate row reduction (Poseidon) | > 5x vs R1CS | RU-L9 analysis (projected: 17x for full Poseidon) |
| SRS degree (k) | k=20 (1M rows max) | RU-L9 analysis (enterprise circuits ~50K rows) |

## Experiment Log

| Date | Experiment | Invariants Affected | Update |
|------|-----------|---------------------|--------|
| 2026-03-19 | RU-L1: EVM Executor | I-01 through I-06 | Initial creation |
| 2026-03-19 | RU-L2: Sequencer | I-09 through I-12 | Added sequencer invariants, performance targets |
| 2026-03-19 | RU-L4: State Database | I-06 (refined), I-13 through I-15 | State root latency, trie isolation, hash alignment |
| 2026-03-19 | RU-L3: Witness Generation | I-08 (refined), I-16 through I-19 | Witness completeness, determinism, multi-table, performance budget |
| 2026-03-19 | RU-L5: Basis Rollup | I-20 through I-24 | L1 rollup contract invariants, gas performance targets |
| 2026-03-19 | RU-L7: Bridge | I-25 through I-31 | Bridge security invariants, gas and latency targets |
| 2026-03-19 | RU-L8: Production DAC | I-32 through I-36 | DAC verifiable encoding, recoverability, privacy, liveness, availability |
| 2026-03-19 | RU-L9: PLONK Migration | I-37 through I-39 | Proof system agnosticism, universal SRS, proof size bound |
