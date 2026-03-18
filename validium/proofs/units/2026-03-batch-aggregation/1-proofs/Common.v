(* ================================================================ *)
(*  Common.v -- Standard Library for Batch Aggregation Unit         *)
(* ================================================================ *)
(*                                                                  *)
(*  Provides type mappings, sequence operations, remove lemmas,     *)
(*  and tactics shared across Spec.v, Impl.v, and Refinement.v.    *)
(*                                                                  *)
(*  Target: validium/proofs/units/2026-03-batch-aggregation/        *)
(*  Source TLA+: BatchAggregation.tla (v1-fix), lines 1-338         *)
(*  Source Impl: transaction-queue.ts, wal.ts, batch-aggregator.ts  *)
(* ================================================================ *)

From Stdlib Require Import Lists.List.
From Stdlib Require Import Arith.Arith.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.Bool.

Import ListNotations.

(* ======================================== *)
(*     TRANSACTION TYPE                     *)
(* ======================================== *)

(* Transaction identifiers are abstract natural numbers.
   [Spec: Element of AllTxs -- finite set of unique identifiers]
   [Impl: Transaction.txHash -- unique SHA-256 string] *)
Definition Tx := nat.

(* ======================================== *)
(*     BATCH SIZE THRESHOLD                 *)
(* ======================================== *)

(* [Spec: CONSTANT BatchSizeThreshold, line 33]
   [Spec: ASSUME BatchSizeThreshold > 0, line 35]
   [Impl: BatchAggregatorConfig.maxBatchSize] *)
Parameter BST : nat.
Axiom bst_positive : BST > 0.

(* ======================================== *)
(*     FLATTEN                              *)
(* ======================================== *)

(* Flatten a sequence of sequences into a single sequence.
   [Spec: RECURSIVE Flatten(_), lines 59-62 of BatchAggregation.tla] *)
Fixpoint flatten {A : Type} (seqs : list (list A)) : list A :=
  match seqs with
  | [] => []
  | s :: rest => s ++ flatten rest
  end.

(* ======================================== *)
(*     FLATTEN LEMMAS                       *)
(* ======================================== *)

Lemma flatten_nil : forall {A : Type},
  @flatten A [] = [].
Proof. reflexivity. Qed.

Lemma flatten_cons : forall {A : Type} (h : list A) (t : list (list A)),
  flatten (h :: t) = h ++ flatten t.
Proof. reflexivity. Qed.

Lemma flatten_app : forall {A : Type} (l1 l2 : list (list A)),
  flatten (l1 ++ l2) = flatten l1 ++ flatten l2.
Proof.
  intros A l1. induction l1 as [| h t IH]; intros l2; simpl.
  - reflexivity.
  - rewrite IH. rewrite app_assoc. reflexivity.
Qed.

Lemma flatten_snoc : forall {A : Type} (seqs : list (list A)) (s : list A),
  flatten (seqs ++ [s]) = flatten seqs ++ s.
Proof.
  intros. rewrite flatten_app. simpl. rewrite app_nil_r. reflexivity.
Qed.

(* ======================================== *)
(*     FIRSTN / SKIPN LEMMAS                *)
(* ======================================== *)

(* firstn of a known prefix *)
Lemma firstn_exact : forall {A : Type} (l1 l2 : list A),
  firstn (length l1) (l1 ++ l2) = l1.
Proof.
  intros A l1. induction l1 as [| x xs IH]; intros l2; simpl.
  - reflexivity.
  - f_equal. apply IH.
Qed.

(* skipn of a known prefix *)
Lemma skipn_exact : forall {A : Type} (l1 l2 : list A),
  skipn (length l1) (l1 ++ l2) = l2.
Proof.
  intros A l1. induction l1 as [| x xs IH]; intros l2; simpl.
  - reflexivity.
  - apply IH.
Qed.

(* firstn when n <= length does not see the suffix *)
Lemma firstn_app_le : forall {A : Type} (n : nat) (l1 l2 : list A),
  n <= length l1 -> firstn n (l1 ++ l2) = firstn n l1.
Proof.
  intros A n. induction n as [| n' IH]; intros l1 l2 Hle; simpl.
  - reflexivity.
  - destruct l1 as [| x xs].
    + simpl in Hle. lia.
    + simpl. f_equal. apply IH. simpl in Hle. lia.
Qed.

(* Length of firstn is bounded by n *)
Lemma length_firstn_le : forall {A : Type} (n : nat) (l : list A),
  length (firstn n l) <= n.
Proof.
  intros A n. induction n as [| n' IH]; intros l; simpl.
  - lia.
  - destruct l as [| x xs]; simpl.
    + lia.
    + specialize (IH xs). lia.
Qed.

(* ======================================== *)
(*     MEMBERSHIP LEMMAS                    *)
(* ======================================== *)

Lemma in_flatten : forall {A : Type} (x : A) (seqs : list (list A)),
  In x (flatten seqs) <-> exists s, In s seqs /\ In x s.
Proof.
  intros A x seqs. induction seqs as [| h t IH]; simpl.
  - split.
    + intros [].
    + intros [s [[] _]].
  - rewrite in_app_iff. rewrite IH. split.
    + intros [Hh | [s [Ht Hx]]].
      * exists h. auto.
      * exists s. auto.
    + intros [s [[Heq | Ht] Hx]].
      * left. subst. exact Hx.
      * right. exists s. auto.
Qed.

(* ======================================== *)
(*     REMOVE LEMMAS                        *)
(* ======================================== *)

(* Forward: membership in remove implies membership in original.
   [Used for WalComplete backward direction after Enqueue] *)
Lemma remove_in_orig : forall (x y : Tx) (l : list Tx),
  In x (remove Nat.eq_dec y l) -> In x l.
Proof.
  intros x y l. induction l as [| a t IH]; simpl.
  - tauto.
  - destruct (Nat.eq_dec y a).
    + intros H. right. exact (IH H).
    + intros [H | H].
      * left. exact H.
      * right. exact (IH H).
Qed.

(* Backward: non-equal elements survive remove.
   [Used for WalComplete forward direction after Enqueue] *)
Lemma in_remove_neq : forall (x y : Tx) (l : list Tx),
  In x l -> x <> y -> In x (remove Nat.eq_dec y l).
Proof.
  intros x y l. induction l as [| a t IH]; simpl.
  - tauto.
  - destruct (Nat.eq_dec y a) as [Hya | Hya].
    + intros [Hxa | Hin] Hneq.
      * exfalso. apply Hneq. congruence.
      * exact (IH Hin Hneq).
    + intros [Hxa | Hin] Hneq.
      * left. exact Hxa.
      * right. exact (IH Hin Hneq).
Qed.

(* ======================================== *)
(*     TACTICS                              *)
(* ======================================== *)

(* Destruct match/if expressions *)
Ltac destruct_match :=
  match goal with
  | [ |- context[if ?c then _ else _] ] => destruct c
  | [ H : context[if ?c then _ else _] |- _ ] => destruct c
  | [ |- context[match ?x with _ => _ end] ] => destruct x
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x
  end.

(* Normalize list associativity to right-associative form *)
Ltac norm_app :=
  repeat rewrite <- app_assoc;
  repeat rewrite <- app_assoc in *.
