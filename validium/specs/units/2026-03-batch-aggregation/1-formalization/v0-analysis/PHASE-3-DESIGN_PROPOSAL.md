# Phase 3: Design Proposal -- Batch Aggregation (RU-V4)

> Unit: `validium/specs/units/2026-03-batch-aggregation/`
> Target: validium | Date: 2026-03-18
> Role: The Protocol Architect

---

## 1. Violated Invariant

**NoLoss** (Transaction Conservation):

```
NoLoss == pending \cup UncommittedWalTxSet \cup BatchedTxSet \cup ProcessedTxSet = AllTxs
```

Every transaction must be accounted for in exactly one of four states: pending
(not yet submitted), uncommitted in WAL (after checkpoint, recoverable), in a
formed batch (volatile), or in a processed batch (durably consumed). The union
of all four must equal the full transaction universe at all times.

---

## 2. Counterexample Narrative

TLC found a 6-state violation trace. Step-by-step reconstruction:

### State 1: Init

All 10 transactions are pending. The system is up with empty queues.

| Variable | Value |
|----------|-------|
| pending | {tx1, tx2, tx3, tx4, tx5, tx6, tx7, tx8, tx9, tx10} |
| queue | <<>> |
| wal | <<>> |
| checkpointSeq | 0 |
| batches | <<>> |
| processed | <<>> |
| systemUp | TRUE |
| timerExpired | FALSE |

### State 2: Enqueue(tx1)

tx1 is persisted to WAL and added to in-memory queue. WAL-first protocol
ensures durability.

| Variable | Change |
|----------|--------|
| pending | {tx2..tx10} (tx1 removed) |
| queue | <<tx1>> |
| wal | <<tx1>> |

Conservation: {tx2..tx10} U {tx1} U {} U {} = AllTxs. **HOLDS.**

### State 3: Enqueue(tx2)

tx2 is persisted to WAL and added to queue.

| Variable | Change |
|----------|--------|
| pending | {tx3..tx10} |
| queue | <<tx1, tx2>> |
| wal | <<tx1, tx2>> |

Conservation: {tx3..tx10} U {tx1, tx2} U {} U {} = AllTxs. **HOLDS.**

### State 4: TimerTick

The time threshold is nondeterministically triggered. The queue has 2 txs
(below the size threshold of 4), so the timer enables a time-triggered batch.

| Variable | Change |
|----------|--------|
| timerExpired | TRUE |

Conservation unchanged. **HOLDS.**

### State 5: FormBatch (time-triggered, batch of 2)

The HYBRID strategy triggers: `timerExpired /\ Len(queue) > 0`. A batch of 2
transactions is formed. The WAL checkpoint advances to 2, marking tx1 and tx2
as "committed."

| Variable | Change |
|----------|--------|
| batches | <<<<tx1, tx2>>>> |
| queue | <<>> |
| checkpointSeq | **2** (advanced from 0) |
| timerExpired | FALSE |

Conservation: {tx3..tx10} U {} U {tx1, tx2} U {} = AllTxs. **HOLDS.**

**Critical moment**: tx1, tx2 are now in `batches` (volatile memory) but have
been checkpointed out of the WAL recovery window. Their durability depends
entirely on the batch object surviving in memory.

### State 6: Crash

The system crashes. All volatile state is destroyed.

| Variable | Change |
|----------|--------|
| queue | <<>> (cleared) |
| batches | **<<>>** (cleared -- tx1, tx2 destroyed) |
| systemUp | FALSE |

Conservation check:
```
pending          = {tx3, tx4, tx5, tx6, tx7, tx8, tx9, tx10}
UncommittedWalTxSet = {wal[i] : i in 3..2} = {}   (checkpointSeq=2, Len(wal)=2)
BatchedTxSet     = {}                                (batches cleared by crash)
ProcessedTxSet   = {}                                (nothing processed yet)

Union = {tx3..tx10} != {tx1..tx10} = AllTxs
```

**NoLoss VIOLATED.** tx1 and tx2 are irrecoverably lost.

On subsequent Recover, `queue' = SubSeq(wal, 3, 2) = <<>>`. The WAL considers
positions 1-2 as committed (at or before checkpoint). tx1 and tx2 are never
seen again.

---

## 3. Root Cause Analysis

The protocol checkpoints the WAL at **batch formation time**, not at **batch
processing time**. This creates a durability gap between two events:

1. **FormBatch**: Dequeues txs from the queue, creates a batch in volatile
   memory, and advances `checkpointSeq` to mark those txs as committed in
   the WAL. From this point, the WAL considers those txs "consumed."

2. **ProcessBatch**: Hands the batch to downstream systems (ZK proof
   generation, L1 submission). Only after this step are the txs truly
   consumed.

Between these two events, the batch exists **only in volatile memory**. The
WAL has already discarded responsibility for those txs (they are before the
checkpoint). If the system crashes in this window, the txs are in none of:
pending (already enqueued), uncommitted WAL (checkpointed away), batches
(volatile, lost), or processed (never reached). They cease to exist.

**Window of vulnerability**: The duration of ZK proof generation (1.9s-12.8s
from RU-V2 benchmarks) plus L1 transaction submission and confirmation. In
production, this window is seconds to minutes per batch.

**Fundamental error**: The WAL checkpoint is a **promise of durability**. By
advancing it at FormBatch, the protocol promises that those txs have been
durably delivered -- but they have not. The batch is a volatile JavaScript
object with no disk backing.

---

## 4. Solution Options

### Option A: Conservative Fix -- Defer Checkpoint to ProcessBatch

**Mechanism**: Move the WAL checkpoint advancement from `FormBatch` to
`ProcessBatch`. The checkpoint only advances after the batch has been fully
consumed by downstream systems (proof generated AND submitted to L1).

**TLA+ Sketch**:

```tla+
\* FormBatch: NO checkpoint advancement
FormBatch ==
    /\ systemUp
    /\ \/ Len(queue) >= BatchSizeThreshold
       \/ (timerExpired /\ Len(queue) > 0)
    /\ LET batchSize == IF Len(queue) >= BatchSizeThreshold
                         THEN BatchSizeThreshold
                         ELSE Len(queue)
           batch == SubSeq(queue, 1, batchSize)
       IN /\ batches' = Append(batches, batch)
          /\ queue' = SubSeq(queue, batchSize + 1, Len(queue))
          /\ timerExpired' = FALSE
    /\ UNCHANGED << wal, checkpointSeq, processed, pending, systemUp >>

\* ProcessBatch: checkpoint advances HERE
ProcessBatch ==
    /\ systemUp
    /\ Len(batches) > 0
    /\ processed' = Append(processed, Head(batches))
    /\ batches' = Tail(batches)
    /\ checkpointSeq' = checkpointSeq + Len(Head(batches))
    /\ UNCHANGED << queue, wal, pending, systemUp, timerExpired >>
```

**Crash recovery behavior**: On crash, both `queue` and `batches` are lost.
On recovery, `queue' = SubSeq(wal, checkpointSeq+1, Len(wal))` restores ALL
uncommitted txs, including those that were in batches. The txs are re-batched
and re-processed from scratch.

**Impact**:

| Dimension | Assessment |
|-----------|------------|
| Safety | MAXIMUM. Checkpoint is a true durability guarantee. |
| Liveness | Preserved. Crash causes re-processing, not loss. Bounded overhead: at most one batch re-proved per crash. |
| Complexity | MINIMAL. One line moved from FormBatch to ProcessBatch. |
| Throughput | Unchanged. Normal-path operation is identical. |
| Recovery cost | Higher than v0. Crashed batch must be re-formed and re-proved (1.9s-12.8s). Acceptable given MTBF >> proving time. |

### Option B: Aggressive Fix -- Defer Checkpoint to After Proof Generation

**Mechanism**: Introduce a durable batch storage layer. After proof generation
(but before L1 submission), persist the batch + proof to disk and advance the
checkpoint. L1 submission reads from durable storage.

**TLA+ Sketch**:

```tla+
VARIABLES
    ...,
    durableBatches  \* Batches persisted to disk after proof generation

\* FormBatch: same as Option A (no checkpoint)
FormBatch == ...

\* NEW: Persist batch after proof generation
PersistProvenBatch ==
    /\ systemUp
    /\ Len(batches) > 0
    /\ durableBatches' = Append(durableBatches, Head(batches))
    /\ batches' = Tail(batches)
    /\ checkpointSeq' = checkpointSeq + Len(Head(batches))
    /\ UNCHANGED << queue, wal, processed, pending, systemUp, timerExpired >>

\* ProcessBatch: L1 submission from durable storage
ProcessBatch ==
    /\ systemUp
    /\ Len(durableBatches) > 0
    /\ processed' = Append(processed, Head(durableBatches))
    /\ durableBatches' = Tail(durableBatches)
    /\ UNCHANGED << queue, wal, checkpointSeq, batches, pending, systemUp, timerExpired >>
```

**Crash recovery behavior**: On crash, volatile `batches` are lost (re-formed
from WAL). Durable `durableBatches` survive. Recovery re-queues uncommitted
txs and resumes L1 submission of already-proven batches.

**Impact**:

| Dimension | Assessment |
|-----------|------------|
| Safety | Good. No tx loss. But introduces a second durable store that must be synchronized with the WAL. |
| Liveness | Higher. Crash after proof preserves the proof -- only L1 submission needed on recovery. |
| Complexity | HIGHER. Adds 1 variable, 1 action, modifies Crash/Recover. Two durable stores to manage. |
| Throughput | Marginal improvement. Saves re-proving cost on recovery (1.9s-12.8s per batch). |
| Recovery cost | Lower than Option A. Already-proven batches skip proof generation. |

---

## 5. Selected Option: A (Conservative Fix)

**Rationale** (evaluated against: Safety > Privacy > Simplicity > Speed):

1. **Safety** (decisive): Both options achieve zero transaction loss. Option A
   has a smaller trusted computing base: one durable store (WAL) with one
   consistency invariant. Option B introduces a second durable store
   (`durableBatches`) that must be crash-consistent with the WAL -- a new
   failure surface.

2. **Privacy** (neutral): Neither option affects data privacy properties.

3. **Simplicity** (strong advantage): Option A requires moving one assignment
   (`checkpointSeq' = ...`) from `FormBatch` to `ProcessBatch`. Option B adds
   a new variable, a new action, and complicates crash recovery. For an MVP,
   the simpler model is strictly preferable.

4. **Speed** (marginal disadvantage): Option A re-proves crashed batches on
   recovery. The cost is 1.9s-12.8s per batch per crash. With typical
   production MTBF (hours to days), the expected overhead is negligible:
   one re-proof per crash event, amortized over thousands of normal batches.

**Option B deferred to production hardening**: The durable batch storage
optimization is valuable for high-availability deployments where even a single
re-proof is unacceptable. It should be a separate research unit after the
MVP architecture is verified.

---

## 6. Invariant Reformulation

The fix changes the checkpoint boundary, which requires updating invariants
that reference the relationship between `checkpointSeq`, `batches`, and
`UncommittedWalTxSet`.

### NoLoss (simplified from 4-way to 3-way partition)

**v0** (violated):
```
pending U UncommittedWalTxSet U BatchedTxSet U ProcessedTxSet = AllTxs
```

**v1-fix**:
```
pending U UncommittedWalTxSet U ProcessedTxSet = AllTxs
```

In v1-fix, `UncommittedWalTxSet` (WAL entries after checkpoint) includes BOTH
queued and batched txs. `BatchedTxSet` is a subset of `UncommittedWalTxSet`,
not a separate partition. The 3-way formulation is strictly WAL-based and holds
across crash boundaries without depending on volatile state.

This is NOT a weakening. The 3-way invariant is stronger in a critical
dimension: it does not reference `BatchedTxSet` (volatile), so it cannot be
defeated by crash. The internal partition of the uncommitted segment
(batches vs queue) is verified by `QueueWalConsistency`.

### NoDuplication (updated to 3-way)

**v0**: 6 pairwise disjointness checks across 4 sets.
**v1-fix**: 3 pairwise disjointness checks across 3 durable sets.

### QueueWalConsistency (extended to include batches)

**v0**: `systemUp => queue = SubSeq(wal, checkpointSeq+1, Len(wal))`
**v1-fix**: `systemUp => Flatten(batches) \o queue = SubSeq(wal, checkpointSeq+1, Len(wal))`

The uncommitted WAL segment now contains both batched and queued txs. This
invariant verifies their concatenation matches the WAL in exact FIFO order.

### FIFOOrdering (extended to full WAL)

**v0**: `Flatten(processed) \o Flatten(batches) = SubSeq(wal, 1, checkpointSeq)`
**v1-fix**: `Flatten(processed) \o Flatten(batches) \o queue = wal`

The full concatenation of processed, batched, and queued txs must equal the
entire WAL. This is the strongest ordering invariant: it implies
`QueueWalConsistency` and additionally verifies that `Flatten(processed) =
SubSeq(wal, 1, checkpointSeq)`.

### BatchSizeBound and TypeOK

Unchanged. These are structural properties independent of checkpoint timing.

---

## 7. Verification Strategy

1. **Fork** `v0-analysis/` to `v1-fix/`.
2. **Modify** `FormBatch`: remove `checkpointSeq' = checkpointSeq + batchSize`.
3. **Modify** `ProcessBatch`: add `checkpointSeq' = checkpointSeq + Len(Head(batches))`.
4. **Update** invariants: NoLoss (3-way), NoDuplication (3-way), QueueWalConsistency (batches + queue), FIFOOrdering (full WAL).
5. **Reduce model**: 4 txs, batch size 2 (sufficient for full-state exploration in reasonable time).
6. **Run TLC**: BFS, all invariants + EventualProcessing.
7. **Expected result**: PASS on all 6 invariants and 1 liveness property.
8. **Counterexample replay**: Verify the v0 trace no longer violates NoLoss.

---

## 8. Impact Analysis

| Dimension | v0 (Current) | v1-fix (Proposed) |
|-----------|-------------|-------------------|
| Checkpoint timing | FormBatch | ProcessBatch |
| NoLoss | VIOLATED | Expected PASS |
| Crash recovery | Loses batch txs | Recovers all txs |
| Recovery overhead | None (txs lost) | Re-form + re-prove one batch |
| Durable stores | WAL only | WAL only |
| State variables | 8 | 8 (unchanged) |
| Actions | 6 | 6 (unchanged) |
| Invariants | 6 + 1 property | 6 + 1 property (reformulated) |
| Implementation change | N/A | Move checkpoint call from formBatch() to after downstream consumption |
