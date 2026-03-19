# Phase 2: Audit Report -- Enterprise Node Orchestrator

## Unit Information

- **Unit**: RU-V5 Enterprise Node Orchestrator
- **Target**: validium
- **Date**: 2026-03-18
- **Phase**: 2 -- Verify Formalization Integrity
- **Role**: The Auditor
- **Verdict**: **TRUE TO SOURCE**

---

## 1. Audit Scope

### 1.1 Source Materials (0-input/)

| Artifact | Path | Role |
|----------|------|------|
| Research Report | `0-input/REPORT.md` | Primary source: architecture, benchmarks, invariants, recovery design |
| State Machine | `0-input/code/src/state-machine.ts` | TRANSITION_TABLE with 16 explicit (state, event) -> state mappings |
| Type Definitions | `0-input/code/src/types.ts` | NodeState enum (6 states), NodeEvent enum (9 events), data interfaces |
| Orchestrator | `0-input/code/src/orchestrator.ts` | Pipelined batch cycle implementation with pluggable components |
| Hypothesis | `0-input/hypothesis.json` | RU-V5 hypothesis, variables, dependencies |

### 1.2 Formalization Artifacts (v0-analysis/)

| Artifact | Path | Role |
|----------|------|------|
| TLA+ Specification | `specs/EnterpriseNode/EnterpriseNode.tla` | 466-line specification, 12 variables, 12 actions, 9 properties |
| Model Instance | `experiments/EnterpriseNode/MC_EnterpriseNode.tla` | 3 txs, BatchThreshold=2, MaxCrashes=2 |
| TLC Configuration | `experiments/EnterpriseNode/MC_EnterpriseNode.cfg` | 8 invariants + 1 temporal property |
| TLC Log | `experiments/EnterpriseNode/MC_EnterpriseNode.log` | PASS: 3,958 states, 1,693 distinct, depth 20, 2s |
| Phase 1 Notes | `PHASE-1-FORMALIZATION_NOTES.md` | Mapping tables, assumptions, design decisions |

---

## 2. Structural Mapping Analysis

### 2.1 State Variable Mapping

| Source (0-input) | Source Location | TLA+ Variable | TLA+ Type | Durable? | Match? |
|-----------------|-----------------|---------------|-----------|----------|--------|
| `NodeState` enum (6 values) | types.ts:6-13 | `nodeState` | `States` (set of 6 strings) | Volatile | EXACT |
| Transaction queue (in-memory FIFO) | orchestrator.ts:180-198, MockQueue | `txQueue` | `Seq(AllTxs)` | Volatile | EXACT |
| Write-Ahead Log | REPORT.md Section 2.5, RU-V4 | `wal` | `Seq(AllTxs)` | Durable | EXACT |
| WAL checkpoint position | REPORT.md Section 2.5, types.ts:120 | `walCheckpoint` | `0..Len(wal)` | Durable | EXACT |
| SMT root hash | orchestrator.ts:27 (IStateMerkleTree) | `smtState` | `SUBSET AllTxs` | Volatile (checkpointed) | ABSTRACTED |
| Current batch transactions | orchestrator.ts:323-348 | `batchTxs` | `Seq(AllTxs)` | Volatile | EXACT |
| Pre-batch SMT state | orchestrator.ts:328 (prevRoot) | `batchPrevSmt` | `SUBSET AllTxs` | Volatile | ABSTRACTED |
| Last confirmed L1 state | REPORT.md Section 7.2, RU-V3 | `l1State` | `SUBSET AllTxs` | Durable (on-chain) | ABSTRACTED |
| External data exposure | REPORT.md Section 2.4 | `dataExposed` | `SUBSET DataKinds` | Tracking | SPEC-ONLY |
| Pending transactions | Environment (implicit) | `pending` | `SUBSET AllTxs` | Environment | SPEC-ONLY |
| Crash counter | Model bound (implicit) | `crashCount` | `0..MaxCrashes` | Model bound | SPEC-ONLY |
| Timer threshold flag | types.ts:187, orchestrator.ts:224 | `timerExpired` | `BOOLEAN` | Volatile | ABSTRACTED |

**Variable Count**: 12 TLA+ variables. 8 map directly to source concepts. 3 are specification-level
tracking variables (`dataExposed`, `pending`, `crashCount`) justified by verification needs.
1 (`timerExpired`) abstracts the real timer mechanism as nondeterministic flag.

**Abstraction Assessment**:

- `smtState` as `SUBSET AllTxs`: Sound. Each unique set of transactions corresponds to a unique
  Merkle root (collision-free by construction). Explores strictly more states than a real hash
  function. Preserves all chain integrity properties.

- `batchPrevSmt` and `l1State` as `SUBSET AllTxs`: Same abstraction, applied consistently.
  Comparisons like `batchPrevSmt = l1State` correctly model root hash equality.

- `timerExpired` as nondeterministic `BOOLEAN`: Sound over-approximation. The real timer fires
  after `maxWaitTimeMs` (types.ts:187). The TLA+ `TimerTick` can fire at any point during
  Receiving with a non-empty queue, exploring strictly more behaviors than reality.

- `dataExposed`, `pending`, `crashCount`: Standard specification-level variables for tracking
  privacy boundaries, environment input, and model exploration bounds. Not present in source
  code but required for property verification. Justified.

### 2.2 State Transition Mapping

| # | Source Function/Event | Source Location | Guards (Source) | TLA+ Action | Guards (TLA+) | Match? |
|---|----------------------|-----------------|-----------------|-------------|----------------|--------|
| 1 | `Idle:TransactionReceived -> Receiving` | state-machine.ts:14 | state=Idle | `ReceiveTx(tx)` | `nodeState="Idle"`, `tx \in pending` | EXACT |
| 2 | `Receiving:TransactionReceived -> Receiving` | state-machine.ts:18 | state=Receiving | `ReceiveTx(tx)` | `nodeState="Receiving"`, `tx \in pending` | EXACT |
| 3 | `Proving:TransactionReceived -> Proving` | state-machine.ts:30 | state=Proving | `ReceiveTx(tx)` | `nodeState="Proving"`, `tx \in pending` | EXACT |
| 4 | `Submitting:TransactionReceived -> Submitting` | state-machine.ts:37 | state=Submitting | `ReceiveTx(tx)` | `nodeState="Submitting"`, `tx \in pending` | EXACT |
| 5 | `Receiving:BatchThresholdReached -> Batching` | state-machine.ts:19 | state=Receiving | `FormBatch` | `nodeState="Receiving"`, `Len >= threshold OR timerExpired` | ENRICHED |
| 6 | `Batching:WitnessGenerated -> Proving` | state-machine.ts:23 | state=Batching | `GenerateWitness` | `nodeState="Batching"`, `Len(batchTxs) > 0` | EXACT |
| 7 | `Proving:ProofGenerated -> Submitting` | state-machine.ts:27 | state=Proving | `GenerateProof` | `nodeState="Proving"` | EXACT |
| 8 | `Submitting:BatchSubmitted -> Submitting` | state-machine.ts:33 | state=Submitting | `SubmitBatch` | `nodeState="Submitting"` | EXACT |
| 9 | `Submitting:L1Confirmed -> Idle` | state-machine.ts:34 | state=Submitting | `ConfirmBatch` | `nodeState="Submitting"` | EXACT |
| 10 | `{Recv,Batch,Prov,Sub}:ErrorOccurred -> Error` | state-machine.ts:20,24,28,35 | state in operational | `Crash` | `nodeState \in {Recv,Batch,Prov,Sub}`, `crashCount < Max` | ENRICHED |
| 11 | (same as 10, L1-specific) | REPORT.md Section 4.3 | L1 rejection | `L1Reject` | `nodeState="Submitting"` | ENRICHED |
| 12 | `Error:RetryRequested -> Idle` | state-machine.ts:40 | state=Error | `Retry` | `nodeState="Error"` | EXACT |
| 13 | `Idle:ShutdownRequested -> Idle` | state-machine.ts:15 | state=Idle | (not modeled) | -- | OMITTED |
| 14 | `Error:ShutdownRequested -> Idle` | state-machine.ts:41 | state=Error | (not modeled) | -- | OMITTED |
| 15 | (batch loop queue detection) | REPORT.md Section 2.2 | Idle, queue non-empty | `CheckQueue` | `nodeState="Idle"`, `Len(txQueue) > 0` | ADDED |
| 16 | Timer expiry | types.ts:187, REPORT.md 2.2 | Receiving, non-empty queue | `TimerTick` | `nodeState="Receiving"`, `~timerExpired`, `Len > 0` | ADDED |
| 17 | Terminal state | (protocol completion) | all txs confirmed | `Done` | `pending={}`, `txQueue empty`, `batchTxs empty`, `Idle` | ADDED |

**Transition Count**: Source defines 14 transitions (state-machine.ts TRANSITION_TABLE). TLA+ defines
12 actions (some consolidating multiple source transitions, some adding new ones).

**Match Summary**:
- **EXACT**: 9 transitions map directly with equivalent guards and effects.
- **ENRICHED**: 3 transitions refine source material (FormBatch adds timer disjunct; Crash/L1Reject
  split the generic ErrorOccurred into two distinct failure modes with different semantics).
- **OMITTED**: 2 transitions (ShutdownRequested from Idle and Error). Justified: Section 3.2.
- **ADDED**: 3 actions (CheckQueue, TimerTick, Done). Justified: Section 3.1.

### 2.3 Control Flow Mapping

The orchestrator.ts `processBatchCycle()` (lines 306-421) executes a sequential pipeline:

```
submitTransaction() -> enqueue -> [Idle->Receiving]
processBatchCycle():
  1. BatchThresholdReached -> [Receiving->Batching]
  2. Dequeue txs + SMT.insert(txs)                    <- TLA+ FormBatch + GenerateWitness
  3. batchBuilder.buildBatch(witness)
  4. WitnessGenerated -> [Batching->Proving]
  5. prover.prove(witness)
  6. ProofGenerated -> [Proving->Submitting]
  7. dac.distributeAndAttest(shares)
  8. submitter.submitBatch(proof)
  9. BatchSubmitted -> [Submitting->Submitting]
  10. L1Confirmed -> [Submitting->Idle]
  11. queue.checkpoint()
```

**TLA+ action correspondence**:

| Code Steps | TLA+ Action(s) | Atomicity |
|-----------|----------------|-----------|
| Steps 1-2 (dequeue + SMT insert) | `FormBatch` (dequeue only) + `GenerateWitness` (SMT update) | Split into two atomic steps |
| Steps 3-4 (witness gen + transition) | Bundled into `GenerateWitness` | Single atomic step |
| Steps 5-6 (prove + transition) | `GenerateProof` | Single atomic step |
| Steps 7-8 (DAC + L1 submit) | `SubmitBatch` | Single atomic step |
| Steps 9-10 (confirm + transition) | `ConfirmBatch` | Single atomic step |
| Step 11 (checkpoint) | Bundled into `ConfirmBatch` (`walCheckpoint` advance) | Bundled |

**Critical atomicity observation**: The TLA+ splits the code's single Batching phase into two
atomic steps (FormBatch + GenerateWitness). This is a FINER granularity than the code, which
executes dequeue + SMT update + witness generation as a single synchronous block in Node.js's
single-threaded event loop. The finer TLA+ granularity allows Crash to interleave between
FormBatch and GenerateWitness. This is a SOUND OVER-APPROXIMATION: it explores strictly more
failure scenarios than reality. If invariants hold under this aggressive interleaving model,
they hold in the real single-threaded implementation.

---

## 3. Discrepancy Detection

### 3.1 Hallucination Check

**Question**: Did the specification introduce mechanisms, transitions, or state not present
in the source materials?

| TLA+ Element | Present in Source? | Justification |
|-------------|-------------------|---------------|
| `CheckQueue` action | Partially. REPORT.md Section 2.2 describes "Batch loop: Monitors queue, forms batches when threshold met." Not in TRANSITION_TABLE (state-machine.ts). | NOT A HALLUCINATION. The action models an implicit behavior described in the research (the batch loop's queue monitoring). The TRANSITION_TABLE has a gap: no transition from Idle when queue is non-empty. Phase 1 notes Section 4.1 correctly identifies and documents this as a design gap. Without `CheckQueue`, pipelined transactions received during proving/submitting would stall in the queue after ConfirmBatch returns to Idle. The Logicist added this action to prevent a liveness violation, with full traceability to REPORT.md Section 2.2. |
| `TimerTick` action | Yes. types.ts:187 defines `maxWaitTimeMs`. REPORT.md Section 2.2 describes HYBRID batch formation (size OR time threshold). orchestrator.ts:224 declares `batchTimer`. | NOT A HALLUCINATION. Sound nondeterministic abstraction of a real timer mechanism. The `FormBatch` guard includes `timerExpired` as a disjunct, matching the HYBRID strategy described in the source. |
| `L1Reject` action | Yes. REPORT.md Section 4.3 identifies "L1 submission timeout" as a risk with "Retry with nonce management" mitigation. Code maps this to `ErrorOccurred` from Submitting. | NOT A HALLUCINATION. The TLA+ refines the generic `ErrorOccurred` into two distinct failure modes (Crash vs L1Reject) with different semantics. L1Reject does not increment `crashCount`. Both modes are described in the source materials. |
| `Done` action | No direct source. | NOT A HALLUCINATION. Standard TLA+ anti-deadlock pattern. Prevents TLC from flagging the legitimate terminal state (all transactions confirmed on L1) as a deadlock. Stuttering self-loop, no state change. |
| `dataExposed` variable | REPORT.md Section 2.4 describes the privacy boundary. Not an explicit variable in code. | NOT A HALLUCINATION. Specification-level tracking variable required to verify the NoDataLeakage invariant (INV-NO3). The privacy architecture is a primary research concern. |
| `AllowedExternalData` constant set | REPORT.md Section 2.4: "proof (a, b, c), publicSignals, Shamir shares" are the only data leaving the node. | NOT A HALLUCINATION. Direct encoding of the privacy boundary from the research report. |
| `pending` variable | Implicit in the environment model. | NOT A HALLUCINATION. Standard TLA+ environment variable for modeling finite transaction arrival. Required for the NoTransactionLoss invariant. |

**Result**: **ZERO hallucinations detected.** All TLA+ elements trace to source materials.
Additions (CheckQueue, TimerTick, L1Reject, Done) are justified enrichments with documented
rationale.

### 3.2 Omission Check

**Question**: Did the specification miss critical behavior, state transitions, or failure
modes present in the source materials?

| Source Element | Modeled? | Assessment |
|---------------|----------|------------|
| `ShutdownRequested` event (types.ts:24) | No | **JUSTIFIED OMISSION.** Two transitions use this event: `Idle:Shutdown->Idle` (no-op) and `Error:Shutdown->Idle` (equivalent to Retry semantics). Shutdown is an operational lifecycle concern, not a protocol safety concern. The spec verifies data integrity and liveness of the processing pipeline. Shutdown handling does not affect any verified invariant: NoTransactionLoss depends on WAL durability (which persists across shutdown), and ProofStateIntegrity is a synchronous invariant on the Submitting state. |
| Multi-enterprise concurrent access | Partially | **JUSTIFIED SIMPLIFICATION.** The hypothesis mentions `concurrent_enterprise_count` as a variable. REPORT.md Section 4.3 identifies "Concurrent SMT access race" as MEDIUM risk, mitigated by "single-writer model." The TLA+ enforces single-writer by construction: only `GenerateWitness` modifies `smtState`, and it requires `nodeState="Batching"`. The validium architecture deploys one node per enterprise, so the single-enterprise model is correct for the MVP. Cross-enterprise concerns belong to a separate specification. |
| Partial batch resumption on recovery | No | **JUSTIFIED ABSTRACTION.** REPORT.md Section 2.5 and types.ts:123-124 describe `pendingBatchState` for resuming in-flight proving after crash. The TLA+ always restarts fresh from WAL replay (Retry rebuilds txQueue from uncommitted WAL entries). This is CONSERVATIVE: if the fresh-start path preserves all invariants, the optimized resume path (which skips redundant work) preserves them too. |
| API layer (Fastify REST/WebSocket) | No | **JUSTIFIED OMISSION.** REPORT.md Section 2.3 describes the API contract. The TLA+ models the protocol layer behind the API. API routing, serialization, and WebSocket event emission do not affect protocol-level invariants. |
| Graceful shutdown (orchestrator.ts:443-452) | No | **JUSTIFIED OMISSION.** Same reasoning as ShutdownRequested. Shutdown flushes WAL and emits events, but these are operational concerns. |
| EventEmitter pattern | No | **JUSTIFIED OMISSION.** Implementation-level observer pattern for metrics, logging, and real-time WebSocket events. No protocol safety impact. |
| Batch ID generation (orchestrator.ts:335-338) | No | **JUSTIFIED OMISSION.** Implementation detail (SHA-256 hash of tx hashes). Not referenced by any invariant. |
| Metrics tracking (orchestrator.ts:202-209) | No | **JUSTIFIED OMISSION.** Observability concern. |
| `Batching:TransactionReceived` | No | **NOTABLE.** The code's TRANSITION_TABLE does not include this transition. The TLA+ `ReceiveTx` guard excludes Batching (`nodeState \in {"Idle", "Receiving", "Proving", "Submitting"}`). This is CONSISTENT: both source and spec reject transactions during batching. In the real system, batching is fast (~11ms) so the window is negligible. Transactions arriving during batching are handled by the OS TCP buffer and processed after the state advances. |

**Result**: **No harmful omissions detected.** All omissions are justified by scope boundaries
(operational vs protocol concerns) or conservative abstraction choices. The spec models the
complete data integrity pipeline from transaction ingestion through L1 confirmation, including
all failure and recovery paths.

### 3.3 Semantic Drift Check

**Question**: Does the specification subtly differ in semantics from the source, even where
the structure appears to match?

| Area | Source Semantics | TLA+ Semantics | Drift? | Assessment |
|------|-----------------|----------------|--------|------------|
| **L1Reject volatile state wipe** | Code's `ErrorOccurred` transitions to Error without specifying volatile state behavior. The code prototype does not implement explicit rollback on L1 rejection. | `L1Reject` clears `txQueue`, `batchTxs`, `batchPrevSmt`, and resets `smtState` to `l1State`. Treats L1 rejection as aggressively as a process crash. | YES (conservative) | **SOUND OVER-APPROXIMATION.** In reality, L1 rejection might preserve the in-memory queue (no process crash occurred). The TLA+ models the worst case: all volatile state is lost. Since `Retry` rebuilds the queue from WAL, correctness is preserved. If the invariants hold under this aggressive failure model, they hold under the real (less destructive) behavior. No weakening of safety guarantees. |
| **FormBatch + GenerateWitness atomicity split** | Code executes dequeue + SMT.insert() + witness generation as a single synchronous block in `processBatchCycle()` (lines 316-359). No interleaving possible in Node.js single-threaded event loop. | FormBatch (dequeue, record prevSmt) and GenerateWitness (SMT update) are two separate atomic actions. A Crash can interleave between them. | YES (conservative) | **SOUND OVER-APPROXIMATION.** The TLA+ explores strictly more interleavings than the real system. A crash between FormBatch and GenerateWitness in TLA+ leaves `smtState = l1State` with `batchTxs` populated but SMT not yet updated. Recovery via Crash + Retry correctly handles this: batch txs remain in the uncommitted WAL segment and are replayed. The `StateRootContinuity` invariant correctly expects `smtState = l1State` when `nodeState = "Batching"`. |
| **SubmitBatch ordering** | Code executes DAC + L1 submission sequentially, then fires `BatchSubmitted` followed by `L1Confirmed`. Both always occur. | `SubmitBatch` and `ConfirmBatch` are independently enabled in "Submitting" state. `ConfirmBatch` can fire without `SubmitBatch` having fired. | YES (conservative) | **SOUND OVER-APPROXIMATION.** In reality, L1 cannot confirm a batch that was never submitted. However, this does not affect any verified invariant. `NoDataLeakage` constrains `dataExposed` to a subset of `AllowedExternalData` -- it prevents raw data from leaving the node, not requiring that proof signals must leave. `ProofStateIntegrity` and `StateRootContinuity` do not reference `dataExposed`. Phase 1 notes Section 4.2 correctly documents this. A `batchSubmitted` boolean guard could tighten the model but is not required for correctness. |
| **DAC bundled with L1 submission** | Code executes DAC attestation (orchestrator.ts:372-378) BEFORE L1 submission (lines 382-389). Two distinct external interactions. | `SubmitBatch` bundles both DAC and L1 as a single data exposure event (`dataExposed' = dataExposed \cup {"proof_signals", "dac_shares"}`). | MINOR | **JUSTIFIED.** Separating DAC and L1 submission into two actions would not change the privacy invariant (both are in `AllowedExternalData`). The ordering (DAC before L1) is an implementation choice, not a protocol constraint. |
| **Crash scope exclusion** | Code's `ErrorOccurred` has no transition from Idle. | TLA+ `Crash` excludes Idle (`nodeState \in {"Receiving", "Batching", "Proving", "Submitting"}`). | NO | **CONSISTENT.** Both source and spec agree: crashes in Idle have no effect (no work in progress, no volatile state to lose). |
| **Queue type: array vs sequence** | Code uses `Array.splice(0, count)` for FIFO dequeue (MockQueue). | TLA+ uses `SubSeq(txQueue, 1, batchSize)` for dequeue, preserving FIFO order. | NO | **EXACT MATCH.** Both implement FIFO semantics. `splice(0, count)` and `SubSeq(1, batchSize)` extract the same prefix. |
| **WAL implementation** | Code uses `MockQueue` with no actual WAL. REPORT.md Section 2.5 designs WAL with checkpoint-based recovery. | TLA+ models WAL as `Seq(AllTxs)` with `walCheckpoint` position. `ReceiveTx` appends to WAL before queue. | NO | **CORRECT.** The spec models the DESIGNED behavior from REPORT.md, not the mock prototype. The mock is explicitly labeled as "Stage 1 benchmarking" (orchestrator.ts:60). The spec correctly formalizes the production design. |

**Result**: **Three instances of conservative semantic drift detected.** All are sound
over-approximations that explore strictly more failure scenarios than the real system.
No drift weakens any invariant or introduces false confidence.

---

## 4. Invariant Completeness Assessment

### 4.1 Source Invariants vs TLA+ Properties

| Source Invariant (REPORT.md 7.2) | TLA+ Property | Faithfulness |
|----------------------------------|---------------|-------------|
| INV-NO1: Liveness (pending txs eventually proved) | `EventualConfirmation` | FAITHFUL. `<>(\A tx \in AllTxs : tx \in l1State)` is strictly stronger than the source: it requires ALL txs reach L1, not just that pending txs eventually enter the proving phase. This is a STRENGTHENING, not a weakening. |
| INV-NO2: Proof-State Root Integrity | `ProofStateIntegrity` | FAITHFUL. `nodeState = "Submitting" => batchPrevSmt = l1State` directly encodes the source requirement that `proof.publicSignals.prevRoot = smt.prevRoot AND proof.publicSignals.newRoot = smt.currentRoot`. The circuit enforcement is abstracted (the spec trusts the Groth16 circuit to bind public signals to witness). |
| INV-NO3: Privacy / Zero Data Leakage | `NoDataLeakage` | FAITHFUL. `dataExposed \subseteq AllowedExternalData` encodes the source requirement that only proof signals and DAC shares leave the node. The `AllowedExternalData` set directly maps to REPORT.md Section 2.4. |
| INV-NO4: Crash Recovery / No Loss | `NoTransactionLoss` + `NoDuplication` | FAITHFUL AND STRENGTHENED. The source states `walReplayedTxCount + committedTxCount = totalEnqueuedTxCount`. The TLA+ encodes this as a partition invariant over durable state: `pending \cup UncommittedWalTxSet \cup l1State = AllTxs` (no loss) AND all three sets are disjoint (no duplication). The partition invariant is strictly stronger than a count equality. |
| INV-NO5: State Root Continuity | `StateRootContinuity` | FAITHFUL. Directly encodes the source requirement that `batch(N).prevRoot = batch(N-1).newRoot` by constraining `smtState` to be consistent with the processing phase: `smtState = l1State` when idle/receiving/batching/error, `smtState = l1State \cup BatchTxSet` when proving/submitting. |
| INV-NO6: Single Writer | Enforced by construction | FAITHFUL. Only `GenerateWitness` modifies `smtState`, and it requires `nodeState = "Batching"`. `StateRootContinuity` provides equivalent verification. Phase 1 notes Section 4.3 documents this design decision. |
| (Derived: RU-V4 consistency) | `QueueWalConsistency` | ENRICHMENT. Not in the source invariant list but derived from the RU-V4 BatchAggregation specification. Verifies volatile-durable sync: `batchTxs \o txQueue = SubSeq(wal, walCheckpoint+1, Len(wal))` in operational states. Strengthens crash recovery guarantees. |
| (Derived: circuit capacity) | `BatchSizeBound` | ENRICHMENT. Ensures `Len(batchTxs) <= BatchThreshold`. Derived from the ZK circuit's fixed batch size parameter (RU-V2). Prevents witness generation failure. |
| (Structural) | `TypeOK` | STANDARD. Type invariant ensuring all variables inhabit their declared domains. |

**Assessment**: All 6 source invariants are faithfully represented. Two additional invariants
(`QueueWalConsistency`, `BatchSizeBound`) are justified enrichments derived from upstream
research units. No source invariant was weakened or omitted.

### 4.2 Fairness Assessment

| TLA+ Fairness | Source Justification | Assessment |
|---------------|---------------------|------------|
| `SF_vars(ReceiveTx(tx))` for all tx | REPORT.md Section 2.1: node always accepts transactions | Correct. Strong fairness required because Crash can temporarily disable ReceiveTx. |
| `SF_vars(CheckQueue)` | REPORT.md Section 2.2: batch loop monitors queue | Correct. Strong fairness for same reason. |
| `SF_vars(FormBatch)` | REPORT.md Section 2.2: batch threshold triggers formation | Correct. |
| `SF_vars(GenerateWitness)` | orchestrator.ts: witness generation follows batch formation | Correct. |
| `SF_vars(GenerateProof)` | orchestrator.ts: proving follows witness generation | Correct. |
| `SF_vars(SubmitBatch)` | orchestrator.ts: submission follows proving | Correct. |
| `SF_vars(ConfirmBatch)` | orchestrator.ts: confirmation follows submission | Correct. |
| `WF_vars(Retry)` | state-machine.ts:40: Retry is the only enabled action in Error | Correct. Weak fairness suffices because no other action can preempt Retry in Error state. |
| `SF_vars(TimerTick)` | types.ts:187: timer must eventually fire | Correct. |
| No fairness on Crash, L1Reject | Adversarial events | Correct. Crashes and L1 rejections are nondeterministic environment events. |

**Assessment**: Fairness constraints are correctly calibrated. Strong fairness for actions
that can be intermittently disabled by crashes. Weak fairness for Retry (no preemption in
Error state). No fairness on adversarial events. Reference to Lamport Section 8.9 is
appropriate.

---

## 5. Model Configuration Assessment

| Parameter | Value | Source Justification | Adequacy |
|-----------|-------|---------------------|----------|
| `AllTxs` | `{tx1, tx2, tx3}` | 3 txs with threshold 2: exercises 1 full batch + 1 timer-triggered batch | ADEQUATE. Exercises size-triggered batching (2 txs), timer-triggered batching (1 tx), pipelined ingestion (tx3 arrives during proving/submitting). |
| `BatchThreshold` | 2 | Minimum non-trivial threshold | ADEQUATE. Threshold of 2 ensures FormBatch requires actual dequeue logic. Combined with 3 txs, exercises sub-threshold timer path. |
| `MaxCrashes` | 2 | Double-crash scenario | ADEQUATE. Exercises crash -> recover -> crash -> recover sequences at every interleaving point. Higher values would not expose new structural violations (same actions, same guards). |
| State space | 1,693 distinct states, depth 20 | Complete exploration (0 states on queue) | ADEQUATE. Small enough for exhaustive search, large enough to cover all structural paths. |

**Assessment**: Model parameters are well-chosen. The configuration exercises all documented
scenarios: happy path, crash during every operational phase, L1 rejection, pipelined
ingestion, timer-triggered batching, and combined adversarial scenarios (crash + L1 reject).

---

## 6. Findings Summary

### 6.1 No Required Corrections

The formalization faithfully represents the source materials. No corrections are required
for the v0-analysis specification to serve as a valid contract for downstream agents.

### 6.2 Observations (Non-Blocking)

| # | Category | Observation | Impact | Recommendation |
|---|----------|-------------|--------|----------------|
| O-1 | Over-approximation | `L1Reject` wipes volatile state (txQueue, batchTxs, smtState) as aggressively as `Crash`. Real L1 rejection likely preserves in-memory state. | None (sound, conservative). | The Architect should note that the implementation may preserve queue state on L1 rejection. The spec guarantees correctness even without this optimization. |
| O-2 | Over-approximation | `ConfirmBatch` can fire without `SubmitBatch` having fired. | None (no invariant affected). | The Architect may add a `batchSubmitted` guard for implementation clarity. Not required for correctness. |
| O-3 | Design gap | `CheckQueue` action was added by the Logicist to fill a gap in the source TRANSITION_TABLE. | Positive (prevents liveness violation). | The Architect MUST implement queue detection in Idle state. Add explicit `QueueNonEmpty` event to the implementation's transition table. |
| O-4 | Abstraction | Partial batch resumption on recovery (types.ts:123-124) not modeled. | None (conservative). | Performance optimization for the Architect. The spec proves correctness of the fresh-start recovery path. |
| O-5 | Scope | Shutdown lifecycle not modeled. | None (operational concern). | The Architect handles graceful shutdown independently. WAL flush on SIGTERM is implementation-level. |

---

## 7. Verdict

### **TRUE TO SOURCE**

The TLA+ specification `EnterpriseNode.tla` is a faithful formalization of the RU-V5
Enterprise Node Orchestrator research materials. The audit confirms:

1. **State completeness**: All 6 node states from the source `NodeState` enum are present.
   All 12 TLA+ variables trace to source concepts or are justified specification-level
   tracking variables.

2. **Transition completeness**: All 14 source transitions are represented (9 exact, 3
   enriched, 2 justified omissions). 3 added actions are justified by source research
   and fill documented design gaps.

3. **Invariant faithfulness**: All 6 source invariants (INV-NO1 through INV-NO6) are
   faithfully represented, with 2 additional enrichments from upstream research units.
   No invariant was weakened.

4. **Semantic integrity**: Three instances of conservative semantic drift were detected.
   All are sound over-approximations that explore strictly more failure scenarios than
   the real system. No drift introduces false confidence.

5. **Zero hallucinations**: Every TLA+ element traces to a source artifact with explicit
   source tags in the specification comments.

The specification is ready to serve as the contract for the Prime Architect (implementation)
and the Prover (Coq certification).

---

## Appendix A: Traceability Matrix

| TLA+ Line | Source Tag | Source Location |
|-----------|-----------|-----------------|
| 44 | `[Source: 0-input/code/src/types.ts, NodeState enum lines 6-13]` | States enumeration |
| 139-143 | `[Source: 0-input/code/src/orchestrator.ts, submitTransaction() lines 278-301]` | ReceiveTx action |
| 140 | `[Source: 0-input/REPORT.md, Section 2.1]` | Pipelined ingestion |
| 155-156 | `[Source: 0-input/REPORT.md, Section 2.2]` | CheckQueue action |
| 168-169 | `[Source: 0-input/code/src/orchestrator.ts, processBatchCycle() lines 316-321]` | FormBatch action |
| 169 | `[Source: 0-input/REPORT.md, Section 2.2]` | HYBRID batch formation |
| 194-195 | `[Source: 0-input/code/src/orchestrator.ts, lines 329-348]` | GenerateWitness action |
| 195 | `[Source: 0-input/REPORT.md, Section 7.2 -- INV-NO6]` | Single writer invariant |
| 209-210 | `[Source: 0-input/code/src/orchestrator.ts, lines 362-366]` | GenerateProof action |
| 210 | `[Source: 0-input/REPORT.md, Section 2.1]` | Async proving |
| 223-224 | `[Source: 0-input/code/src/orchestrator.ts, lines 373-389]` | SubmitBatch action |
| 224 | `[Source: 0-input/REPORT.md, Section 2.4]` | Privacy architecture |
| 237-238 | `[Source: 0-input/code/src/orchestrator.ts, lines 392-398]` | ConfirmBatch action |
| 238 | `[Source: 0-input/REPORT.md, Section 2.5]` | Checkpoint triggers |
| 258 | `[Source: 0-input/REPORT.md, Section 2.5]` | Crash recovery design |
| 275 | `[Source: 0-input/REPORT.md, Section 4.3]` | L1 rejection risk |
| 290-291 | `[Source: 0-input/code/src/state-machine.ts, line 40]` | Retry action |
| 291 | `[Source: 0-input/REPORT.md, Section 2.5]` | Recovery protocol |
| 304 | `[Source: 0-input/REPORT.md, Section 2.2]` | Timer mechanism |
| 389 | `[Source: 0-input/REPORT.md, Section 7.2 -- INV-NO2]` | ProofStateIntegrity |
| 399 | `[Source: 0-input/REPORT.md, Section 2.4]` | NoDataLeakage |
| 410 | `[Source: 0-input/REPORT.md, Section 7.2 -- INV-NO4]` | NoTransactionLoss |
| 428 | `[Source: 0-input/REPORT.md, Section 7.2 -- INV-NO5]` | StateRootContinuity |
| 441 | `[Source: Derived from RU-V4]` | QueueWalConsistency |
| 462 | `[Source: 0-input/REPORT.md, Section 7.2 -- INV-NO1]` | EventualConfirmation |
