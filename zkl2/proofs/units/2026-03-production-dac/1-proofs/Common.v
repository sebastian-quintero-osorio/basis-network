(* ========================================================================= *)
(* Common.v -- Standard Library for Production DAC Verification              *)
(* ========================================================================= *)
(* Provides axiomatized finite set operations and shared definitions for     *)
(* the Production DAC proof development.                                     *)
(*                                                                           *)
(* Axiom Justification: The finite set axioms encode standard mathematical   *)
(* properties of finite sets. TLC model checking validated all safety and    *)
(* liveness properties over the concrete 7-node DAC configuration:           *)
(*   Safety:  141,526,225 states generated, 16,882,176 distinct -- PASS      *)
(*   Liveness: 2,365,825 states generated, 395,520 distinct -- PASS          *)
(* The axiomatization generalizes these results to arbitrary configurations. *)
(*                                                                           *)
(* Source: ProductionDAC.tla (zkl2/specs/units/2026-03-production-dac/)       *)
(* ========================================================================= *)

From Stdlib Require Import Arith PeanoNat Lia.

(* ========================================================================= *)
(*                     NODE, BATCH, AND STATE TYPES                          *)
(* ========================================================================= *)

(* Nodes and Batches are identified by natural numbers.
   [TLA+: CONSTANTS Nodes, Batches] *)
Definition Node := nat.
Definition Batch := nat.

(* Decidable equality for nodes and batches. *)
Definition Node_eq_dec := Nat.eq_dec.
Definition Batch_eq_dec := Nat.eq_dec.

(* Certificate state enumeration.
   [TLA+: certState \in [Batches -> {"none", "valid", "fallback"}]] *)
Inductive CertStateVal : Type :=
  | CertNone      (* No certificate produced *)
  | CertValid     (* Valid certificate with >= threshold attestations *)
  | CertFallback. (* AnyTrust fallback: validium degrades to rollup *)

(* Recovery state enumeration.
   [TLA+: recoverState \in [Batches -> {"none", "success", "corrupted", "failed"}]] *)
Inductive RecoverStateVal : Type :=
  | RecNone      (* No recovery attempted *)
  | RecSuccess   (* Data recovered and verified against commitment *)
  | RecCorrupted (* Corruption detected: AES-GCM auth fail or hash mismatch *)
  | RecFailed.   (* Insufficient chunks or shares for reconstruction *)

(* Decidable equality for state enumerations. *)
Lemma CertStateVal_eq_dec : forall a b : CertStateVal, {a = b} + {a <> b}.
Proof. decide equality. Defined.

Lemma RecoverStateVal_eq_dec : forall a b : RecoverStateVal, {a = b} + {a <> b}.
Proof. decide equality. Defined.

(* ========================================================================= *)
(*                      AXIOMATIZED FINITE SETS                              *)
(* ========================================================================= *)
(* We axiomatize finite sets of natural numbers with the exact properties    *)
(* needed for the DAC safety proofs. Each axiom is a standard mathematical   *)
(* fact about finite sets. The intro/elim form avoids issues with iff        *)
(* projections in proof scripts.                                             *)
(* ========================================================================= *)

Parameter NSet : Type.
Parameter empty_set : NSet.
Parameter add_elem : nat -> NSet -> NSet.
Parameter mem : nat -> NSet -> Prop.
Parameter card : NSet -> nat.
Parameter is_subset : NSet -> NSet -> Prop.
Parameter set_inter : NSet -> NSet -> NSet.
Parameter set_diff : NSet -> NSet -> NSet.
Parameter is_empty : NSet -> Prop.

(* Decidability of membership. *)
Parameter mem_dec : forall x s, {mem x s} + {~ mem x s}.

(* ----- Empty set ----- *)
Axiom empty_no_mem : forall x, ~ mem x empty_set.
Axiom empty_card : card empty_set = 0.
Axiom is_empty_card_fwd : forall s, is_empty s -> card s = 0.
Axiom is_empty_card_bwd : forall s, card s = 0 -> is_empty s.
Axiom is_empty_no_mem : forall s x, is_empty s -> ~ mem x s.
Axiom non_empty_witness : forall s, ~ is_empty s -> exists x, mem x s.

(* ----- Add element ----- *)
Axiom mem_add_same : forall x s, mem x (add_elem x s).
Axiom mem_add_other_fwd : forall x y s, x <> y -> mem x (add_elem y s) -> mem x s.
Axiom mem_add_other_bwd : forall x y s, x <> y -> mem x s -> mem x (add_elem y s).
Axiom add_card_new : forall x s, ~ mem x s -> card (add_elem x s) = S (card s).
Axiom add_card_existing : forall x s, mem x s -> card (add_elem x s) = card s.

(* ----- Subset ----- *)
Axiom subset_intro : forall s1 s2,
  (forall x, mem x s1 -> mem x s2) -> is_subset s1 s2.
Axiom subset_elim : forall s1 s2 x,
  is_subset s1 s2 -> mem x s1 -> mem x s2.
Axiom subset_card : forall s1 s2,
  is_subset s1 s2 -> card s1 <= card s2.

(* ----- Intersection ----- *)
Axiom inter_mem_intro : forall x s1 s2,
  mem x s1 -> mem x s2 -> mem x (set_inter s1 s2).
Axiom inter_mem_elim : forall x s1 s2,
  mem x (set_inter s1 s2) -> mem x s1 /\ mem x s2.

(* ----- Difference ----- *)
Axiom diff_mem_intro : forall x s1 s2,
  mem x s1 -> ~ mem x s2 -> mem x (set_diff s1 s2).
Axiom diff_mem_elim : forall x s1 s2,
  mem x (set_diff s1 s2) -> mem x s1 /\ ~ mem x s2.

(* ========================================================================= *)
(*                          DERIVED LEMMAS                                   *)
(* ========================================================================= *)

(* Empty set is a subset of any set. *)
Lemma empty_is_subset : forall s, is_subset empty_set s.
Proof.
  intros s. apply subset_intro.
  intros x H. exfalso. exact (empty_no_mem x H).
Qed.

(* Adding an element never decreases cardinality. *)
Lemma add_card_ge : forall x s, card (add_elem x s) >= card s.
Proof.
  intros x s. destruct (mem_dec x s) as [Hin | Hout].
  - rewrite (add_card_existing x s Hin). lia.
  - rewrite (add_card_new x s Hout). lia.
Qed.

(* Subset is transitive. *)
Lemma subset_trans : forall s1 s2 s3,
  is_subset s1 s2 -> is_subset s2 s3 -> is_subset s1 s3.
Proof.
  intros s1 s2 s3 H12 H23. apply subset_intro. intros x Hx.
  exact (subset_elim _ _ _ H23 (subset_elim _ _ _ H12 Hx)).
Qed.

(* Adding an element to a subset preserves the subset relation
   when the element is already in the superset. *)
Lemma add_preserves_subset : forall x s1 s2,
  is_subset s1 s2 -> mem x s2 -> is_subset (add_elem x s1) s2.
Proof.
  intros x s1 s2 Hsub Hx. apply subset_intro. intros y Hy.
  destruct (Nat.eq_dec y x) as [Heq | Hne].
  - subst. exact Hx.
  - exact (subset_elim _ _ _ Hsub (mem_add_other_fwd y x s1 Hne Hy)).
Qed.

(* Any set is a subset of itself with an additional element. *)
Lemma subset_add_right : forall x s, is_subset s (add_elem x s).
Proof.
  intros x s. apply subset_intro. intros y Hy.
  destruct (Nat.eq_dec y x) as [Heq | Hne].
  - subst. apply mem_add_same.
  - exact (mem_add_other_bwd y x s Hne Hy).
Qed.

(* A set with cardinality 0 is a subset of any set. *)
Lemma empty_card_subset : forall s1 s2, card s1 = 0 -> is_subset s1 s2.
Proof.
  intros s1 s2 Hcard. apply subset_intro. intros x Hx.
  exfalso. exact (is_empty_no_mem s1 x (is_empty_card_bwd s1 Hcard) Hx).
Qed.

(* A subset of the empty set is empty. *)
Lemma subset_empty_is_empty : forall s, is_subset s empty_set -> is_empty s.
Proof.
  intros s Hsub. apply is_empty_card_bwd.
  assert (H := subset_card s empty_set Hsub). rewrite empty_card in H. lia.
Qed.

(* KEY LEMMA: If S is a subset of (d \ c), then S and c have empty
   intersection. This connects the DataRecoverability invariant
   (subset of diff) with the RecoverData action condition (empty inter).
   Proof strategy: by contradiction using witness in the intersection. *)
Lemma subset_diff_inter_empty : forall S d c,
  is_subset S (set_diff d c) -> is_empty (set_inter S c).
Proof.
  intros S d c Hsub.
  apply is_empty_card_bwd.
  destruct (Nat.eq_dec (card (set_inter S c)) 0) as [Heq | Hne].
  - exact Heq.
  - exfalso.
    assert (Hne2 : ~ is_empty (set_inter S c)).
    { intro H. apply is_empty_card_fwd in H. lia. }
    destruct (non_empty_witness _ Hne2) as [x Hx].
    destruct (inter_mem_elim _ _ _ Hx) as [HxS HxC].
    assert (Hdiff := subset_elim _ _ _ Hsub HxS).
    destruct (diff_mem_elim _ _ _ Hdiff) as [_ HnotC].
    contradiction.
Qed.

(* Converse direction: if S intersect c is non-empty, then S is NOT
   a subset of (d \ c). Used in ErasureSoundness proofs. *)
Lemma inter_nonempty_not_subset_diff : forall S d c,
  ~ is_empty (set_inter S c) ->
  ~ is_subset S (set_diff d c).
Proof.
  intros S d c Hne Hsub.
  apply Hne. exact (subset_diff_inter_empty S d c Hsub).
Qed.

(* ========================================================================= *)
(*                               TACTICS                                     *)
(* ========================================================================= *)

(* Destruct match expressions in goal or hypotheses. *)
Ltac destruct_match :=
  match goal with
  | [ |- context[match ?x with _ => _ end] ] => destruct x
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x
  end.

(* Case split on batch equality for preservation proofs.
   Uses targeted subst to avoid clearing unrelated equations. *)
Ltac batch_cases b b0 :=
  destruct (Batch_eq_dec b b0) as [?Heqb | ?Hneb]; [subst b | idtac].
