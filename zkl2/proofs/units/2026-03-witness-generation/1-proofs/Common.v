(* ========================================== *)
(*     Common.v -- Standard Library            *)
(*     Witness Generation Verification Unit    *)
(*     zkl2/proofs/units/2026-03-witness-generation *)
(* ========================================== *)

(* Shared infrastructure for the Witness Generation verification:
   list operations (take), counting predicates, ordered sequences,
   and tactics. Domain-independent and reusable.

   Key mappings from TLA+:
     Take(s, n)       -> take n s
     Len(s)           -> length s
     Append(s, e)     -> s ++ [e]
     s \o t           -> s ++ t
     Cardinality(...) -> count_pred p l

   [Source: WitnessGeneration.tla] *)

From Stdlib Require Import List.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
Import ListNotations.

(* ========================================== *)
(*     LIST TAKE                               *)
(* ========================================== *)

(* First n elements. [Spec: WitnessGeneration.tla -- Take semantics] *)
Fixpoint take {A : Type} (n : nat) (l : list A) : list A :=
  match n, l with
  | 0, _ => []
  | _, [] => []
  | S n', x :: rest => x :: take n' rest
  end.

(* Take with successor and nth_error: extending prefix by one element.
   Key lemma for relating take (n+1) to take n when nth_error is known. *)
Lemma take_succ_nth_error : forall {A : Type} (l : list A) n x,
  nth_error l n = Some x ->
  take (S n) l = take n l ++ [x].
Proof.
  intros A l; induction l as [|a rest IH]; intros n x Hnth.
  - destruct n; discriminate.
  - destruct n as [|n'].
    + simpl in Hnth. injection Hnth; intros; subst. simpl. reflexivity.
    + simpl in *. f_equal. apply IH. exact Hnth.
Qed.

(* nth_error implies index is within bounds. *)
Lemma nth_error_lt : forall {A : Type} (l : list A) n x,
  nth_error l n = Some x -> n < length l.
Proof.
  intros A l; induction l as [|a rest IH]; intros n x H.
  - destruct n; discriminate.
  - destruct n as [|n']; simpl in *.
    + lia.
    + apply IH in H. lia.
Qed.

(* ========================================== *)
(*     COUNTING PREDICATE                      *)
(* ========================================== *)

(* Count elements satisfying a boolean predicate.
   Models TLA+ Cardinality({i \in S : P(i)}).
   [Source: WitnessGeneration.tla lines 245-249] *)
Fixpoint count_pred {A : Type} (p : A -> bool) (l : list A) : nat :=
  match l with
  | [] => 0
  | x :: rest => (if p x then 1 else 0) + count_pred p rest
  end.

Lemma count_pred_app : forall {A : Type} (p : A -> bool) (l1 l2 : list A),
  count_pred p (l1 ++ l2) = count_pred p l1 + count_pred p l2.
Proof.
  intros A p l1; induction l1 as [|x rest IH]; intros l2; simpl.
  - reflexivity.
  - rewrite IH. destruct (p x); lia.
Qed.

Lemma count_pred_le_length : forall {A : Type} (p : A -> bool) (l : list A),
  count_pred p l <= length l.
Proof.
  intros A p l; induction l as [|x rest IH]; simpl.
  - lia.
  - destruct (p x); lia.
Qed.

(* ========================================== *)
(*     ORDERED SEQUENCES                       *)
(* ========================================== *)

(* Strictly increasing natural numbers.
   Models TLA+ S6 sequential order for arithmetic/call tables.
   [Source: WitnessGeneration.tla lines 312-315] *)
Inductive strictly_increasing : list nat -> Prop :=
  | si_nil : strictly_increasing []
  | si_one : forall n, strictly_increasing [n]
  | si_cons : forall a b rest,
      a < b -> strictly_increasing (b :: rest) ->
      strictly_increasing (a :: b :: rest).

(* Non-decreasing natural numbers.
   Models TLA+ S6 sequential order for storage table
   (SSTORE produces 2 rows with same srcIdx).
   [Source: WitnessGeneration.tla lines 316-317] *)
Inductive non_decreasing : list nat -> Prop :=
  | nd_nil : non_decreasing []
  | nd_one : forall n, non_decreasing [n]
  | nd_cons : forall a b rest,
      a <= b -> non_decreasing (b :: rest) ->
      non_decreasing (a :: b :: rest).

(* Appending an element larger than all existing preserves strict increase. *)
Lemma si_app_single : forall l n,
  strictly_increasing l ->
  (forall x, In x l -> x < n) ->
  strictly_increasing (l ++ [n]).
Proof.
  intros l n Hsi Hlt.
  induction Hsi as [| m | a b rest Hab Hbr IH].
  - simpl. constructor.
  - simpl. constructor.
    + apply Hlt. left. reflexivity.
    + constructor.
  - simpl. constructor.
    + exact Hab.
    + apply IH. intros x Hx. apply Hlt. right. exact Hx.
Qed.

(* Appending an element >= all existing preserves non-decrease. *)
Lemma nd_app_single : forall l n,
  non_decreasing l ->
  (forall x, In x l -> x <= n) ->
  non_decreasing (l ++ [n]).
Proof.
  intros l n Hnd Hle.
  induction Hnd as [| m | a b rest Hab Hbr IH].
  - simpl. constructor.
  - simpl. constructor.
    + apply Hle. left. reflexivity.
    + constructor.
  - simpl. constructor.
    + exact Hab.
    + apply IH. intros x Hx. apply Hle. right. exact Hx.
Qed.

(* Appending a pair of equal elements preserves non-decrease.
   Used for SSTORE which produces 2 rows with the same source index.
   [Source: WitnessGeneration.tla lines 170-179 -- ProcessStorageWrite] *)
Lemma nd_app_pair : forall l n,
  non_decreasing l ->
  (forall x, In x l -> x <= n) ->
  non_decreasing (l ++ [n; n]).
Proof.
  intros l n Hnd Hle.
  replace (l ++ [n; n]) with ((l ++ [n]) ++ [n])
    by (rewrite <- app_assoc; reflexivity).
  apply nd_app_single.
  - apply nd_app_single; assumption.
  - intros x Hx. apply in_app_or in Hx.
    destruct Hx as [Hx | [-> | []]].
    + apply Hle. exact Hx.
    + lia.
Qed.

(* ========================================== *)
(*     MAP BOUND HELPER                        *)
(* ========================================== *)

(* If all elements of a list satisfy a bound on a projected field,
   then all elements of the projected list satisfy the bound. *)
Lemma map_bound : forall {A : Type} (f : A -> nat) (l : list A) (n : nat),
  (forall a, In a l -> f a < n) ->
  forall x, In x (map f l) -> x < n.
Proof.
  intros A f l n Hlt x Hx.
  rewrite in_map_iff in Hx. destruct Hx as [a [<- Ha]].
  exact (Hlt a Ha).
Qed.

Lemma map_bound_le : forall {A : Type} (f : A -> nat) (l : list A) (n : nat),
  (forall a, In a l -> f a < n) ->
  forall x, In x (map f l) -> x <= n.
Proof.
  intros A f l n Hlt x Hx. assert (H := map_bound f l n Hlt x Hx). lia.
Qed.

(* ========================================== *)
(*     TACTICS                                 *)
(* ========================================== *)

Ltac destruct_match :=
  match goal with
  | [ |- context[match ?x with _ => _ end] ] => destruct x eqn:?
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x eqn:?
  end.

Ltac auto_spec :=
  intros; simpl; try destruct_match; try reflexivity; try assumption; auto.
