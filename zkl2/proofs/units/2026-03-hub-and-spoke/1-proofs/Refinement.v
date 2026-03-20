(* ========================================== *)
(*     Refinement.v -- Verification Proofs     *)
(*     Implementation Refines Specification    *)
(*     zkl2/proofs/units/2026-03-hub-and-spoke *)
(* ========================================== *)

(* This file proves the six core safety properties of the
   Hub-and-Spoke cross-enterprise protocol:

     INV-CE5  CrossEnterpriseIsolation
     INV-CE6  AtomicSettlement         (SECURITY CRITICAL)
     INV-CE7  CrossRefConsistency
     INV-CE8  ReplayProtection         (SECURITY CRITICAL)
     INV-CE9  TimeoutSafety
     INV-CE10 HubNeutrality

   Proof architecture:
     1. Define composite invariant (Inv) with 7 components.
     2. Prove Inv holds on init_state.
     3. Prove Inv is preserved by each of 9 step constructors
        via separate lemmas for modularity.
     4. Extract six target safety theorems from Inv.

   Key theorems proved (all without Admitted):
     T1.  inv_init               -- Init establishes invariant
     T2.  inv_preserved          -- Step preserves invariant
     T3.  cross_isolation        -- INV-CE5
     T4.  atomic_settlement      -- INV-CE6
     T5.  cross_ref_consistency  -- INV-CE7
     T6.  replay_protection      -- INV-CE8
     T7.  timeout_safety         -- INV-CE9
     T8.  hub_neutrality         -- INV-CE10
     T9.  impl_inv_preserved     -- Implementation preserves invariant

   Source: HubAndSpoke.tla (spec), hub.go + spoke.go + BasisHub.sol (impl) *)

From HubAndSpoke Require Import Common.
From HubAndSpoke Require Import Spec.
From HubAndSpoke Require Import Impl.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.

(* ========================================== *)
(*     COMPOSITE INVARIANT                     *)
(* ========================================== *)

Record Inv (s : State) (tb : nat) : Prop := mk_inv {
  (* I1: Source /= dest for all messages (Isolation).
     [Source: HubAndSpoke.tla, line 132 -- source /= dest] *)
  inv_src_ne_dst : forall src dst n msg,
    st_msgs s src dst n = Some msg -> src <> dst;

  (* I2: Message fields match store key.
     [Source: BasisHub.sol, lines 268-270] *)
  inv_key_ok : forall src dst n msg,
    st_msgs s src dst n = Some msg ->
    msg_source msg = src /\ msg_dest msg = dst /\ msg_nonce msg = n;

  (* I3: AtomicSettlement. Settled => both roots strictly advanced.
     [Source: HubAndSpoke.tla, lines 476-480 -- INV-CE6] *)
  inv_atomic : forall src dst n msg,
    st_msgs s src dst n = Some msg -> msg_status msg = Settled ->
    st_roots s src > msg_srcRootVer msg /\
    st_roots s dst > msg_dstRootVer msg;

  (* I4: CrossRefConsistency. Settled => both proofs valid.
     [Source: HubAndSpoke.tla, lines 492-496 -- INV-CE7] *)
  inv_crossref : forall src dst n msg,
    st_msgs s src dst n = Some msg -> msg_status msg = Settled ->
    msg_srcProofValid msg = true /\ msg_dstProofValid msg = true;

  (* I5: HubNeutrality. Post-verified => source proof valid.
     [Source: HubAndSpoke.tla, lines 558-561 -- INV-CE10] *)
  inv_hub_neutral : forall src dst n msg,
    st_msgs s src dst n = Some msg ->
    is_post_verified (msg_status msg) = true ->
    msg_srcProofValid msg = true;

  (* I6: Nonce tracking. Post-verified => nonce consumed.
     [Source: HubAndSpoke.tla, lines 228-230] *)
  inv_nonce_used : forall src dst n msg,
    st_msgs s src dst n = Some msg ->
    is_post_verified (msg_status msg) = true ->
    st_nonces s src dst n = true;

  (* I7: TimeoutSafety. TimedOut => deadline exceeded.
     [Source: HubAndSpoke.tla, lines 537-540 -- INV-CE9] *)
  inv_timeout : forall src dst n msg,
    st_msgs s src dst n = Some msg -> msg_status msg = TimedOut ->
    st_block s >= msg_createdAt msg + tb;
}.

(* ========================================== *)
(*     T1: INIT ESTABLISHES INVARIANT          *)
(* ========================================== *)

Theorem inv_init : forall tb, Inv init_state tb.
Proof.
  intro tb. constructor; simpl; intros; discriminate.
Qed.

(* ========================================== *)
(*     PRESERVATION LEMMAS                     *)
(* ========================================== *)

(* Tactic: case-split on message key by matching the hypothesis.
   Uses -> to rewrite equalities without removing original key variables. *)
Local Ltac msg_split H :=
  match type of H with
  | update_map3 _ ?k1 ?k2 ?k3 _ ?n1 ?n2 ?n3 = Some _ =>
    destruct (triple_eq_dec n1 n2 n3 k1 k2 k3) as [[-> [-> ->]] | ?Hdiff];
    [rewrite update_map3_eq in H
    | rewrite update_map3_neq in H by exact Hdiff]
  end.

(* Tactic: resolve nonce store lookups after msg_split. *)
Local Ltac nonce_split :=
  match goal with
  | [ Hd : _ <> _ \/ _ <> _ \/ _ <> _
      |- context[update_map3 _ _ _ _ _ _ _ _] ] =>
    rewrite update_map3_neq by exact Hd
  | |- context[update_map3 _ ?k1 ?k2 ?k3 _ ?k1 ?k2 ?k3] =>
    rewrite update_map3_eq
  end.


(* --- Prepare --- *)
Lemma inv_prepare : forall s tb src dst pv nonce,
  Inv s tb ->
  src <> dst ->
  nonce = st_counter s src dst + 1 ->
  st_msgs s src dst nonce = None ->
  Inv (mkState
    (st_roots s)
    (update_map3 (st_msgs s) src dst nonce
      (Some (mkMsg src dst nonce pv false (st_roots s src) 0 Prepared (st_block s))))
    (st_nonces s)
    (update_map2 (st_counter s) src dst nonce)
    (st_block s)) tb.
Proof.
  intros s tb src dst pv nonce [I1 I2 I3 I4 I5 I6 I7] Hne Hn Hempty.
  constructor; simpl;
    intros src' dst' n' msg' Hmsg'; msg_split Hmsg'.
  (* I1 *) - assert (msg' = mkMsg src dst nonce pv false (st_roots s src) 0 Prepared (st_block s))
               by congruence; subst; assumption.
            - eapply I1; eassumption.
  (* I2 *) - assert (msg' = mkMsg src dst nonce pv false (st_roots s src) 0 Prepared (st_block s))
               by congruence; subst; simpl; auto.
            - eapply I2; eassumption.
  (* I3 *) - intros Hs. assert (msg' = mkMsg src dst nonce pv false (st_roots s src) 0 Prepared (st_block s))
               by congruence; subst; simpl in Hs; discriminate.
            - intros; eapply I3; eassumption.
  (* I4 *) - intros Hs. assert (msg' = mkMsg src dst nonce pv false (st_roots s src) 0 Prepared (st_block s))
               by congruence; subst; simpl in Hs; discriminate.
            - intros; eapply I4; eassumption.
  (* I5 *) - intros Hpv. assert (msg' = mkMsg src dst nonce pv false (st_roots s src) 0 Prepared (st_block s))
               by congruence; subst; simpl in Hpv; discriminate.
            - intros; eapply I5; eassumption.
  (* I6 *) - intros Hpv. assert (msg' = mkMsg src dst nonce pv false (st_roots s src) 0 Prepared (st_block s))
               by congruence; subst; simpl in Hpv; discriminate.
            - intros; eapply I6; eassumption.
  (* I7 *) - intros Hs. assert (msg' = mkMsg src dst nonce pv false (st_roots s src) 0 Prepared (st_block s))
               by congruence; subst; simpl in Hs; discriminate.
            - intros; eapply I7; eassumption.
Qed.

(* --- Verify Pass --- *)
Lemma inv_verify_pass : forall s tb src dst n msg,
  Inv s tb ->
  st_msgs s src dst n = Some msg ->
  msg_status msg = Prepared ->
  msg_srcRootVer msg = st_roots s src ->
  msg_srcProofValid msg = true ->
  st_nonces s src dst n = false ->
  Inv (mkState
    (st_roots s)
    (update_map3 (st_msgs s) src dst n (Some (set_status msg HubVerified)))
    (update_map3 (st_nonces s) src dst n true)
    (st_counter s)
    (st_block s)) tb.
Proof.
  intros s tb src dst n msg [I1 I2 I3 I4 I5 I6 I7]
    Hmsg Hstat Hroot Hproof Hnonce.
  constructor; simpl;
    intros src' dst' n' msg' Hmsg'; msg_split Hmsg'.
  (* I1 *) - assert (msg' = set_status msg HubVerified) by congruence; subst; simpl;
               eapply I1; eassumption.
            - eapply I1; eassumption.
  (* I2 *) - assert (msg' = set_status msg HubVerified) by congruence; subst; simpl;
               eapply I2; eassumption.
            - eapply I2; eassumption.
  (* I3 *) - intros Hs. assert (msg' = set_status msg HubVerified) by congruence; subst;
               simpl in Hs; discriminate.
            - intros; eapply I3; eassumption.
  (* I4 *) - intros Hs. assert (msg' = set_status msg HubVerified) by congruence; subst;
               simpl in Hs; discriminate.
            - intros; eapply I4; eassumption.
  (* I5: New HubVerified message has valid source proof. *)
  - intros _. assert (msg' = set_status msg HubVerified) by congruence; subst; simpl; exact Hproof.
  - intros; eapply I5; eassumption.
  (* I6: Nonce consumed for newly verified message. *)
  - intros _Hpv. nonce_split. reflexivity.
  - intros Hpv. nonce_split. eapply I6; eassumption.
  (* I7 *) - intros Hs. assert (msg' = set_status msg HubVerified) by congruence; subst;
               simpl in Hs; discriminate.
            - intros; eapply I7; eassumption.
Qed.

(* --- Verify Fail ---
   Failed is terminal, not post-verified, not Settled. All vacuous. *)
Lemma inv_verify_fail : forall s tb src dst n msg,
  Inv s tb ->
  st_msgs s src dst n = Some msg ->
  msg_status msg = Prepared ->
  (msg_srcRootVer msg <> st_roots s src \/
   msg_srcProofValid msg = false \/
   st_nonces s src dst n = true) ->
  Inv (mkState
    (st_roots s)
    (update_map3 (st_msgs s) src dst n (Some (set_status msg Failed)))
    (st_nonces s)
    (st_counter s)
    (st_block s)) tb.
Proof.
  intros s tb src dst n msg [I1 I2 I3 I4 I5 I6 I7]
    Hmsg Hstat Hfail.
  constructor; simpl;
    intros src' dst' n' msg' Hmsg'; msg_split Hmsg'.
  - assert (msg' = set_status msg Failed) by congruence; subst; simpl;
      eapply I1; eassumption.
  - eapply I1; eassumption.
  - assert (msg' = set_status msg Failed) by congruence; subst; simpl;
      eapply I2; eassumption.
  - eapply I2; eassumption.
  - intros Hs; assert (msg' = set_status msg Failed) by congruence; subst;
      simpl in Hs; discriminate.
  - intros; eapply I3; eassumption.
  - intros Hs; assert (msg' = set_status msg Failed) by congruence; subst;
      simpl in Hs; discriminate.
  - intros; eapply I4; eassumption.
  - intros Hpv; assert (msg' = set_status msg Failed) by congruence; subst;
      simpl in Hpv; discriminate.
  - intros; eapply I5; eassumption.
  - intros Hpv; assert (msg' = set_status msg Failed) by congruence; subst;
      simpl in Hpv; discriminate.
  - intros; eapply I6; eassumption.
  - intros Hs; assert (msg' = set_status msg Failed) by congruence; subst;
      simpl in Hs; discriminate.
  - intros; eapply I7; eassumption.
Qed.

(* --- Respond --- *)
Lemma inv_respond : forall s tb src dst n msg dpv,
  Inv s tb ->
  st_msgs s src dst n = Some msg ->
  msg_status msg = HubVerified ->
  Inv (mkState
    (st_roots s)
    (update_map3 (st_msgs s) src dst n
      (Some (set_response msg dpv (st_roots s dst))))
    (st_nonces s)
    (st_counter s)
    (st_block s)) tb.
Proof.
  intros s tb src dst n msg dpv [I1 I2 I3 I4 I5 I6 I7] Hmsg Hstat.
  constructor; simpl;
    intros src' dst' n' msg' Hmsg'; msg_split Hmsg'.
  (* I1 *) - assert (msg' = set_response msg dpv (st_roots s dst)) by congruence; subst; simpl;
               eapply I1; eassumption.
            - eapply I1; eassumption.
  (* I2 *) - assert (msg' = set_response msg dpv (st_roots s dst)) by congruence; subst; simpl;
               eapply I2; eassumption.
            - eapply I2; eassumption.
  (* I3 *) - intros Hs. assert (msg' = set_response msg dpv (st_roots s dst)) by congruence; subst;
               simpl in Hs; discriminate.
            - intros; eapply I3; eassumption.
  (* I4 *) - intros Hs. assert (msg' = set_response msg dpv (st_roots s dst)) by congruence; subst;
               simpl in Hs; discriminate.
            - intros; eapply I4; eassumption.
  (* I5: srcProofValid preserved by set_response. *)
  - intros Hpv. assert (msg' = set_response msg dpv (st_roots s dst)) by congruence; subst; simpl.
    eapply I5; [exact Hmsg | rewrite Hstat; reflexivity].
  - intros; eapply I5; eassumption.
  (* I6: nonce unchanged. Was HubVerified, now Responded -- both post-verified. *)
  - intros Hpv. eapply I6; [exact Hmsg | rewrite Hstat; reflexivity].
  - intros; eapply I6; eassumption.
  (* I7 *) - intros Hs. assert (msg' = set_response msg dpv (st_roots s dst)) by congruence; subst;
               simpl in Hs; discriminate.
            - intros; eapply I7; eassumption.
Qed.

(* --- Settle Pass --- THE CRITICAL PROOF.
   ATOMIC: Both roots advance by 1 in a single step.
   [Invariant: INV-CE6 AtomicSettlement] *)
Lemma inv_settle_pass : forall s tb src dst n msg,
  Inv s tb ->
  st_msgs s src dst n = Some msg ->
  msg_status msg = Responded ->
  msg_srcProofValid msg = true ->
  msg_dstProofValid msg = true ->
  msg_srcRootVer msg = st_roots s src ->
  msg_dstRootVer msg = st_roots s dst ->
  Inv (mkState
    (advance_roots (st_roots s) src dst)
    (update_map3 (st_msgs s) src dst n (Some (set_status msg Settled)))
    (st_nonces s)
    (st_counter s)
    (st_block s)) tb.
Proof.
  intros s tb src dst n msg [I1 I2 I3 I4 I5 I6 I7]
    Hmsg Hstat Hsp Hdp Hsr Hdr.
  constructor; simpl;
    intros src' dst' n' msg' Hmsg'; msg_split Hmsg'.
  (* I1 *)
  - assert (msg' = set_status msg Settled) by congruence; subst; simpl;
      eapply I1; eassumption.
  - eapply I1; eassumption.
  (* I2 *)
  - assert (msg' = set_status msg Settled) by congruence; subst; simpl;
      eapply I2; eassumption.
  - eapply I2; eassumption.
  (* I3: AtomicSettlement -- THE KEY THEOREM.
     For newly settled: advance_roots gives root + 1 > recorded version.
     For previously settled: roots only increased, so still > recorded. *)
  - intros Hstatus'.
    assert (Heq : msg' = set_status msg Settled) by congruence; subst; simpl.
    split.
    + (* Source root *) rewrite advance_roots_at_e1. rewrite Hsr. lia.
    + (* Dest root *) rewrite advance_roots_at_e2. rewrite Hdr. lia.
  - intros Hstatus'.
    specialize (I3 _ _ _ _ Hmsg' Hstatus'). destruct I3 as [Hs Hd].
    split.
    + pose proof (advance_roots_ge (st_roots s) src dst src'). lia.
    + pose proof (advance_roots_ge (st_roots s) src dst dst'). lia.
  (* I4: CrossRefConsistency. Both proofs valid from preconditions. *)
  - intros _. assert (msg' = set_status msg Settled) by congruence; subst; simpl.
    split; assumption.
  - intros; eapply I4; eassumption.
  (* I5: HubNeutrality. srcProofValid preserved by set_status. *)
  - assert (msg' = set_status msg Settled) by congruence; subst; simpl.
    intros _. exact Hsp.
  - intros; eapply I5; eassumption.
  (* I6: Nonce. Was Responded (post-verified). Nonces unchanged. *)
  - intros _.
    eapply I6; [exact Hmsg | rewrite Hstat; reflexivity].
  - intros; eapply I6; eassumption.
  (* I7 *)
  - intros Hstatus'.
    assert (msg' = set_status msg Settled) by congruence; subst;
      simpl in Hstatus'; discriminate.
  - intros; eapply I7; eassumption.
Qed.

(* --- Settle Fail ---
   Failed is terminal, not post-verified. All vacuous. *)
Lemma inv_settle_fail : forall s tb src dst n msg,
  Inv s tb ->
  st_msgs s src dst n = Some msg ->
  msg_status msg = Responded ->
  (msg_srcProofValid msg = false \/
   msg_dstProofValid msg = false \/
   msg_srcRootVer msg <> st_roots s src \/
   msg_dstRootVer msg <> st_roots s dst) ->
  Inv (mkState
    (st_roots s)
    (update_map3 (st_msgs s) src dst n (Some (set_status msg Failed)))
    (st_nonces s)
    (st_counter s)
    (st_block s)) tb.
Proof.
  intros s tb src dst n msg [I1 I2 I3 I4 I5 I6 I7] Hmsg Hstat Hfail.
  constructor; simpl;
    intros src' dst' n' msg' Hmsg'; msg_split Hmsg'.
  - assert (msg' = set_status msg Failed) by congruence; subst; simpl;
      eapply I1; eassumption.
  - eapply I1; eassumption.
  - assert (msg' = set_status msg Failed) by congruence; subst; simpl;
      eapply I2; eassumption.
  - eapply I2; eassumption.
  - intros Hs; assert (msg' = set_status msg Failed) by congruence; subst;
      simpl in Hs; discriminate.
  - intros; eapply I3; eassumption.
  - intros Hs; assert (msg' = set_status msg Failed) by congruence; subst;
      simpl in Hs; discriminate.
  - intros; eapply I4; eassumption.
  - intros Hpv; assert (msg' = set_status msg Failed) by congruence; subst;
      simpl in Hpv; discriminate.
  - intros; eapply I5; eassumption.
  - intros Hpv; assert (msg' = set_status msg Failed) by congruence; subst;
      simpl in Hpv; discriminate.
  - intros; eapply I6; eassumption.
  - intros Hs; assert (msg' = set_status msg Failed) by congruence; subst;
      simpl in Hs; discriminate.
  - intros; eapply I7; eassumption.
Qed.

(* --- Timeout --- *)
Lemma inv_timeout_step : forall s tb src dst n msg,
  Inv s tb ->
  st_msgs s src dst n = Some msg ->
  is_terminal (msg_status msg) = false ->
  st_block s >= msg_createdAt msg + tb ->
  Inv (mkState
    (st_roots s)
    (update_map3 (st_msgs s) src dst n (Some (set_status msg TimedOut)))
    (st_nonces s)
    (st_counter s)
    (st_block s)) tb.
Proof.
  intros s tb src dst n msg [I1 I2 I3 I4 I5 I6 I7] Hmsg Hterm Hdeadline.
  constructor; simpl;
    intros src' dst' n' msg' Hmsg'; msg_split Hmsg'.
  - assert (msg' = set_status msg TimedOut) by congruence; subst; simpl;
      eapply I1; eassumption.
  - eapply I1; eassumption.
  - assert (msg' = set_status msg TimedOut) by congruence; subst; simpl;
      eapply I2; eassumption.
  - eapply I2; eassumption.
  - intros Hs; assert (msg' = set_status msg TimedOut) by congruence; subst;
      simpl in Hs; discriminate.
  - intros; eapply I3; eassumption.
  - intros Hs; assert (msg' = set_status msg TimedOut) by congruence; subst;
      simpl in Hs; discriminate.
  - intros; eapply I4; eassumption.
  - intros Hpv; assert (msg' = set_status msg TimedOut) by congruence; subst;
      simpl in Hpv; discriminate.
  - intros; eapply I5; eassumption.
  - intros Hpv; assert (msg' = set_status msg TimedOut) by congruence; subst;
      simpl in Hpv; discriminate.
  - intros; eapply I6; eassumption.
  (* I7: New TimedOut message satisfies deadline from precondition. *)
  - intros Hs. assert (msg' = set_status msg TimedOut) by congruence; subst; simpl.
    exact Hdeadline.
  - intros; eapply I7; eassumption.
Qed.

(* --- Advance Block ---
   Only st_block increases. Everything else unchanged. *)
Lemma inv_advance_block : forall s tb,
  Inv s tb ->
  Inv (mkState (st_roots s) (st_msgs s) (st_nonces s) (st_counter s)
    (st_block s + 1)) tb.
Proof.
  intros s tb [I1 I2 I3 I4 I5 I6 I7].
  constructor; simpl.
  - exact I1.
  - exact I2.
  - exact I3.
  - exact I4.
  - exact I5.
  - exact I6.
  - intros src dst n msg H Hs. specialize (I7 _ _ _ _ H Hs). lia.
Qed.

(* --- Update Root ---
   Only st_roots increases for one enterprise. *)
Lemma inv_update_root : forall s tb e,
  Inv s tb ->
  Inv (mkState
    (update_map (st_roots s) e (st_roots s e + 1))
    (st_msgs s)
    (st_nonces s)
    (st_counter s)
    (st_block s)) tb.
Proof.
  intros s tb e [I1 I2 I3 I4 I5 I6 I7].
  constructor; simpl.
  - exact I1.
  - exact I2.
  (* I3: Roots only increase, so previously settled messages OK. *)
  - intros src dst n msg H Hs.
    specialize (I3 _ _ _ _ H Hs). destruct I3 as [Hsrc Hdst].
    split; unfold update_map;
      destruct (Nat.eqb_spec src e) as [-> | _];
      destruct (Nat.eqb_spec dst e) as [-> | _]; lia.
  - exact I4.
  - exact I5.
  - exact I6.
  - exact I7.
Qed.

(* ========================================== *)
(*     T2: STEP PRESERVES INVARIANT            *)
(* ========================================== *)

Theorem inv_preserved : forall s s' tb,
  Inv s tb -> step tb s s' -> Inv s' tb.
Proof.
  intros s s' tb Hinv Hstep.
  inversion_clear Hstep.
  - eapply inv_prepare; try eassumption; auto.
  - eapply inv_verify_pass; try eassumption; auto.
  - eapply inv_verify_fail; try eassumption; auto.
  - eapply inv_respond; try eassumption; auto.
  - eapply inv_settle_pass; try eassumption; auto.
  - eapply inv_settle_fail; try eassumption; auto.
  - eapply inv_timeout_step; try eassumption; auto.
  - apply inv_advance_block; assumption.
  - apply inv_update_root; assumption.
Qed.

(* ========================================== *)
(*     T3-T8: SAFETY THEOREMS                  *)
(* ========================================== *)

(* T3. CrossEnterpriseIsolation (INV-CE5).
   [Source: HubAndSpoke.tla, lines 450-458] *)
Theorem cross_isolation : forall s tb,
  Inv s tb -> CrossEnterpriseIsolation s.
Proof.
  intros s tb Hinv. unfold CrossEnterpriseIsolation.
  exact (inv_src_ne_dst s tb Hinv).
Qed.

(* T4. AtomicSettlement (INV-CE6). SECURITY CRITICAL.
   Prevents partial settlement where one enterprise's root advances
   but the other's does not.
   [Source: HubAndSpoke.tla, lines 476-480] *)
Theorem atomic_settlement : forall s tb,
  Inv s tb -> AtomicSettlement s.
Proof.
  intros s tb Hinv. unfold AtomicSettlement.
  exact (inv_atomic s tb Hinv).
Qed.

(* T5. CrossRefConsistency (INV-CE7).
   [Source: HubAndSpoke.tla, lines 492-496] *)
Theorem cross_ref_consistency : forall s tb,
  Inv s tb -> CrossRefConsistency s.
Proof.
  intros s tb Hinv. unfold CrossRefConsistency.
  exact (inv_crossref s tb Hinv).
Qed.

(* T6. ReplayProtection (INV-CE8). SECURITY CRITICAL.
   The nonce mechanism prevents re-verification:
   (a) VerifyAtHub consumes nonce on success
   (b) This theorem: consumed nonce for all post-verified messages
   (c) step_verify_pass requires nonce fresh => re-verification impossible
   [Source: HubAndSpoke.tla, lines 514-521] *)
Theorem replay_protection : forall s tb,
  Inv s tb -> ReplayProtection s.
Proof.
  intros s tb Hinv. unfold ReplayProtection.
  exact (inv_nonce_used s tb Hinv).
Qed.

(* T7. TimeoutSafety (INV-CE9).
   [Source: HubAndSpoke.tla, lines 537-540] *)
Theorem timeout_safety : forall s tb,
  Inv s tb -> TimeoutSafety s tb.
Proof.
  intros s tb Hinv. unfold TimeoutSafety.
  exact (inv_timeout s tb Hinv).
Qed.

(* T8. HubNeutrality (INV-CE10).
   [Source: HubAndSpoke.tla, lines 558-561] *)
Theorem hub_neutrality : forall s tb,
  Inv s tb -> HubNeutrality s.
Proof.
  intros s tb Hinv. unfold HubNeutrality.
  exact (inv_hub_neutral s tb Hinv).
Qed.

(* ========================================== *)
(*     T9: IMPLEMENTATION REFINEMENT           *)
(* ========================================== *)

Theorem impl_inv_preserved : forall s s' tb,
  Inv s tb -> impl_step tb s s' -> Inv s' tb.
Proof.
  intros s s' tb Hinv Hstep.
  apply inv_preserved with s.
  - exact Hinv.
  - exact (impl_refines_spec tb s s' Hstep).
Qed.

Corollary impl_atomic_settlement : forall s tb,
  Inv s tb -> AtomicSettlement s.
Proof. exact atomic_settlement. Qed.

Corollary impl_cross_ref_consistency : forall s tb,
  Inv s tb -> CrossRefConsistency s.
Proof. exact cross_ref_consistency. Qed.

Corollary impl_replay_protection : forall s tb,
  Inv s tb -> ReplayProtection s.
Proof. exact replay_protection. Qed.

(* ========================================== *)
(*     VERIFICATION SUMMARY                    *)
(* ========================================== *)

(* All 9 theorems + 3 corollaries proved without Admitted.

   INVARIANT ESTABLISHMENT AND PRESERVATION
     T1. inv_init               -- Init establishes Inv
     T2. inv_preserved          -- Any step preserves Inv

   SAFETY PROPERTIES (derived from Inv)
     T3. cross_isolation        -- INV-CE5: source /= dest
     T4. atomic_settlement      -- INV-CE6: both roots advanced or neither
     T5. cross_ref_consistency  -- INV-CE7: settled => both proofs valid
     T6. replay_protection      -- INV-CE8: nonce consumed => no re-verify
     T7. timeout_safety         -- INV-CE9: no premature timeouts
     T8. hub_neutrality         -- INV-CE10: hub only verifies

   IMPLEMENTATION REFINEMENT
     T9. impl_inv_preserved     -- Go + Solidity preserve Inv

   TLC Evidence:
     7,411 states, 3,602 distinct, all 6 invariants verified
     [Source: 0-input-spec/MC_HubAndSpoke.log]

   Cryptographic Assumptions (trusted, not verified):
     ZK Soundness, ZK Zero-Knowledge, Poseidon Hiding, Hub Neutrality
     [Source: HubAndSpoke.tla, lines 96-121] *)
