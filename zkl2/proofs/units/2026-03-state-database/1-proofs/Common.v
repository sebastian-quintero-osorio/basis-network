(* ========================================== *)
(*     Common.v -- Shared Standard Library     *)
(* ========================================== *)
(* Type mappings, functional updates, and      *)
(* summation lemmas for the StateDatabase      *)
(* verification unit.                          *)
(*                                             *)
(* [Source: lab/4-prover/CLAUDE.md, Section 4] *)
(* ========================================== *)

From Stdlib Require Import ZArith.
From Stdlib Require Import Arith.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import List.
From Stdlib Require Import Lia.
Import ListNotations.

Open Scope Z_scope.

(* ========================================== *)
(*     TYPE DEFINITIONS                        *)
(* ========================================== *)

(* BN254 field elements modeled as integers.
   Production: gnark-crypto fr.Element.
   [Spec: Values operate over a prime field] *)
Definition FieldElement := Z.

(* Empty sentinel value.
   [Spec: EMPTY == 0, line 68] *)
Definition EMPTY : FieldElement := 0.

(* ========================================== *)
(*     FUNCTIONAL UPDATE                       *)
(* ========================================== *)

(* Models Go map assignment: m[k] = v.
   Used for balance and storage updates. *)
Definition fupdate (f : nat -> Z) (k : nat) (v : Z) : nat -> Z :=
  fun x => if Nat.eqb x k then v else f x.

(* Boolean variant for alive flags.
   Models Go: account.Alive = v *)
Definition bupdate (f : nat -> bool) (k : nat) (v : bool) : nat -> bool :=
  fun x => if Nat.eqb x k then v else f x.

(* fupdate reads back the new value at the updated key. *)
Lemma fupdate_eq : forall f k v, fupdate f k v k = v.
Proof.
  intros. unfold fupdate. rewrite Nat.eqb_refl. reflexivity.
Qed.

(* fupdate preserves values at other keys. *)
Lemma fupdate_neq : forall f k1 k2 v,
  k2 <> k1 -> fupdate f k1 v k2 = f k2.
Proof.
  intros f k1 k2 v Hneq. unfold fupdate.
  destruct (Nat.eqb k2 k1) eqn:E; [|reflexivity].
  exfalso. apply Hneq.
  exact (proj1 (Nat.eqb_eq k2 k1) E).
Qed.

(* bupdate reads back the new value at the updated key. *)
Lemma bupdate_eq : forall f k v, bupdate f k v k = v.
Proof.
  intros. unfold bupdate. rewrite Nat.eqb_refl. reflexivity.
Qed.

(* bupdate preserves values at other keys. *)
Lemma bupdate_neq : forall f k1 k2 v,
  k2 <> k1 -> bupdate f k1 v k2 = f k2.
Proof.
  intros f k1 k2 v Hneq. unfold bupdate.
  destruct (Nat.eqb k2 k1) eqn:E; [|reflexivity].
  exfalso. apply Hneq.
  exact (proj1 (Nat.eqb_eq k2 k1) E).
Qed.

(* ========================================== *)
(*     SUMMATION                               *)
(* ========================================== *)

(* Sum f(a) over a list of indices.
   Models total balance computation.
   [Spec: SumOver(f, S), lines 321-324] *)
Fixpoint sum_list (f : nat -> Z) (addrs : list nat) : Z :=
  match addrs with
  | nil => 0
  | a :: rest => f a + sum_list f rest
  end.

(* Updating a key absent from the list preserves the sum. *)
Lemma sum_list_fupdate_notin : forall f k v addrs,
  ~ In k addrs ->
  sum_list (fupdate f k v) addrs = sum_list f addrs.
Proof.
  intros f k v addrs Hnotin.
  induction addrs as [|a rest IH]; [reflexivity|].
  simpl in *. unfold fupdate at 1.
  destruct (Nat.eqb a k) eqn:E.
  - exfalso. apply Hnotin. left.
    exact (proj1 (Nat.eqb_eq a k) E).
  - rewrite IH; [reflexivity | tauto].
Qed.

(* Updating a key in a NoDup list shifts the sum by (v - f k). *)
Lemma sum_list_fupdate_in : forall f k v addrs,
  NoDup addrs ->
  In k addrs ->
  sum_list (fupdate f k v) addrs = sum_list f addrs + (v - f k).
Proof.
  intros f k v addrs Hnd Hin.
  induction addrs as [|a rest IH]; [contradiction|].
  simpl in *.
  assert (Hna : ~ In a rest)
    by (inversion Hnd; assumption).
  assert (Hndr : NoDup rest)
    by (inversion Hnd; assumption).
  destruct Hin as [<- | Hin'].
  - unfold fupdate at 1. rewrite Nat.eqb_refl.
    rewrite sum_list_fupdate_notin by assumption. lia.
  - unfold fupdate at 1.
    destruct (Nat.eqb a k) eqn:E.
    + exfalso. apply Hna.
      rewrite (proj1 (Nat.eqb_eq a k) E). exact Hin'.
    + specialize (IH Hndr Hin'). lia.
Qed.

(* Two compensating updates preserve the sum.
   Core lemma for Transfer and SelfDestruct balance conservation. *)
Lemma sum_list_double_fupdate : forall f k1 k2 v1 v2 addrs,
  NoDup addrs ->
  In k1 addrs ->
  In k2 addrs ->
  k1 <> k2 ->
  v1 - f k1 + (v2 - f k2) = 0 ->
  sum_list (fupdate (fupdate f k1 v1) k2 v2) addrs = sum_list f addrs.
Proof.
  intros f k1 k2 v1 v2 addrs Hnd Hin1 Hin2 Hneq Hdelta.
  rewrite sum_list_fupdate_in by assumption.
  assert (Hfk2 : fupdate f k1 v1 k2 = f k2).
  { apply fupdate_neq. intro H. apply Hneq. symmetry. exact H. }
  rewrite Hfk2.
  rewrite sum_list_fupdate_in by assumption.
  lia.
Qed.

(* ========================================== *)
(*     RESULT TYPE                             *)
(* ========================================== *)

(* Go error return pattern. *)
Inductive Result (T E : Type) : Type :=
  | Ok : T -> Result T E
  | Err : E -> Result T E.

Arguments Ok {T E}.
Arguments Err {T E}.

(* ========================================== *)
(*     TACTICS                                 *)
(* ========================================== *)

Ltac destruct_match :=
  match goal with
  | [ |- context[match ?x with _ => _ end] ] => destruct x eqn:?
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x eqn:?
  end.

Ltac auto_spec :=
  intros; simpl in *; try destruct_match;
  try reflexivity; try assumption; try lia.
