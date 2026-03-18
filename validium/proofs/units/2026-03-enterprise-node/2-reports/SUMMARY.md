# Verification Summary: Enterprise Node (2026-03-enterprise-node)

## Unit Information

| Field | Value |
|-------|-------|
| Target | validium |
| Unit | 2026-03-enterprise-node |
| Date | 2026-03-18 |
| Prover | Rocq (Coq) 9.0.1 |
| Status | PASS -- all theorems proved, zero Admitted |

## Source Artifacts

| Artifact | Path |
|----------|------|
| TLA+ Spec | `0-input-spec/EnterpriseNode.tla` (467 lines, 12 variables, 12 actions) |
| TypeScript Impl | `0-input-impl/orchestrator.ts` (602 lines, pipelined state machine) |
| TypeScript Types | `0-input-impl/types.ts` (258 lines, NodeState enum, DataKind) |

## Proof Artifacts

| File | Lines | Purpose |
|------|-------|---------|
| `Common.v` | 126 | Abstract Tx type, NodeState/DataKind enums, set operations, constants |
| `Spec.v` | 333 | Faithful TLA+ translation: State record, 12 actions, step relation, invariants |
| `Impl.v` | 118 | TypeScript model: identity mapping, bundled operations (batch_cycle, handle_error) |
| `Refinement.v` | 376 | 13 proved theorems: safety invariant, proof-state integrity, liveness progress |

## Theorems Proved

### Safety (Inductive Invariant)

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 1 | `init_safety` | SafetyInv holds for the initial state | PROVED |
| 2 | `safety_preserved` | SafetyInv preserved by every Spec.step | PROVED |
| 3 | `safety_reachable` | SafetyInv holds for all reachable states | PROVED |

### Safety Sub-Lemmas (one per TLA+ action)

| # | Lemma | Action | Status |
|---|-------|--------|--------|
| 1 | `safe_receive_tx` | ReceiveTx (pipelined ingestion) | PROVED |
| 2 | `safe_check_queue` | CheckQueue (queue monitoring) | PROVED |
| 3 | `safe_form_batch` | FormBatch (HYBRID batch formation) | PROVED |
| 4 | `safe_gen_witness` | GenerateWitness (SMT update) | PROVED |
| 5 | `safe_gen_proof` | GenerateProof (ZK proof) | PROVED |
| 6 | `safe_submit_batch` | SubmitBatch (L1 + DAC) | PROVED |
| 7 | `safe_confirm_batch` | ConfirmBatch (L1 confirmation) | PROVED |
| 8 | `safe_crash` | Crash (volatile state loss) | PROVED |
| 9 | `safe_l1_reject` | L1Reject (submission rejection) | PROVED |
| 10 | `safe_retry` | Retry (WAL recovery) | PROVED |
| 11 | `safe_timer_tick` | TimerTick (time threshold) | PROVED |
| 12 | `safe_done` | Done (terminal stuttering) | PROVED |

### Key Safety Properties

| # | Theorem | TLA+ Invariant | Statement | Status |
|---|---------|----------------|-----------|--------|
| 4 | `proof_state_integrity` | INV-NO2 | Submitting -> batchPrevSmt = l1State | PROVED |
| 5 | `proof_state_integrity_reachable` | INV-NO2 | INV-NO2 for all reachable states | PROVED |
| 6 | `state_root_continuity` | INV-NO5 | SRC for all reachable states | PROVED |
| 7 | `no_data_leakage` | INV-NO3 | dataExposed subset of AllowedExternalData | PROVED |

### Implementation Safety (Composed Operations)

| # | Theorem | Impl Method | Status |
|---|---------|-------------|--------|
| 8 | `safe_batch_cycle` | processBatchCycle() | PROVED |
| 9 | `safe_handle_error` | handleBatchError() (crash) | PROVED |
| 10 | `safe_handle_l1_reject` | handleBatchError() (L1 reject) | PROVED |

### Liveness Progress

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 11 | `confirm_extends_l1` | ConfirmBatch adds batch txs to l1State | PROVED |
| 12 | `confirm_preserves_l1` | ConfirmBatch preserves existing l1State (monotonicity) | PROVED |

## Safety Invariant: SafetyInv

The combined safety invariant consists of three components:

### SRC (State Root Continuity, INV-NO5)

In idle-like states (Idle, Receiving, Batching, Error): `smtState = l1State`.
In active states (Proving, Submitting): `smtState = l1State UNION BatchTxSet`.

This ensures the Sparse Merkle Tree state is always derivable from the last
confirmed L1 state plus the current batch (if any).

### PSI (Proof-State Integrity, INV-NO2 strengthened)

In batch-active states (Batching, Proving, Submitting): `batchPrevSmt = l1State`.

This ensures the ZK proof's prevRoot public signal matches the on-chain state.
The L1 StateCommitment contract verifies `submittedPrevRoot == lastConfirmedRoot`,
so a mismatch here would cause L1 rejection.

### NDL (No Data Leakage, INV-NO3)

`dataExposed` is always a subset of `{proof_signals, dac_shares}`.
Raw enterprise data never exits the node boundary.

## Axiom Trust Base

| Axiom | Source | Justification |
|-------|--------|---------------|
| `batch_threshold_pos` | Common.v | BatchThreshold > 0. Matches TLA+ ASSUME. |

One axiom. Minimal trust base.

## Modeling Decisions

1. **Sets as predicates (Tx -> Prop)**: Leibniz equality maintained by construction.
   No functional extensionality needed. Changed fields create new predicates;
   unchanged fields reuse the same object (computational equality).

2. **Impl state = Spec state (identity mapping)**: The TypeScript class fields
   map 1:1 to TLA+ variables. The refinement mapping is the identity function.

3. **Impl bundling**: processBatchCycle() composes 5 spec actions. Safety follows
   from compositionality of the spec-level invariant.

4. **Liveness as progress lemma**: Full temporal logic proof requires trace
   semantics. We prove the key step: ConfirmBatch monotonically extends l1State.

## What This Proves

1. **The node never submits a proof with an incorrect state root.** Every proof
   submitted to L1 has prevRoot matching the last confirmed on-chain state.

2. **The SMT state is always consistent with the processing phase.** No gaps,
   no orphaned transitions, no state root discontinuities.

3. **Raw enterprise data never leaves the node.** Only ZK proofs, public signals,
   and DAC shares cross the privacy boundary.

4. **Each confirmed batch strictly extends the confirmed state.** Combined with
   fairness (from the TLA+ model checking), this yields eventual confirmation
   of all transactions.
