# Phase 1: Formalization Notes -- Batch Aggregation (RU-V4)

> Unit: `validium/specs/units/2026-03-batch-aggregation/`
> Target: validium | Date: 2026-03-18

---

## 1. Research-to-Spec Mapping

| Source Concept | Source Location | TLA+ Element | Fidelity |
|----------------|----------------|--------------|----------|
| Transaction queue (FIFO) | `persistent-queue.ts`, lines 19-53 | `queue` variable, `Enqueue(tx)` action | Exact |
| WAL append-only log | `wal.ts`, lines 58-84 | `wal` variable, WAL-first in `Enqueue` | Exact |
| WAL checkpoint | `wal.ts`, lines 88-98 | `checkpointSeq` variable, advanced in `FormBatch` | Exact |
| HYBRID batch strategy | `batch-aggregator.ts`, lines 37-53 | `FormBatch` guard: size OR time trigger | Exact |
| Batch formation | `batch-aggregator.ts`, lines 56-91 | `FormBatch` action: dequeue + checkpoint | Exact |
| Time threshold | REPORT.md, "HYBRID" section | `timerExpired` flag, `TimerTick` action | Abstracted (nondeterministic) |
| Crash recovery | REPORT.md, "Crash Recovery Protocol" | `Crash` + `Recover` actions | Exact |
| WAL replay | `wal.ts`, lines 110-147 | `Recover`: `SubSeq(wal, checkpointSeq+1, Len(wal))` | Exact |
| Batch processing (downstream) | REPORT.md, "Recommendations" | `ProcessBatch` action | Modeled (not in source code) |
| Forced batch (shutdown) | `batch-aggregator.ts`, lines 94-120 | Not modeled (operational, not protocol) | Omitted |
| WAL compaction | `wal.ts`, lines 150-177 | Not modeled (optimization, not safety-critical) | Omitted |
| SHA-256 checksums | `wal.ts`, lines 17-20 | Not modeled (implementation detail) | Omitted |
| Batch ID computation | `batch-aggregator.ts`, lines 124-127 | Not modeled (determinism is structural) | Omitted |

### Abstraction Decisions

1. **Time threshold as nondeterministic flag**: Real-time clocks cannot be directly modeled
   in TLA+. The `timerExpired` flag is set nondeterministically by `TimerTick`, which
   over-approximates reality (timer can fire at any moment with a non-empty queue). This is
   sound for safety: if an invariant holds under arbitrary timer behavior, it holds under
   real-time constraints. For liveness, it may produce spurious violations.

2. **ProcessBatch as explicit action**: The source code returns the batch to the caller but
   does not model what happens next (proof generation, L1 submission). The spec adds
   `ProcessBatch` to track batch lifecycle to completion. This is necessary to verify the
   end-to-end `NoLoss` property.

3. **Omitted mechanisms**: WAL compaction, batch ID computation, SHA-256 checksums, and
   `forceBatch` are implementation details that do not affect the protocol's safety properties.
   They are noted as omissions for traceability.

---

## 2. State Space Design

### Variables

| Variable | Type | Role |
|----------|------|------|
| `queue` | `Seq(AllTxs)` | In-memory FIFO queue (volatile) |
| `wal` | `Seq(AllTxs)` | Write-ahead log (durable, append-only) |
| `checkpointSeq` | `0..Len(wal)` | WAL sequence up to which batches are committed |
| `batches` | `Seq(Seq(AllTxs))` | Formed but unprocessed batches (volatile) |
| `processed` | `Seq(Seq(AllTxs))` | Downstream-consumed batches (durable) |
| `pending` | `SUBSET AllTxs` | Transactions not yet submitted |
| `systemUp` | `BOOLEAN` | System running vs. crashed |
| `timerExpired` | `BOOLEAN` | Time threshold elapsed (nondeterministic) |

### Actions

| Action | Guard | Effect |
|--------|-------|--------|
| `Enqueue(tx)` | `systemUp /\ tx \in pending` | WAL append, queue push, remove from pending |
| `FormBatch` | `systemUp /\ (size >= threshold \/ timerExpired)` | Dequeue, append to batches, advance checkpoint |
| `ProcessBatch` | `systemUp /\ Len(batches) > 0` | Move head of batches to processed |
| `Crash` | `systemUp` | Clear queue + batches, set systemUp=FALSE |
| `Recover` | `~systemUp` | Rebuild queue from WAL after checkpoint |
| `TimerTick` | `systemUp /\ ~timerExpired /\ Len(queue) > 0` | Set timerExpired=TRUE |

---

## 3. Invariants and Properties

### Safety Invariants

| Invariant | Description | Status |
|-----------|-------------|--------|
| `TypeOK` | Structural type constraint on all variables | Not reached (TLC stopped at NoLoss) |
| **`NoLoss`** | **Transaction conservation: pending + uncommitted WAL + batched + processed = AllTxs** | **VIOLATED** |
| `NoDuplication` | No tx exists in two states simultaneously | Not reached |
| `QueueWalConsistency` | When up: queue = uncommitted WAL segment | Not reached |
| `FIFOOrdering` | Batched tx sequence = WAL prefix (order preservation) | Not reached |
| `BatchSizeBound` | Every batch has at most BatchSizeThreshold txs | Not reached |

### Liveness Properties

| Property | Description | Status |
|----------|-------------|--------|
| `EventualProcessing` | Every tx eventually in a processed batch | Not checked (safety violation first) |

---

## 4. Verification Results

### TLC Execution

| Parameter | Value |
|-----------|-------|
| TLC version | 2.16 (2020-12-31, rev cdddf55) |
| Workers | 4 |
| AllTxs | 10 model values |
| BatchSizeThreshold | 4 |
| Symmetry | Disabled (Permutations of 10 too costly) |
| States generated | 3,262 |
| Distinct states | 2,899 |
| Max depth | 6 |
| Runtime | 1 second |
| Result | **FAIL -- NoLoss violated** |

### Counterexample Trace (depth 6)

```
State 1: Init
  pending = {tx1..tx10}, queue = <<>>, wal = <<>>, checkpointSeq = 0
  batches = <<>>, processed = <<>>, systemUp = TRUE, timerExpired = FALSE

State 2: Enqueue(tx1)
  pending = {tx2..tx10}, queue = <<tx1>>, wal = <<tx1>>

State 3: Enqueue(tx2)
  pending = {tx3..tx10}, queue = <<tx1, tx2>>, wal = <<tx1, tx2>>

State 4: TimerTick
  timerExpired = TRUE

State 5: FormBatch (time-triggered, batch of 2)
  batches = <<<<tx1, tx2>>>>, checkpointSeq = 2, queue = <<>>

State 6: Crash
  batches = <<>>, queue = <<>>, systemUp = FALSE
  ** tx1, tx2 are IRRECOVERABLY LOST **
```

### Root Cause Analysis

The protocol checkpoints the WAL at **batch formation time** (`FormBatch`), not at **batch
processing time** (`ProcessBatch`). This creates a durability gap:

1. `FormBatch` dequeues tx1, tx2 from the queue, adds them to a batch, and advances
   `checkpointSeq` to 2. The WAL now considers tx1, tx2 as "committed."
2. The batch object exists only in volatile memory (`batches` variable).
3. `Crash` clears all volatile state: `queue = <<>>`, `batches = <<>>`.
4. `Recover` rebuilds the queue from WAL entries after `checkpointSeq` (entries 3+).
   Since tx1, tx2 are at WAL positions 1-2 (before checkpoint), they are NOT recovered.
5. tx1, tx2 are now in **none** of: pending, WAL uncommitted, batches, processed.

The conservation equation fails:
```
{tx3..tx10} U {} U {} U {} = {tx3..tx10} != {tx1..tx10} = AllTxs
```

This is a **genuine protocol flaw**, not a specification error. The flaw exists in the
reference implementation (`batch-aggregator.ts`, line 80: `this.queue.checkpoint(batchId)`
is called immediately after batch formation).

---

## 5. Implications

### Severity: CRITICAL

Any crash between `FormBatch` and `ProcessBatch` causes irrecoverable data loss. The
window of vulnerability is the entire duration of:
- ZK proof generation (1.9s-12.8s per batch, from RU-V2 benchmarks)
- L1 transaction submission and confirmation

This window can be seconds to minutes -- far too large for a production system that
claims "zero transaction loss."

### The Scientist's Testing Gap

The Scientist's crash recovery tests (0-input/REPORT.md, Section "Crash Recovery Test
Results") show 5 scenarios with 150/150 pass rate. However:

- Scenario 1 ("crash after enqueue, pre-batch"): Tests crash BEFORE checkpoint. No loss.
- Scenario 2 ("crash mid-batch"): Tests crash DURING formation. Checkpoint not written. No loss.
- Scenario 4 ("crash after checkpoint, clean state"): Tests crash after ALL txs are batched
  AND processed. No loss because processing is already complete.

**No scenario tests crash AFTER checkpoint but BEFORE processing** -- which is exactly the
vulnerability the model checker found. The test suite has a coverage gap at the most critical
interleaving point.

---

## 6. Reproduction

```bash
cd validium/specs/units/2026-03-batch-aggregation/1-formalization/v0-analysis/experiments/BatchAggregation/_build/
java -jar <path-to>/tla2tools.jar -config MC_BatchAggregation.cfg -workers 4 -deadlock MC_BatchAggregation
```

Expected output: `Error: Invariant NoLoss is violated.` at depth 6.

---

## 7. Next Steps

This is a **Phase 3 trigger**. The NoLoss violation represents a genuine protocol flaw
that requires a design fix before the specification can be handed to the Architect.

**Proposed fix direction** (to be formalized in Phase 3):
- Move the WAL checkpoint from `FormBatch` to `ProcessBatch` (or to a separate
  `CommitBatch` step that persists the batch to durable storage before checkpointing).
- This ensures that checkpointed txs have already been durably consumed, so crash
  recovery correctly replays any uncommitted txs.
