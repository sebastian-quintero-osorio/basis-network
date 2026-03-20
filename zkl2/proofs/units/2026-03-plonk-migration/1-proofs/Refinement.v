(* ========================================================================= *)
(* Refinement.v -- Safety Invariant Proofs for PLONK Migration               *)
(* ========================================================================= *)
(* Proves all 8 safety properties from PlonkMigration.tla as inductive      *)
(* invariants: they hold in Init and are preserved by every action in Next. *)
(*                                                                           *)
(* Properties proved:                                                        *)
(*   S1 MigrationSafety          -- No batch lost during migration           *)
(*   S2 BackwardCompatibility    -- Groth16 accepted when active             *)
(*   S3 Soundness                -- No false positives                       *)
(*   S4 Completeness             -- No false negatives                       *)
(*   S5 NoGroth16AfterCutover    -- Groth16 rejected after cutover           *)
(*   S6 PhaseConsistency         -- Holds by construction                    *)
(*   S7 RollbackOnlyOnFailure    -- Rollback requires failure detection      *)
(*   S8 NoBatchLossDuringRollback-- Follows from S1                          *)
(*                                                                           *)
(* TLC verified these over 9.1M states. These proofs formalize the          *)
(* logical structure that TLC enumerated.                                    *)
(* ========================================================================= *)

From Stdlib Require Import Arith PeanoNat Lia List Bool.
Import ListNotations.
From PlonkMigration Require Import Common.
From PlonkMigration Require Import Spec.
From PlonkMigration Require Import Impl.

(* ========================================================================= *)
(*                     REACHABLE STATES                                      *)
(* ========================================================================= *)

Inductive Reachable : State -> Prop :=
  | reach_init : forall s, Init s -> Reachable s
  | reach_step : forall s s', Reachable s -> Next s s' -> Reachable s'.

(* ========================================================================= *)
(*                     COMBINED SAFETY INVARIANT                             *)
(* ========================================================================= *)

Definition AllSafety (s : State) : Prop :=
  MigrationSafety s /\
  BackwardCompatibility s /\
  Soundness s /\
  Completeness s /\
  NoGroth16AfterCutover s /\
  PhaseConsistency s /\
  RollbackOnlyOnFailure s /\
  NoBatchLossDuringRollback s.

(* ========================================================================= *)
(*          SECTION 1: INIT ESTABLISHES ALL INVARIANTS                       *)
(* ========================================================================= *)

Theorem init_migration_safety : forall s, Init s -> MigrationSafety s.
Proof.
  intros s [_ [_ [_ [Hbc [_ [_ _]]]]]].
  unfold MigrationSafety. intros e n H1 H2.
  pose proof (Hbc e). lia.
Qed.

Theorem init_backward_compat : forall s, Init s -> BackwardCompatibility s.
Proof.
  intros s [_ [_ [_ [_ [Hpr [_ _]]]]]].
  unfold BackwardCompatibility. intros r Hr.
  rewrite Hpr in Hr. destruct Hr.
Qed.

Theorem init_soundness : forall s, Init s -> Soundness s.
Proof.
  intros s [_ [_ [Hvb _]]].
  unfold Soundness. intros e b Hin.
  rewrite (Hvb e) in Hin. destruct Hin.
Qed.

Theorem init_completeness : forall s, Init s -> Completeness s.
Proof.
  intros s [_ [_ [_ [_ [Hpr [_ _]]]]]].
  unfold Completeness. intros r Hr.
  rewrite Hpr in Hr. destruct Hr.
Qed.

Theorem init_no_groth16_after : forall s, Init s -> NoGroth16AfterCutover s.
Proof.
  intros s [_ [_ [_ [_ [Hpr [_ _]]]]]].
  unfold NoGroth16AfterCutover. intros r Hr.
  rewrite Hpr in Hr. destruct Hr.
Qed.

Theorem init_phase_consistency : forall s, Init s -> PhaseConsistency s.
Proof. intros s _. exact I. Qed.

Theorem init_rollback_failure : forall s, Init s -> RollbackOnlyOnFailure s.
Proof.
  intros s [Hph _].
  unfold RollbackOnlyOnFailure. rewrite Hph. discriminate.
Qed.

Theorem init_no_batch_loss_rollback : forall s,
  Init s -> NoBatchLossDuringRollback s.
Proof.
  intros s Hi. unfold NoBatchLossDuringRollback.
  destruct Hi as [Hph _]. rewrite Hph. discriminate.
Qed.

Theorem init_all_safety : forall s, Init s -> AllSafety s.
Proof.
  intros s Hi. unfold AllSafety. repeat split.
  - exact (init_migration_safety s Hi).
  - exact (init_backward_compat s Hi).
  - exact (init_soundness s Hi).
  - exact (init_completeness s Hi).
  - exact (init_no_groth16_after s Hi).
  - exact (init_rollback_failure s Hi).
  - exact (init_no_batch_loss_rollback s Hi).
Qed.

(* ========================================================================= *)
(*          SECTION 2: PRESERVATION HELPER LEMMAS                            *)
(* ========================================================================= *)

(* Soundness preserved when verifiedBatches and proofRegistry unchanged. *)
Lemma soundness_unchanged : forall s s',
  Soundness s ->
  verifiedBatches s' = verifiedBatches s ->
  proofRegistry s' = proofRegistry s ->
  Soundness s'.
Proof.
  intros s s' Hs Hvb Hpr.
  unfold Soundness in *. intros e b Hin.
  rewrite Hvb in Hin. rewrite Hpr.
  exact (Hs e b Hin).
Qed.

(* BackwardCompatibility preserved when proofRegistry unchanged. *)
Lemma backward_compat_unchanged : forall s s',
  BackwardCompatibility s ->
  proofRegistry s' = proofRegistry s ->
  BackwardCompatibility s'.
Proof.
  intros s s' Hbc Hpr.
  unfold BackwardCompatibility in *. intros r Hr.
  rewrite Hpr in Hr. exact (Hbc r Hr).
Qed.

(* Completeness preserved when proofRegistry unchanged. *)
Lemma completeness_unchanged : forall s s',
  Completeness s ->
  proofRegistry s' = proofRegistry s ->
  Completeness s'.
Proof.
  intros s s' Hc Hpr.
  unfold Completeness in *. intros r Hr.
  rewrite Hpr in Hr. exact (Hc r Hr).
Qed.

(* NoGroth16AfterCutover preserved when proofRegistry unchanged. *)
Lemma no_groth16_unchanged : forall s s',
  NoGroth16AfterCutover s ->
  proofRegistry s' = proofRegistry s ->
  NoGroth16AfterCutover s'.
Proof.
  intros s s' Hng Hpr.
  unfold NoGroth16AfterCutover in *. intros r Hr.
  rewrite Hpr in Hr. exact (Hng r Hr).
Qed.

(* MigrationSafety preserved when queue, counter, registry unchanged. *)
Lemma migration_safety_unchanged : forall s s',
  MigrationSafety s ->
  batchQueue s' = batchQueue s ->
  batchCounter s' = batchCounter s ->
  proofRegistry s' = proofRegistry s ->
  MigrationSafety s'.
Proof.
  intros s s' Hms Hbq Hbc Hpr.
  unfold MigrationSafety in *. intros e n H1 H2.
  rewrite Hbc in H2. rewrite Hbq. rewrite Hpr.
  exact (Hms e n H1 H2).
Qed.

(* RollbackOnlyOnFailure preserved when phase and failure unchanged. *)
Lemma rollback_failure_unchanged : forall s s',
  RollbackOnlyOnFailure s ->
  migrationPhase s' = migrationPhase s ->
  failureDetected s' = failureDetected s ->
  RollbackOnlyOnFailure s'.
Proof.
  intros s s' Hrf Hph Hfd.
  unfold RollbackOnlyOnFailure in *.
  rewrite Hph, Hfd. exact Hrf.
Qed.

(* RollbackOnlyOnFailure holds when phase is not Rollback. *)
Lemma rollback_failure_not_rollback : forall s,
  migrationPhase s <> Rollback ->
  RollbackOnlyOnFailure s.
Proof.
  intros s Hne. unfold RollbackOnlyOnFailure. intro H. contradiction.
Qed.

(* ========================================================================= *)
(*          SECTION 3: VERIFY-BATCH PRESERVATION                             *)
(* ========================================================================= *)

(* S3: Soundness preserved by VerifyBatch.
   Key: batch added to verifiedBatches only when isValid = true,
   and the corresponding proof record has proof_valid = true. *)
Lemma verify_preserves_soundness : forall e s s',
  Soundness s -> VerifyBatch e s s' -> Soundness s'.
Proof.
  intros e s s' Hs [batch [rest [Hq [Hpr [Hvb [Hvb_oth
    [Hq_e [Hq_oth [Hph [Hbc [Hsc Hfd]]]]]]]]]]].
  unfold Soundness in *. intros e0 b Hin.
  destruct (Enterprise_eq_dec e0 e) as [Heq | Hne].
  - subst e0.
    destruct (ps_accepted (batch_proofSystem batch) (migrationPhase s)) eqn:Eacc;
      simpl in Hvb; rewrite Hvb in Hin.
    + (* isValid = true *)
      destruct Hin as [Heq | Hin_old].
      * subst b.
        exists (mkProofRec batch true (migrationPhase s)).
        rewrite Hpr. split; [left; reflexivity | simpl; auto].
      * destruct (Hs e b Hin_old) as [r [Hr [Hrb Hrv]]].
        exists r. rewrite Hpr. split; [right; exact Hr | exact (conj Hrb Hrv)].
    + (* isValid = false *)
      destruct (Hs e b Hin) as [r [Hr [Hrb Hrv]]].
      exists r. rewrite Hpr. split; [right; exact Hr | exact (conj Hrb Hrv)].
  - rewrite (Hvb_oth e0 Hne) in Hin.
    destruct (Hs e0 b Hin) as [r [Hr [Hrb Hrv]]].
    exists r. rewrite Hpr. split; [right; exact Hr | exact (conj Hrb Hrv)].
Qed.

(* S2: BackwardCompatibility preserved by VerifyBatch.
   New record: proof_valid = ps_accepted (batch_proofSystem batch) phase.
   If batch uses Groth16 and Groth16 is accepted in the phase,
   then proof_valid = true. *)
Lemma verify_preserves_backward_compat : forall e s s',
  BackwardCompatibility s -> VerifyBatch e s s' -> BackwardCompatibility s'.
Proof.
  intros e s s' Hbc [batch [rest [_ [Hpr _]]]].
  unfold BackwardCompatibility in *. intros r Hr Hps Hacc.
  rewrite Hpr in Hr. destruct Hr as [Heq | Hr_old].
  - subst r. simpl in *. rewrite Hps. exact Hacc.
  - exact (Hbc r Hr_old Hps Hacc).
Qed.

(* S4: Completeness preserved by VerifyBatch.
   New record: proof_valid = ps_accepted (batch_proofSystem batch) phase.
   If that ps_accepted returns true, then proof_valid = true. *)
Lemma verify_preserves_completeness : forall e s s',
  Completeness s -> VerifyBatch e s s' -> Completeness s'.
Proof.
  intros e s s' Hc [batch [rest [_ [Hpr _]]]].
  unfold Completeness in *. intros r Hr Hacc.
  rewrite Hpr in Hr. destruct Hr as [Heq | Hr_old].
  - subst r. simpl in *. exact Hacc.
  - exact (Hc r Hr_old Hacc).
Qed.

(* S5: NoGroth16AfterCutover preserved by VerifyBatch.
   New record: if Groth16 batch verified in PlonkOnly,
   proof_valid = ps_accepted PSGroth16 PlonkOnly = false. *)
Lemma verify_preserves_no_groth16 : forall e s s',
  NoGroth16AfterCutover s -> VerifyBatch e s s' -> NoGroth16AfterCutover s'.
Proof.
  intros e s s' Hng [batch [rest [_ [Hpr _]]]].
  unfold NoGroth16AfterCutover in *. intros r Hr Hps Hph.
  rewrite Hpr in Hr. destruct Hr as [Heq | Hr_old].
  - subst r. simpl in *. rewrite Hps, Hph. reflexivity.
  - exact (Hng r Hr_old Hps Hph).
Qed.

(* ========================================================================= *)
(*          SECTION 4: SUBMIT-BATCH PRESERVATION FOR S1                      *)
(* ========================================================================= *)

(* S1: MigrationSafety preserved by SubmitBatch.
   New batch appended to queue with seqNo = S (batchCounter s e).
   Old batches remain (In preserved under append).
   Counter incremented by 1. *)
Lemma submit_preserves_migration_safety : forall e ps s s',
  MigrationSafety s -> SubmitBatch e ps s s' -> MigrationSafety s'.
Proof.
  intros e ps s s' Hms [Hlt [Hnr [Hbq_e [Hbq_oth [Hbc_e [Hbc_oth
    [Hph [Hvb [Hpr [Hsc Hfd]]]]]]]]]].
  unfold MigrationSafety in *. intros e0 n H1 H2.
  destruct (Enterprise_eq_dec e0 e) as [Heq | Hne].
  - subst e0. rewrite Hbc_e in H2.
    destruct (Nat.eq_dec n (S (batchCounter s e))) as [Heq_n | Hne_n].
    + (* n = S (batchCounter s e): the newly submitted batch *)
      subst n. left.
      exists (mkBatch e (S (batchCounter s e)) ps).
      rewrite Hbq_e. split.
      * apply in_or_app. right. simpl. left. reflexivity.
      * simpl. split; reflexivity.
    + (* n <= batchCounter s e: existing batch *)
      assert (H2' : n <= batchCounter s e) by lia.
      destruct (Hms e n H1 H2') as [[b [Hin [He Hn]]] | [r [Hin [He Hn]]]].
      * left. exists b. rewrite Hbq_e. split.
        -- apply in_or_app. left. exact Hin.
        -- exact (conj He Hn).
      * right. exists r. rewrite Hpr. exact (conj Hin (conj He Hn)).
  - rewrite (Hbc_oth e0 Hne) in H2.
    destruct (Hms e0 n H1 H2) as [[b [Hin [He Hn]]] | [r [Hin [He Hn]]]].
    + left. exists b. rewrite (Hbq_oth e0 Hne). exact (conj Hin (conj He Hn)).
    + right. exists r. rewrite Hpr. exact (conj Hin (conj He Hn)).
Qed.

(* ========================================================================= *)
(*          SECTION 5: VERIFY-BATCH PRESERVATION FOR S1                      *)
(* ========================================================================= *)

(* S1: MigrationSafety preserved by VerifyBatch.
   Head batch moves from queue to registry. Remaining batches stay.
   Counter unchanged. Batch identity (enterprise, seqNo) preserved
   in the proof record. *)
Lemma verify_preserves_migration_safety : forall e s s',
  MigrationSafety s -> VerifyBatch e s s' -> MigrationSafety s'.
Proof.
  intros e s s' Hms [batch [rest [Hq [Hpr [_ [_ [Hq_e [Hq_oth
    [_ [Hbc [_ _ ]]]]]]]]]]].
  unfold MigrationSafety in *. intros e0 n H1 H2.
  rewrite Hbc in H2.
  destruct (Enterprise_eq_dec e0 e) as [Heq | Hne].
  - subst e0.
    destruct (Hms e n H1 H2) as [[b [Hin [He Hn]]] | [r [Hin [He Hn]]]].
    + (* b was in batchQueue s e = batch :: rest *)
      rewrite Hq in Hin. destruct Hin as [Heq | Hin_rest].
      * (* b = batch: moved to registry *)
        subst b. right.
        exists (mkProofRec batch
          (ps_accepted (batch_proofSystem batch) (migrationPhase s))
          (migrationPhase s)).
        rewrite Hpr. split; [left; reflexivity |].
        simpl. exact (conj He Hn).
      * (* b in rest = batchQueue s' e *)
        left. exists b. rewrite Hq_e.
        exact (conj Hin_rest (conj He Hn)).
    + (* r was in proofRegistry s *)
      right. exists r. rewrite Hpr.
      split; [right; exact Hin |]. exact (conj He Hn).
  - destruct (Hms e0 n H1 H2) as [[b [Hin [He Hn]]] | [r [Hin [He Hn]]]].
    + left. exists b. rewrite (Hq_oth e0 Hne).
      exact (conj Hin (conj He Hn)).
    + right. exists r. rewrite Hpr.
      split; [right; exact Hin |]. exact (conj He Hn).
Qed.

(* ========================================================================= *)
(*          SECTION 6: PROPERTY-LEVEL NEXT PRESERVATION                      *)
(* ========================================================================= *)

(* Each theorem proves that a single safety property is preserved by
   every action in Next. Trivial cases use helper lemmas; non-trivial
   cases (VerifyBatch, SubmitBatch) use the dedicated lemmas above. *)

Theorem soundness_preserved : forall s s',
  Soundness s -> Next s s' -> Soundness s'.
Proof.
  intros s s' Hs Hn.
  destruct Hn as [[e [ps Hsub]] | [[e Hver] |
    [Hsd | [Hco | [Hdt | [Hdf | [Hrm | Hcr]]]]]]].
  - destruct Hsub as [_ [_ [_ [_ [_ [_ [_ [Hvb [Hpr [_ _]]]]]]]]]].
    exact (soundness_unchanged s s' Hs Hvb Hpr).
  - exact (verify_preserves_soundness e s s' Hs Hver).
  - destruct Hsd as [_ [_ [_ [_ [Hvb [_ [Hpr _]]]]]]].
    exact (soundness_unchanged s s' Hs Hvb Hpr).
  - destruct Hco as [_ [_ [_ [_ [_ [Hvb [_ [Hpr [_ _]]]]]]]]].
    exact (soundness_unchanged s s' Hs Hvb Hpr).
  - destruct Hdt as [_ [_ [_ [_ [_ [Hvb [_ [Hpr _]]]]]]]].
    exact (soundness_unchanged s s' Hs Hvb Hpr).
  - destruct Hdf as [_ [_ [_ [_ [_ [Hvb [_ [Hpr _]]]]]]]].
    exact (soundness_unchanged s s' Hs Hvb Hpr).
  - destruct Hrm as [_ [_ [_ [_ [Hvb [_ [Hpr [_ _]]]]]]]].
    exact (soundness_unchanged s s' Hs Hvb Hpr).
  - destruct Hcr as [_ [_ [_ [_ [_ [_ [Hvb [_ Hpr]]]]]]]].
    exact (soundness_unchanged s s' Hs Hvb Hpr).
Qed.

Theorem backward_compat_preserved : forall s s',
  BackwardCompatibility s -> Next s s' -> BackwardCompatibility s'.
Proof.
  intros s s' Hbc Hn.
  destruct Hn as [[e [ps Hsub]] | [[e Hver] |
    [Hsd | [Hco | [Hdt | [Hdf | [Hrm | Hcr]]]]]]].
  - destruct Hsub as [_ [_ [_ [_ [_ [_ [_ [_ [Hpr [_ _]]]]]]]]]].
    exact (backward_compat_unchanged s s' Hbc Hpr).
  - exact (verify_preserves_backward_compat e s s' Hbc Hver).
  - destruct Hsd as [_ [_ [_ [_ [_ [_ [Hpr _]]]]]]].
    exact (backward_compat_unchanged s s' Hbc Hpr).
  - destruct Hco as [_ [_ [_ [_ [_ [_ [_ [Hpr [_ _]]]]]]]]].
    exact (backward_compat_unchanged s s' Hbc Hpr).
  - destruct Hdt as [_ [_ [_ [_ [_ [_ [_ [Hpr _]]]]]]]].
    exact (backward_compat_unchanged s s' Hbc Hpr).
  - destruct Hdf as [_ [_ [_ [_ [_ [_ [_ [Hpr _]]]]]]]].
    exact (backward_compat_unchanged s s' Hbc Hpr).
  - destruct Hrm as [_ [_ [_ [_ [_ [_ [Hpr [_ _]]]]]]]].
    exact (backward_compat_unchanged s s' Hbc Hpr).
  - destruct Hcr as [_ [_ [_ [_ [_ [_ [_ [_ Hpr]]]]]]]].
    exact (backward_compat_unchanged s s' Hbc Hpr).
Qed.

Theorem completeness_preserved : forall s s',
  Completeness s -> Next s s' -> Completeness s'.
Proof.
  intros s s' Hc Hn.
  destruct Hn as [[e [ps Hsub]] | [[e Hver] |
    [Hsd | [Hco | [Hdt | [Hdf | [Hrm | Hcr]]]]]]].
  - destruct Hsub as [_ [_ [_ [_ [_ [_ [_ [_ [Hpr [_ _]]]]]]]]]].
    exact (completeness_unchanged s s' Hc Hpr).
  - exact (verify_preserves_completeness e s s' Hc Hver).
  - destruct Hsd as [_ [_ [_ [_ [_ [_ [Hpr _]]]]]]].
    exact (completeness_unchanged s s' Hc Hpr).
  - destruct Hco as [_ [_ [_ [_ [_ [_ [_ [Hpr [_ _]]]]]]]]].
    exact (completeness_unchanged s s' Hc Hpr).
  - destruct Hdt as [_ [_ [_ [_ [_ [_ [_ [Hpr _]]]]]]]].
    exact (completeness_unchanged s s' Hc Hpr).
  - destruct Hdf as [_ [_ [_ [_ [_ [_ [_ [Hpr _]]]]]]]].
    exact (completeness_unchanged s s' Hc Hpr).
  - destruct Hrm as [_ [_ [_ [_ [_ [_ [Hpr [_ _]]]]]]]].
    exact (completeness_unchanged s s' Hc Hpr).
  - destruct Hcr as [_ [_ [_ [_ [_ [_ [_ [_ Hpr]]]]]]]].
    exact (completeness_unchanged s s' Hc Hpr).
Qed.

Theorem no_groth16_preserved : forall s s',
  NoGroth16AfterCutover s -> Next s s' -> NoGroth16AfterCutover s'.
Proof.
  intros s s' Hng Hn.
  destruct Hn as [[e [ps Hsub]] | [[e Hver] |
    [Hsd | [Hco | [Hdt | [Hdf | [Hrm | Hcr]]]]]]].
  - destruct Hsub as [_ [_ [_ [_ [_ [_ [_ [_ [Hpr [_ _]]]]]]]]]].
    exact (no_groth16_unchanged s s' Hng Hpr).
  - exact (verify_preserves_no_groth16 e s s' Hng Hver).
  - destruct Hsd as [_ [_ [_ [_ [_ [_ [Hpr _]]]]]]].
    exact (no_groth16_unchanged s s' Hng Hpr).
  - destruct Hco as [_ [_ [_ [_ [_ [_ [_ [Hpr [_ _]]]]]]]]].
    exact (no_groth16_unchanged s s' Hng Hpr).
  - destruct Hdt as [_ [_ [_ [_ [_ [_ [_ [Hpr _]]]]]]]].
    exact (no_groth16_unchanged s s' Hng Hpr).
  - destruct Hdf as [_ [_ [_ [_ [_ [_ [_ [Hpr _]]]]]]]].
    exact (no_groth16_unchanged s s' Hng Hpr).
  - destruct Hrm as [_ [_ [_ [_ [_ [_ [Hpr [_ _]]]]]]]].
    exact (no_groth16_unchanged s s' Hng Hpr).
  - destruct Hcr as [_ [_ [_ [_ [_ [_ [_ [_ Hpr]]]]]]]].
    exact (no_groth16_unchanged s s' Hng Hpr).
Qed.

Theorem migration_safety_preserved : forall s s',
  MigrationSafety s -> Next s s' -> MigrationSafety s'.
Proof.
  intros s s' Hms Hn.
  destruct Hn as [[e [ps Hsub]] | [[e Hver] |
    [Hsd | [Hco | [Hdt | [Hdf | [Hrm | Hcr]]]]]]].
  - exact (submit_preserves_migration_safety e ps s s' Hms Hsub).
  - exact (verify_preserves_migration_safety e s s' Hms Hver).
  - destruct Hsd as [_ [_ [_ [Hbq [_ [Hbc [Hpr _]]]]]]].
    exact (migration_safety_unchanged s s' Hms Hbq Hbc Hpr).
  - destruct Hco as [_ [_ [_ [_ [Hbq [_ [Hbc [Hpr [_ _]]]]]]]]].
    exact (migration_safety_unchanged s s' Hms Hbq Hbc Hpr).
  - destruct Hdt as [_ [_ [_ [_ [Hbq [_ [Hbc [Hpr _]]]]]]]].
    exact (migration_safety_unchanged s s' Hms Hbq Hbc Hpr).
  - destruct Hdf as [_ [_ [_ [_ [Hbq [_ [Hbc [Hpr _]]]]]]]].
    exact (migration_safety_unchanged s s' Hms Hbq Hbc Hpr).
  - destruct Hrm as [_ [_ [_ [Hbq [_ [Hbc [Hpr [_ _]]]]]]]].
    exact (migration_safety_unchanged s s' Hms Hbq Hbc Hpr).
  - destruct Hcr as [_ [_ [_ [_ [_ [Hbq [_ [Hbc Hpr]]]]]]]].
    exact (migration_safety_unchanged s s' Hms Hbq Hbc Hpr).
Qed.

Theorem rollback_failure_preserved : forall s s',
  RollbackOnlyOnFailure s -> Next s s' -> RollbackOnlyOnFailure s'.
Proof.
  intros s s' Hrf Hn.
  destruct Hn as [[e [ps Hsub]] | [[e Hver] |
    [Hsd | [Hco | [Hdt | [Hdf | [Hrm | Hcr]]]]]]].
  - (* SubmitBatch: phase and failure unchanged *)
    destruct Hsub as [_ [_ [_ [_ [_ [_ [Hph [_ [_ [_ Hfd]]]]]]]]]].
    exact (rollback_failure_unchanged s s' Hrf Hph Hfd).
  - (* VerifyBatch: phase and failure unchanged *)
    destruct Hver as [_ [_ [_ [_ [_ [_ [_ [_ [Hph [_ [_ Hfd]]]]]]]]]]].
    exact (rollback_failure_unchanged s s' Hrf Hph Hfd).
  - (* StartDualVerification: phase s' = Dual <> Rollback *)
    destruct Hsd as [_ [Hph _]].
    apply rollback_failure_not_rollback. rewrite Hph. discriminate.
  - (* CutoverToPlonkOnly: phase s' = PlonkOnly <> Rollback *)
    destruct Hco as [_ [_ [_ [Hph _]]]].
    apply rollback_failure_not_rollback. rewrite Hph. discriminate.
  - (* DualPeriodTick: phase unchanged = Dual <> Rollback *)
    destruct Hdt as [Hdual [_ [_ [Hph _]]]].
    apply rollback_failure_not_rollback. rewrite Hph, Hdual. discriminate.
  - (* DetectFailure: phase unchanged = Dual <> Rollback *)
    destruct Hdf as [Hdual [_ [_ [Hph _]]]].
    apply rollback_failure_not_rollback. rewrite Hph, Hdual. discriminate.
  - (* RollbackMigration: phase s' = Rollback, failureDetected s = true *)
    destruct Hrm as [_ [Hfail [_ [_ [_ [_ [_ [_ Hfd]]]]]]]].
    unfold RollbackOnlyOnFailure. intros _. rewrite Hfd. exact Hfail.
  - (* CompleteRollback: phase s' = Groth16Only <> Rollback *)
    destruct Hcr as [_ [_ [Hph _]]].
    apply rollback_failure_not_rollback. rewrite Hph. discriminate.
Qed.

(* ========================================================================= *)
(*          SECTION 7: COMBINED PRESERVATION AND MAIN THEOREM                *)
(* ========================================================================= *)

Theorem next_preserves_all_safety : forall s s',
  AllSafety s -> Next s s' -> AllSafety s'.
Proof.
  intros s s' [Hms [Hbc [Hs [Hcomp [Hng [_ [Hrf _]]]]]]] Hn.
  unfold AllSafety. repeat split.
  - exact (migration_safety_preserved s s' Hms Hn).
  - exact (backward_compat_preserved s s' Hbc Hn).
  - exact (soundness_preserved s s' Hs Hn).
  - exact (completeness_preserved s s' Hcomp Hn).
  - exact (no_groth16_preserved s s' Hng Hn).
  - exact (rollback_failure_preserved s s' Hrf Hn).
  - intros _. exact (migration_safety_preserved s s' Hms Hn).
Qed.

(* ========================================================================= *)
(*                     MAIN THEOREM                                          *)
(* ========================================================================= *)

(* Every reachable state satisfies all 8 safety properties.
   This is the mathematical certificate that the PLONK migration
   preserves system safety: no batch is lost (S1), Groth16 backward
   compatibility holds during transition (S2), soundness is maintained
   across proof systems (S3), valid proofs are never rejected (S4),
   Groth16 is correctly disabled after cutover (S5), the phase-verifier
   relationship is consistent (S6), rollback requires failure (S7),
   and batches survive rollback (S8). *)
Theorem reachable_all_safety : forall s,
  Reachable s -> AllSafety s.
Proof.
  intros s Hr. induction Hr as [s0 Hi | s0 s0' Hreach IH Hn].
  - exact (init_all_safety s0 Hi).
  - exact (next_preserves_all_safety s0 s0' IH Hn).
Qed.

(* ========================================================================= *)
(*          EXTRACTED COROLLARIES (User-requested properties)                *)
(* ========================================================================= *)

(* Soundness: The proof system change does not introduce false positives. *)
Corollary reachable_soundness : forall s,
  Reachable s -> Soundness s.
Proof.
  intros s Hr. destruct (reachable_all_safety s Hr) as [_ [_ [Hs _]]].
  exact Hs.
Qed.

(* MigrationSafety: No batch goes unverified during migration. *)
Corollary reachable_migration_safety : forall s,
  Reachable s -> MigrationSafety s.
Proof.
  intros s Hr. destruct (reachable_all_safety s Hr) as [Hms _].
  exact Hms.
Qed.

(* BackwardCompatibility: Groth16 proofs accepted during dual period. *)
Corollary reachable_backward_compat : forall s,
  Reachable s -> BackwardCompatibility s.
Proof.
  intros s Hr. destruct (reachable_all_safety s Hr) as [_ [Hbc _]].
  exact Hbc.
Qed.

(* NoGroth16AfterCutover: Groth16 rejected after PLONK-only cutover. *)
Corollary reachable_no_groth16_after_cutover : forall s,
  Reachable s -> NoGroth16AfterCutover s.
Proof.
  intros s Hr.
  destruct (reachable_all_safety s Hr) as [_ [_ [_ [_ [Hng _]]]]].
  exact Hng.
Qed.
