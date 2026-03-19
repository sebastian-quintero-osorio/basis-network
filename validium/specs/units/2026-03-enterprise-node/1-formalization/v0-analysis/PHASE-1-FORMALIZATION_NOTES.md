# Phase 1: Formalization Notes -- Enterprise Node Orchestrator

## Unit Information

- **Unit**: RU-V5 Enterprise Node Orchestrator
- **Target**: validium
- **Date**: 2026-03-18
- **Phase**: 1 -- Formalize Research
- **Result**: PASS (all 8 safety invariants + 1 liveness property verified)

---

## 1. Research-to-Specification Mapping

### 1.1 State Machine Mapping

| Source (REPORT.md / code) | TLA+ Element | Notes |
|---------------------------|--------------|-------|
| `NodeState` enum (types.ts:6-13) | `States` set | 6 states: Idle, Receiving, Batching, Proving, Submitting, Error |
| `TRANSITION_TABLE` (state-machine.ts:12-42) | `ReceiveTx`, `FormBatch`, `GenerateWitness`, `GenerateProof`, `SubmitBatch`, `ConfirmBatch`, `Crash`, `L1Reject`, `Retry` | 11 actions modeling all transitions |
| Pipelined ingestion (REPORT.md 2.1) | `ReceiveTx` guard: `nodeState \in {"Idle", "Receiving", "Proving", "Submitting"}` | Txs accepted during proving/submitting |
| Batch loop monitoring (REPORT.md 2.2) | `CheckQueue` action | Detects queued txs after ConfirmBatch returns to Idle |
| HYBRID batch formation (REPORT.md 2.2) | `FormBatch` with `timerExpired` disjunct | Size OR time threshold triggers |
| Async proving (REPORT.md 2.1) | `GenerateProof` action | Modeled as atomic step (abstraction of child process) |

### 1.2 State Variable Mapping

| Source Concept | TLA+ Variable | Type | Durable? |
|----------------|---------------|------|----------|
| Node state (types.ts) | `nodeState` | States | Volatile |
| Transaction queue (orchestrator.ts:181-198) | `txQueue` | Seq(AllTxs) | Volatile |
| Write-Ahead Log (RU-V4) | `wal` | Seq(AllTxs) | Durable |
| WAL checkpoint (RU-V4 v1-fix) | `walCheckpoint` | Nat | Durable |
| SMT root hash (RU-V1) | `smtState` | SUBSET AllTxs | Volatile (checkpointed) |
| Current batch (orchestrator.ts:323-348) | `batchTxs` | Seq(AllTxs) | Volatile |
| Pre-batch SMT state (orchestrator.ts:328) | `batchPrevSmt` | SUBSET AllTxs | Volatile |
| L1 confirmed state (StateCommitment.sol, RU-V3) | `l1State` | SUBSET AllTxs | Durable (on-chain) |
| External data exposure (REPORT.md 2.4) | `dataExposed` | SUBSET DataKinds | N/A (tracking) |
| Pending transactions | `pending` | SUBSET AllTxs | Environment |
| Crash counter | `crashCount` | Nat | N/A (model bound) |
| Timer threshold (types.ts:187) | `timerExpired` | BOOLEAN | Volatile |

### 1.3 Invariant Mapping

| Source Invariant (REPORT.md 7.2) | TLA+ Property | Type | Verified |
|----------------------------------|---------------|------|----------|
| INV-NO1: Liveness | `EventualConfirmation` | Temporal (liveness) | PASS |
| INV-NO2: Proof-State Root Integrity | `ProofStateIntegrity` | Safety invariant | PASS |
| INV-NO3: Privacy / Zero Data Leakage | `NoDataLeakage` | Safety invariant | PASS |
| INV-NO4: Crash Recovery / No Loss | `NoTransactionLoss` | Safety invariant | PASS |
| INV-NO4 complement | `NoDuplication` | Safety invariant | PASS |
| INV-NO5: State Root Continuity | `StateRootContinuity` | Safety invariant | PASS |
| INV-NO6: Single Writer | Enforced by construction | Design constraint | N/A |
| (Derived from RU-V4) | `QueueWalConsistency` | Safety invariant | PASS |
| (Derived from circuit capacity) | `BatchSizeBound` | Safety invariant | PASS |
| (Structural) | `TypeOK` | Type invariant | PASS |

### 1.4 Scenario Coverage

| Scenario | How Modeled | Coverage |
|----------|-------------|----------|
| Happy path | Full cycle: Idle -> Receive -> Batch -> Prove -> Submit -> Confirm -> Idle | Exhaustive |
| Crash during proving | `Crash` action enabled in Proving state | All interleavings explored |
| Crash during batching | `Crash` action enabled in Batching state | All interleavings explored |
| Crash during receiving | `Crash` action enabled in Receiving state | All interleavings explored |
| Crash during submitting | `Crash` action enabled in Submitting state | All interleavings explored |
| L1 rejection | `L1Reject` action from Submitting state | All interleavings explored |
| Concurrent submissions | `ReceiveTx` during Proving/Submitting | All orderings explored |
| Timer-triggered batch | `TimerTick` + sub-threshold `FormBatch` | All interleavings explored |
| Double crash | `MaxCrashes = 2` allows crash -> recover -> crash -> recover | All sequences explored |
| Crash + L1 reject | Combined adversarial scenarios | All interleavings explored |

---

## 2. Modeling Assumptions

### 2.1 Abstractions (Sound Over-Approximations)

| Abstraction | Justification |
|-------------|---------------|
| SMT root = set of applied txs | Collision-free by construction. Each unique set maps to a unique root. Strictly more permissive than a real hash function (no hash collisions to worry about). |
| Proof generation is atomic | Abstracts the async child process. Sound because the spec captures the state before (Proving) and after (Submitting) proof generation, which is what the invariants check. |
| L1 submission is atomic | Abstracts the RPC call + block confirmation. The choice between Confirm and L1Reject models the nondeterministic outcome. |
| Timer is nondeterministic | `TimerTick` can fire at any time in Receiving with a non-empty queue. Explores strictly more behaviors than a real timer (sound for safety). |
| Crash loses all volatile state instantly | No partial persistence modeled. Sound over-approximation: partial persistence would leave more data available, making recovery easier. |
| DAC attestation bundled with L1 submission | Both are external data exposure events. Separating them would not change the privacy invariant. |

### 2.2 Design Decisions

| Decision | Rationale |
|----------|-----------|
| Deferred WAL checkpoint (from RU-V4 v1-fix) | Checkpoint advances only after L1 confirmation, not at batch formation. Prevents the durability gap discovered in BatchAggregation v0. |
| `CheckQueue` action added | The transition table in REPORT.md Section 7.1 does not explicitly model queue detection in Idle. The pipelined architecture (Section 2.2) requires it: the batch loop monitors the queue. Without it, pipelined txs in the queue after ConfirmBatch would never be processed (liveness violation). |
| `Done` stuttering action | Prevents TLC from flagging the legitimate terminal state (all txs confirmed) as a deadlock. The terminal state is the desired end state. |
| No separate `batchSubmitted` guard | SubmitBatch and ConfirmBatch are both enabled in Submitting independently. This over-approximation does not affect any invariant (the privacy invariant holds regardless of SubmitBatch ordering). |

---

## 3. Verification Results

### 3.1 TLC Output Summary

```
TLC2 Version 2.16 of 31 December 2020 (rev: cdddf55)
Workers: 4 on 20 cores, 7252MB heap

States generated:  3,958
Distinct states:   1,693
Queue remaining:   0 (complete exploration)
Search depth:      20
Max outdegree:     4
Runtime:           2 seconds

Result: Model checking completed. No error has been found.
Fingerprint collision probability: 2.1E-13
```

### 3.2 Property Results

| Property | Type | Result |
|----------|------|--------|
| TypeOK | Invariant | PASS |
| ProofStateIntegrity | Invariant | PASS |
| NoDataLeakage | Invariant | PASS |
| NoTransactionLoss | Invariant | PASS |
| NoDuplication | Invariant | PASS |
| StateRootContinuity | Invariant | PASS |
| QueueWalConsistency | Invariant | PASS |
| BatchSizeBound | Invariant | PASS |
| EventualConfirmation | Temporal | PASS |

### 3.3 Model Configuration

| Parameter | Value | Justification |
|-----------|-------|---------------|
| AllTxs | {tx1, tx2, tx3} | 3 txs: 1 full batch (2 txs) + 1 timer-triggered batch (1 tx) |
| BatchThreshold | 2 | Exercises both size-triggered and time-triggered batches |
| MaxCrashes | 2 | Explores double-crash scenarios at every interleaving |

### 3.4 Reproduction Instructions

```bash
cd validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/experiments/EnterpriseNode/_build
java -cp ../../../../../../../../../lab/2-logicist/tools/tla2tools.jar \
    tlc2.TLC MC_EnterpriseNode -workers 4 -config MC_EnterpriseNode.cfg
```

---

## 4. Open Issues

### 4.1 CheckQueue Action (Design Gap in Research)

The state machine transition table in REPORT.md Section 7.1 does not include a
transition from Idle to Receiving when the queue is non-empty. The only way to
enter Receiving from Idle is via `TransactionReceived`. This means pipelined
transactions (received during proving/submitting) that remain in the queue after
ConfirmBatch returns to Idle would never be processed if no new transactions
arrive.

The `CheckQueue` action was added to model the batch loop's queue monitoring
described in REPORT.md Section 2.2 ("Batch loop: Monitors queue, forms batches
when threshold met"). The Architect should ensure the implementation includes
this queue detection mechanism.

**Recommendation**: Add an explicit `QueueNonEmpty` event to the transition
table: `Idle --[QueueNonEmpty]--> Receiving`.

### 4.2 SubmitBatch Ordering

The current model allows `ConfirmBatch` to fire without `SubmitBatch` having
fired first. This is an over-approximation: in the real system, L1 cannot
confirm a batch that was never submitted. However, this does not affect any
verified invariant (the privacy invariant holds regardless of SubmitBatch
ordering). A more precise model could add a `batchSubmitted` boolean guard.

### 4.3 INV-NO6 Single Writer

The Single Writer invariant (only the batch loop modifies the SMT) is enforced
by the state machine design: only `GenerateWitness` adds transactions to
`smtState`, and it requires `nodeState = "Batching"`. This is a structural
guarantee, not a separately checked invariant. The `StateRootContinuity`
invariant provides equivalent verification by checking that `smtState` is
consistent with the processing phase.

---

## 5. Conclusion

The Enterprise Node Orchestrator specification passes all 8 safety invariants
and the liveness property across 1,693 distinct states with exhaustive
exploration. The protocol design is sound: crash recovery preserves all
transactions via WAL replay, state root chain integrity is maintained through
the deferred checkpoint pattern, and no raw enterprise data crosses the node
boundary.

The specification is ready for Phase 2 audit.
