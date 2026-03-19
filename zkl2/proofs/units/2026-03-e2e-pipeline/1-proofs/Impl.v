(* ========================================== *)
(*     Impl.v -- Go Implementation Model       *)
(*     Abstract Model of pipeline Go code      *)
(*     zkl2/proofs/units/2026-03-e2e-pipeline  *)
(* ========================================== *)

(* This file models the Go implementation of the E2E proving pipeline
   as Coq definitions. The key difference from the spec:

   TLA+ (Spec.v):
     MaxRetries is a global constant parameter.

   Go (this file):
     MaxRetries is a per-orchestrator configuration value
     (PipelineConfig.RetryPolicy.MaxRetries), carried in each state.

   The verification proves that every Go implementation step, when
   the configuration matches the spec parameter, corresponds to a
   valid specification step.

   Goroutine modeling: the Go orchestrator uses sync.Mutex to serialize
   access to batch state. ProcessBatch runs sequentially per batch.
   We model each stage execution as an atomic state transition.

   [Source: orchestrator.go, stages.go, types.go (frozen in 0-input-impl/)] *)

From E2EPipeline Require Import Common.
From E2EPipeline Require Import Spec.
From Stdlib Require Import Bool.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.

(* ========================================== *)
(*     IMPLEMENTATION STATE                    *)
(* ========================================== *)

(* Mirrors spec_state but carries the configured MaxRetries.
   [Source: types.go lines 175-180 -- RetryPolicy]
   [Source: types.go lines 320-371 -- BatchState] *)
Record impl_state := mkImplState {
  im_stage       : stage;
  im_retries     : nat;
  im_has_trace   : bool;
  im_has_witness : bool;
  im_has_proof   : bool;
  im_proof_on_l1 : bool;
  im_max_retries : nat     (* PipelineConfig.RetryPolicy.MaxRetries *)
}.

(* [Source: types.go lines 378-392 -- NewBatchState] *)
Definition impl_init (mr : nat) : impl_state :=
  mkImplState Pending 0 false false false false mr.

(* ========================================== *)
(*     IMPLEMENTATION STEPS                    *)
(* ========================================== *)

(* Models Orchestrator.ProcessBatch + executeWithRetry.
   Each constructor maps to a TLA+ action, using im_max_retries
   instead of the global MaxRetries parameter.
   [Source: orchestrator.go lines 88-227] *)
Inductive impl_step : impl_state -> impl_state -> Prop :=

  (* [Source: orchestrator.go line 200 -- err == nil, execute stage] *)
  | ImExecuteSuccess : forall s,
      im_stage s = Pending ->
      impl_step s (mkImplState Executed 0 true
        (im_has_witness s) (im_has_proof s) (im_proof_on_l1 s)
        (im_max_retries s))

  (* [Source: orchestrator.go lines 176-221 -- retry loop] *)
  | ImExecuteFail : forall s,
      im_stage s = Pending ->
      im_retries s < im_max_retries s ->
      impl_step s (mkImplState Pending (im_retries s + 1)
        (im_has_trace s) (im_has_witness s) (im_has_proof s)
        (im_proof_on_l1 s) (im_max_retries s))

  (* [Source: orchestrator.go lines 223-226 -- retries exhausted] *)
  | ImExecuteExhaust : forall s,
      im_stage s = Pending ->
      im_retries s >= im_max_retries s ->
      impl_step s (mkImplState Failed (im_retries s)
        (im_has_trace s) (im_has_witness s) (im_has_proof s)
        (im_proof_on_l1 s) (im_max_retries s))

  (* [Source: orchestrator.go line 200 -- err == nil, witness stage] *)
  | ImWitnessSuccess : forall s,
      im_stage s = Executed ->
      im_has_trace s = true ->
      impl_step s (mkImplState Witnessed 0 (im_has_trace s) true
        (im_has_proof s) (im_proof_on_l1 s) (im_max_retries s))

  | ImWitnessFail : forall s,
      im_stage s = Executed ->
      im_has_trace s = true ->
      im_retries s < im_max_retries s ->
      impl_step s (mkImplState Executed (im_retries s + 1)
        (im_has_trace s) (im_has_witness s) (im_has_proof s)
        (im_proof_on_l1 s) (im_max_retries s))

  | ImWitnessExhaust : forall s,
      im_stage s = Executed ->
      im_retries s >= im_max_retries s ->
      impl_step s (mkImplState Failed (im_retries s)
        (im_has_trace s) (im_has_witness s) (im_has_proof s)
        (im_proof_on_l1 s) (im_max_retries s))

  (* [Source: orchestrator.go line 200 -- err == nil, prove stage] *)
  | ImProveSuccess : forall s,
      im_stage s = Witnessed ->
      im_has_witness s = true ->
      impl_step s (mkImplState Proved 0 (im_has_trace s)
        (im_has_witness s) true (im_proof_on_l1 s) (im_max_retries s))

  | ImProveFail : forall s,
      im_stage s = Witnessed ->
      im_has_witness s = true ->
      im_retries s < im_max_retries s ->
      impl_step s (mkImplState Witnessed (im_retries s + 1)
        (im_has_trace s) (im_has_witness s) (im_has_proof s)
        (im_proof_on_l1 s) (im_max_retries s))

  | ImProveExhaust : forall s,
      im_stage s = Witnessed ->
      im_retries s >= im_max_retries s ->
      impl_step s (mkImplState Failed (im_retries s)
        (im_has_trace s) (im_has_witness s) (im_has_proof s)
        (im_proof_on_l1 s) (im_max_retries s))

  (* [Source: orchestrator.go line 200 -- err == nil, submit stage] *)
  | ImSubmitSuccess : forall s,
      im_stage s = Proved ->
      im_has_proof s = true ->
      impl_step s (mkImplState Submitted 0 (im_has_trace s)
        (im_has_witness s) (im_has_proof s) true (im_max_retries s))

  | ImSubmitFail : forall s,
      im_stage s = Proved ->
      im_has_proof s = true ->
      im_retries s < im_max_retries s ->
      impl_step s (mkImplState Proved (im_retries s + 1)
        (im_has_trace s) (im_has_witness s) (im_has_proof s)
        (im_proof_on_l1 s) (im_max_retries s))

  | ImSubmitExhaust : forall s,
      im_stage s = Proved ->
      im_retries s >= im_max_retries s ->
      impl_step s (mkImplState Failed (im_retries s)
        (im_has_trace s) (im_has_witness s) (im_has_proof s)
        (im_proof_on_l1 s) (im_max_retries s))

  (* [Source: orchestrator.go lines 148-154 -- finalize] *)
  | ImFinalize : forall s,
      im_stage s = Submitted ->
      im_proof_on_l1 s = true ->
      impl_step s (mkImplState Finalized (im_retries s)
        (im_has_trace s) (im_has_witness s) (im_has_proof s)
        (im_proof_on_l1 s) (im_max_retries s)).

(* ========================================== *)
(*     REFINEMENT MAPPING                      *)
(* ========================================== *)

(* Erases im_max_retries (implementation configuration detail).
   All other fields map identically to spec_state. *)
Definition map_state (is : impl_state) : spec_state :=
  mkSpecState (im_stage is) (im_retries is) (im_has_trace is)
              (im_has_witness is) (im_has_proof is) (im_proof_on_l1 is).

(* Implementation initial state maps to spec initial state. *)
Lemma map_init : forall mr,
  map_state (impl_init mr) = spec_init.
Proof. reflexivity. Qed.

(* Every implementation step corresponds to a valid spec step,
   when the configuration matches the spec parameter.

   The Go code's ProcessBatch sequential execution produces transitions
   that are individually valid TLA+ actions. im_max_retries matches
   MaxRetries by construction (set once from PipelineConfig).

   [Source: orchestrator.go ProcessBatch -> executeWithRetry] *)
Theorem refinement_step : forall is is',
  im_max_retries is = MaxRetries ->
  impl_step is is' ->
  spec_step (map_state is) (map_state is').
Proof.
  intros is is' Hmr Hstep.
  inversion Hstep; subst; simpl.
  - apply SpExecuteSuccess; simpl; assumption.
  - apply SpExecuteFail; simpl; [assumption | lia].
  - apply SpExecuteExhaust; simpl; [assumption | lia].
  - apply SpWitnessSuccess; simpl; assumption.
  - apply SpWitnessFail; simpl; [assumption | assumption | lia].
  - apply SpWitnessExhaust; simpl; [assumption | lia].
  - apply SpProveSuccess; simpl; assumption.
  - apply SpProveFail; simpl; [assumption | assumption | lia].
  - apply SpProveExhaust; simpl; [assumption | lia].
  - apply SpSubmitSuccess; simpl; assumption.
  - apply SpSubmitFail; simpl; [assumption | assumption | lia].
  - apply SpSubmitExhaust; simpl; [assumption | lia].
  - apply SpFinalize; simpl; assumption.
Qed.
