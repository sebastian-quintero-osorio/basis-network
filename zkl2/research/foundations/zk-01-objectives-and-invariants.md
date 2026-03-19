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

## Experiment Log

| Date | Experiment | Invariants Affected | Update |
|------|-----------|---------------------|--------|
| 2026-03-19 | RU-L1: EVM Executor | I-01 through I-06 | Initial creation |
| 2026-03-19 | RU-L2: Sequencer | I-09 through I-12 | Added sequencer invariants, performance targets |
| 2026-03-19 | RU-L4: State Database | I-06 (refined), I-13 through I-15 | State root latency, trie isolation, hash alignment |
| 2026-03-19 | RU-L3: Witness Generation | I-08 (refined), I-16 through I-19 | Witness completeness, determinism, multi-table, performance budget |
