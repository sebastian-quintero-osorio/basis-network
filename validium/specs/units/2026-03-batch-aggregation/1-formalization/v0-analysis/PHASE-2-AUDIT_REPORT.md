# Phase 2: Audit Report -- Batch Aggregation (RU-V4)

> Unit: `validium/specs/units/2026-03-batch-aggregation/`
> Target: validium | Date: 2026-03-18
> Auditor role: The Auditor (integrity verification of Phase 1 formalization)

---

## 1. Structural Mapping

Side-by-side comparison of `0-input/` source materials and the TLA+ specification.

### 1.1 Data Structures

| Source (TypeScript) | TLA+ | Faithful? | Notes |
|---------------------|------|-----------|-------|
| `Transaction` (types.ts:3-10) | Element of `AllTxs` | YES | Abstracted to identifiers. Fields (txHash, key, oldValue, newValue, enterpriseId, timestamp) are not modeled because no invariant depends on transaction contents -- only on identity and ordering. |
| `WALEntry` (types.ts:13-18) | Element of `wal` sequence | YES | Seq number is the position in the `wal` sequence. Checksum is an implementation detail (integrity, not protocol). |
| `WALCheckpoint` (types.ts:21-26) | `checkpointSeq` integer | YES | Simplified from a record to a high-water mark. The checkpoint's batchId is not needed for safety properties. |
| `Batch` (types.ts:29-37) | Element of `batches` or `processed` (Seq of txs) | YES | Batch metadata (batchId, batchNum, formationLatencyMs, strategy) omitted. Only the tx sequence matters for conservation and ordering. |
| `QueueItem` (persistent-queue.ts:5-8) | Element of `queue` sequence | YES | The `seq` field is the implicit position in `queue`. |

### 1.2 State Transitions

| Source Operation | TLA+ Action | Faithful? | Notes |
|------------------|-------------|-----------|-------|
| `PersistentQueue.enqueue()` (line 31-36) | `Enqueue(tx)` | YES | WAL append then queue push. Atomic in spec (no intermediate crash point between WAL write and queue push). See Section 2.2 for analysis. |
| `BatchAggregator.shouldFormBatch()` (lines 37-53) | `FormBatch` guard | YES | HYBRID strategy: `Len(queue) >= threshold \/ (timerExpired /\ Len(queue) > 0)`. Matches SIZE case (line 42), TIME case (line 45), HYBRID case (lines 48-51). |
| `BatchAggregator.formBatch()` (lines 56-91) | `FormBatch` body | YES | Dequeue min(available, threshold), append to batches, checkpoint WAL. The spec faithfully models the checkpoint-at-formation design choice. |
| `PersistentQueue.checkpoint()` (lines 62-64) | `checkpointSeq' = checkpointSeq + batchSize` | YES | Advances the high-water mark by the number of dequeued txs. |
| `WriteAheadLog.recover()` (lines 110-147) | `Recover` | YES | Rebuilds queue from entries after last checkpoint. `SubSeq(wal, checkpointSeq+1, Len(wal))` matches the source's sorted-seq-after-checkpoint logic. |
| `BatchAggregator.forceBatch()` (lines 94-120) | Not modeled | ACCEPTABLE | `forceBatch` is an operational concern (shutdown/flush). Its safety properties are identical to `FormBatch` (same checkpoint behavior). |
| `WriteAheadLog.compact()` (lines 150-177) | Not modeled | ACCEPTABLE | Compaction is an optimization that removes already-checkpointed entries. It does not affect the protocol's safety properties (checkpointed entries are already excluded from recovery). |

### 1.3 Crash Model

| Source Behavior | TLA+ Model | Faithful? | Notes |
|-----------------|------------|-----------|-------|
| Process termination | `Crash` action | YES | Clears all volatile state (queue, batches). Preserves durable state (wal, checkpointSeq, processed). |
| WAL persistence across crash | `wal` unchanged in `Crash` | YES | The WAL is an append-only file on disk. Crash does not modify it. |
| Recovery replay | `Recover` action | YES | Queue rebuilt from uncommitted WAL entries. Matches `wal.ts` recover() logic exactly. |

---

## 2. Hallucination Detection

### 2.1 Mechanisms Present in Spec but Not in Source

| Mechanism | Present in Spec? | Present in Source? | Verdict |
|-----------|------------------|--------------------|---------|
| `ProcessBatch` action | YES | NO (implicit) | **JUSTIFIED ADDITION** |
| `timerExpired` flag + `TimerTick` | YES | Implicit (performance.now()) | **JUSTIFIED ABSTRACTION** |
| `processed` variable | YES | NO (batches returned to caller) | **JUSTIFIED ADDITION** |
| `pending` variable | YES | NO (txs arrive externally) | **JUSTIFIED ADDITION** |

**ProcessBatch**: The source code returns the formed batch to the caller but does not track
what happens next. The spec needs `ProcessBatch` to model the complete transaction lifecycle
and verify end-to-end delivery (`NoLoss`). Without it, we cannot distinguish "batch formed
but not yet consumed" from "batch consumed." This is a necessary model extension, not a
hallucination.

**TimerTick**: The source uses `performance.now() - this.lastBatchTime` to check elapsed
time. TLA+ cannot model real-time clocks. The nondeterministic `TimerTick` is a standard
abstraction that over-approximates the timer: it allows the timer to fire at any point,
which is strictly more permissive than reality. This makes safety results stronger (not
weaker).

**processed / pending**: These are bookkeeping variables needed to close the conservation
equation. The source code's external environment (callers submitting txs, downstream
consuming batches) is implicit. The spec makes it explicit for verification.

### 2.2 Atomicity Assumptions

The spec models `Enqueue` as atomic: WAL append and queue push happen in a single step.
In the source, these are two sequential operations (lines 33-34 of persistent-queue.ts):

```typescript
const result = this.wal.append(tx);    // Step 1: WAL write
this.queue.push({ tx, seq: result.seq }); // Step 2: Queue push
```

A crash between Step 1 and Step 2 would leave the tx in the WAL but not in the queue.
On recovery, `wal.recover()` would return the tx (it is after the last checkpoint), so
the queue would be correctly rebuilt. The atomicity assumption is **safe** because recovery
corrects the intermediate state.

---

## 3. Omission Detection

### 3.1 Mechanisms Present in Source but Not in Spec

| Mechanism | Source Location | Omitted Because | Risk |
|-----------|----------------|-----------------|------|
| SHA-256 checksum computation | `wal.ts:17-20` | Implementation integrity check, not protocol | NONE |
| Batch ID computation (SHA-256 of tx hashes) | `batch-aggregator.ts:124-127` | Determinism is structural in TLA+ | NONE |
| `forceBatch()` | `batch-aggregator.ts:94-120` | Identical checkpoint behavior to `FormBatch` | NONE |
| WAL compaction | `wal.ts:150-177` | Optimization, does not affect safety | NONE |
| Group commit / fsync strategy | `wal.ts:75-78` | Durability implementation detail | NONE |
| Corrupted WAL entry handling | `wal.ts:132-133` | Defensive coding, not protocol state | LOW |
| `maxBatchSize` config parameter | `types.ts:56` | Spec uses `BatchSizeThreshold` as upper bound | NONE |

### 3.2 Potential Risk: Corrupted WAL Entry

The source code's `recover()` silently skips corrupted WAL entries (try/catch at line 132).
The spec does not model WAL corruption. If a valid WAL entry is incorrectly classified as
corrupted (false positive), that transaction would be silently lost. This is a low-risk
omission because:

1. The checksum verification (`wal.ts:127-129`) uses SHA-256 with the full entry payload.
2. False positives require a SHA-256 collision, which is computationally infeasible.
3. True corrupted entries (partial writes during crash) are correctly identified.

The omission is acceptable for the MVP spec. A production spec should model WAL corruption
as an explicit action to verify the skip-and-continue strategy.

---

## 4. Counterexample Assessment

### 4.1 Is the NoLoss Violation a Spec Error or a Protocol Flaw?

**VERDICT: Genuine protocol flaw.**

Evidence:

1. **Source code confirms the checkpoint timing**: `batch-aggregator.ts`, line 80 calls
   `this.queue.checkpoint(batchId)` inside `formBatch()`, immediately after dequeuing
   transactions. This matches the spec's `FormBatch` action exactly.

2. **No durable batch storage exists**: The formed batch is returned as a JavaScript object
   (line 82-90). It is not written to disk, a database, or any durable medium. The batch
   exists only in the caller's memory.

3. **The recovery logic confirms the gap**: `wal.ts` `recover()` at lines 137-144 only
   returns entries with `seq > lastCheckpointSeq`. Entries at or before the checkpoint are
   considered "committed" and excluded from recovery -- even if the batch they belong to
   was never persisted.

4. **The Scientist's test suite did not cover this interleaving**: The 5 crash recovery
   scenarios (REPORT.md, "Crash Recovery Test Results") test crash before checkpoint,
   during checkpoint, and after full processing -- but not the critical window between
   checkpoint and processing.

### 4.2 Severity Assessment

| Factor | Assessment |
|--------|------------|
| Data loss | Irrecoverable. Txs cannot be re-enqueued (they are no longer in pending). |
| Window of vulnerability | Duration of ZK proving + L1 submission (1.9s to 12.8s from RU-V2). |
| Trigger | Any system crash, OOM, power loss, or process kill during proving. |
| Scope | All txs in the current unprocessed batch. Up to BatchSizeThreshold txs lost per crash. |
| Detection | Silent. No error is raised. The system resumes from the checkpoint as if nothing was lost. |

---

## 5. Invariant Soundness

### 5.1 NoLoss

```
NoLoss == pending U UncommittedWalTxSet U BatchedTxSet U ProcessedTxSet = AllTxs
```

This invariant uses the WAL (not the volatile queue) as the source of truth for uncommitted
transactions. This is correct: the WAL is the durable record, and the queue is a volatile
cache. The four-way partition (pending, WAL uncommitted, batched, processed) is exhaustive
and mutually exclusive (verified by `NoDuplication`).

The invariant is **not weakened** by the crash model: it uses `UncommittedWalTxSet`
(WAL-based) rather than `QueueTxSet` (memory-based), so it correctly tracks transactions
across crash boundaries.

**Assessment: Sound. The invariant correctly captures the zero-loss requirement.**

### 5.2 QueueWalConsistency

```
QueueWalConsistency == systemUp => queue = SubSeq(wal, checkpointSeq+1, Len(wal))
```

Only checked when `systemUp = TRUE`. This is correct: during crash, the queue is empty
but the WAL still holds the entries. After recovery, the queue is rebuilt to match the
uncommitted WAL segment. The invariant verifies this reconstruction.

**Assessment: Sound. Implies FIFO ordering and correct recovery.**

### 5.3 FIFOOrdering

```
FIFOOrdering == systemUp => Flatten(processed) \o Flatten(batches) = SubSeq(wal, 1, checkpointSeq)
```

Verifies that the global sequence of all batched transactions matches the WAL prefix in
exact order. This captures both within-batch and across-batch ordering. The invariant is
conditional on `systemUp` because crash clears `batches`, creating a gap in the sequence.

**Assessment: Sound. Would fail as a consequence of the NoLoss violation (gap in the
batched sequence after crash). Not independently testable until NoLoss is fixed.**

---

## 6. Final Assessment

| Criterion | Result |
|-----------|--------|
| Structural fidelity to source | PASS |
| No hallucinated mechanisms | PASS |
| No critical omissions | PASS |
| Invariant soundness | PASS |
| Model check result | **FAIL (NoLoss violated)** |
| Root cause | **Genuine protocol flaw: premature WAL checkpoint** |

### Recommendation

Proceed to **Phase 3** (`/3-diagnose`) to propose a protocol fix. The specification is
faithful to the source and the counterexample is genuine. The fix must move the WAL
checkpoint from batch formation to batch processing (or introduce durable batch storage
before checkpointing).

The `v0-analysis/` directory is **frozen** as forensic evidence of the protocol flaw.
The corrected specification will be developed in `v1-fix/`.
