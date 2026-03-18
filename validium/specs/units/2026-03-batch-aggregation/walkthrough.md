# Walkthrough: Batch Aggregation Formalization (RU-V4)

> Unit: `validium/specs/units/2026-03-batch-aggregation/`
> Target: validium | Date: 2026-03-18
> Pipeline: Scientist (RU-V4) -> Logicist (this unit) -> Architect -> Prover

---

## Overview

This unit formalizes the Scientist's RU-V4 research on transaction queue and batch
aggregation for the Basis Network Enterprise ZK Validium Node. The formalization
discovered a **critical protocol flaw** -- silent transaction loss on crash -- that
was not detected by the Scientist's test suite. The flaw was diagnosed, fixed, and
verified through the 5-phase pipeline.

**Input**: Experimental evidence on HYBRID batch aggregation with WAL persistence.
**Output**: Verified TLA+ specification with deferred checkpoint protocol.
**Result**: APPROVED. Ready for implementation.

---

## The Discovery

The Scientist's research (RU-V4) established that a HYBRID batch aggregation strategy
with WAL persistence achieves exceptional performance: 14,000-274,000 tx/min throughput
with sub-millisecond latency and 150/150 crash recovery tests passing.

Phase 1 formalization translated this into a TLA+ specification with 8 variables,
6 actions, and 6 safety invariants. TLC model checking (3,262 states, 1 second)
found a NoLoss violation at depth 6: a crash between batch formation and batch
processing causes irrecoverable transaction loss.

**Root cause**: The WAL checkpoint advances at batch formation time, not at batch
processing time. Checkpointed transactions are excluded from crash recovery, but
the batch exists only in volatile memory. A crash destroys the batch while the WAL
considers those transactions "committed."

**Why the tests missed it**: The Scientist's 5 crash scenarios covered pre-checkpoint,
mid-checkpoint, and post-processing crashes. None tested the critical window: post-
checkpoint, pre-processing. The model checker found the missing interleaving in 1
second.

---

## Phase-by-Phase Evolution

### Phase 1: Formalize Research -- FAIL

Translated the Scientist's batch aggregation protocol into TLA+ with full traceability
to source code and research report. The specification faithfully models the WAL-first
persistence, HYBRID batch formation, and crash recovery protocol.

TLC found `NoLoss` violated at depth 6: `Enqueue(tx1) -> Enqueue(tx2) -> TimerTick ->
FormBatch -> Crash -> tx1, tx2 lost`.

**Artifact**: `v0-analysis/specs/BatchAggregation/BatchAggregation.tla`

### Phase 2: Verify Integrity -- PASS

Audited the specification against the source implementation. Confirmed:
- All 5 data structures faithfully mapped.
- All 6 state transitions faithfully modeled.
- 4 justified additions (ProcessBatch, TimerTick, processed, pending).
- 7 acceptable omissions (checksums, compaction, batch IDs, etc.).
- The NoLoss violation is a **genuine protocol flaw**, not a specification error.

**Artifact**: `v0-analysis/PHASE-2-AUDIT_REPORT.md`

### Phase 3: Diagnose -- Option A Selected

Analyzed the counterexample and proposed two fix options:

- **Option A (Conservative)**: Defer WAL checkpoint to after batch processing
  (proof + L1 confirmation). Maximum safety, minimal change. One batch re-proof per
  crash on recovery.

- **Option B (Aggressive)**: Introduce durable batch storage. Checkpoint after proof
  generation. Saves re-proving cost on recovery but adds a second durable store with
  synchronization concerns.

Selected **Option A** per Safety > Privacy > Simplicity > Speed.

**Artifact**: `v0-analysis/PHASE-3-DESIGN_PROPOSAL.md`

### Phase 4: Fix and Verify -- PASS

Created `v1-fix/` with the corrected specification. Changes:

1. `FormBatch`: removed `checkpointSeq' = checkpointSeq + batchSize`.
2. `ProcessBatch`: added `checkpointSeq' = checkpointSeq + Len(Head(batches))`.
3. `NoLoss`: reformulated as 3-way partition (pending, uncommitted WAL, processed).
4. `QueueWalConsistency`: extended to include `Flatten(batches) \o queue`.
5. `FIFOOrdering`: extended to cover full WAL.
6. Fairness: upgraded progress actions from WF to SF (pre-existing issue exposed by
   complete state-space exploration).

TLC result: 6,763 states generated, 2,630 distinct, 0 errors. All 6 safety invariants
and EventualProcessing liveness property **PASS**.

**Artifact**: `v1-fix/specs/BatchAggregation/BatchAggregation.tla`,
`v1-fix/experiments/BatchAggregation/MC_BatchAggregation.log`

### Phase 5: Critical Review -- APPROVED

Verified:
- No features removed or restricted.
- No invariants weakened (all reformulations are equivalent or stronger).
- Protocol still makes progress (EventualProcessing verified).
- Fix matches Phase 3 proposal exactly (one deviation: fairness upgrade, justified).
- All TLA+ constructs are directly implementable.

**Artifact**: `v1-fix/PHASE-5-CRITICAL_REVIEW.md`

---

## Key Metrics

| Metric | Value |
|--------|-------|
| Phases completed | 5/5 |
| Safety invariants verified | 6/6 |
| Liveness properties verified | 1/1 |
| States explored (v1-fix) | 2,630 distinct (complete) |
| Model checking time | < 1 second |
| Spec changes (actions) | 2 (FormBatch, ProcessBatch) |
| Invariant changes | 4 (NoLoss, NoDuplication, QueueWalConsistency, FIFOOrdering) |
| Counterexample resolution | Confirmed (v0 trace no longer violates NoLoss) |

---

## Implementation Summary

The fix requires one change in the implementation:

**Move** `this.queue.checkpoint(batchId)` from `formBatch()` to a callback invoked
after successful L1 confirmation of the ZK proof.

Additional requirements:
- L1 contract must handle duplicate state root submissions (idempotency).
- Add crash recovery test for the post-checkpoint, pre-processing window.
- WAL compaction should run after checkpoint advancement.

---

## File Manifest

```
validium/specs/units/2026-03-batch-aggregation/
|-- walkthrough.md                              # This file
|-- 0-input/                                    # READ-ONLY Scientist's evidence
|   |-- REPORT.md                               # Research findings
|   |-- hypothesis.json                         # Hypothesis definition
|   |-- code/                                   # Reference implementation
|   `-- results/                                # Benchmark + test results
`-- 1-formalization/
    |-- v0-analysis/                            # FROZEN forensic evidence
    |   |-- specs/BatchAggregation/
    |   |   `-- BatchAggregation.tla            # Original spec (NoLoss VIOLATED)
    |   |-- experiments/BatchAggregation/
    |   |   |-- MC_BatchAggregation.tla         # 10 txs, batch size 4
    |   |   |-- MC_BatchAggregation.cfg
    |   |   `-- MC_BatchAggregation.log         # Certificate: FAIL at depth 6
    |   |-- PHASE-1-FORMALIZATION_NOTES.md
    |   |-- PHASE-2-AUDIT_REPORT.md
    |   `-- PHASE-3-DESIGN_PROPOSAL.md
    `-- v1-fix/                                 # VERIFIED corrected specification
        |-- specs/BatchAggregation/
        |   `-- BatchAggregation.tla            # Fixed spec (ALL PASS)
        |-- experiments/BatchAggregation/
        |   |-- MC_BatchAggregation.tla         # 4 txs, batch size 2
        |   |-- MC_BatchAggregation.cfg
        |   `-- MC_BatchAggregation.log         # Certificate: PASS (2,630 states)
        |-- PHASE-4-VERIFICATION_REPORT.md
        `-- PHASE-5-CRITICAL_REVIEW.md
```
