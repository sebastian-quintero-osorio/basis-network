# Session Log: Batch Aggregation Formalization

> Date: 2026-03-18
> Agent: The Logicist
> Target: validium
> Unit: `validium/specs/units/2026-03-batch-aggregation/`

---

## Phases Completed

### Phase 1: Formalize Research -- FAIL (NoLoss violated)

Formalized the Scientist's RU-V4 research into a TLA+ specification covering:
- `Enqueue(tx)`: WAL-first transaction persistence
- `FormBatch`: HYBRID (size OR time) batch formation with WAL checkpoint
- `ProcessBatch`: Downstream consumption (circuit proving, L1 submission)
- `Crash` / `Recover`: Volatile state loss and WAL-based recovery
- `TimerTick`: Nondeterministic time threshold abstraction

TLC model check (10 txs, batch size 4, 4 workers) found **NoLoss invariant violation**
at depth 6 in 1 second (3,262 states generated, 2,899 distinct).

**Counterexample**: Enqueue 2 txs -> TimerTick -> FormBatch (checkpoint advances) ->
Crash -> tx1, tx2 irrecoverably lost (checkpointed but batch only in volatile memory).

**Root cause**: Premature WAL checkpoint at batch formation time. The window between
checkpoint and batch processing (ZK proving + L1 submission) is 1.9s-12.8s, during which
a crash causes silent, irrecoverable data loss.

### Phase 2: Verify Integrity -- PASS

Audit confirmed the specification faithfully models the source implementation:
- All data structures mapped correctly (with justified abstractions)
- All state transitions match source code behavior
- No hallucinated mechanisms (ProcessBatch, TimerTick, pending are justified additions)
- No critical omissions
- Counterexample is a genuine protocol flaw, not a spec error

### Phase 3: Diagnose Protocol Flaw -- Option A Selected

Analyzed counterexample trace step-by-step and proposed two fix options:

- **Option A (Conservative)**: Defer WAL checkpoint from FormBatch to ProcessBatch.
  Maximum safety, minimal change (one assignment moved). Re-prove one batch per crash.
- **Option B (Aggressive)**: Introduce durable batch storage with checkpoint after proof
  generation. Saves re-proving cost but adds a second durable store.

Selected **Option A** per Safety > Privacy > Simplicity > Speed. Option B deferred to
production hardening as a separate research unit.

Reformulated invariants: NoLoss (3-way partition), NoDuplication (3 checks),
QueueWalConsistency (include batches), FIFOOrdering (full WAL coverage).

### Phase 4: Fix and Verify -- PASS

Created `v1-fix/` with corrected specification. Two action changes:
1. `FormBatch`: removed `checkpointSeq' = checkpointSeq + batchSize`
2. `ProcessBatch`: added `checkpointSeq' = checkpointSeq + Len(Head(batches))`

TLC model check (4 txs, batch size 2, 4 workers, BFS):
- 6,763 states generated, 2,630 distinct, max depth 18
- **All 6 safety invariants: PASS**
- **EventualProcessing liveness: PASS**
- Complete state-space exploration (0 states left on queue)
- Runtime: < 1 second

**Intermediate discovery**: TLC exposed a pre-existing liveness issue -- WF is vacuous
for progress actions in a crash-recovery system (Crash intermittently disables all
progress). Upgraded to SF for Enqueue, FormBatch, ProcessBatch, TimerTick. Recover
stays WF (nothing preempts it). Standard for crash-recovery TLA+ specifications.

### Phase 5: Critical Design Review -- APPROVED

Verified across 5 dimensions:
1. **Divergence audit**: No features removed, no states restricted, no invariants weakened.
2. **Liveness**: Protocol makes progress. EventualProcessing verified.
3. **Proposal adherence**: v1-fix matches Phase 3 proposal exactly. One justified deviation
   (fairness upgrade, pre-existing issue).
4. **Implementation viability**: All constructs implementable. One atomicity requirement
   (checkpoint after L1 confirmation). Idempotency needed at L1 contract.
5. **Verdict**: **APPROVED** for handoff to the Prime Architect.

---

## Artifacts Produced

| Artifact | Path |
|----------|------|
| TLA+ specification (v0, FAIL) | `validium/specs/units/2026-03-batch-aggregation/1-formalization/v0-analysis/specs/BatchAggregation/BatchAggregation.tla` |
| TLC log (v0, Certificate of FAIL) | `validium/specs/units/2026-03-batch-aggregation/1-formalization/v0-analysis/experiments/BatchAggregation/MC_BatchAggregation.log` |
| Phase 1 report | `validium/specs/units/2026-03-batch-aggregation/1-formalization/v0-analysis/PHASE-1-FORMALIZATION_NOTES.md` |
| Phase 2 report | `validium/specs/units/2026-03-batch-aggregation/1-formalization/v0-analysis/PHASE-2-AUDIT_REPORT.md` |
| Phase 3 proposal | `validium/specs/units/2026-03-batch-aggregation/1-formalization/v0-analysis/PHASE-3-DESIGN_PROPOSAL.md` |
| TLA+ specification (v1-fix, PASS) | `validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla` |
| Model instance (v1-fix) | `validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/experiments/BatchAggregation/MC_BatchAggregation.tla` |
| TLC config (v1-fix) | `validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/experiments/BatchAggregation/MC_BatchAggregation.cfg` |
| TLC log (v1-fix, Certificate of PASS) | `validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/experiments/BatchAggregation/MC_BatchAggregation.log` |
| Phase 4 report | `validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/PHASE-4-VERIFICATION_REPORT.md` |
| Phase 5 report | `validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/PHASE-5-CRITICAL_REVIEW.md` |
| Walkthrough | `validium/specs/units/2026-03-batch-aggregation/walkthrough.md` |

---

## Key Decisions

1. **No symmetry reduction**: `Permutations(10-element set)` exceeds TLC 2.16 startup
   capacity. BFS finds the counterexample at depth 6 without symmetry in 1 second.

2. **Timer modeled as nondeterministic flag**: Sound over-approximation for safety.
   The counterexample uses TimerTick to trigger a sub-threshold batch (2 txs < 4 threshold),
   which is the minimum reproduction of the vulnerability.

3. **ProcessBatch added to spec**: Not present in source code but necessary to model the
   complete transaction lifecycle. Without it, the conservation equation cannot distinguish
   "batch formed" from "batch consumed."

4. **Option A (Conservative) selected over Option B (Aggressive)**: Safety > Simplicity.
   One durable store (WAL) preferred over two (WAL + durable batch storage).

5. **Model reduced to 4 txs for v1-fix**: Full state-space exploration requires smaller
   model. 4 txs with batch size 2 exercises all critical scenarios (full batch, timer
   batch, multiple batches, crash/recovery). Property is parameterized.

6. **WF -> SF for progress actions**: Pre-existing issue in v0 (masked by early safety
   violation). Standard for crash-recovery TLA+ specifications. Not a safety weakening.

---

## Status

**COMPLETE.** All 5 phases finished. Specification APPROVED.

Ready for handoff:
- **Prime Architect** (lab/3-architect/): Implement the deferred checkpoint protocol.
- **Prover** (lab/4-prover/): Certify isomorphism between TLA+ spec and implementation.
