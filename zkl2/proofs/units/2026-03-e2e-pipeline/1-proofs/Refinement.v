(* ========================================== *)
(*     Refinement.v -- Verification Proofs     *)
(*     Implementation Refines Specification    *)
(*     zkl2/proofs/units/2026-03-e2e-pipeline  *)
(* ========================================== *)

(* This file proves the core safety properties of the E2E Pipeline:

   1. PipelineIntegrity        -- Finalized batch has complete artifact chain
   2. AtomicFailure            -- Failed batch leaves zero L1 footprint
   3. ArtifactDependencyChain  -- Strict causal ordering of artifacts
   4. MonotonicProgress        -- Artifact presence implies minimum stage

   Proof strategy: define a valid_state predicate that exactly
   characterizes the reachable artifact configurations for each stage.
   Prove it is an inductive invariant, then derive all properties.

   All theorems proved without Admitted.

   [Source: E2EPipeline.tla (spec), orchestrator.go + types.go (impl)] *)

From E2EPipeline Require Import Common.
From E2EPipeline Require Import Spec.
From E2EPipeline Require Import Impl.
From Stdlib Require Import Bool.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.

(* ========================================== *)
(*     INDUCTIVE INVARIANT                     *)
(* ========================================== *)

(* valid_state exactly characterizes the reachable artifact configurations.
   For each non-terminal stage, artifacts are fully determined by the stage.
   For the Failed terminal state, only proofOnL1 = false is guaranteed,
   plus the dependency chain among lower artifacts.

   This invariant is stronger than the four safety properties individually.
   It provides the complete state machine contract:

   - Pending:              no artifacts
   - Executed:             hasTrace only
   - Witnessed:            hasTrace + hasWitness
   - Proved:               hasTrace + hasWitness + hasProof
   - Submitted/Finalized:  all four artifacts
   - Failed:               proofOnL1 = false, lower chain preserved

   [Source: E2EPipeline.tla lines 334-387 -- safety properties] *)
Definition valid_state (s : spec_state) : Prop :=
  match sp_stage s with
  | Pending   => sp_has_trace s = false /\ sp_has_witness s = false /\
                 sp_has_proof s = false /\ sp_proof_on_l1 s = false
  | Executed  => sp_has_trace s = true  /\ sp_has_witness s = false /\
                 sp_has_proof s = false /\ sp_proof_on_l1 s = false
  | Witnessed => sp_has_trace s = true  /\ sp_has_witness s = true  /\
                 sp_has_proof s = false /\ sp_proof_on_l1 s = false
  | Proved    => sp_has_trace s = true  /\ sp_has_witness s = true  /\
                 sp_has_proof s = true  /\ sp_proof_on_l1 s = false
  | Submitted => sp_has_trace s = true  /\ sp_has_witness s = true  /\
                 sp_has_proof s = true  /\ sp_proof_on_l1 s = true
  | Finalized => sp_has_trace s = true  /\ sp_has_witness s = true  /\
                 sp_has_proof s = true  /\ sp_proof_on_l1 s = true
  | Failed    => sp_proof_on_l1 s = false /\
                 (sp_has_witness s = true -> sp_has_trace s = true) /\
                 (sp_has_proof s = true -> sp_has_witness s = true)
  end.

(* ========================================== *)
(*     INVARIANT INIT                          *)
(* ========================================== *)

Lemma valid_state_init : valid_state spec_init.
Proof. simpl; repeat split. Qed.

(* ========================================== *)
(*     INVARIANT PRESERVATION                  *)
(* ========================================== *)

(* Proof strategy: inversion on the step produces 13 cases.
   For each case, the stage of s is known from the precondition.
   We rewrite in valid_state to extract artifact values, then
   verify the post-state satisfies valid_state.
   All cases resolve by propositional reasoning + congruence. *)
Lemma valid_state_step : forall s s',
  valid_state s -> spec_step s s' -> valid_state s'.
Proof.
  intros s s' Hv Hstep; unfold valid_state in *.
  inversion Hstep; subst; simpl;
    (match goal with
     | [ H : sp_stage _ = _ |- _ ] => rewrite H in Hv; simpl in Hv
     end);
    intuition congruence.
Qed.

(* ========================================== *)
(*     REACHABILITY                            *)
(* ========================================== *)

(* Reachable states: the initial state and any state reachable by a
   finite sequence of spec steps. *)
Inductive reachable : spec_state -> Prop :=
  | reach_init : reachable spec_init
  | reach_step : forall s s',
      reachable s -> spec_step s s' -> reachable s'.

(* The invariant holds for all reachable states. *)
Theorem valid_state_reachable : forall s,
  reachable s -> valid_state s.
Proof.
  intros s Hr; induction Hr.
  - exact valid_state_init.
  - exact (valid_state_step _ _ IHHr H).
Qed.

(* ========================================== *)
(*     SAFETY THEOREMS                         *)
(* ========================================== *)

(* All safety properties follow by case analysis on sp_stage
   using the valid_state invariant. *)

(* Theorem 1: Every finalized batch has a complete artifact chain.
   Finalized => hasTrace /\ hasWitness /\ hasProof /\ proofOnL1.

   This is the core integrity guarantee: the system cannot mark a
   batch as finalized without actual cryptographic verification on L1.

   [Source: E2EPipeline.tla lines 334-340] *)
Theorem thm_pipeline_integrity : forall s,
  reachable s -> pipeline_integrity s.
Proof.
  intros s Hr; apply valid_state_reachable in Hr.
  unfold pipeline_integrity; intro Hfin.
  unfold valid_state in Hr; rewrite Hfin in Hr; exact Hr.
Qed.

(* Theorem 2: Failed batches leave zero L1 footprint.
   Failed => proofOnL1 = false.

   Partial failure must not corrupt L1 state. A batch that fails at
   any stage before L1 submission leaves zero on-chain artifacts.

   [Source: E2EPipeline.tla lines 351-353] *)
Theorem thm_atomic_failure : forall s,
  reachable s -> atomic_failure s.
Proof.
  intros s Hr; apply valid_state_reachable in Hr.
  unfold atomic_failure; intro Hfail.
  unfold valid_state in Hr; rewrite Hfail in Hr.
  destruct Hr as [Hl _]; exact Hl.
Qed.

(* Theorem 3: Artifacts form a strict causal dependency chain.
   hasWitness => hasTrace, hasProof => hasWitness, proofOnL1 => hasProof.

   The witness commits to the execution trace; the proof commits to
   the witness; the L1 verification commits to the proof. Breaking
   this chain would allow fabricated state transitions.

   [Source: E2EPipeline.tla lines 364-368] *)
Theorem thm_artifact_dependency_chain : forall s,
  reachable s -> artifact_dependency_chain s.
Proof.
  intros s Hr; apply valid_state_reachable in Hr.
  unfold artifact_dependency_chain, valid_state in *.
  destruct (sp_stage s); intuition congruence.
Qed.

(* Theorem 4: Artifact presence implies minimum pipeline stage.
   Once an artifact is produced, the batch stage is consistent
   with having that artifact. Artifacts are never revoked.

   [Source: E2EPipeline.tla lines 378-387] *)
Theorem thm_monotonic_progress : forall s,
  reachable s -> monotonic_progress s.
Proof.
  intros s Hr; apply valid_state_reachable in Hr.
  unfold monotonic_progress, valid_state in *.
  destruct (sp_stage s); intuition congruence.
Qed.

(* ========================================== *)
(*     IMPLEMENTATION REFINEMENT               *)
(* ========================================== *)

(* Every implementation step corresponds to a valid spec step.
   Proved in Impl.v as refinement_step. Restated here for completeness.

   The Go orchestrator's ProcessBatch function processes stages
   sequentially, producing transitions that are individually valid
   TLA+ actions. The im_max_retries configuration field is erased
   by map_state, requiring only that it equals the spec's MaxRetries. *)
Theorem impl_refines_spec : forall is is',
  im_max_retries is = MaxRetries ->
  impl_step is is' ->
  spec_step (map_state is) (map_state is').
Proof. exact refinement_step. Qed.

(* ========================================== *)
(*     VERIFICATION SUMMARY                    *)
(* ========================================== *)

(* All safety properties proved without Admitted:

   INDUCTIVE INVARIANT:
     valid_state -- exact characterization of reachable artifact
     configurations, mapping each pipeline stage to its permitted
     artifact combinations

   SAFETY THEOREMS (for all reachable states):
     1. thm_pipeline_integrity         -- Finalized => all artifacts
     2. thm_atomic_failure             -- Failed => proofOnL1 = false
     3. thm_artifact_dependency_chain  -- Strict causal ordering
     4. thm_monotonic_progress         -- Artifact => minimum stage

   REFINEMENT:
     5. impl_refines_spec -- Go impl step -> valid TLA+ spec step
        (requires im_max_retries = MaxRetries)

   Proof Architecture:
     - Single inductive invariant (valid_state) captures all constraints
     - Case-split on stage for preservation (13 cases, all automatic)
     - Safety properties derived by case-split on stage
     - Refinement by constructor-matching (Impl.v -> Spec.v) *)
