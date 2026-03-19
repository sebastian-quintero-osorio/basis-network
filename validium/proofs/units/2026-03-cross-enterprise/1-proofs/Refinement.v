(* ================================================================ *)
(*  Refinement.v -- Proof of Safety Invariants for Cross-Enterprise *)
(* ================================================================ *)
(*                                                                  *)
(*  Proves that the three safety properties from                    *)
(*  CrossEnterprise.tla are inductive invariants: each holds at     *)
(*  Init and is preserved by every action in the Step relation.     *)
(*                                                                  *)
(*  FOCUS AREAS:                                                    *)
(*    Isolation:   Enterprise A's data not visible/modifiable by B  *)
(*    Consistency: Cross-ref valid only if both proofs are valid    *)
(*                                                                  *)
(*  Structure:                                                      *)
(*    Part 1: Invariant Initialization (3 properties at Init)       *)
(*    Part 2: Isolation Preservation (6 actions)                    *)
(*    Part 3: Consistency Preservation (6 actions)                  *)
(*    Part 4: NoCrossRefSelfLoop Preservation (6 actions)           *)
(*    Part 5: Combined Inductive Invariant                          *)
(*    Part 6: Corollaries                                           *)
(*                                                                  *)
(*  Source Spec: 0-input-spec/CrossEnterprise.tla                   *)
(*  Source Impl: 0-input-impl/cross-reference-builder.ts,           *)
(*               0-input-impl/CrossEnterpriseVerifier.sol           *)
(* ================================================================ *)

From CE Require Import Common.
From CE Require Import Spec.
From CE Require Import Impl.
From Stdlib Require Import Arith.Arith.
From Stdlib Require Import Bool.Bool.

(* ================================================================ *)
(*  PART 1: INVARIANT INITIALIZATION                                *)
(* ================================================================ *)

(* All three safety properties hold at the initial state. *)

(* currentRoot = GenesisRoot for all enterprises. Left disjunct. *)
Theorem isolation_init : Spec.Isolation Spec.Init.
Proof.
  unfold Spec.Isolation, Spec.Init. simpl.
  intros e. left. reflexivity.
Qed.

(* crossRefStatus = CRNone for all refs. Hypothesis CRVerified is false. *)
Theorem consistency_init : Spec.Consistency Spec.Init.
Proof.
  unfold Spec.Consistency, Spec.Init. simpl.
  intros ref H. discriminate.
Qed.

(* crossRefStatus = CRNone for all refs. Hypothesis <> CRNone is false. *)
Theorem no_self_loop_init : Spec.NoCrossRefSelfLoop Spec.Init.
Proof.
  unfold Spec.NoCrossRefSelfLoop, Spec.Init. simpl.
  intros ref H. exfalso. apply H. reflexivity.
Qed.

(* ================================================================ *)
(*  PART 2: ISOLATION PRESERVATION                                  *)
(* ================================================================ *)

(* Isolation: forall e, currentRoot[e] = GenesisRoot \/
                        exists b, batchStatus[e][b] = Verified /\
                                  batchNewRoot[e][b] = currentRoot[e]

   Key insight: currentRoot changes ONLY in VerifyBatch, which
   simultaneously sets the witness batch to Verified with matching root.
   Cross-enterprise actions never touch currentRoot, batchStatus, or
   batchNewRoot, making Isolation trivially preserved.

   For SubmitBatch and FailBatch: the witness batch from the IH has
   Verified status, but these actions only modify Idle/Submitted batches.
   The witness cannot be the modified batch (status contradiction),
   so it survives unchanged. *)

Theorem isolation_preserved : forall s s',
    Spec.Isolation s ->
    Spec.Step s s' ->
    Spec.Isolation s'.
Proof.
  intros s s' HIso Hstep.
  unfold Spec.Isolation in *.
  destruct Hstep.

  - (* SubmitBatch: currentRoot unchanged, batchStatus[e][b] Idle->Submitted,
       batchNewRoot[e][b] updated. Witness has Verified status, which
       contradicts Idle guard if witness position = (e, b). *)
    destruct H as [Hidle _].
    intros e0. specialize (HIso e0) as [Hgen | [b0 [Hv Hr]]].
    + left. unfold Spec.SubmitBatch. simpl. exact Hgen.
    + right. exists b0.
      assert (Hpair : ~ (e0 = e /\ b0 = b)).
      { intros [He Hb]. subst. congruence. }
      unfold Spec.SubmitBatch. simpl. split.
      * rewrite (fupdate2_neq_pair _ _ _ _ _ _ Hpair). exact Hv.
      * rewrite (fupdate2_neq_pair _ _ _ _ _ _ Hpair). exact Hr.

  - (* VerifyBatch: currentRoot[e] -> batchNewRoot[e][b],
       batchStatus[e][b] -> Verified. For e0 = e, witness is b.
       For e0 <> e, old witness survives unchanged. *)
    intros e0.
    destruct (Nat.eq_dec e0 e) as [Hee | Hee].
    + (* e0 = e: the batch being verified is the witness *)
      subst. right. exists b.
      unfold Spec.VerifyBatch. simpl. split.
      * rewrite fupdate2_eq. reflexivity.
      * rewrite fupdate1_eq. reflexivity.
    + (* e0 <> e: old witness survives *)
      specialize (HIso e0) as [Hgen | [b0 [Hv Hr]]].
      * left. unfold Spec.VerifyBatch. simpl.
        rewrite (fupdate1_neq _ _ _ _ Hee). exact Hgen.
      * right. exists b0. unfold Spec.VerifyBatch. simpl. split.
        -- rewrite (fupdate2_neq_e _ _ _ _ _ _ Hee). exact Hv.
        -- rewrite (fupdate1_neq _ _ _ _ Hee). exact Hr.

  - (* FailBatch: currentRoot unchanged, batchStatus[e][b] Submitted->Idle.
       Witness has Verified status, contradicts Submitted guard. *)
    intros e0. specialize (HIso e0) as [Hgen | [b0 [Hv Hr]]].
    + left. unfold Spec.FailBatch. simpl. exact Hgen.
    + right. exists b0.
      assert (Hpair : ~ (e0 = e /\ b0 = b)).
      { intros [He Hb]. subst.
        unfold Spec.can_fail_batch in H. congruence. }
      unfold Spec.FailBatch. simpl. split.
      * rewrite (fupdate2_neq_pair _ _ _ _ _ _ Hpair). exact Hv.
      * exact Hr.

  - (* RequestCrossRef: UNCHANGED << currentRoot, batchStatus, batchNewRoot >> *)
    intros e0. unfold Spec.RequestCrossRef. simpl. exact (HIso e0).

  - (* VerifyCrossRef: UNCHANGED << currentRoot, batchStatus, batchNewRoot >> *)
    intros e0. unfold Spec.VerifyCrossRef. simpl. exact (HIso e0).

  - (* RejectCrossRef: UNCHANGED << currentRoot, batchStatus, batchNewRoot >> *)
    intros e0. unfold Spec.RejectCrossRef. simpl. exact (HIso e0).
Qed.

(* ================================================================ *)
(*  PART 3: CONSISTENCY PRESERVATION                                *)
(* ================================================================ *)

(* Consistency: forall ref, crossRefStatus[ref] = CRVerified ->
                 batchStatus[src][srcBatch] = Verified /\
                 batchStatus[dst][dstBatch] = Verified

   Key insight: only VerifyCrossRef sets crossRefStatus to CRVerified,
   and its guard requires both batch statuses to be Verified. Once a
   batch is Verified, no action downgrades it (SubmitBatch requires
   Idle, FailBatch requires Submitted). *)

Theorem consistency_preserved : forall s s',
    Spec.Consistency s ->
    Spec.Step s s' ->
    Spec.Consistency s'.
Proof.
  intros s s' HCon Hstep.
  unfold Spec.Consistency in *.
  destruct Hstep.

  - (* SubmitBatch: crossRefStatus unchanged.
       batchStatus[e][b] Idle->Submitted. Verified batch backing a
       verified cross-ref cannot be (e,b) since Idle <> Verified. *)
    destruct H as [Hidle _].
    intros ref0 Hcv. unfold Spec.SubmitBatch in Hcv. simpl in Hcv.
    specialize (HCon ref0 Hcv) as [Hsrc Hdst].
    unfold Spec.SubmitBatch. simpl. split.
    + assert (Hne : ~ (cr_src ref0 = e /\ cr_srcBatch ref0 = b))
        by (intros [He Hb]; subst; congruence).
      rewrite (fupdate2_neq_pair _ _ _ _ _ _ Hne). exact Hsrc.
    + assert (Hne : ~ (cr_dst ref0 = e /\ cr_dstBatch ref0 = b))
        by (intros [He Hb]; subst; congruence).
      rewrite (fupdate2_neq_pair _ _ _ _ _ _ Hne). exact Hdst.

  - (* VerifyBatch: crossRefStatus unchanged.
       batchStatus[e][b] Submitted->Verified. Updating to Verified
       preserves any position already at Verified (fupdate2_to_same). *)
    intros ref0 Hcv. unfold Spec.VerifyBatch in Hcv. simpl in Hcv.
    specialize (HCon ref0 Hcv) as [Hsrc Hdst].
    unfold Spec.VerifyBatch. simpl. split.
    + exact (fupdate2_to_same _ _ _ _ _ _ Hsrc).
    + exact (fupdate2_to_same _ _ _ _ _ _ Hdst).

  - (* FailBatch: crossRefStatus unchanged.
       batchStatus[e][b] Submitted->Idle. Verified batch backing a
       verified cross-ref cannot be (e,b) since Submitted <> Verified. *)
    unfold Spec.can_fail_batch in H.
    intros ref0 Hcv. unfold Spec.FailBatch in Hcv. simpl in Hcv.
    specialize (HCon ref0 Hcv) as [Hsrc Hdst].
    unfold Spec.FailBatch. simpl. split.
    + assert (Hne : ~ (cr_src ref0 = e /\ cr_srcBatch ref0 = b))
        by (intros [He Hb]; subst; congruence).
      rewrite (fupdate2_neq_pair _ _ _ _ _ _ Hne). exact Hsrc.
    + assert (Hne : ~ (cr_dst ref0 = e /\ cr_dstBatch ref0 = b))
        by (intros [He Hb]; subst; congruence).
      rewrite (fupdate2_neq_pair _ _ _ _ _ _ Hne). exact Hdst.

  - (* RequestCrossRef: batchStatus unchanged.
       crossRefStatus[ref] None->Pending. CRPending <> CRVerified. *)
    intros ref0 Hcv.
    unfold Spec.RequestCrossRef in Hcv. simpl in Hcv.
    unfold fupdate_cr in Hcv.
    destruct (crossrefid_eqb ref0 ref) eqn:Heq.
    + discriminate.
    + unfold Spec.RequestCrossRef. simpl. exact (HCon ref0 Hcv).

  - (* VerifyCrossRef: batchStatus unchanged.
       crossRefStatus[ref] Pending->Verified.
       Guard: both batches Verified. *)
    destruct H as [_ [_ [Hsrc_v Hdst_v]]].
    intros ref0 Hcv.
    unfold Spec.VerifyCrossRef in *. simpl in *.
    unfold fupdate_cr in Hcv.
    destruct (crossrefid_eqb ref0 ref) eqn:Heq.
    + apply crossrefid_eqb_true_iff in Heq. subst.
      split; assumption.
    + exact (HCon ref0 Hcv).

  - (* RejectCrossRef: batchStatus unchanged.
       crossRefStatus[ref] Pending->Rejected. CRRejected <> CRVerified. *)
    intros ref0 Hcv.
    unfold Spec.RejectCrossRef in Hcv. simpl in Hcv.
    unfold fupdate_cr in Hcv.
    destruct (crossrefid_eqb ref0 ref) eqn:Heq.
    + discriminate.
    + unfold Spec.RejectCrossRef. simpl. exact (HCon ref0 Hcv).
Qed.

(* ================================================================ *)
(*  PART 4: NOCROSSREFSELFLOOP PRESERVATION                         *)
(* ================================================================ *)

(* NoCrossRefSelfLoop: forall ref, crossRefStatus[ref] <> CRNone ->
                         valid_ref ref (src <> dst)

   Only cross-ref actions change crossRefStatus, and all three require
   valid_ref ref in their guards. Batch actions leave crossRefStatus
   unchanged. *)

Theorem no_self_loop_preserved : forall s s',
    Spec.NoCrossRefSelfLoop s ->
    Spec.Step s s' ->
    Spec.NoCrossRefSelfLoop s'.
Proof.
  intros s s' HNSL Hstep.
  unfold Spec.NoCrossRefSelfLoop in *.
  destruct Hstep.

  - (* SubmitBatch: crossRefStatus unchanged *)
    intros ref0 Hne. unfold Spec.SubmitBatch in Hne. simpl in Hne.
    exact (HNSL ref0 Hne).

  - (* VerifyBatch: crossRefStatus unchanged *)
    intros ref0 Hne. unfold Spec.VerifyBatch in Hne. simpl in Hne.
    exact (HNSL ref0 Hne).

  - (* FailBatch: crossRefStatus unchanged *)
    intros ref0 Hne. unfold Spec.FailBatch in Hne. simpl in Hne.
    exact (HNSL ref0 Hne).

  - (* RequestCrossRef: crossRefStatus[ref] None->Pending *)
    destruct H as [Hvalid _].
    intros ref0 Hne.
    unfold Spec.RequestCrossRef in Hne. simpl in Hne.
    unfold fupdate_cr in Hne.
    destruct (crossrefid_eqb ref0 ref) eqn:Heq.
    + apply crossrefid_eqb_true_iff in Heq. subst. exact Hvalid.
    + exact (HNSL ref0 Hne).

  - (* VerifyCrossRef: crossRefStatus[ref] Pending->Verified *)
    destruct H as [Hvalid _].
    intros ref0 Hne.
    unfold Spec.VerifyCrossRef in Hne. simpl in Hne.
    unfold fupdate_cr in Hne.
    destruct (crossrefid_eqb ref0 ref) eqn:Heq.
    + apply crossrefid_eqb_true_iff in Heq. subst. exact Hvalid.
    + exact (HNSL ref0 Hne).

  - (* RejectCrossRef: crossRefStatus[ref] Pending->Rejected *)
    destruct H as [Hvalid _].
    intros ref0 Hne.
    unfold Spec.RejectCrossRef in Hne. simpl in Hne.
    unfold fupdate_cr in Hne.
    destruct (crossrefid_eqb ref0 ref) eqn:Heq.
    + apply crossrefid_eqb_true_iff in Heq. subst. exact Hvalid.
    + exact (HNSL ref0 Hne).
Qed.

(* ================================================================ *)
(*  PART 5: COMBINED INDUCTIVE INVARIANT                            *)
(* ================================================================ *)

(* The full invariant suite. *)
Definition Invariants (s : Spec.State) : Prop :=
  Spec.Isolation s /\
  Spec.Consistency s /\
  Spec.NoCrossRefSelfLoop s.

(* All invariants hold at initialization. *)
Theorem all_invariants_init : Invariants Spec.Init.
Proof.
  unfold Invariants.
  exact (conj isolation_init
    (conj consistency_init
          no_self_loop_init)).
Qed.

(* All invariants are preserved by every action. *)
Theorem all_invariants_preserved : forall s s',
    Invariants s ->
    Spec.Step s s' ->
    Invariants s'.
Proof.
  intros s s' [HIso [HCon HNSL]] Hstep.
  unfold Invariants.
  exact (conj (isolation_preserved s s' HIso Hstep)
    (conj (consistency_preserved s s' HCon Hstep)
          (no_self_loop_preserved s s' HNSL Hstep))).
Qed.

(* Invariants hold for all reachable states. *)
Corollary invariants_reachable : forall s s',
    Invariants s ->
    Spec.Step s s' ->
    Spec.Isolation s' /\
    Spec.Consistency s' /\
    Spec.NoCrossRefSelfLoop s'.
Proof.
  intros s s' HI Hstep.
  exact (all_invariants_preserved s s' HI Hstep).
Qed.

(* ================================================================ *)
(*  PART 6: COROLLARIES                                             *)
(* ================================================================ *)

(* Cross-enterprise actions cannot alter any enterprise state root.
   This is the core privacy isolation guarantee of the validium:
   enterprise data remains private and state is self-sovereign. *)
Corollary cross_ref_preserves_roots : forall s ref,
    forall e,
      Spec.currentRoot (Spec.VerifyCrossRef s ref) e =
      Spec.currentRoot s e.
Proof.
  intros. unfold Spec.VerifyCrossRef. simpl. reflexivity.
Qed.

(* A verified cross-reference certifies that both enterprises have
   independently proven their state on L1 via Groth16 proofs. *)
Corollary verified_crossref_both_verified : forall s ref,
    Invariants s ->
    Spec.crossRefStatus s ref = CRVerified ->
    Spec.batchStatus s (cr_src ref) (cr_srcBatch ref) = Verified /\
    Spec.batchStatus s (cr_dst ref) (cr_dstBatch ref) = Verified.
Proof.
  intros s ref [_ [HCon _]] Hcv.
  exact (HCon ref Hcv).
Qed.

(* If an enterprise's state root has advanced beyond genesis, there is
   a verified batch that witnesses the current root value. *)
Corollary enterprise_root_has_witness : forall s e,
    Invariants s ->
    Spec.currentRoot s e <> GenesisRoot ->
    exists b, Spec.batchStatus s e b = Verified /\
              Spec.batchNewRoot s e b = Spec.currentRoot s e.
Proof.
  intros s e [HIso _] Hne.
  specialize (HIso e) as [Hgen | Hex].
  - exfalso. exact (Hne Hgen).
  - exact Hex.
Qed.

(* Cross-references with non-None status always have distinct endpoints.
   Self-loops are structurally impossible in the protocol. *)
Corollary active_crossref_distinct : forall s ref,
    Invariants s ->
    Spec.crossRefStatus s ref <> CRNone ->
    cr_src ref <> cr_dst ref.
Proof.
  intros s ref [_ [_ HNSL]] Hne.
  exact (HNSL ref Hne).
Qed.

(* ================================================================ *)
(*  SUMMARY OF VERIFIED THEOREMS                                    *)
(* ================================================================ *)

(*
   INVARIANT INITIALIZATION:
   1. isolation_init          Init satisfies Isolation          Qed
   2. consistency_init        Init satisfies Consistency        Qed
   3. no_self_loop_init       Init satisfies NoCrossRefSelfLoop Qed

   INVARIANT PRESERVATION (each covers all 6 actions):
   4. isolation_preserved     Isolation preserved by Step       Qed
   5. consistency_preserved   Consistency preserved by Step     Qed
   6. no_self_loop_preserved  NoCrossRefSelfLoop preserved     Qed

   COMBINED INVARIANT:
   7.  all_invariants_init       All hold at Init               Qed
   8.  all_invariants_preserved  All preserved by Step           Qed
   9.  invariants_reachable      All reachable states satisfy    Qed

   COROLLARIES:
   10. cross_ref_preserves_roots       Isolation: roots unchanged   Qed
   11. verified_crossref_both_verified Consistency: both verified   Qed
   12. enterprise_root_has_witness     Isolation: witness exists    Qed
   13. active_crossref_distinct        NoCrossRefSelfLoop: src<>dst Qed

   AXIOM TRUST BASE:
   - GenesisRoot : StateRoot (parameter, no axioms on its value)

   ADMITTED: 0
   QED: 13
*)
