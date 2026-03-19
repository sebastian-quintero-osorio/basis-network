(* ========================================== *)
(*     Common.v -- Standard Library            *)
(*     E2E Pipeline Verification Unit          *)
(*     zkl2/proofs/units/2026-03-e2e-pipeline  *)
(* ========================================== *)

(* Shared infrastructure for the E2E Pipeline verification:
   pipeline stage definitions and tactics.

   Key TLA+ mappings:
     StageSet         -> Inductive stage
     TerminalStages   -> is_terminal predicate

   [Source: E2EPipeline.tla lines 43-46] *)

From Stdlib Require Import Bool.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.

(* ========================================== *)
(*     PIPELINE STAGES                         *)
(* ========================================== *)

(* Models the TLA+ StageSet.
   Seven stages forming a linear pipeline with two terminal states.

   [Source: E2EPipeline.tla lines 43-44]
   StageSet == {"pending", "executed", "witnessed", "proved",
                "submitted", "finalized", "failed"} *)
Inductive stage : Type :=
  | Pending
  | Executed
  | Witnessed
  | Proved
  | Submitted
  | Finalized
  | Failed.

(* Terminal stages: a batch in a terminal stage takes no further actions.
   [Source: E2EPipeline.tla line 46]
   TerminalStages == {"finalized", "failed"} *)
Definition is_terminal (s : stage) : bool :=
  match s with
  | Finalized | Failed => true
  | _ => false
  end.

(* Decidable equality for stages. *)
Lemma stage_eq_dec : forall s1 s2 : stage, {s1 = s2} + {s1 <> s2}.
Proof. decide equality. Defined.

(* ========================================== *)
(*     TACTICS                                 *)
(* ========================================== *)

(* Destruct the first match expression found in goal or hypotheses. *)
Ltac destruct_match :=
  match goal with
  | [ |- context[match ?x with _ => _ end] ] => destruct x eqn:?
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x eqn:?
  end.

(* Combined automation tactic for specification proofs. *)
Ltac auto_spec :=
  intros; simpl; try destruct_match; try reflexivity;
  try assumption; auto.
