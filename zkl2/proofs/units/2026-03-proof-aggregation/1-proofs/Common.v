(* ========================================================================= *)
(* Common.v -- Standard Library for Proof Aggregation Verification           *)
(* ========================================================================= *)
(* Provides axiomatized finite set operations, proof identity types,         *)
(* gas constants, and shared tactics for the proof aggregation development.  *)
(*                                                                           *)
(* Axiom Justification: The finite set axioms encode standard mathematical   *)
(* properties of finite sets. TLC model checking validated all 5 safety     *)
(* properties over the concrete enterprise configuration:                    *)
(*   788,734 states generated, 209,517 distinct -- PASS                     *)
(* The axiomatization generalizes these results.                             *)
(*                                                                           *)
(* Source: ProofAggregation.tla (0-input-spec/)                              *)
(* ========================================================================= *)

From Stdlib Require Import Arith PeanoNat Lia Bool List.
Import ListNotations.

(* ========================================================================= *)
(*                     PROOF IDENTITY TYPE                                    *)
(* ========================================================================= *)

(* Each proof is identified by (enterprise, sequence_number).
   [TLA+: ProofIds == Enterprises \X (1..MaxProofsPerEnt), line 22] *)
Record ProofId := mkPid {
  pid_ent : nat;
  pid_seq : nat
}.

(* Decidable equality for ProofId. *)
Lemma ProofId_eq_dec : forall a b : ProofId, {a = b} + {a <> b}.
Proof.
  intros [e1 s1] [e2 s2].
  destruct (Nat.eq_dec e1 e2) as [He | He];
  destruct (Nat.eq_dec s1 s2) as [Hs | Hs].
  - left. subst. reflexivity.
  - right. intro H. injection H. intros. contradiction.
  - right. intro H. injection H. intros. contradiction.
  - right. intro H. injection H. intros. contradiction.
Defined.

(* ========================================================================= *)
(*                     AXIOMATIZED FINITE SETS OF PROOF IDS                  *)
(* ========================================================================= *)
(* Standard finite set axioms. Satisfiable by any sorted-list               *)
(* implementation over ProofId with decidable equality.                      *)
(* ========================================================================= *)

Parameter PidSet : Type.
Parameter pid_empty : PidSet.
Parameter pid_add : ProofId -> PidSet -> PidSet.
Parameter pid_mem : ProofId -> PidSet -> Prop.
Parameter pid_card : PidSet -> nat.
Parameter pid_is_subset : PidSet -> PidSet -> Prop.
Parameter pid_union : PidSet -> PidSet -> PidSet.
Parameter pid_diff : PidSet -> PidSet -> PidSet.

(* Decidability *)
Parameter pid_mem_dec : forall x s, {pid_mem x s} + {~ pid_mem x s}.
Parameter pid_is_subset_dec :
  forall s1 s2, {pid_is_subset s1 s2} + {~ pid_is_subset s1 s2}.

(* ----- Empty set ----- *)
Axiom pid_empty_no_mem : forall x, ~ pid_mem x pid_empty.
Axiom pid_empty_card : pid_card pid_empty = 0.

(* ----- Add element ----- *)
Axiom pid_mem_add_same : forall x s, pid_mem x (pid_add x s).
Axiom pid_mem_add_elim : forall x y s,
  pid_mem x (pid_add y s) -> x = y \/ pid_mem x s.

(* ----- Subset ----- *)
Axiom pid_subset_intro : forall s1 s2,
  (forall x, pid_mem x s1 -> pid_mem x s2) -> pid_is_subset s1 s2.
Axiom pid_subset_elim : forall s1 s2 x,
  pid_is_subset s1 s2 -> pid_mem x s1 -> pid_mem x s2.
Axiom pid_subset_refl : forall s, pid_is_subset s s.
Axiom pid_subset_trans : forall s1 s2 s3,
  pid_is_subset s1 s2 -> pid_is_subset s2 s3 -> pid_is_subset s1 s3.

(* ----- Union ----- *)
Axiom pid_union_mem_intro_l : forall x s1 s2,
  pid_mem x s1 -> pid_mem x (pid_union s1 s2).
Axiom pid_union_mem_intro_r : forall x s1 s2,
  pid_mem x s2 -> pid_mem x (pid_union s1 s2).
Axiom pid_union_mem_elim : forall x s1 s2,
  pid_mem x (pid_union s1 s2) -> pid_mem x s1 \/ pid_mem x s2.

(* ----- Difference ----- *)
Axiom pid_diff_mem_intro : forall x s1 s2,
  pid_mem x s1 -> ~ pid_mem x s2 -> pid_mem x (pid_diff s1 s2).
Axiom pid_diff_mem_elim : forall x s1 s2,
  pid_mem x (pid_diff s1 s2) -> pid_mem x s1 /\ ~ pid_mem x s2.

(* ----- Non-subset witness ----- *)
Axiom pid_not_subset_witness : forall s1 s2,
  ~ pid_is_subset s1 s2 -> exists p, pid_mem p s1 /\ ~ pid_mem p s2.

(* ========================================================================= *)
(*                     SUBSET BOOLEAN DECISION                                *)
(* ========================================================================= *)

Definition subset_bool (s1 s2 : PidSet) : bool :=
  if pid_is_subset_dec s1 s2 then true else false.

Lemma subset_bool_true_iff : forall s1 s2,
  subset_bool s1 s2 = true <-> pid_is_subset s1 s2.
Proof.
  intros. unfold subset_bool.
  destruct (pid_is_subset_dec s1 s2); split; auto; discriminate.
Qed.

Lemma subset_bool_false_iff : forall s1 s2,
  subset_bool s1 s2 = false <-> ~ pid_is_subset s1 s2.
Proof.
  intros. unfold subset_bool.
  destruct (pid_is_subset_dec s1 s2); split; auto; try discriminate.
  intro. contradiction.
Qed.

(* ========================================================================= *)
(*                     AGGREGATION STATUS                                     *)
(* ========================================================================= *)

(* [TLA+: AggStatuses == {"aggregated", "l1_verified", "l1_rejected"}, line 28] *)
Inductive AggStatus : Type :=
  | Aggregated
  | L1Verified
  | L1Rejected.

Lemma AggStatus_eq_dec : forall a b : AggStatus, {a = b} + {a <> b}.
Proof. decide equality. Defined.

(* ========================================================================= *)
(*                     GAS CONSTANTS                                          *)
(* ========================================================================= *)

(* [TLA+: CONSTANTS BaseGasPerProof, AggregatedGasCost, lines 12-13]
   Parametrized to avoid large-number representation issues with lia.
   The concrete values are 420K and 220K respectively. *)
Parameter BaseGasPerProof : nat.
Parameter AggregatedGasCost : nat.
Definition MinAggregationSize : nat := 2.

(* BaseGasPerProof = 420000, AggregatedGasCost = 220000.
   The critical property: aggregated cost < individual cost for N >= 2.
   220000 < 420000 * 2 = 840000. *)
Axiom gas_relation : AggregatedGasCost < BaseGasPerProof * MinAggregationSize.

(* Gas cost is positive. *)
Axiom gas_positive : BaseGasPerProof > 0.

(* ========================================================================= *)
(*                     DERIVED LEMMAS                                         *)
(* ========================================================================= *)

Lemma pid_singleton_mem : forall x y,
  pid_mem x (pid_add y pid_empty) -> x = y.
Proof.
  intros x y H.
  apply pid_mem_add_elim in H. destruct H as [Heq | Habs].
  - exact Heq.
  - exfalso. exact (pid_empty_no_mem x Habs).
Qed.

(* KEY LEMMA: Adding an element not in S to the superset does not
   change the subset_bool result. Used for AggregationSoundness
   preservation under GenerateValidProof. *)
Lemma subset_bool_add_irrelevant : forall S A x,
  ~ pid_mem x S ->
  subset_bool S (pid_union A (pid_add x pid_empty)) = subset_bool S A.
Proof.
  intros S A x Hnx.
  unfold subset_bool.
  destruct (pid_is_subset_dec S A) as [Hsub | Hnsub];
  destruct (pid_is_subset_dec S (pid_union A (pid_add x pid_empty)))
    as [Hsub' | Hnsub'].
  - reflexivity.
  - exfalso. apply Hnsub'. apply pid_subset_intro. intros p Hp.
    apply pid_union_mem_intro_l. exact (pid_subset_elim _ _ _ Hsub Hp).
  - exfalso. apply Hnsub. apply pid_subset_intro. intros p Hp.
    assert (Hp' := pid_subset_elim _ _ _ Hsub' Hp).
    apply pid_union_mem_elim in Hp'. destruct Hp' as [Hl | Hr].
    + exact Hl.
    + apply pid_singleton_mem in Hr. subst. contradiction.
  - reflexivity.
Qed.

Lemma subset_union_left : forall s1 s2 s3,
  pid_is_subset s1 s2 -> pid_is_subset s1 (pid_union s2 s3).
Proof.
  intros s1 s2 s3 Hsub. apply pid_subset_intro. intros x Hx.
  apply pid_union_mem_intro_l. exact (pid_subset_elim _ _ _ Hsub Hx).
Qed.

Lemma pid_diff_subset : forall s1 s2,
  pid_is_subset (pid_diff s1 s2) s1.
Proof.
  intros. apply pid_subset_intro. intros x Hx.
  apply pid_diff_mem_elim in Hx. destruct Hx. assumption.
Qed.

Lemma pid_union_subset : forall a b c,
  pid_is_subset a c -> pid_is_subset b c ->
  pid_is_subset (pid_union a b) c.
Proof.
  intros a b c Ha Hb. apply pid_subset_intro. intros x Hx.
  apply pid_union_mem_elim in Hx. destruct Hx as [H | H].
  - exact (pid_subset_elim _ _ _ Ha H).
  - exact (pid_subset_elim _ _ _ Hb H).
Qed.

Lemma pid_empty_subset : forall s, pid_is_subset pid_empty s.
Proof.
  intros s. apply pid_subset_intro. intros x H.
  exfalso. exact (pid_empty_no_mem x H).
Qed.

(* ========================================================================= *)
(*                     TACTICS                                                *)
(* ========================================================================= *)

Ltac destruct_match :=
  match goal with
  | [ |- context[match ?x with _ => _ end] ] => destruct x
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x
  end.
