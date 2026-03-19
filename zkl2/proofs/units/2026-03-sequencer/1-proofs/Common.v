(* ========================================== *)
(*     Common.v -- Standard Library            *)
(*     Sequencer Verification Unit             *)
(*     zkl2/proofs/units/2026-03-sequencer     *)
(* ========================================== *)

(* Shared infrastructure for the Sequencer verification: list
   operations (take/drop), NoDup preservation, sorted pair lists,
   and tactics. Domain-independent and reusable.

   Key mappings from TLA+:
     Take(s, n) -> take n s
     Drop(s, n) -> drop n s
     Range(s)   -> In x s
     Sequences  -> list

   [Source: Sequencer.tla lines 43-49, helper operators] *)

From Stdlib Require Import List.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
Import ListNotations.

(* ========================================== *)
(*     LIST TAKE / DROP                        *)
(* ========================================== *)

(* First n elements. [Spec: Sequencer.tla line 46] *)
Fixpoint take {A : Type} (n : nat) (l : list A) : list A :=
  match n, l with
  | 0, _ => []
  | _, [] => []
  | S n', x :: rest => x :: take n' rest
  end.

(* Remove first n elements. [Spec: Sequencer.tla line 49] *)
Fixpoint drop {A : Type} (n : nat) (l : list A) : list A :=
  match n, l with
  | 0, l => l
  | _, [] => []
  | S n', _ :: rest => drop n' rest
  end.

Lemma take_drop_id : forall (A : Type) (n : nat) (l : list A),
  take n l ++ drop n l = l.
Proof.
  intros A n; induction n as [|n' IH]; intros [|x rest]; simpl;
    try reflexivity.
  f_equal. apply IH.
Qed.

Lemma In_take : forall (A : Type) (n : nat) (l : list A) x,
  In x (take n l) -> In x l.
Proof.
  intros A n; induction n as [|n' IH]; intros [|y rest] x H;
    simpl in *; try contradiction.
  destruct H as [->|H]; [left; reflexivity | right; exact (IH _ _ H)].
Qed.

Lemma In_drop : forall (A : Type) (n : nat) (l : list A) x,
  In x (drop n l) -> In x l.
Proof.
  intros A n; induction n as [|n' IH]; intros [|y rest] x H;
    simpl in *; try contradiction; try exact H.
  right; exact (IH _ _ H).
Qed.

(* ========================================== *)
(*     NODUP PRESERVATION                      *)
(* ========================================== *)

Lemma NoDup_take : forall (A : Type) (n : nat) (l : list A),
  NoDup l -> NoDup (take n l).
Proof.
  intros A n; induction n as [|n' IH]; intros [|x rest] Hnd; simpl.
  - constructor.
  - constructor.
  - constructor.
  - inversion Hnd; subst. constructor.
    + intro H; apply H1; exact (In_take _ _ _ _ H).
    + exact (IH _ H2).
Qed.

Lemma NoDup_drop : forall (A : Type) (n : nat) (l : list A),
  NoDup l -> NoDup (drop n l).
Proof.
  intros A n; induction n as [|n' IH]; intros [|x rest] Hnd; simpl.
  - exact Hnd.
  - exact Hnd.
  - constructor.
  - inversion Hnd; subst. exact (IH _ H2).
Qed.

Lemma disjoint_take_drop : forall (A : Type) (n : nat) (l : list A),
  NoDup l -> forall x, In x (take n l) -> ~ In x (drop n l).
Proof.
  intros A n; induction n as [|n' IH]; intros [|y rest] Hnd x Ht;
    simpl in *; try contradiction.
  inversion Hnd; subst. destruct Ht as [->|Ht].
  - intro Hd; apply H1; exact (In_drop _ _ _ _ Hd).
  - exact (IH _ H2 _ Ht).
Qed.

Lemma NoDup_app : forall (A : Type) (l1 l2 : list A),
  NoDup l1 -> NoDup l2 ->
  (forall x, In x l1 -> ~ In x l2) ->
  NoDup (l1 ++ l2).
Proof.
  intros A l1; induction l1 as [|x rest IH]; intros l2 H1 H2 Hdisj;
    simpl; [exact H2|].
  inversion H1; subst. constructor.
  - intro Hin; apply in_app_or in Hin; destruct Hin as [H|H].
    + exact (H3 H).
    + exact (Hdisj x (or_introl eq_refl) H).
  - apply IH; [exact H4 | exact H2 |].
    intros y Hy; apply Hdisj; right; exact Hy.
Qed.

(* Extract NoDup of prefix. *)
Lemma NoDup_app_fst : forall (A : Type) (l1 l2 : list A),
  NoDup (l1 ++ l2) -> NoDup l1.
Proof.
  intros A l1; induction l1 as [|a rest IH]; intros l2 Hnd; simpl in *.
  - constructor.
  - inversion Hnd; subst. constructor.
    + intro Hin. apply H1. apply in_or_app. left. exact Hin.
    + exact (IH _ H2).
Qed.

(* Extract NoDup of suffix. *)
Lemma NoDup_app_snd : forall (A : Type) (l1 l2 : list A),
  NoDup (l1 ++ l2) -> NoDup l2.
Proof.
  intros A l1; induction l1 as [|a rest IH]; intros l2 Hnd; simpl in *.
  - exact Hnd.
  - inversion Hnd; subst. exact (IH _ H2).
Qed.

(* Disjointness from NoDup. *)
Lemma NoDup_disj : forall (A : Type) (l1 l2 : list A),
  NoDup (l1 ++ l2) -> forall x, In x l1 -> ~ In x l2.
Proof.
  intros A l1; induction l1 as [|a rest IH]; intros l2 Hnd x Hin;
    simpl in *; [destruct Hin|].
  inversion Hnd; subst. destruct Hin as [->|Hin].
  - intro Hx. apply H1. apply in_or_app. right. exact Hx.
  - exact (IH _ H2 _ Hin).
Qed.

(* ========================================== *)
(*     CONCAT MEMBERSHIP                       *)
(* ========================================== *)

(* Models TLA+ included == UNION {Range(blocks[i]) : i \in 1..Len(blocks)}.
   [Source: Sequencer.tla line 80] *)
Lemma In_concat_iff : forall (A : Type) (x : A) (ls : list (list A)),
  In x (concat ls) <-> exists l, In l ls /\ In x l.
Proof.
  intros A x ls; split.
  - induction ls as [|l rest IH]; simpl; intro H; [contradiction|].
    apply in_app_or in H; destruct H as [Hl|Hr].
    + exists l; split; [left; reflexivity | exact Hl].
    + destruct (IH Hr) as [l' [H1 H2]].
      exists l'; split; [right; exact H1 | exact H2].
  - intros [l [H1 H2]].
    induction ls as [|l' rest IH]; simpl; [destruct H1|].
    destruct H1 as [->|Hin].
    + apply in_or_app; left; exact H2.
    + apply in_or_app; right; exact (IH Hin).
Qed.

Lemma concat_app_dist : forall (A : Type) (l1 l2 : list (list A)),
  concat (l1 ++ l2) = concat l1 ++ concat l2.
Proof.
  intros A l1; induction l1 as [|x rest IH]; intros l2; simpl.
  - reflexivity.
  - rewrite IH, app_assoc; reflexivity.
Qed.

(* ========================================== *)
(*     MAP PRESERVATION                        *)
(* ========================================== *)

Lemma map_take : forall (A B : Type) (f : A -> B) (n : nat) (l : list A),
  map f (take n l) = take n (map f l).
Proof.
  intros A B f n; induction n as [|n' IH]; intros [|x rest]; simpl;
    try reflexivity.
  f_equal; apply IH.
Qed.

Lemma map_drop : forall (A B : Type) (f : A -> B) (n : nat) (l : list A),
  map f (drop n l) = drop n (map f l).
Proof.
  intros A B f n; induction n as [|n' IH]; intros [|x rest]; simpl;
    try reflexivity.
  apply IH.
Qed.

Lemma In_map_fst : forall (A B : Type) (x : A) (l : list (A * B)),
  In x (map fst l) <-> exists b, In (x, b) l.
Proof.
  intros A B x l; split.
  - induction l as [|[a b] rest IH]; simpl; intro H; [contradiction|].
    destruct H as [->|H].
    + exists b; left; reflexivity.
    + destruct (IH H) as [b' Hb']; exists b'; right; exact Hb'.
  - intros [b Hb].
    induction l as [|[a b'] rest IH]; simpl; [destruct Hb|].
    destruct Hb as [Heq|Hin].
    + injection Heq; intros; subst; left; reflexivity.
    + right; exact (IH Hin).
Qed.

(* ========================================== *)
(*     POSITIONAL ACCESS                       *)
(* ========================================== *)

(* If i < n and i < length l, then nth i l d is in take n l. *)
Lemma nth_In_take : forall (A : Type) (n : nat) (l : list A) (i : nat) (d : A),
  i < n -> i < length l -> In (nth i l d) (take n l).
Proof.
  intros A n; induction n as [|n' IH]; intros [|x rest] i d Hi Hlen;
    simpl in *; try lia.
  destruct i as [|i'].
  - left; reflexivity.
  - right; apply IH; lia.
Qed.

(* ========================================== *)
(*     SORTED PAIRS (by second component)      *)
(* ========================================== *)

(* Non-decreasing order by snd. Models the FIFO property of the
   forced inclusion queue: transactions submitted at earlier blocks
   have smaller or equal submit_block numbers.
   [Spec: Sequencer.tla -- forcedQueue is FIFO, submissions record blockNum] *)
Inductive sorted_snd : list (nat * nat) -> Prop :=
  | sorted_snd_nil : sorted_snd []
  | sorted_snd_one : forall x, sorted_snd [x]
  | sorted_snd_cons : forall a b rest,
      snd a <= snd b -> sorted_snd (b :: rest) -> sorted_snd (a :: b :: rest).

Lemma sorted_snd_tail : forall a l,
  sorted_snd (a :: l) -> sorted_snd l.
Proof.
  intros a l H; inversion H; subst; [constructor | assumption].
Qed.

Lemma sorted_snd_drop : forall n l,
  sorted_snd l -> sorted_snd (drop n l).
Proof.
  induction n as [|n' IH]; intros [|a rest] Hs; simpl;
    try exact Hs; try constructor.
  apply IH; exact (sorted_snd_tail _ _ Hs).
Qed.

(* Head of a sorted list is <= all tail elements. *)
Lemma sorted_snd_head_le : forall q a,
  sorted_snd (a :: q) -> forall i, i < length q ->
  snd a <= snd (nth i q (0,0)).
Proof.
  induction q as [|b rest IH]; intros a Hs i Hi.
  - simpl in Hi; lia.
  - inversion Hs; subst. destruct i as [|i'].
    + simpl; exact H1.
    + simpl.
      assert (Hbi : snd b <= snd (nth i' rest (0,0)))
        by (apply (IH b H3 i'); simpl in Hi; lia).
      lia.
Qed.

(* Appending an element >= all existing preserves sortedness. *)
Lemma sorted_snd_app_single : forall l x,
  sorted_snd l ->
  (forall y, In y l -> snd y <= snd x) ->
  sorted_snd (l ++ [x]).
Proof.
  intros l x Hs Hle. induction Hs as [| a | a b rest Hab Hbr IH].
  - simpl; constructor.
  - simpl; constructor; [apply Hle; left; reflexivity | constructor].
  - simpl; constructor; [exact Hab |].
    apply IH; intros y Hy; apply Hle; right; exact Hy.
Qed.

(* ========================================== *)
(*     COUNTING HELPERS                        *)
(* ========================================== *)

Fixpoint count_pred {A : Type} (p : A -> bool) (l : list A) : nat :=
  match l with
  | [] => 0
  | x :: rest => (if p x then 1 else 0) + count_pred p rest
  end.

Lemma count_pred_app : forall (A : Type) (p : A -> bool) (l1 l2 : list A),
  count_pred p (l1 ++ l2) = count_pred p l1 + count_pred p l2.
Proof.
  intros A p l1; induction l1 as [|x rest IH]; intros l2; simpl.
  - reflexivity.
  - rewrite IH; destruct (p x); lia.
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
