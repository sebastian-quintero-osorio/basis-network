(* ========================================== *)
(*     Spec.v -- TLA+ Specification Model      *)
(*     Faithful Translation of E2EPipeline.tla *)
(*     zkl2/proofs/units/2026-03-e2e-pipeline  *)
(* ========================================== *)

(* This file translates the TLA+ specification of the E2E proving
   pipeline into Coq definitions. The specification models a per-batch
   state machine with:

   - 7 stages: Pending -> Executed -> Witnessed -> Proved ->
               Submitted -> Finalized (terminal), or Failed (terminal)
   - Bounded retry with MaxRetries attempts per stage
   - Artifact tracking: hasTrace, hasWitness, hasProof, proofOnL1
   - 13 transition actions (Success/Fail/Exhaust per stage + Finalize)

   Since batches are independent in the TLA+ spec (each batch has its
   own state variables), we model a single batch. The universally
   quantified properties reduce to single state machine properties.

   Every definition is tagged with its source location.

   [Source: zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/
    v0-analysis/specs/E2EPipeline/E2EPipeline.tla] *)

From E2EPipeline Require Import Common.
From Stdlib Require Import Bool.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.

(* ========================================== *)
(*     CONSTANTS                               *)
(* ========================================== *)

(* Maximum retry attempts per stage before terminal failure.
   [Source: E2EPipeline.tla line 28] *)
Parameter MaxRetries : nat.

(* ========================================== *)
(*     STATE                                   *)
(* ========================================== *)

(* Per-batch state combining all TLA+ variables.
   [Source: E2EPipeline.tla lines 53-58] *)
Record spec_state := mkSpecState {
  sp_stage       : stage;    (* batchStage[b]  *)
  sp_retries     : nat;      (* retryCount[b]  *)
  sp_has_trace   : bool;     (* hasTrace[b]    *)
  sp_has_witness : bool;     (* hasWitness[b]  *)
  sp_has_proof   : bool;     (* hasProof[b]    *)
  sp_proof_on_l1 : bool;     (* proofOnL1[b]   *)
}.

(* All batches begin at Pending with zero retries and no artifacts.
   [Source: E2EPipeline.tla lines 80-86] *)
Definition spec_init : spec_state :=
  mkSpecState Pending 0 false false false false.

(* ========================================== *)
(*     STEP RELATION                           *)
(* ========================================== *)

(* Next-state relation. Each constructor corresponds to a TLA+ action.
   [Source: E2EPipeline.tla lines 274-289] *)
Inductive spec_step : spec_state -> spec_state -> Prop :=

  (* === Execute Stage === *)

  (* Run L2 transactions through EVM executor, collect traces.
     [Source: E2EPipeline.tla lines 99-104] *)
  | SpExecuteSuccess : forall s,
      sp_stage s = Pending ->
      spec_step s (mkSpecState Executed 0 true
        (sp_has_witness s) (sp_has_proof s) (sp_proof_on_l1 s))

  (* Retry: stage function failed, retries remain.
     [Source: E2EPipeline.tla lines 109-113] *)
  | SpExecuteFail : forall s,
      sp_stage s = Pending ->
      sp_retries s < MaxRetries ->
      spec_step s (mkSpecState Pending (sp_retries s + 1)
        (sp_has_trace s) (sp_has_witness s)
        (sp_has_proof s) (sp_proof_on_l1 s))

  (* Terminal: all retries exhausted at execute stage.
     [Source: E2EPipeline.tla lines 118-122] *)
  | SpExecuteExhaust : forall s,
      sp_stage s = Pending ->
      sp_retries s >= MaxRetries ->
      spec_step s (mkSpecState Failed (sp_retries s)
        (sp_has_trace s) (sp_has_witness s)
        (sp_has_proof s) (sp_proof_on_l1 s))

  (* === Witness Stage === *)

  (* Generate witness tables from execution traces.
     [Source: E2EPipeline.tla lines 137-143] *)
  | SpWitnessSuccess : forall s,
      sp_stage s = Executed ->
      sp_has_trace s = true ->
      spec_step s (mkSpecState Witnessed 0 (sp_has_trace s) true
        (sp_has_proof s) (sp_proof_on_l1 s))

  (* [Source: E2EPipeline.tla lines 145-150] *)
  | SpWitnessFail : forall s,
      sp_stage s = Executed ->
      sp_has_trace s = true ->
      sp_retries s < MaxRetries ->
      spec_step s (mkSpecState Executed (sp_retries s + 1)
        (sp_has_trace s) (sp_has_witness s)
        (sp_has_proof s) (sp_proof_on_l1 s))

  (* [Source: E2EPipeline.tla lines 154-158] *)
  | SpWitnessExhaust : forall s,
      sp_stage s = Executed ->
      sp_retries s >= MaxRetries ->
      spec_step s (mkSpecState Failed (sp_retries s)
        (sp_has_trace s) (sp_has_witness s)
        (sp_has_proof s) (sp_proof_on_l1 s))

  (* === Prove Stage === *)

  (* Generate Groth16 ZK proof from witness tables.
     [Source: E2EPipeline.tla lines 174-180] *)
  | SpProveSuccess : forall s,
      sp_stage s = Witnessed ->
      sp_has_witness s = true ->
      spec_step s (mkSpecState Proved 0 (sp_has_trace s)
        (sp_has_witness s) true (sp_proof_on_l1 s))

  (* [Source: E2EPipeline.tla lines 182-187] *)
  | SpProveFail : forall s,
      sp_stage s = Witnessed ->
      sp_has_witness s = true ->
      sp_retries s < MaxRetries ->
      spec_step s (mkSpecState Witnessed (sp_retries s + 1)
        (sp_has_trace s) (sp_has_witness s)
        (sp_has_proof s) (sp_proof_on_l1 s))

  (* [Source: E2EPipeline.tla lines 191-195] *)
  | SpProveExhaust : forall s,
      sp_stage s = Witnessed ->
      sp_retries s >= MaxRetries ->
      spec_step s (mkSpecState Failed (sp_retries s)
        (sp_has_trace s) (sp_has_witness s)
        (sp_has_proof s) (sp_proof_on_l1 s))

  (* === Submit Stage === *)

  (* Submit ZK proof to L1: commitBatch + proveBatch + executeBatch.
     [Source: E2EPipeline.tla lines 216-222] *)
  | SpSubmitSuccess : forall s,
      sp_stage s = Proved ->
      sp_has_proof s = true ->
      spec_step s (mkSpecState Submitted 0 (sp_has_trace s)
        (sp_has_witness s) (sp_has_proof s) true)

  (* [Source: E2EPipeline.tla lines 224-229] *)
  | SpSubmitFail : forall s,
      sp_stage s = Proved ->
      sp_has_proof s = true ->
      sp_retries s < MaxRetries ->
      spec_step s (mkSpecState Proved (sp_retries s + 1)
        (sp_has_trace s) (sp_has_witness s)
        (sp_has_proof s) (sp_proof_on_l1 s))

  (* [Source: E2EPipeline.tla lines 233-237] *)
  | SpSubmitExhaust : forall s,
      sp_stage s = Proved ->
      sp_retries s >= MaxRetries ->
      spec_step s (mkSpecState Failed (sp_retries s)
        (sp_has_trace s) (sp_has_witness s)
        (sp_has_proof s) (sp_proof_on_l1 s))

  (* === Finalize === *)

  (* Deterministic: after L1 verification, batch is finalized.
     [Source: E2EPipeline.tla lines 253-257] *)
  | SpFinalize : forall s,
      sp_stage s = Submitted ->
      sp_proof_on_l1 s = true ->
      spec_step s (mkSpecState Finalized (sp_retries s)
        (sp_has_trace s) (sp_has_witness s)
        (sp_has_proof s) (sp_proof_on_l1 s)).

(* ========================================== *)
(*     SAFETY PROPERTIES                       *)
(* ========================================== *)

(* Every finalized batch has a complete artifact chain AND L1 verification.
   [Source: E2EPipeline.tla lines 334-340] *)
Definition pipeline_integrity (s : spec_state) : Prop :=
  sp_stage s = Finalized ->
    sp_has_trace s = true /\ sp_has_witness s = true /\
    sp_has_proof s = true /\ sp_proof_on_l1 s = true.

(* Failed batches leave zero footprint on L1.
   [Source: E2EPipeline.tla lines 351-353] *)
Definition atomic_failure (s : spec_state) : Prop :=
  sp_stage s = Failed -> sp_proof_on_l1 s = false.

(* Artifacts form a strict causal dependency chain.
   [Source: E2EPipeline.tla lines 364-368] *)
Definition artifact_dependency_chain (s : spec_state) : Prop :=
  (sp_has_witness s = true -> sp_has_trace s = true) /\
  (sp_has_proof s = true -> sp_has_witness s = true) /\
  (sp_proof_on_l1 s = true -> sp_has_proof s = true).

(* Artifact presence implies minimum pipeline stage.
   [Source: E2EPipeline.tla lines 378-387] *)
Definition monotonic_progress (s : spec_state) : Prop :=
  (sp_has_trace s = true -> sp_stage s <> Pending) /\
  (sp_has_witness s = true ->
     sp_stage s <> Pending /\ sp_stage s <> Executed) /\
  (sp_has_proof s = true ->
     sp_stage s <> Pending /\ sp_stage s <> Executed /\
     sp_stage s <> Witnessed) /\
  (sp_proof_on_l1 s = true ->
     sp_stage s = Submitted \/ sp_stage s = Finalized).
