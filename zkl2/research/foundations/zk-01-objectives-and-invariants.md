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

## Experiment Log

| Date | Experiment | Invariants Affected | Update |
|------|-----------|---------------------|--------|
| 2026-03-19 | RU-L1: EVM Executor | I-01 through I-06 | Initial creation |
