(* ========================================== *)
(*     Common.v -- Standard Library            *)
(*     EVM Executor Verification Unit          *)
(*     zkl2/proofs/units/2026-03-evm-executor  *)
(* ========================================== *)

(* Shared types, counting helpers, and tactics used across all proof files.
   This file establishes the infrastructure needed for Determinism and
   TraceCompleteness proofs without importing domain-specific definitions. *)

From Stdlib Require Import List.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
Import ListNotations.

(* ========================================== *)
(*     COUNTING HELPERS                        *)
(* ========================================== *)

(* Count elements in a list satisfying a boolean predicate.
   Used to count trace entries by type and opcodes by type. *)
Fixpoint count_pred {A : Type} (p : A -> bool) (l : list A) : nat :=
  match l with
  | [] => 0
  | x :: rest => (if p x then 1 else 0) + count_pred p rest
  end.

(* count_pred distributes over list concatenation.
   Critical for TraceCompleteness: when a trace entry is appended,
   the count of the combined list equals the sum of counts. *)
Lemma count_pred_app : forall (A : Type) (p : A -> bool) (l1 l2 : list A),
  count_pred p (l1 ++ l2) = count_pred p l1 + count_pred p l2.
Proof.
  intros A p l1.
  induction l1 as [| x rest IH]; intros l2; simpl.
  - reflexivity.
  - rewrite IH. destruct (p x); lia.
Qed.

(* count_pred of a singleton list reduces to the predicate evaluation. *)
Lemma count_pred_singleton : forall (A : Type) (p : A -> bool) (x : A),
  count_pred p [x] = if p x then 1 else 0.
Proof.
  intros. simpl. lia.
Qed.

(* ========================================== *)
(*     TACTICS                                 *)
(* ========================================== *)

(* Destruct the outermost match expression in goal or hypothesis. *)
Ltac destruct_match :=
  match goal with
  | [ |- context[match ?x with _ => _ end] ] => destruct x eqn:?
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x eqn:?
  end.
