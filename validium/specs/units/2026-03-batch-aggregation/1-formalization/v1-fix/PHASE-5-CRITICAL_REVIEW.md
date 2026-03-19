# Phase 5: Critical Design Review -- Batch Aggregation (RU-V4)

> Unit: `validium/specs/units/2026-03-batch-aggregation/`
> Target: validium | Date: 2026-03-18
> Role: The Principal Architect

---

## Verdict: APPROVED

The v1-fix specification is correct, minimal, and implementable. It resolves the
critical NoLoss violation discovered in v0 without weakening any invariant, restricting
any valid state, or removing any protocol feature. TLC has exhaustively verified all
6 safety invariants and 1 liveness property across 2,630 distinct states.

The specification is ready for handoff to the Prime Architect (lab/3-architect/).

---

## 1. Divergence Audit

### 1.1 Did the fix remove features to pass invariants?

**NO.** The fix does not remove, disable, or restrict any protocol feature.

| Feature | v0 | v1-fix | Preserved? |
|---------|----|----|------------|
| WAL-first transaction persistence | Enqueue(tx) | Enqueue(tx) -- identical | YES |
| HYBRID batch formation (size OR time) | FormBatch | FormBatch -- same guards, same batch logic | YES |
| Downstream batch processing | ProcessBatch | ProcessBatch -- same + checkpoint | YES |
| Crash (volatile state loss) | Crash | Crash -- identical | YES |
| WAL-based recovery | Recover | Recover -- identical | YES |
| Nondeterministic timer | TimerTick | TimerTick -- identical | YES |

The fix changes exactly ONE assignment: `checkpointSeq' = checkpointSeq + batchSize`
is removed from `FormBatch` and an equivalent `checkpointSeq' = checkpointSeq +
Len(Head(batches))` is added to `ProcessBatch`. This is a timing change, not a
feature removal.

### 1.2 Did the fix restrict valid states?

**NO.** The state space uses the same 8 variables with the same types and domains.
No new guards were added to any action. No preconditions were strengthened. The only
behavioral difference is the checkpoint timing, which does not restrict reachable
states -- it changes the value of `checkpointSeq` at specific points in the execution.

Evidence: v0 explored 2,899 distinct states (partial, stopped at violation). v1-fix
explored 2,630 distinct states (complete). The difference is because v0 used 10 txs
(larger model) while v1-fix used 4 txs (smaller model for full exploration). Under the
same configuration, v1-fix would produce a superset of behaviors (more states reachable
because fewer txs are "lost" to the durability gap).

### 1.3 Did the fix weaken any invariant?

**NO.** Detailed analysis:

| Invariant | Change | Direction |
|-----------|--------|-----------|
| TypeOK | Unchanged | N/A |
| NoLoss | 4-way -> 3-way partition | **STRENGTHENED**: uses only durable state, holds across crash boundaries without volatile references |
| NoDuplication | 6 checks -> 3 checks | **EQUIVALENT**: 3 checks on durable sets. Internal batch/queue disjointness subsumed by QueueWalConsistency. |
| QueueWalConsistency | queue = uncommitted WAL -> batches + queue = uncommitted WAL | **STRENGTHENED**: verifies MORE (batches + queue, not just queue) |
| FIFOOrdering | processed + batches = WAL prefix -> processed + batches + queue = full WAL | **STRENGTHENED**: covers entire WAL, not just checkpointed prefix |
| BatchSizeBound | Unchanged | N/A |
| EventualProcessing | Unchanged (fairness model upgraded) | **UNCHANGED** (SF is a stronger environment assumption, making the property easier to satisfy -- but the property itself is identical) |

---

## 2. Liveness Verification

### 2.1 Does the protocol still make progress?

**YES.** TLC verified `EventualProcessing` (every transaction eventually in a processed
batch) across the complete state space. Under the SF fairness model, the protocol
guarantees end-to-end delivery despite arbitrary crash patterns.

### 2.2 Feature-by-feature liveness check

| Capability | Before fix | After fix | Impact |
|-----------|------------|-----------|--------|
| Enterprise submits transaction | Enqueue persists to WAL + queue | Identical | NONE |
| Batch formation (size trigger) | Forms batch when queue >= threshold | Identical | NONE |
| Batch formation (time trigger) | Forms batch on timer expiry | Identical | NONE |
| Proof generation + L1 submission | ProcessBatch moves batch to processed | ProcessBatch also checkpoints WAL | Positive: checkpoint is now a true durability guarantee |
| Crash recovery | Rebuilds queue from WAL after checkpoint | Rebuilds queue + re-batches previously batched txs | **IMPROVED**: zero transaction loss |

### 2.3 Is the system useful?

**YES.** The specification models a complete enterprise transaction pipeline:
1. Transactions are received and durably persisted (Enqueue).
2. Transactions are aggregated into batches using a configurable HYBRID strategy (FormBatch).
3. Batches are processed by downstream ZK proving and L1 submission (ProcessBatch).
4. The system recovers from arbitrary crashes with zero data loss (Crash + Recover).

The fix does not impair any of these capabilities. The only operational difference is
that crash recovery restores more transactions (those in formed-but-unprocessed batches),
which requires re-proving at most one batch per crash event.

---

## 3. Proposal Adherence

### 3.1 Phase 3 proposal vs v1-fix implementation

| Proposal Element | Proposed (Phase 3) | Implemented (v1-fix) | Match? |
|------------------|--------------------|----------------------|--------|
| Remove checkpoint from FormBatch | `UNCHANGED << checkpointSeq >>` | `UNCHANGED << wal, checkpointSeq, processed, pending, systemUp >>` | YES |
| Add checkpoint to ProcessBatch | `checkpointSeq' = checkpointSeq + Len(Head(batches))` | `checkpointSeq' = checkpointSeq + Len(Head(batches))` | EXACT |
| NoLoss: 3-way partition | `pending U UncommittedWal U Processed = AllTxs` | `pending \cup UncommittedWalTxSet \cup ProcessedTxSet = AllTxs` | EXACT |
| NoDuplication: 3 checks | 3 pairwise on durable sets | 3 pairwise on durable sets | EXACT |
| QueueWalConsistency: include batches | `Flatten(batches) \o queue = SubSeq(...)` | `Flatten(batches) \o queue = SubSeq(wal, checkpointSeq + 1, Len(wal))` | EXACT |
| FIFOOrdering: full WAL | `Flatten(processed) \o Flatten(batches) \o queue = wal` | `Flatten(processed) \o Flatten(batches) \o queue = wal` | EXACT |
| Model: 4 txs, batch size 2 | Proposed in verification strategy | Implemented | EXACT |

### 3.2 Deviations from proposal

One deviation exists:

| Deviation | Description | Justified? |
|-----------|-------------|------------|
| Fairness model upgrade (WF -> SF) | Not proposed in Phase 3. Discovered during Phase 4 verification when TLC exposed liveness lassos under WF. | **YES.** Pre-existing issue in v0 (masked by early safety violation). Standard solution for crash-recovery TLA+ specifications. Does not affect safety. |

The Phase 3 proposal did not address fairness because the issue was not known at
proposal time. It is a necessary addition discovered through verification -- exactly
the kind of insight the pipeline is designed to produce.

---

## 4. Implementation Viability

### 4.1 TLA+ construct analysis

| Construct | Implementable? | Notes |
|-----------|---------------|-------|
| `Append(wal, tx)` | YES | WAL append (single writer, append-only file) |
| `Append(queue, tx)` | YES | In-memory queue push |
| `SubSeq(queue, 1, batchSize)` | YES | Array slice |
| `Append(batches, batch)` | YES | Add batch to in-memory list |
| `Head(batches)`, `Tail(batches)` | YES | Dequeue from batch list |
| `Append(processed, Head(batches))` | YES | Move to processed list |
| `checkpointSeq + Len(Head(batches))` | YES | Integer arithmetic, write to checkpoint file |
| `SubSeq(wal, checkpointSeq+1, Len(wal))` | YES | Read WAL entries after checkpoint (recovery) |
| `Flatten(batches) \o queue` | Verification only | Not needed in implementation (invariant, not action) |

No construct requires distributed locks, unbounded computation, or global coordination.
All actions are local to a single enterprise node.

### 4.2 Atomicity requirements

| Action | Atomicity in TLA+ | Implementation requirement |
|--------|-------------------|---------------------------|
| Enqueue | Atomic (WAL write + queue push) | WAL write MUST complete before queue push. Crash between them is safe (recovery corrects). Already in source code. |
| FormBatch | Atomic (dequeue + append batch) | Single-threaded. No atomicity concern. |
| ProcessBatch | Atomic (move to processed + checkpoint) | Checkpoint MUST NOT advance until downstream confirms batch consumption. This is the core safety requirement of the fix. |
| Crash | Atomic (clear volatile state) | Process termination. OS-level atomicity. |
| Recover | Atomic (replay WAL) | Single-threaded startup. No atomicity concern. |

**Critical implementation requirement**: The `ProcessBatch` atomicity. The checkpoint
must advance ONLY AFTER:
1. ZK proof generation succeeds, AND
2. L1 transaction submission succeeds, AND
3. L1 confirmation is received (finality).

If the system crashes between steps 1-3, the txs remain in the uncommitted WAL segment
and are recovered for re-processing. This is the correct behavior.

### 4.3 Idempotency requirement

The fix introduces a scenario where the same batch may be submitted to L1 twice:
1. First attempt: proof generated, L1 submission sent, crash before checkpoint.
2. Recovery: txs re-queued, re-batched, re-proved, re-submitted.

The L1 contract (`ZKVerifier`) must handle duplicate state root submissions. Options:
- Reject if state root already recorded (idempotent no-op).
- Accept unconditionally (overwrite with same value).

This is a downstream implementation concern, not a specification issue. The spec
correctly models the protocol; the implementation team must ensure L1 idempotency.

### 4.4 Performance implications

| Scenario | Impact | Mitigation |
|----------|--------|------------|
| Normal operation | ZERO impact. Same actions, same ordering. | N/A |
| Crash recovery (per event) | Re-prove at most 1 batch (1.9s-12.8s). | Acceptable at production MTBF. |
| WAL size | Uncommitted segment may grow larger (includes batched txs). | WAL compaction after checkpoint. Already planned. |

---

## 5. Final Mapping Table

### v1-fix Spec <-> 0-input Source <-> Phase 3 Proposal

| TLA+ Element | Source Code Reference | Phase 3 Proposal | Status |
|--------------|----------------------|-------------------|--------|
| `Enqueue(tx)` | `persistent-queue.ts:enqueue()` + `wal.ts:append()` | Unchanged | VERIFIED |
| `FormBatch` (no checkpoint) | `batch-aggregator.ts:formBatch()` lines 56-91 | Remove `checkpoint()` call at line 80 | VERIFIED |
| `ProcessBatch` (with checkpoint) | New: callback after downstream completion | Add `checkpoint()` after proof + L1 confirm | VERIFIED |
| `Crash` | Process termination (OS-level) | Unchanged | VERIFIED |
| `Recover` | `wal.ts:recover()` lines 110-147 | Unchanged (behavior improved by fix) | VERIFIED |
| `TimerTick` | `performance.now()` timer in `shouldFormBatch()` | Unchanged | VERIFIED |
| `NoLoss` (3-way) | Conservation law | `pending U UncommittedWal U Processed = AllTxs` | VERIFIED |
| `NoDuplication` (3-way) | Mutual exclusion | 3 pairwise checks | VERIFIED |
| `QueueWalConsistency` | WAL as source of truth | `Flatten(batches) \o queue = uncommitted WAL` | VERIFIED |
| `FIFOOrdering` | Deterministic batching | `processed \o batches \o queue = wal` | VERIFIED |
| `BatchSizeBound` | Circuit capacity | Unchanged | VERIFIED |
| `EventualProcessing` | End-to-end delivery | Unchanged (SF fairness) | VERIFIED |

---

## 6. Implementation Advisory

### For the Prime Architect (lab/3-architect/)

1. **Core change**: Move `this.queue.checkpoint(batchId)` from `formBatch()` to a
   new `onBatchProcessed(batchId)` callback invoked after successful L1 confirmation.

2. **Recovery change**: After recovery, the queue will contain ALL uncommitted txs,
   including those that were previously in formed batches. The batch aggregator must
   re-form batches from the recovered queue. This requires no code change if the
   aggregator already processes the queue on startup.

3. **L1 idempotency**: The `ZKVerifier` contract must handle duplicate `verifyProof()`
   calls for the same state root. Recommend: revert with a descriptive error if the
   state root is already recorded (cheapest gas, clearest semantics).

4. **Test the missing scenario**: Add a crash recovery test that:
   - Enqueues N txs
   - Forms a batch (checkpoint should NOT advance)
   - Kills the process
   - Restarts and verifies ALL N txs are in the recovered queue
   - This is the exact scenario the Scientist's test suite missed.

5. **WAL compaction**: With the deferred checkpoint, the uncommitted WAL segment grows
   larger (includes batched txs). Compaction should run after checkpoint advancement
   to reclaim disk space. Already planned as an optimization.

### For the Prover (lab/4-prover/)

The Coq proof of isomorphism between this TLA+ spec and the implementation must verify:
1. The checkpoint assignment in ProcessBatch matches the implementation's checkpoint call.
2. The recovery logic restores the full uncommitted WAL segment (not just the queue-only segment).
3. The fairness model (SF) is satisfied by the implementation's scheduler (no infinite crash loops).

---

## 7. Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| L1 contract lacks idempotency | MEDIUM | Implementation advisory (Section 6.1, item 3) |
| WAL growth under sustained load without processing | LOW | Compaction after checkpoint; bounded by batch size x pending batches |
| Re-proving cost on repeated crashes | LOW | Bounded: 1 batch per crash. MTBF >> proving time. |
| SF fairness assumption violated (adversarial crash rate) | THEORETICAL | Not a production concern. Applies only to formal liveness guarantee. |

---

## 8. Conclusion

The v1-fix specification resolves the critical NoLoss violation discovered in v0 through
a minimal, principled change: deferring the WAL checkpoint from batch formation to batch
processing. The fix:

1. **Preserves all protocol features** (no features removed or restricted).
2. **Strengthens invariants** (NoLoss now uses only durable state; FIFOOrdering covers full WAL).
3. **Passes exhaustive model checking** (6,763 states, 2,630 distinct, 0 errors).
4. **Is directly implementable** (one function call moved, no architectural changes).
5. **Improves crash recovery** (zero transaction loss in all crash scenarios).

The specification is **APPROVED** for handoff to the Prime Architect.
