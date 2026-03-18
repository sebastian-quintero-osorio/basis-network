(* ================================================================ *)
(*  Common.v -- Standard Library for Data Availability Unit         *)
(* ================================================================ *)
(*                                                                  *)
(*  Provides type mappings, set operations, cardinality lemmas,     *)
(*  and tactics shared across Spec.v, Impl.v, and Refinement.v.    *)
(*                                                                  *)
(*  Target: validium/proofs/units/2026-03-data-availability/        *)
(*  Source TLA+: DataAvailability.tla, lines 1-318                  *)
(*  Source Impl: shamir.ts, dac-node.ts, dac-protocol.ts, types.ts *)
(* ================================================================ *)

From Stdlib Require Import Lists.List.
From Stdlib Require Import Arith.Arith.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.Bool.

Import ListNotations.

(* ======================================== *)
(*     NODE AND BATCH TYPES                 *)
(* ======================================== *)

(* [Spec: Nodes -- set of DAC committee members, line 29]
   [Impl: nodeId -- 1-indexed, dac-node.ts line 35] *)
Definition Node := nat.

(* [Spec: Batches -- set of batch identifiers, line 30]
   [Impl: batchId -- string, types.ts line 88] *)
Definition Batch := nat.

(* [Spec: SUBSET Nodes -- mathematical sets]
   [Impl: filtering arrays of DACNode] *)
Definition NodeSet := list Node.

(* ======================================== *)
(*     PROTOCOL STATES                      *)
(* ======================================== *)

(* [Spec: certState \in {"none", "valid", "fallback"}, line 46]
   [Impl: CertificateState enum, types.ts lines 106-113] *)
Inductive cert_state : Type :=
  | CertNone | CertValid | CertFallback.

(* [Spec: recoverState \in {"none", "success", "corrupted", "failed"}, line 48]
   [Impl: RecoveryState enum, types.ts lines 120-129] *)
Inductive recover_state : Type :=
  | RecNone | RecSuccess | RecCorrupted | RecFailed.

(* ======================================== *)
(*     THRESHOLD PARAMETER                  *)
(* ======================================== *)

(* [Spec: CONSTANT Threshold, line 31]
   [Spec: ASSUME Threshold >= 1, line 34]
   [Impl: DACConfig.threshold, types.ts line 160] *)
Parameter Threshold : nat.
Axiom threshold_ge_1 : Threshold >= 1.

(* ======================================== *)
(*     NODE SET MEMBERSHIP                  *)
(* ======================================== *)

(* Boolean membership test for node sets.
   [Spec: n \in S, used throughout for precondition checks] *)
Fixpoint mem (n : Node) (s : NodeSet) : bool :=
  match s with
  | [] => false
  | x :: xs => if Nat.eqb n x then true else mem n xs
  end.

Lemma mem_true_iff : forall n s, mem n s = true <-> In n s.
Proof.
  intros n s. induction s as [| x xs IH]; simpl.
  - split.
    + discriminate.
    + intros [].
  - destruct (Nat.eqb n x) eqn:E.
    + apply Nat.eqb_eq in E. subst. split; auto.
    + apply Nat.eqb_neq in E. rewrite IH. split.
      * intros H. right. exact H.
      * intros [Heq | H]. exfalso; auto. exact H.
Qed.

Lemma mem_false_iff : forall n s, mem n s = false <-> ~ In n s.
Proof.
  intros n s. split.
  - intros H Hin. apply mem_true_iff in Hin. congruence.
  - intros H. destruct (mem n s) eqn:E; auto.
    exfalso. apply H. apply mem_true_iff. exact E.
Qed.

(* ======================================== *)
(*     INTERSECTION MEMBERSHIP CHECK        *)
(* ======================================== *)

(* Check if any element of s1 appears in s2.
   Returns true iff s1 \cap s2 /= {}.
   [Spec: S \cap Malicious /= {}, line 166] *)
Fixpoint has_member_in (s1 s2 : NodeSet) : bool :=
  match s1 with
  | [] => false
  | n :: ns => if mem n s2 then true else has_member_in ns s2
  end.

Lemma has_member_in_true_iff : forall s1 s2,
  has_member_in s1 s2 = true <-> exists n, In n s1 /\ In n s2.
Proof.
  intros s1 s2. induction s1 as [| x xs IH]; simpl.
  - split. discriminate. intros [n [[] _]].
  - destruct (mem x s2) eqn:E.
    + apply mem_true_iff in E. split; intros _.
      * exists x. auto.
      * reflexivity.
    + apply mem_false_iff in E. rewrite IH. split.
      * intros [n [Hin1 Hin2]]. exists n. auto.
      * intros [n [[Heq | Hin1] Hin2]].
        -- exfalso. subst. auto.
        -- exists n. auto.
Qed.

Lemma has_member_in_false_iff : forall s1 s2,
  has_member_in s1 s2 = false <-> forall n, ~ (In n s1 /\ In n s2).
Proof.
  intros s1 s2. split.
  - intros H n Hconj.
    assert (has_member_in s1 s2 = true)
      by (apply has_member_in_true_iff; exists n; auto).
    congruence.
  - intros H. destruct (has_member_in s1 s2) eqn:E; auto.
    apply has_member_in_true_iff in E. destruct E as [n Hconj].
    exfalso. exact (H n Hconj).
Qed.

(* ======================================== *)
(*     SET OPERATIONS                       *)
(* ======================================== *)

(* [Spec: S \ T, used for Honest == Nodes \ Malicious, line 57] *)
Definition set_diff (s1 s2 : NodeSet) : NodeSet :=
  filter (fun n => negb (mem n s2)) s1.

(* [Spec: {n \in S : f(n)}, used for online node filtering, line 96] *)
Definition set_filter (f : Node -> bool) (s : NodeSet) : NodeSet :=
  filter f s.

Lemma set_diff_In : forall n s1 s2,
  In n (set_diff s1 s2) <-> In n s1 /\ ~ In n s2.
Proof.
  intros. unfold set_diff. rewrite filter_In.
  rewrite negb_true_iff. rewrite mem_false_iff. tauto.
Qed.

Lemma set_filter_In : forall n f s,
  In n (set_filter f s) <-> In n s /\ f n = true.
Proof.
  intros. unfold set_filter. rewrite filter_In. tauto.
Qed.

(* ======================================== *)
(*     SUBSET AND DISJOINTNESS              *)
(* ======================================== *)

(* Propositional subset.
   [Spec: S \subseteq T, used throughout for set containment] *)
Definition subset (s1 s2 : NodeSet) : Prop :=
  forall n, In n s1 -> In n s2.

(* Propositional disjointness.
   [Spec: S \cap T = {}, used for honest/malicious separation] *)
Definition disjoint (s1 s2 : NodeSet) : Prop :=
  forall n, ~ (In n s1 /\ In n s2).

Lemma subset_nil : forall s, subset [] s.
Proof. intros s n []. Qed.

(* Key lemma: subset of set_diff implies disjointness with second set.
   Used to prove DataAvailability from Honest = Nodes \ Malicious. *)
Lemma subset_diff_disjoint : forall s1 s2 s3,
  subset s1 (set_diff s2 s3) -> disjoint s1 s3.
Proof.
  intros s1 s2 s3 Hsub n [H1 H3].
  apply Hsub in H1. apply set_diff_In in H1. destruct H1. contradiction.
Qed.

(* Connect disjoint to has_member_in *)
Lemma disjoint_has_member_in : forall s1 s2,
  disjoint s1 s2 <-> has_member_in s1 s2 = false.
Proof.
  intros s1 s2. rewrite has_member_in_false_iff.
  unfold disjoint. reflexivity.
Qed.

(* ======================================== *)
(*     FUNCTIONAL UPDATE                    *)
(* ======================================== *)

(* Models TLA+ f' = [f EXCEPT ![k] = v].
   [Spec: EXCEPT notation, used in all action definitions] *)
Definition fupdate (f : Batch -> NodeSet) (b : Batch) (v : NodeSet)
  : Batch -> NodeSet :=
  fun b' => if Nat.eqb b' b then v else f b'.

Definition fupdate_cert (f : Batch -> cert_state) (b : Batch) (v : cert_state)
  : Batch -> cert_state :=
  fun b' => if Nat.eqb b' b then v else f b'.

Definition fupdate_rec (f : Batch -> recover_state) (b : Batch) (v : recover_state)
  : Batch -> recover_state :=
  fun b' => if Nat.eqb b' b then v else f b'.

Lemma fupdate_eq : forall f b v, fupdate f b v b = v.
Proof. intros. unfold fupdate. rewrite Nat.eqb_refl. reflexivity. Qed.

Lemma fupdate_neq : forall f b b' v, b' <> b -> fupdate f b v b' = f b'.
Proof.
  intros. unfold fupdate.
  destruct (Nat.eqb b' b) eqn:E; auto.
  apply Nat.eqb_eq in E. contradiction.
Qed.

Lemma fupdate_cert_eq : forall f b v, fupdate_cert f b v b = v.
Proof. intros. unfold fupdate_cert. rewrite Nat.eqb_refl. reflexivity. Qed.

Lemma fupdate_cert_neq : forall f b b' v,
  b' <> b -> fupdate_cert f b v b' = f b'.
Proof.
  intros. unfold fupdate_cert.
  destruct (Nat.eqb b' b) eqn:E; auto.
  apply Nat.eqb_eq in E. contradiction.
Qed.

Lemma fupdate_rec_eq : forall f b v, fupdate_rec f b v b = v.
Proof. intros. unfold fupdate_rec. rewrite Nat.eqb_refl. reflexivity. Qed.

Lemma fupdate_rec_neq : forall f b b' v,
  b' <> b -> fupdate_rec f b v b' = f b'.
Proof.
  intros. unfold fupdate_rec.
  destruct (Nat.eqb b' b) eqn:E; auto.
  apply Nat.eqb_eq in E. contradiction.
Qed.

(* ======================================== *)
(*     TACTICS                              *)
(* ======================================== *)

(* Destruct match/if expressions in goal or hypotheses *)
Ltac destruct_match :=
  match goal with
  | [ |- context[if ?c then _ else _] ] => destruct c
  | [ H : context[if ?c then _ else _] |- _ ] => destruct c
  | [ |- context[match ?x with _ => _ end] ] => destruct x
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x
  end.
