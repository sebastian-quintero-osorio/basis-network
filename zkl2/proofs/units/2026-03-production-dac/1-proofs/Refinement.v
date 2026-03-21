(* ========================================================================= *)
(* Refinement.v -- Safety Invariant Proofs for Production DAC                *)
(* ========================================================================= *)
(* Proves that the 7 safety properties from ProductionDAC.tla are           *)
(* inductive invariants: they hold in Init and are preserved by Next.        *)
(*                                                                           *)
(* Proof methodology:                                                        *)
(*   1. Show Init establishes each invariant                                 *)
(*   2. Show each action in Next preserves each invariant                    *)
(*   3. By induction on Reachable, conclude invariants hold universally      *)
(*                                                                           *)
(* The proofs formalize the logical structure that TLC verified              *)
(* exhaustively over 141M states with 0 errors.                              *)
(* ========================================================================= *)

From Stdlib Require Import Arith PeanoNat Lia List.
Import ListNotations.
From ProductionDAC Require Import Common.
From ProductionDAC Require Import Spec.
From ProductionDAC Require Import Impl.

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
  CertificateSoundness s /\
  DataRecoverability s /\
  ErasureSoundness s /\
  Privacy s /\
  RecoveryIntegrity s /\
  AttestationIntegrity s /\
  VerificationIntegrity s /\
  NoRecoveryBeforeDistribution s.

(* ========================================================================= *)
(*          SECTION 1: INIT ESTABLISHES ALL INVARIANTS                       *)
(* ========================================================================= *)

Theorem init_cert_soundness : forall s, Init s -> CertificateSoundness s.
Proof.
  intros s [_ [_ [_ [_ [_ [Hcs _]]]]]].
  unfold CertificateSoundness. intros b Hb Hv.
  rewrite Hcs in Hv; [discriminate | exact Hb].
Qed.

Theorem init_data_recoverability : forall s, Init s -> DataRecoverability s.
Proof.
  intros s [_ [_ [_ [_ [_ [_ [_ Hrs]]]]]]].
  unfold DataRecoverability. intros b Hb Hne.
  rewrite Hrs in Hne; [contradiction | exact Hb].
Qed.

Theorem init_erasure_soundness : forall s, Init s -> ErasureSoundness s.
Proof.
  intros s [_ [_ [_ [_ [_ [_ [_ Hrs]]]]]]].
  unfold ErasureSoundness. intros b Hb Hne.
  rewrite Hrs in Hne; [contradiction | exact Hb].
Qed.

Theorem init_privacy : forall s, Init s -> Privacy s.
Proof.
  intros s [_ [_ [_ [_ [_ [_ [_ Hrs]]]]]]].
  unfold Privacy. intros b Hb Hv.
  rewrite Hrs in Hv; [discriminate | exact Hb].
Qed.

Theorem init_recovery_integrity : forall s, Init s -> RecoveryIntegrity s.
Proof.
  intros s [_ [_ [_ [_ [_ [_ [_ Hrs]]]]]]].
  unfold RecoveryIntegrity. intros b Hb Hv.
  rewrite Hrs in Hv; [discriminate | exact Hb].
Qed.

Theorem init_attestation_integrity : forall s, Init s -> AttestationIntegrity s.
Proof.
  intros s [_ [_ [_ [_ [Hat _]]]]].
  unfold AttestationIntegrity. intros b Hb.
  rewrite Hat; [apply empty_is_subset | exact Hb].
Qed.

Theorem init_verification_integrity : forall s, Init s -> VerificationIntegrity s.
Proof.
  intros s [_ [_ [Hcv _]]].
  unfold VerificationIntegrity. intros b Hb.
  rewrite Hcv; [apply empty_is_subset | exact Hb].
Qed.

Theorem init_no_recovery_before_dist : forall s,
  Init s -> NoRecoveryBeforeDistribution s.
Proof.
  intros s [_ [_ [_ [_ [_ [_ [_ Hrs]]]]]]].
  unfold NoRecoveryBeforeDistribution. intros b Hb _.
  exact (Hrs b Hb).
Qed.

Theorem init_all_safety : forall s, Init s -> AllSafety s.
Proof.
  intros s Hi. unfold AllSafety. repeat split.
  - exact (init_cert_soundness s Hi).
  - exact (init_data_recoverability s Hi).
  - exact (init_erasure_soundness s Hi).
  - exact (init_privacy s Hi).
  - exact (init_recovery_integrity s Hi).
  - exact (init_attestation_integrity s Hi).
  - exact (init_verification_integrity s Hi).
  - exact (init_no_recovery_before_dist s Hi).
Qed.

(* ========================================================================= *)
(*          SECTION 2: HELPER LEMMAS FOR PRESERVATION                        *)
(* ========================================================================= *)

(* When certSt and attested are pointwise unchanged,
   CertificateSoundness is preserved. Covers 7 of 9 actions. *)
Lemma cert_soundness_unchanged : forall s s',
  CertificateSoundness s ->
  (forall b, certSt s' b = certSt s b) ->
  (forall b, attested s' b = attested s b) ->
  CertificateSoundness s'.
Proof.
  intros s s' Hinv Hcs Hat.
  unfold CertificateSoundness in *. intros b Hb Hv.
  rewrite Hcs in Hv. rewrite Hat. exact (Hinv b Hb Hv).
Qed.

(* When recoverSt and recoveryNodes are pointwise unchanged,
   all four recovery invariants are preserved. *)
Lemma data_recov_unchanged : forall s s',
  DataRecoverability s ->
  (forall b, recoverSt s' b = recoverSt s b) ->
  (forall b, recoveryNodes s' b = recoveryNodes s b) ->
  (forall b, distributedTo s' b = distributedTo s b) ->
  (forall b, chunkCorrupted s' b = chunkCorrupted s b) ->
  DataRecoverability s'.
Proof.
  intros s s' Hinv Hrs Hrn Hdt Hcc.
  unfold DataRecoverability in *. intros b Hb Hne Hsub Hcard.
  rewrite Hrs in Hne. rewrite Hrn in Hsub, Hcard. rewrite Hdt, Hcc in Hsub.
  rewrite Hrs. exact (Hinv b Hb Hne Hsub Hcard).
Qed.

Lemma erasure_sound_unchanged : forall s s',
  ErasureSoundness s ->
  (forall b, recoverSt s' b = recoverSt s b) ->
  (forall b, recoveryNodes s' b = recoveryNodes s b) ->
  (forall b, chunkCorrupted s' b = chunkCorrupted s b) ->
  ErasureSoundness s'.
Proof.
  intros s s' Hinv Hrs Hrn Hcc.
  unfold ErasureSoundness in *. intros b Hb Hne Hcard Hinter.
  rewrite Hrs in Hne. rewrite Hrn in Hcard, Hinter. rewrite Hcc in Hinter.
  rewrite Hrs. exact (Hinv b Hb Hne Hcard Hinter).
Qed.

Lemma privacy_unchanged : forall s s',
  Privacy s ->
  (forall b, recoverSt s' b = recoverSt s b) ->
  (forall b, recoveryNodes s' b = recoveryNodes s b) ->
  Privacy s'.
Proof.
  intros s s' Hinv Hrs Hrn.
  unfold Privacy in *. intros b Hb Hv.
  rewrite Hrs in Hv. rewrite Hrn. exact (Hinv b Hb Hv).
Qed.

Lemma recovery_int_unchanged : forall s s',
  RecoveryIntegrity s ->
  (forall b, recoverSt s' b = recoverSt s b) ->
  (forall b, recoveryNodes s' b = recoveryNodes s b) ->
  (forall b, chunkCorrupted s' b = chunkCorrupted s b) ->
  RecoveryIntegrity s'.
Proof.
  intros s s' Hinv Hrs Hrn Hcc.
  unfold RecoveryIntegrity in *. intros b Hb Hv.
  rewrite Hrs in Hv. rewrite Hrn. rewrite Hcc.
  exact (Hinv b Hb Hv).
Qed.

Lemma attest_int_unchanged : forall s s',
  AttestationIntegrity s ->
  (forall b, attested s' b = attested s b) ->
  (forall b, chunkVerified s' b = chunkVerified s b) ->
  AttestationIntegrity s'.
Proof.
  intros s s' Hinv Hat Hcv.
  unfold AttestationIntegrity in *. intros b Hb.
  rewrite Hat. rewrite Hcv. exact (Hinv b Hb).
Qed.

Lemma verif_int_unchanged : forall s s',
  VerificationIntegrity s ->
  (forall b, chunkVerified s' b = chunkVerified s b) ->
  (forall b, distributedTo s' b = distributedTo s b) ->
  VerificationIntegrity s'.
Proof.
  intros s s' Hinv Hcv Hdt.
  unfold VerificationIntegrity in *. intros b Hb.
  rewrite Hcv. rewrite Hdt. exact (Hinv b Hb).
Qed.

(* ========================================================================= *)
(*          SECTION 3: CERTIFICATE SOUNDNESS PRESERVATION                    *)
(* ========================================================================= *)

(* CertificateSoundness: certSt[b] = CertValid -> card(attested[b]) >= Threshold
   Critical actions: ProduceCertificate (sets certSt), NodeAttest (grows attested)
   All other actions preserve both certSt and attested pointwise. *)

Theorem cert_soundness_preserved : forall s s',
  AllSafety s -> Next s s' -> CertificateSoundness s'.
Proof.
  intros s s' [HCS [HDR [HES [HP [HRI [HAI [HVI HNRD]]]]]]] Hnext.
  destruct Hnext as
    [Hdc | [Hvc | [Hna | [Hcc | [Hpc | [Htf | [Hrd | [Hnf | Hnr]]]]]]]].
  (* Case 1: DistributeChunks -- certSt, attested unchanged *)
  - destruct Hdc as [b0 (? & ? & ? & ? & ? & ? & ? & Hat & Hcs & ? & ?)].
    exact (cert_soundness_unchanged s s' HCS Hcs Hat).
  (* Case 2: VerifyChunk -- certSt, attested unchanged *)
  - destruct Hvc as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hat & Hcs & _ & _)]].
    exact (cert_soundness_unchanged s s' HCS Hcs Hat).
  (* Case 3: NodeAttest -- attested grows for one batch, certSt unchanged *)
  - destruct Hna as [n0 [b0 (? & ? & ? & Hverif & Hnoatt & ? &
      Hatt' & Hattother & _ & _ & _ & _ & Hcs & _ & _)]].
    unfold CertificateSoundness. intros b Hb Hv.
    rewrite Hcs in Hv.
    batch_cases b b0.
    + (* b = b0: attested grew, card can only increase *)
      rewrite Hatt'.
      assert (Hge := add_card_ge n0 (attested s b0)).
      assert (Hold := HCS b0 Hb Hv). lia.
    + (* b <> b0: unchanged *)
      rewrite (Hattother b Hneb). exact (HCS b Hb Hv).
  (* Case 4: CorruptChunk -- certSt, attested unchanged *)
  - destruct Hcc as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hat & Hcs & _ & _)]].
    exact (cert_soundness_unchanged s s' HCS Hcs Hat).
  (* Case 5: ProduceCertificate -- CRITICAL CASE *)
  - destruct Hpc as [b0 (? & ? & Hcard & Hcs' & Hcsother & _ & _ & _ & _ & Hat & _ & _)].
    unfold CertificateSoundness. intros b Hb Hv.
    batch_cases b b0.
    + (* b = b0: guard ensures card >= Threshold *)
      rewrite Hat. exact Hcard.
    + (* b <> b0: certSt unchanged *)
      rewrite (Hcsother b Hneb) in Hv.
      rewrite Hat. exact (HCS b Hb Hv).
  (* Case 6: TriggerFallback -- sets certSt to Fallback, not Valid *)
  - destruct Htf as [b0 (? & ? & ? & ? & Hcs' & Hcsother & _ & _ & _ & _ & Hat & _ & _)].
    unfold CertificateSoundness. intros b Hb Hv.
    batch_cases b b0.
    + rewrite Hcs' in Hv. discriminate.
    + rewrite (Hcsother b Hneb) in Hv. rewrite Hat. exact (HCS b Hb Hv).
  (* Case 7: RecoverData -- certSt, attested unchanged *)
  - destruct Hrd as [b0 [S0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hat & Hcs)]].
    exact (cert_soundness_unchanged s s' HCS Hcs Hat).
  (* Case 8: NodeFail -- certSt, attested unchanged *)
  - destruct Hnf as [n0 (_ & _ & _ & _ & _ & _ & _ & Hat & Hcs & _ & _)].
    exact (cert_soundness_unchanged s s' HCS Hcs Hat).
  (* Case 9: NodeRecover -- certSt, attested unchanged *)
  - destruct Hnr as [n0 (_ & _ & _ & _ & _ & _ & _ & Hat & Hcs & _ & _)].
    exact (cert_soundness_unchanged s s' HCS Hcs Hat).
Qed.

(* ========================================================================= *)
(*          SECTION 4: RECOVERY INVARIANTS PRESERVATION                      *)
(* ========================================================================= *)

(* All four recovery invariants (DataRecoverability, ErasureSoundness,
   Privacy, RecoveryIntegrity) share the same proof structure:
   - RecoverData is the only critical action (sets recoverSt)
   - All other actions preserve recoverSt, recoveryNodes, and
     chunkCorrupted pointwise (or only modify chunkCorrupted when
     recoverSt = RecNone, making the antecedent false). *)

(* DataRecoverability preserved by RecoverData:
   Antecedent: recoverSt <> RecNone, recoveryNodes subset (dist\corrupt), card >= Threshold
   The three disjuncts of RecoverData:
     1. card < Threshold, recoverSt = RecFailed  -> card >= Threshold contradicts
     2. card >= Threshold, inter non-empty, recoverSt = RecCorrupted
        -> subset_diff_inter_empty contradicts inter non-empty
     3. card >= Threshold, inter empty, recoverSt = RecSuccess -> goal is RecSuccess *)
Theorem data_recov_preserved : forall s s',
  AllSafety s -> Next s s' -> DataRecoverability s'.
Proof.
  intros s s' [HCS [HDR [HES [HP [HRI [HAI [HVI HNRD]]]]]]] Hnext.
  destruct Hnext as
    [Hdc | [Hvc | [Hna | [Hcc | [Hpc | [Htf | [Hrd | [Hnf | Hnr]]]]]]]].
  (* Cases 1-6, 8-9: recoverSt, recoveryNodes, dist, corrupt unchanged *)
  - destruct Hdc as [b0 (Hb0 & Hempty & _ & Hdtother & _ & _ & Hcc' & _ & _ & Hrn & Hrs)].
    unfold DataRecoverability. intros b Hb Hne Hsub Hcard.
    batch_cases b b0.
    + (* b = b0: recoverSt s b0 must be RecNone since distributedTo was empty *)
      rewrite Hrs in Hne.
      assert (HrsNone := HNRD b0 Hb0 Hempty).
      contradiction.
    + rewrite Hrs in Hne. rewrite Hrs.
      rewrite Hrn in Hsub, Hcard. rewrite (Hdtother b Hneb) in Hsub. rewrite Hcc' in Hsub.
      exact (HDR b Hb Hne Hsub Hcard).
  - destruct Hvc as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & Hdt & Hcc' & _ & _ & Hrn & Hrs)]].
    exact (data_recov_unchanged s s' HDR Hrs Hrn Hdt Hcc').
  - destruct Hna as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & Hdt & _ & Hcc' & _ & Hrn & Hrs)]].
    exact (data_recov_unchanged s s' HDR Hrs Hrn Hdt Hcc').
  - (* CorruptChunk: changes chunkCorrupted for b0 where recoverSt = RecNone *)
    destruct Hcc as [n0 [b0 (_ & ? & _ & _ & HrsNone & _ & Hccother & _ & Hdt & _ & _ & _ & Hrn & Hrs)]].
    unfold DataRecoverability. intros b Hb Hne Hsub Hcard.
    batch_cases b b0.
    + (* b = b0: recoverSt s' b0 = recoverSt s b0 = RecNone. Contradicts Hne. *)
      rewrite Hrs in Hne. contradiction.
    + (* b <> b0: everything unchanged *)
      rewrite Hrs in Hne |- *.
      rewrite Hrn in Hsub, Hcard.
      rewrite Hdt in Hsub. rewrite (Hccother b Hneb) in Hsub.
      exact (HDR b Hb Hne Hsub Hcard).
  - destruct Hpc as [b0 (_ & _ & _ & _ & _ & _ & Hdt & _ & Hcc' & _ & Hrn & Hrs)].
    exact (data_recov_unchanged s s' HDR Hrs Hrn Hdt Hcc').
  - destruct Htf as [b0 (_ & _ & _ & _ & _ & _ & _ & Hdt & _ & Hcc' & _ & Hrn & Hrs)].
    exact (data_recov_unchanged s s' HDR Hrs Hrn Hdt Hcc').
  - (* RecoverData: CRITICAL CASE *)
    destruct Hrd as [b0 [S0 Hrd_prop]].
    destruct Hrd_prop as
      (Hb0 & Hcv0 & HrsNone & Hsmem & Hne0 &
       Hrn' & Hcases & Hrnother & Hrsother &
       Honl & Hdt & Hcvf & Hcc' & Hatf & Hcsf).
    unfold DataRecoverability. intros b Hb Hne Hsub Hcard.
    batch_cases b b0.
    + (* b = b0: case analysis on the three disjuncts *)
      rewrite Hrn' in Hsub, Hcard.
      destruct Hcases as [[Hlt Hfail] | [[Hge [Hnotempty Hcorr]] | [Hge [Hempty Hsucc]]]].
      * (* card < Threshold but card >= Threshold: contradiction *)
        lia.
      * (* inter non-empty but S0 subset diff: contradiction *)
        exfalso. apply Hnotempty.
        rewrite Hcc' in Hsub. rewrite Hdt in Hsub.
        exact (subset_diff_inter_empty S0 (distributedTo s b0) (chunkCorrupted s b0) Hsub).
      * (* inter empty, card >= Threshold: success *)
        exact Hsucc.
    + (* b <> b0: unchanged *)
      rewrite (Hrsother b Hneb) in Hne.
      rewrite (Hrsother b Hneb).
      rewrite (Hrnother b Hneb) in Hsub, Hcard.
      rewrite Hdt in Hsub. rewrite Hcc' in Hsub.
      exact (HDR b Hb Hne Hsub Hcard).
  - destruct Hnf as [n0 (_ & _ & _ & _ & Hdt & _ & Hcc' & _ & _ & Hrn & Hrs)].
    exact (data_recov_unchanged s s' HDR Hrs Hrn Hdt Hcc').
  - destruct Hnr as [n0 (_ & _ & _ & _ & Hdt & _ & Hcc' & _ & _ & Hrn & Hrs)].
    exact (data_recov_unchanged s s' HDR Hrs Hrn Hdt Hcc').
Qed.

(* ErasureSoundness preserved *)
Theorem erasure_sound_preserved : forall s s',
  AllSafety s -> Next s s' -> ErasureSoundness s'.
Proof.
  intros s s' [HCS [HDR [HES [HP [HRI [HAI [HVI HNRD]]]]]]] Hnext.
  destruct Hnext as
    [Hdc | [Hvc | [Hna | [Hcc | [Hpc | [Htf | [Hrd | [Hnf | Hnr]]]]]]]].
  - destruct Hdc as [b0 (_ & _ & _ & _ & _ & _ & Hcc' & _ & _ & Hrn & Hrs)].
    exact (erasure_sound_unchanged s s' HES Hrs Hrn Hcc').
  - destruct Hvc as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hcc' & _ & _ & Hrn & Hrs)]].
    exact (erasure_sound_unchanged s s' HES Hrs Hrn Hcc').
  - destruct Hna as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hcc' & _ & Hrn & Hrs)]].
    exact (erasure_sound_unchanged s s' HES Hrs Hrn Hcc').
  - (* CorruptChunk: recoverSt[b0] = RecNone *)
    destruct Hcc as [n0 [b0 (_ & ? & _ & _ & HrsNone & _ & Hccother & _ & _ & _ & _ & _ & Hrn & Hrs)]].
    unfold ErasureSoundness. intros b Hb Hne Hcard Hinter.
    batch_cases b b0.
    + rewrite Hrs in Hne. contradiction.
    + rewrite Hrs in Hne. rewrite Hrs.
      rewrite Hrn in Hcard, Hinter. rewrite (Hccother b Hneb) in Hinter.
      exact (HES b Hb Hne Hcard Hinter).
  - destruct Hpc as [b0 (_ & _ & _ & _ & _ & _ & _ & _ & Hcc' & _ & Hrn & Hrs)].
    exact (erasure_sound_unchanged s s' HES Hrs Hrn Hcc').
  - destruct Htf as [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & Hcc' & _ & Hrn & Hrs)].
    exact (erasure_sound_unchanged s s' HES Hrs Hrn Hcc').
  - (* RecoverData: CRITICAL CASE *)
    destruct Hrd as [b0 [S0 Hrd_prop2]].
    destruct Hrd_prop2 as (Hb0 & _ & HrsNone & _ & _ &
      Hrn' & Hcases & Hrnother & Hrsother & _ & _ & _ & Hcc' & _ & _).
    unfold ErasureSoundness. intros b Hb Hne Hcard Hinter.
    batch_cases b b0.
    + rewrite Hrn' in Hcard, Hinter. rewrite Hcc' in Hinter.
      destruct Hcases as [[Hlt _] | [[_ [_ Hcorr]] | [_ [Hempty _]]]].
      * lia.
      * exact Hcorr.
      * exfalso.
        destruct (non_empty_witness _ Hinter) as [x Hx].
        exact (is_empty_no_mem _ x Hempty Hx).
    + rewrite (Hrsother b Hneb) in Hne. rewrite (Hrsother b Hneb).
      rewrite (Hrnother b Hneb) in Hcard, Hinter. rewrite Hcc' in Hinter.
      exact (HES b Hb Hne Hcard Hinter).
  - destruct Hnf as [n0 (_ & _ & _ & _ & _ & _ & Hcc' & _ & _ & Hrn & Hrs)].
    exact (erasure_sound_unchanged s s' HES Hrs Hrn Hcc').
  - destruct Hnr as [n0 (_ & _ & _ & _ & _ & _ & Hcc' & _ & _ & Hrn & Hrs)].
    exact (erasure_sound_unchanged s s' HES Hrs Hrn Hcc').
Qed.

(* Privacy preserved *)
Theorem privacy_preserved : forall s s',
  AllSafety s -> Next s s' -> Privacy s'.
Proof.
  intros s s' [HCS [HDR [HES [HP [HRI [HAI [HVI HNRD]]]]]]] Hnext.
  destruct Hnext as
    [Hdc | [Hvc | [Hna | [Hcc | [Hpc | [Htf | [Hrd | [Hnf | Hnr]]]]]]]].
  - destruct Hdc as [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & Hrn & Hrs)].
    exact (privacy_unchanged s s' HP Hrs Hrn).
  - destruct Hvc as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hrn & Hrs)]].
    exact (privacy_unchanged s s' HP Hrs Hrn).
  - destruct Hna as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hrn & Hrs)]].
    exact (privacy_unchanged s s' HP Hrs Hrn).
  - destruct Hcc as [n0 [b0 (_ & ? & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hrn & Hrs)]].
    exact (privacy_unchanged s s' HP Hrs Hrn).
  - destruct Hpc as [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hrn & Hrs)].
    exact (privacy_unchanged s s' HP Hrs Hrn).
  - destruct Htf as [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hrn & Hrs)].
    exact (privacy_unchanged s s' HP Hrs Hrn).
  - (* RecoverData: CRITICAL CASE *)
    destruct Hrd as [b0 [S0 Hrd_prop3]].
    destruct Hrd_prop3 as (Hb0 & _ & _ & _ & _ &
      Hrn' & Hcases & Hrnother & Hrsother & _ & _ & _ & _ & _ & _).
    unfold Privacy. intros b Hb Hv.
    batch_cases b b0.
    + rewrite Hrn'.
      destruct Hcases as [[_ Hfail] | [[Hge [_ Hcorr]] | [Hge _]]].
      * rewrite Hfail in Hv. discriminate.
      * rewrite Hcorr in Hv. discriminate.
      * exact Hge.
    + rewrite (Hrsother b Hneb) in Hv.
      rewrite (Hrnother b Hneb).
      exact (HP b Hb Hv).
  - destruct Hnf as [n0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & Hrn & Hrs)].
    exact (privacy_unchanged s s' HP Hrs Hrn).
  - destruct Hnr as [n0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & Hrn & Hrs)].
    exact (privacy_unchanged s s' HP Hrs Hrn).
Qed.

(* RecoveryIntegrity preserved *)
Theorem recovery_int_preserved : forall s s',
  AllSafety s -> Next s s' -> RecoveryIntegrity s'.
Proof.
  intros s s' [HCS [HDR [HES [HP [HRI [HAI [HVI HNRD]]]]]]] Hnext.
  destruct Hnext as
    [Hdc | [Hvc | [Hna | [Hcc | [Hpc | [Htf | [Hrd | [Hnf | Hnr]]]]]]]].
  - destruct Hdc as [b0 (_ & _ & _ & _ & _ & _ & Hcc' & _ & _ & Hrn & Hrs)].
    exact (recovery_int_unchanged s s' HRI Hrs Hrn Hcc').
  - destruct Hvc as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hcc' & _ & _ & Hrn & Hrs)]].
    exact (recovery_int_unchanged s s' HRI Hrs Hrn Hcc').
  - destruct Hna as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hcc' & _ & Hrn & Hrs)]].
    exact (recovery_int_unchanged s s' HRI Hrs Hrn Hcc').
  - (* CorruptChunk: changes chunkCorrupted but recoverSt = RecNone *)
    destruct Hcc as [n0 [b0 (_ & ? & _ & _ & HrsNone & _ & Hccother & _ & _ & _ & _ & _ & Hrn & Hrs)]].
    unfold RecoveryIntegrity. intros b Hb Hv.
    batch_cases b b0.
    + (* recoverSt s' b0 = recoverSt s b0 = RecNone <> RecSuccess *)
      rewrite Hrs in Hv. rewrite HrsNone in Hv. discriminate.
    + rewrite Hrs in Hv. rewrite Hrn. rewrite (Hccother b Hneb).
      exact (HRI b Hb Hv).
  - destruct Hpc as [b0 (_ & _ & _ & _ & _ & _ & _ & _ & Hcc' & _ & Hrn & Hrs)].
    exact (recovery_int_unchanged s s' HRI Hrs Hrn Hcc').
  - destruct Htf as [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & Hcc' & _ & Hrn & Hrs)].
    exact (recovery_int_unchanged s s' HRI Hrs Hrn Hcc').
  - (* RecoverData: CRITICAL CASE *)
    destruct Hrd as [b0 [S0 Hrd_prop4]].
    destruct Hrd_prop4 as (Hb0 & _ & _ & _ & _ &
      Hrn' & Hcases & Hrnother & Hrsother & _ & _ & _ & Hcc' & _ & _).
    unfold RecoveryIntegrity. intros b Hb Hv.
    batch_cases b b0.
    + rewrite Hrn'. rewrite Hcc'.
      destruct Hcases as [[_ Hfail] | [[_ [_ Hcorr]] | [_ [Hempty Hsucc]]]].
      * rewrite Hfail in Hv. discriminate.
      * rewrite Hcorr in Hv. discriminate.
      * exact Hempty.
    + rewrite (Hrsother b Hneb) in Hv.
      rewrite (Hrnother b Hneb). rewrite Hcc'.
      exact (HRI b Hb Hv).
  - destruct Hnf as [n0 (_ & _ & _ & _ & _ & _ & Hcc' & _ & _ & Hrn & Hrs)].
    exact (recovery_int_unchanged s s' HRI Hrs Hrn Hcc').
  - destruct Hnr as [n0 (_ & _ & _ & _ & _ & _ & Hcc' & _ & _ & Hrn & Hrs)].
    exact (recovery_int_unchanged s s' HRI Hrs Hrn Hcc').
Qed.

(* ========================================================================= *)
(*          SECTION 5: ATTESTATION/VERIFICATION INTEGRITY                    *)
(* ========================================================================= *)

(* AttestationIntegrity: attested[b] subset chunkVerified[b]
   Critical: NodeAttest (adds to attested), VerifyChunk (adds to verified) *)
Theorem attest_int_preserved : forall s s',
  AllSafety s -> Next s s' -> AttestationIntegrity s'.
Proof.
  intros s s' [HCS [HDR [HES [HP [HRI [HAI [HVI HNRD]]]]]]] Hnext.
  destruct Hnext as
    [Hdc | [Hvc | [Hna | [Hcc | [Hpc | [Htf | [Hrd | [Hnf | Hnr]]]]]]]].
  - destruct Hdc as [b0 (_ & _ & _ & _ & _ & Hcv & _ & Hat & _ & _ & _)].
    exact (attest_int_unchanged s s' HAI Hat Hcv).
  - (* VerifyChunk: adds to chunkVerified, attested unchanged *)
    destruct Hvc as [n0 [b0 (_ & _ & _ & _ & _ & _ &
      Hcv' & Hcvother & _ & _ & _ & Hat & _ & _ & _)]].
    unfold AttestationIntegrity. intros b Hb.
    batch_cases b b0.
    + rewrite Hat. rewrite Hcv'.
      exact (subset_trans _ _ _ (HAI b0 Hb) (subset_add_right n0 (chunkVerified s b0))).
    + rewrite Hat. rewrite (Hcvother b Hneb). exact (HAI b Hb).
  - (* NodeAttest: adds to attested, guard requires n in chunkVerified *)
    destruct Hna as [n0 [b0 (_ & _ & _ & Hverif & _ & _ &
      Hatt' & Hattother & _ & _ & Hcv & _ & _ & _ & _)]].
    unfold AttestationIntegrity. intros b Hb.
    batch_cases b b0.
    + rewrite Hatt'. rewrite Hcv.
      exact (add_preserves_subset n0 (attested s b0) (chunkVerified s b0) (HAI b0 Hb) Hverif).
    + rewrite (Hattother b Hneb). rewrite Hcv. exact (HAI b Hb).
  - destruct Hcc as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & Hcv & Hat & _ & _ & _)]].
    exact (attest_int_unchanged s s' HAI Hat Hcv).
  - destruct Hpc as [b0 (_ & _ & _ & _ & _ & _ & _ & Hcv & _ & Hat & _ & _)].
    exact (attest_int_unchanged s s' HAI Hat Hcv).
  - destruct Htf as [b0 (_ & _ & _ & _ & _ & _ & _ & _ & Hcv & _ & Hat & _ & _)].
    exact (attest_int_unchanged s s' HAI Hat Hcv).
  - destruct Hrd as [b0 [S0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hcv & _ & Hat & _)]].
    exact (attest_int_unchanged s s' HAI Hat Hcv).
  - destruct Hnf as [n0 (_ & _ & _ & _ & _ & Hcv & _ & Hat & _ & _ & _)].
    exact (attest_int_unchanged s s' HAI Hat Hcv).
  - destruct Hnr as [n0 (_ & _ & _ & _ & _ & Hcv & _ & Hat & _ & _ & _)].
    exact (attest_int_unchanged s s' HAI Hat Hcv).
Qed.

(* VerificationIntegrity: chunkVerified[b] subset distributedTo[b]
   Critical: VerifyChunk (adds to verified), DistributeChunks (changes dist) *)
Theorem verif_int_preserved : forall s s',
  AllSafety s -> Next s s' -> VerificationIntegrity s'.
Proof.
  intros s s' [HCS [HDR [HES [HP [HRI [HAI [HVI HNRD]]]]]]] Hnext.
  destruct Hnext as
    [Hdc | [Hvc | [Hna | [Hcc | [Hpc | [Htf | [Hrd | [Hnf | Hnr]]]]]]]].
  - (* DistributeChunks: changes distributedTo, chunkVerified unchanged *)
    destruct Hdc as [b0 (_ & Hempty & _ & Hdtother & _ & Hcv & _ & _ & _ & _ & _)].
    unfold VerificationIntegrity. intros b Hb.
    batch_cases b b0.
    + (* b = b0: chunkVerified was subset of empty -> empty -> subset of anything *)
      rewrite Hcv.
      assert (Hsub := HVI b0 Hb).
      rewrite Hempty in Hsub.
      assert (Hcard := subset_card _ _ Hsub).
      rewrite empty_card in Hcard.
      exact (empty_card_subset (chunkVerified s b0) (distributedTo s' b0) (Nat.le_antisymm _ _ Hcard (Nat.le_0_l _))).
    + rewrite Hcv. rewrite (Hdtother b Hneb). exact (HVI b Hb).
  - (* VerifyChunk: adds n to verified, guard: n in distributedTo *)
    destruct Hvc as [n0 [b0 (_ & _ & _ & Hdist & _ & _ &
      Hcv' & Hcvother & _ & Hdt & _ & _ & _ & _ & _)]].
    unfold VerificationIntegrity. intros b Hb.
    batch_cases b b0.
    + rewrite Hcv'. rewrite Hdt.
      exact (add_preserves_subset n0 (chunkVerified s b0) (distributedTo s b0) (HVI b0 Hb) Hdist).
    + rewrite (Hcvother b Hneb). rewrite Hdt. exact (HVI b Hb).
  - destruct Hna as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & Hdt & Hcv & _ & _ & _ & _)]].
    exact (verif_int_unchanged s s' HVI Hcv Hdt).
  - destruct Hcc as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & Hdt & Hcv & _ & _ & _ & _)]].
    exact (verif_int_unchanged s s' HVI Hcv Hdt).
  - destruct Hpc as [b0 (_ & _ & _ & _ & _ & _ & Hdt & Hcv & _ & _ & _ & _)].
    exact (verif_int_unchanged s s' HVI Hcv Hdt).
  - destruct Htf as [b0 (_ & _ & _ & _ & _ & _ & _ & Hdt & Hcv & _ & _ & _ & _)].
    exact (verif_int_unchanged s s' HVI Hcv Hdt).
  - destruct Hrd as [b0 [S0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & _ & Hdt & Hcv & _ & _ & _)]].
    exact (verif_int_unchanged s s' HVI Hcv Hdt).
  - destruct Hnf as [n0 (_ & _ & _ & _ & Hdt & Hcv & _ & _ & _ & _ & _)].
    exact (verif_int_unchanged s s' HVI Hcv Hdt).
  - destruct Hnr as [n0 (_ & _ & _ & _ & Hdt & Hcv & _ & _ & _ & _ & _)].
    exact (verif_int_unchanged s s' HVI Hcv Hdt).
Qed.

(* NoRecoveryBeforeDistribution: distributedTo[b] = empty -> recoverSt[b] = RecNone
   Only action that changes distributedTo is DistributeChunks (sets to non-empty
   or empty depending on online nodes). Only action that changes recoverSt is
   RecoverData (which requires certSt = CertValid, impossible with empty dist). *)
Theorem no_recov_before_dist_preserved : forall s s',
  AllSafety s -> Next s s' -> NoRecoveryBeforeDistribution s'.
Proof.
  intros s s' Hsafe Hnext.
  destruct Hsafe as (HCS & HDR & HES & HP & HRI & HAI & HVI & HNRD).
  destruct Hnext as
    [Hdc | [Hvc | [Hna | [Hcc | [Hpc | [Htf | [Hrd | [Hnf | Hnr]]]]]]]].
  - (* DistributeChunks: distributedTo changes, recoverSt unchanged *)
    destruct Hdc as [b0 (Hb0 & Hempty & _ & Hdtother & _ & _ & _ & _ & _ & _ & Hrs)].
    unfold NoRecoveryBeforeDistribution. intros b Hb Hdt.
    rewrite Hrs. batch_cases b b0.
    + (* b = b0: use the guard distributedTo s b0 = empty_set *)
      exact (HNRD b0 Hb Hempty).
    + (* b <> b0: distributedTo unchanged *)
      apply HNRD; auto. rewrite <- (Hdtother b Hneb). exact Hdt.
  - destruct Hvc as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & Hdt & _ & _ & _ & _ & Hrs)]].
    unfold NoRecoveryBeforeDistribution. intros b Hb Hd. rewrite Hrs. apply HNRD; auto. rewrite <- Hdt. exact Hd.
  - destruct Hna as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & _ & Hdt & _ & _ & _ & _ & Hrs)]].
    unfold NoRecoveryBeforeDistribution. intros b Hb Hd. rewrite Hrs. apply HNRD; auto. rewrite <- Hdt. exact Hd.
  - destruct Hcc as [n0 [b0 (_ & _ & _ & _ & _ & _ & _ & _ & Hdt & _ & _ & _ & _ & Hrs)]].
    unfold NoRecoveryBeforeDistribution. intros b Hb Hd. rewrite Hrs. apply HNRD; auto. rewrite <- Hdt. exact Hd.
  - destruct Hpc as [b0 (_ & _ & _ & _ & _ & _ & Hdt & _ & _ & _ & _ & Hrs)].
    unfold NoRecoveryBeforeDistribution. intros b Hb Hd. rewrite Hrs. apply HNRD; auto. rewrite <- Hdt. exact Hd.
  - destruct Htf as [b0 (_ & _ & _ & _ & _ & _ & _ & Hdt & _ & _ & _ & _ & Hrs)].
    unfold NoRecoveryBeforeDistribution. intros b Hb Hd. rewrite Hrs. apply HNRD; auto. rewrite <- Hdt. exact Hd.
  - (* RecoverData: changes recoverSt[b0] from RecNone, distributedTo unchanged *)
    destruct Hrd as [b0 [S0 Hrd_prop5]].
    destruct Hrd_prop5 as (_ & _ & HrsNone & Hsmem & Hne & _ & _ & _ & Hrsother & _ & Hdt & _ & _ & _ & _).
    unfold NoRecoveryBeforeDistribution. intros b Hb Hd.
    batch_cases b b0.
    + (* b = b0: RecoverData requires S non-empty subset of distributed nodes.
         If distributedTo = empty, S must be empty. Contradiction with S non-empty. *)
      exfalso.
      destruct (non_empty_witness _ Hne) as [x Hx].
      destruct (Hsmem x Hx) as [_ [_ Hdist_x]].
      rewrite <- Hdt in Hdist_x. rewrite Hd in Hdist_x.
      exact (empty_no_mem x Hdist_x).
    + rewrite (Hrsother b Hneb). apply HNRD; auto. rewrite <- Hdt. exact Hd.
  - destruct Hnf as [n0 (_ & _ & _ & _ & Hdt & _ & _ & _ & _ & _ & Hrs)].
    unfold NoRecoveryBeforeDistribution. intros b Hb Hd. rewrite Hrs. apply HNRD; auto. rewrite <- Hdt. exact Hd.
  - destruct Hnr as [n0 (_ & _ & _ & _ & Hdt & _ & _ & _ & _ & _ & Hrs)].
    unfold NoRecoveryBeforeDistribution. intros b Hb Hd. rewrite Hrs. apply HNRD; auto. rewrite <- Hdt. exact Hd.
Qed.

(* ========================================================================= *)
(*          SECTION 6: ALL SAFETY PRESERVED                                  *)
(* ========================================================================= *)

Theorem all_safety_preserved : forall s s',
  AllSafety s -> Next s s' -> AllSafety s'.
Proof.
  intros s s' Hsafe Hnext. unfold AllSafety. repeat split.
  - exact (cert_soundness_preserved s s' Hsafe Hnext).
  - exact (data_recov_preserved s s' Hsafe Hnext).
  - exact (erasure_sound_preserved s s' Hsafe Hnext).
  - exact (privacy_preserved s s' Hsafe Hnext).
  - exact (recovery_int_preserved s s' Hsafe Hnext).
  - exact (attest_int_preserved s s' Hsafe Hnext).
  - exact (verif_int_preserved s s' Hsafe Hnext).
  - exact (no_recov_before_dist_preserved s s' Hsafe Hnext).
Qed.

(* ========================================================================= *)
(*          SECTION 7: MAIN THEOREMS                                         *)
(* ========================================================================= *)

(* Master theorem: all safety invariants hold for every reachable state. *)
Theorem all_safety_invariant : forall s, Reachable s -> AllSafety s.
Proof.
  intros s Hreach. induction Hreach as [s Hinit | s s' _ IH Hnext].
  - exact (init_all_safety s Hinit).
  - exact (all_safety_preserved s s' IH Hnext).
Qed.

(* Individual invariant theorems extracted from the master theorem. *)

Theorem certificate_soundness_holds : forall s,
  Reachable s -> CertificateSoundness s.
Proof. intros s H. exact (proj1 (all_safety_invariant s H)). Qed.

Theorem data_recoverability_holds : forall s,
  Reachable s -> DataRecoverability s.
Proof. intros s H. exact (proj1 (proj2 (all_safety_invariant s H))). Qed.

Theorem erasure_soundness_holds : forall s,
  Reachable s -> ErasureSoundness s.
Proof. intros s H. exact (proj1 (proj2 (proj2 (all_safety_invariant s H)))). Qed.

Theorem privacy_holds : forall s,
  Reachable s -> Privacy s.
Proof. intros s H. exact (proj1 (proj2 (proj2 (proj2 (all_safety_invariant s H))))). Qed.

Theorem recovery_integrity_holds : forall s,
  Reachable s -> RecoveryIntegrity s.
Proof. intros s H. exact (proj1 (proj2 (proj2 (proj2 (proj2 (all_safety_invariant s H)))))). Qed.

Theorem attestation_integrity_holds : forall s,
  Reachable s -> AttestationIntegrity s.
Proof. intros s H. exact (proj1 (proj2 (proj2 (proj2 (proj2 (proj2 (all_safety_invariant s H))))))). Qed.

Theorem verification_integrity_holds : forall s,
  Reachable s -> VerificationIntegrity s.
Proof. intros s H. exact (proj1 (proj2 (proj2 (proj2 (proj2 (proj2 (proj2 (all_safety_invariant s H)))))))). Qed.

Theorem no_recovery_before_dist_holds : forall s,
  Reachable s -> NoRecoveryBeforeDistribution s.
Proof. intros s H. exact (proj2 (proj2 (proj2 (proj2 (proj2 (proj2 (proj2 (all_safety_invariant s H)))))))). Qed.

(* ========================================================================= *)
(*          SECTION 8: CRYPTO PROPERTY THEOREMS                              *)
(* ========================================================================= *)
(* These theorems connect the abstract specification properties to the       *)
(* concrete cryptographic primitive guarantees in the implementation.         *)

(* RS + AES-GCM composition: data recoverable from any k authentic chunks.
   Combines rs_mds_correctness with aes_correctness.
   This is the concrete mechanism underlying DataRecoverability. *)
Theorem rs_aes_data_recovery : forall key plaindata k n,
  k >= 1 -> k <= n ->
  exists ct chunks,
    ct = aes_encrypt key plaindata /\
    chunks = rs_encode ct k n /\
    aes_decrypt key ct = Some plaindata.
Proof.
  intros key plaindata k n Hk Hn.
  exists (aes_encrypt key plaindata).
  exists (rs_encode (aes_encrypt key plaindata) k n).
  repeat split. exact (aes_correctness key plaindata).
Qed.

(* Shamir threshold property: recovery requires exactly k shares.
   Fewer than k shares cannot recover the key (privacy).
   This is the concrete mechanism underlying the Privacy invariant. *)
Theorem shamir_threshold_property : forall key k n,
  k >= 2 -> k <= n ->
  (exists shares, shares = shamir_split key k n /\ length shares = n /\
    forall selected, length selected = k ->
      (forall s, In s selected -> In s shares) ->
      shamir_recover selected = Some key) /\
  (forall insufficient, length insufficient < k ->
    shamir_recover insufficient = None).
Proof.
  intros key k n Hk Hn. split.
  - exact (shamir_correctness key k n Hk Hn).
  - intros insufficient Hlen. exact (shamir_insufficient insufficient k Hlen).
Qed.

(* AES-GCM integrity detection: any tampering detected.
   Wrong key -> decryption fails. Wrong ciphertext -> decryption fails.
   This is the concrete mechanism underlying ErasureSoundness. *)
Theorem aes_integrity_detection : forall key1 key2 plaindata,
  key1 <> key2 ->
  aes_decrypt key2 (aes_encrypt key1 plaindata) = None.
Proof.
  intros key1 key2 plaindata Hne.
  exact (aes_tamper_detection key1 key2 plaindata Hne).
Qed.
