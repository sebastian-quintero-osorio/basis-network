(* ========================================== *)
(*     Refinement.v -- Verification Proofs     *)
(*     Implementation Refines Specification    *)
(*     zkl2/proofs/units/2026-03-sequencer     *)
(* ========================================== *)

(* This file proves the core safety properties of the Sequencer:
   1. NoDoubleInclusion       -- No tx in two different blocks
   2. IncludedWereSubmitted    -- Only submitted txs in blocks
   3. ForcedBeforeMempool      -- Forced txs precede mempool in each block
   4. ForcedInclusionDeadline  -- Expired forced txs are included
   5. FIFOWithinBlock          -- FIFO ordering within each block

   All theorems proved without Admitted.

   Source: Sequencer.tla (spec), sequencer.go + supporting files (impl) *)

From Sequencer Require Import Common.
From Sequencer Require Import Spec.
From Sequencer Require Import Impl.
From Stdlib Require Import List.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
From Stdlib Require Import Permutation.
Import ListNotations.

(* ========================================== *)
(*     INFRASTRUCTURE LEMMAS                   *)
(* ========================================== *)

(* NoDup is preserved by permutation. *)
Lemma NoDup_perm : forall (A : Type) (l1 l2 : list A),
  Permutation l1 l2 -> NoDup l1 -> NoDup l2.
Proof.
  intros A l1 l2 Hp Hnd.
  induction Hp; auto.
  - inversion Hnd; subst. constructor.
    + intro Hin. apply H1. eapply Permutation_in.
      * apply Permutation_sym. exact Hp.
      * exact Hin.
    + exact (IHHp H2).
  - inversion Hnd; subst. inversion H2; subst. constructor.
    + intros [->|Hin]; [apply H1; left; reflexivity | exact (H3 Hin)].
    + constructor; [intro Hin; apply H1; right; exact Hin | exact H4].
Qed.

(* Insert a fresh element after a prefix, preserving NoDup. *)
Lemma NoDup_insert : forall (A : Type) (l1 : list A) (x : A) (l2 : list A),
  NoDup (l1 ++ l2) -> ~ In x (l1 ++ l2) -> NoDup (l1 ++ x :: l2).
Proof.
  intros A l1 x l2 Hnd Hni.
  induction l1 as [|a rest IH]; simpl in *.
  - constructor; [exact Hni | exact Hnd].
  - inversion Hnd; subst. constructor.
    + intro Hin. apply in_app_or in Hin. destruct Hin as [Hin|[->|Hin]].
      * exact (H1 (in_or_app _ _ _ (or_introl Hin))).
      * exact (Hni (or_introl eq_refl)).
      * exact (H1 (in_or_app _ _ _ (or_intror Hin))).
    + apply IH; [exact H2 | intro H; exact (Hni (or_intror H))].
Qed.

(* Disjointness from NoDup of concatenation. *)
Lemma NoDup_disj12 : forall (A : Type) (l1 l2 : list A),
  NoDup (l1 ++ l2) -> forall x, In x l1 -> ~ In x l2.
Proof.
  intros A l1; induction l1 as [|a rest IH]; intros l2 Hnd x Hin;
    simpl in *; [destruct Hin|].
  inversion Hnd; subst. destruct Hin as [->|Hin].
  - intro Hx. exact (H1 (in_or_app _ _ _ (or_intror Hx))).
  - exact (IH _ H2 _ Hin).
Qed.

(* forced_ids distributes over app. *)
Lemma forced_ids_app : forall l1 l2,
  forced_ids (l1 ++ l2) = forced_ids l1 ++ forced_ids l2.
Proof. intros. unfold forced_ids. apply map_app. Qed.

(* Block structure: forced prefix then mempool suffix. *)
Lemma new_block_structure :
  forall (fpart mpart : list nat),
    (forall x, In x fpart -> is_forced_b x = true) ->
    (forall x, In x mpart -> is_forced_b x = false) ->
    exists k,
      (forall i, i < k -> i < length (fpart ++ mpart) ->
        is_forced_b (nth i (fpart ++ mpart) 0) = true) /\
      (forall i, k <= i -> i < length (fpart ++ mpart) ->
        is_forced_b (nth i (fpart ++ mpart) 0) = false).
Proof.
  intros fpart mpart Hf Hm.
  exists (length fpart). split.
  - intros i Hi Hlen.
    rewrite app_nth1 by lia. apply Hf. apply nth_In. lia.
  - intros i Hi Hlen.
    rewrite app_nth2 by lia. apply Hm. apply nth_In.
    rewrite length_app in Hlen. lia.
Qed.

(* Expired entries in a sorted queue are a prefix of expired_prefix_count.
   [Spec: Sequencer.tla lines 147-156] *)
Lemma expired_in_prefix : forall bn q i,
  sorted_snd q ->
  i < length q ->
  snd (nth i q (0,0)) + ForcedDeadlineBlocks <= bn ->
  i < expired_prefix_count bn q.
Proof.
  intros bn q. induction q as [|[fid sb] rest IH]; intros i Hs Hi Hexp.
  - simpl in Hi; lia.
  - simpl. destruct (Nat.leb (sb + ForcedDeadlineBlocks) bn) eqn:Eleb.
    + destruct i as [|i']; [lia|].
      apply -> Nat.succ_lt_mono. apply IH.
      * exact (sorted_snd_tail _ _ Hs).
      * simpl in Hi; lia.
      * simpl in Hexp; exact Hexp.
    + exfalso.
      assert (Hle : sb + ForcedDeadlineBlocks <= bn).
      { destruct i as [|i']; simpl in Hexp.
        - exact Hexp.
        - assert (Hh := sorted_snd_head_le rest (fid, sb) Hs i').
          simpl in Hi. assert (Hi' : i' < length rest) by lia.
          specialize (Hh Hi'). simpl in Hh. lia. }
      apply Nat.leb_le in Hle. congruence.
Qed.

(* ========================================== *)
(*     SUB-INVARIANT 1: NO DUPLICATES          *)
(* ========================================== *)

Definition nd_inv (s : spec_state) : Prop :=
  NoDup (sp_mempool s ++ forced_ids (sp_fqueue s) ++ included s).

Lemma nd_inv_init : nd_inv spec_init.
Proof. unfold nd_inv, included; simpl; constructor. Qed.

Lemma nd_inv_step : forall s s',
  nd_inv s ->
  (forall x, In x (sp_mempool s ++ forced_ids (sp_fqueue s) ++ included s) ->
    In x (sp_everseen s)) ->
  spec_step s s' -> nd_inv s'.
Proof.
  intros s s' Hnd Hei Hstep.
  inversion Hstep; subst; unfold nd_inv, included in *; simpl.
  - (* SubmitTx: insert tx after mempool *)
    rewrite <- app_assoc.
    apply NoDup_insert; [exact Hnd | intro Hin; exact (H0 (Hei _ Hin))].
  - (* SubmitForcedTx: insert ftx after fqueue *)
    rewrite forced_ids_app. simpl.
    rewrite <- (app_assoc (forced_ids (sp_fqueue s)) [ftx] (concat (sp_blocks s))).
    rewrite (app_assoc (sp_mempool s) (forced_ids (sp_fqueue s))).
    apply NoDup_insert.
    + rewrite <- app_assoc. exact Hnd.
    + rewrite <- app_assoc. intro Hin. exact (H0 (Hei _ Hin)).
  - (* ProduceBlock: NoDup of rearranged list *)
    rewrite concat_app_dist. simpl. rewrite app_nil_r.
    unfold forced_ids in *. rewrite map_drop, map_take.
    set (mp := sp_mempool s) in *.
    set (fids := map fst (sp_fqueue s)) in *.
    set (cbs := concat (sp_blocks s)) in *.
    (* Extract NoDup of parts from Hnd : NoDup (mp ++ fids ++ cbs) *)
    pose proof (NoDup_app_fst _ _ _ Hnd) as Hnd_mp.
    pose proof (NoDup_app_snd _ _ _ Hnd) as Hnd_fc.
    pose proof (NoDup_app_fst _ _ _ Hnd_fc) as Hnd_fids.
    pose proof (NoDup_app_snd _ _ _ Hnd_fc) as Hnd_cbs.
    pose proof (NoDup_disj _ _ _ Hnd) as Hdm_fc.
    pose proof (NoDup_disj _ _ _ Hnd_fc) as Hdf_c.
    assert (Hdm_f : forall x, In x mp -> ~ In x fids).
    { intros x Hx Hf. exact (Hdm_fc x Hx (in_or_app _ _ _ (or_introl Hf))). }
    assert (Hdm_c : forall x, In x mp -> ~ In x cbs).
    { intros x Hx Hc. exact (Hdm_fc x Hx (in_or_app _ _ _ (or_intror Hc))). }
    (* Build NoDup (drop_mp ++ drop_fids ++ (cbs ++ take_fids ++ take_mp)) *)
    apply NoDup_app; [apply NoDup_drop; exact Hnd_mp | |].
    { apply NoDup_app; [apply NoDup_drop; exact Hnd_fids | |].
      { apply NoDup_app; [exact Hnd_cbs | |].
        { apply NoDup_app; [apply NoDup_take; exact Hnd_fids |
                             apply NoDup_take; exact Hnd_mp |].
          intros x Hx Hy.
          exact (Hdm_f x (In_take _ _ _ _ Hy) (In_take _ _ _ _ Hx)). }
        intros x Hx Hy. apply in_app_or in Hy. destruct Hy as [Hy|Hy].
        - exact (Hdf_c x (In_take _ _ _ _ Hy) Hx).
        - exact (Hdm_c x (In_take _ _ _ _ Hy) Hx). }
      intros x Hx Hy. apply in_app_or in Hy. destruct Hy as [Hy|Hy].
      - exact (Hdf_c x (In_drop _ _ _ _ Hx) Hy).
      - apply in_app_or in Hy. destruct Hy as [Hy|Hy].
        + exact (disjoint_take_drop _ nf fids Hnd_fids x Hy Hx).
        + exact (Hdm_f x (In_take _ _ _ _ Hy) (In_drop _ _ _ _ Hx)). }
    intros x Hx Hy. apply in_app_or in Hy. destruct Hy as [Hy|Hy].
    { exact (Hdm_f x (In_drop _ _ _ _ Hx) (In_drop _ _ _ _ Hy)). }
    apply in_app_or in Hy. destruct Hy as [Hy|Hy].
    { exact (Hdm_c x (In_drop _ _ _ _ Hx) Hy). }
    apply in_app_or in Hy. destruct Hy as [Hy|Hy].
    { exact (Hdm_f x (In_drop _ _ _ _ Hx) (In_take _ _ _ _ Hy)). }
    exact (disjoint_take_drop _ nm mp Hnd_mp x Hy Hx).
Qed.

Theorem no_double_inclusion_safe : forall s,
  nd_inv s -> no_double_inclusion s.
Proof.
  intros s Hnd. unfold no_double_inclusion, included, nd_inv in *.
  (* NoDup of the last component follows from NoDup of the full list *)
  induction (sp_mempool s) as [|a rest IH]; simpl in Hnd.
  - induction (forced_ids (sp_fqueue s)) as [|b rest2 IH2]; simpl in Hnd.
    + exact Hnd.
    + inversion Hnd; subst. exact (IH2 H2).
  - inversion Hnd; subst. exact (IH H2).
Qed.

(* ========================================== *)
(*     SUB-INVARIANT 2: TRACKING               *)
(* ========================================== *)

Definition ei_inv (s : spec_state) : Prop :=
  forall x, In x (sp_mempool s ++ forced_ids (sp_fqueue s) ++ included s) ->
    In x (sp_everseen s).

Lemma ei_inv_init : ei_inv spec_init.
Proof. unfold ei_inv, included; simpl; intros; contradiction. Qed.

Lemma ei_inv_step : forall s s',
  ei_inv s -> spec_step s s' -> ei_inv s'.
Proof.
  intros s s' Hei Hstep.
  inversion Hstep; subst; unfold ei_inv, included in *; simpl.
  - (* SubmitTx *)
    intros x Hx. rewrite <- app_assoc in Hx.
    apply in_app_or in Hx. destruct Hx as [Hx|Hx].
    + apply in_or_app; left; apply Hei; apply in_or_app; left; exact Hx.
    + simpl in Hx. destruct Hx as [->|Hx].
      * apply in_or_app; right; apply in_eq.
      * apply in_or_app; left; apply Hei; apply in_or_app; right; exact Hx.
  - (* SubmitForcedTx *)
    intros x Hx. rewrite forced_ids_app in Hx. simpl in Hx.
    rewrite <- (app_assoc (forced_ids (sp_fqueue s))) in Hx.
    rewrite app_assoc in Hx.
    apply in_app_or in Hx. destruct Hx as [Hx|Hx].
    + apply in_app_or in Hx. destruct Hx as [Hx|Hx].
      * apply in_or_app; left; apply Hei; apply in_or_app; left; exact Hx.
      * apply in_or_app; left; apply Hei;
        apply in_or_app; right; apply in_or_app; left; exact Hx.
    + simpl in Hx. destruct Hx as [->|Hx].
      * apply in_or_app; right; apply in_eq.
      * apply in_or_app; left; apply Hei;
        apply in_or_app; right; apply in_or_app; right; exact Hx.
  - (* ProduceBlock *)
    intros x Hx.
    rewrite concat_app_dist in Hx. simpl in Hx. rewrite app_nil_r in Hx.
    apply Hei.
    apply in_app_or in Hx. destruct Hx as [Hx|Hx].
    + apply in_or_app; left; exact (In_drop _ _ _ _ Hx).
    + apply in_app_or in Hx. destruct Hx as [Hx|Hx].
      * apply in_or_app; right; apply in_or_app; left.
        unfold forced_ids in *. rewrite map_drop in Hx.
        exact (In_drop _ _ _ _ Hx).
      * apply in_app_or in Hx. destruct Hx as [Hx|Hx].
        -- apply in_or_app; right; apply in_or_app; right; exact Hx.
        -- apply in_app_or in Hx. destruct Hx as [Hx|Hx].
           ++ apply in_or_app; right; apply in_or_app; left.
              unfold forced_ids in *. rewrite map_take in Hx.
              exact (In_take _ _ _ _ Hx).
           ++ apply in_or_app; left; exact (In_take _ _ _ _ Hx).
Qed.

Theorem included_submitted_safe : forall s,
  ei_inv s -> included_were_submitted s.
Proof.
  intros s Hei x Hx. apply Hei.
  apply in_or_app; right; apply in_or_app; right; exact Hx.
Qed.

(* ========================================== *)
(*     SUB-INVARIANT 3: BLOCK STRUCTURE        *)
(* ========================================== *)

Definition bs_inv (s : spec_state) : Prop :=
  (forall x, In x (sp_mempool s) -> is_forced_b x = false) /\
  (forall x, In x (forced_ids (sp_fqueue s)) -> is_forced_b x = true) /\
  fifo_within_block s.

Lemma bs_inv_init : bs_inv spec_init.
Proof. unfold bs_inv, fifo_within_block; simpl; repeat split; intros; contradiction. Qed.

Lemma bs_inv_step : forall s s',
  bs_inv s -> spec_step s s' -> bs_inv s'.
Proof.
  intros s s' [Htm [Htf Hbs]] Hstep.
  inversion Hstep; subst; unfold bs_inv; repeat split.
  (* SubmitTx *)
  - simpl. intros x Hx; apply in_app_or in Hx;
      destruct Hx as [Hx|[->|[]]]; [exact (Htm _ Hx) | exact H].
  - exact Htf.
  - exact Hbs.
  (* SubmitForcedTx *)
  - exact Htm.
  - simpl. intros x Hx; rewrite forced_ids_app in Hx; simpl in Hx;
      apply in_app_or in Hx;
      destruct Hx as [Hx|[->|[]]]; [exact (Htf _ Hx) | exact H].
  - exact Hbs.
  (* ProduceBlock *)
  - simpl. intros x Hx; apply Htm; exact (In_drop _ _ _ _ Hx).
  - simpl. intros x Hx; apply Htf; unfold forced_ids in *;
      rewrite map_drop in Hx; exact (In_drop _ _ _ _ Hx).
  - unfold fifo_within_block. intros b Hb. simpl sp_blocks in Hb.
    apply in_app_or in Hb. destruct Hb as [Hb|Hb].
    + exact (Hbs _ Hb).
    + destruct Hb as [Heq|[]]. subst b.
      apply new_block_structure.
      * intros x Hx.
        apply In_map_fst in Hx. destruct Hx as [b' Hb'].
        apply In_take in Hb'. apply Htf. apply In_map_fst.
        exists b'. exact Hb'.
      * intros x Hx. apply Htm. exact (In_take _ _ _ _ Hx).
Qed.

Theorem forced_before_mempool_safe : forall s,
  bs_inv s -> forced_before_mempool s.
Proof.
  intros s [_ [_ Hbs]].
  unfold forced_before_mempool. intros b Hb [i [j [Hij [Hj [Hr Hf]]]]].
  destruct (Hbs b Hb) as [k [Hk1 Hk2]].
  assert (Hjk : j < k).
  { destruct (Nat.lt_ge_cases j k); [assumption|].
    rewrite (Hk2 j H Hj) in Hf; discriminate. }
  assert (Hik : i >= k).
  { destruct (Nat.lt_ge_cases i k); [|assumption].
    rewrite (Hk1 i H (Nat.lt_trans _ _ _ Hij Hj)) in Hr; discriminate. }
  lia.
Qed.

Theorem fifo_within_block_safe : forall s,
  bs_inv s -> fifo_within_block s.
Proof. intros s [_ [_ H]]; exact H. Qed.

(* ========================================== *)
(*     SUB-INVARIANT 4: FORCED DEADLINE        *)
(* ========================================== *)

Definition fd_inv (s : spec_state) : Prop :=
  sorted_snd (sp_fqueue s) /\
  (forall ftx sb, In (ftx, sb) (sp_fdeadlines s) ->
    In (ftx, sb) (sp_fqueue s) \/ In ftx (included s)) /\
  (forall ftx sb, In (ftx, sb) (sp_fqueue s) ->
    sb <= sp_blocknum s) /\
  forced_inclusion_deadline s.

Lemma fd_inv_init : fd_inv spec_init.
Proof.
  unfold fd_inv; repeat split; try constructor;
    try (intros; contradiction).
  unfold forced_inclusion_deadline, included; simpl; intros; contradiction.
Qed.

Lemma fd_inv_step : forall s s',
  fd_inv s -> spec_step s s' -> fd_inv s'.
Proof.
  intros s s' [Hsort [Hcons [Hdb Hfd]]] Hstep.
  inversion Hstep; subst; unfold fd_inv; repeat split.
  (* SubmitTx *)
  - exact Hsort.
  - exact Hcons.
  - exact Hdb.
  - exact Hfd.
  (* SubmitForcedTx *)
  - apply sorted_snd_app_single; [exact Hsort|].
    intros [fid sb'] Hin; simpl; exact (Hdb _ _ Hin).
  - intros ftx0 sb0 Hin.
    apply in_app_or in Hin. destruct Hin as [Hin|[Heq|[]]].
    + destruct (Hcons _ _ Hin) as [HQ|HB].
      * left; apply in_or_app; left; exact HQ.
      * right; exact HB.
    + injection Heq; intros; subst.
      left; apply in_or_app; right; simpl; left; reflexivity.
  - intros ftx0 sb0 Hin.
    apply in_app_or in Hin. destruct Hin as [Hin|[Heq|[]]].
    + exact (Hdb _ _ Hin).
    + inversion Heq; subst; auto.
  - unfold forced_inclusion_deadline, included; simpl.
    intros ftx0 sb0 Hin Hgt.
    apply in_app_or in Hin. destruct Hin as [Hin|[Heq|[]]].
    + exact (Hfd _ _ Hin Hgt).
    + injection Heq; intros; subst.
      exfalso; pose proof ForcedDeadlineBlocks_pos; lia.
  (* ProduceBlock *)
  - exact (sorted_snd_drop nf _ Hsort).
  - intros ftx0 sb0 Hin.
    destruct (Hcons _ _ Hin) as [HQ|HB].
    + assert (Hin_td : In (ftx0, sb0)
                        (take nf (sp_fqueue s) ++ drop nf (sp_fqueue s))).
      { rewrite take_drop_id. exact HQ. }
      apply in_app_or in Hin_td. destruct Hin_td as [Htk|Hdk].
      * right. unfold included. simpl.
        rewrite concat_app_dist. simpl. rewrite app_nil_r.
        apply in_or_app. right. apply in_or_app. left.
        apply In_map_fst. exists sb0. exact Htk.
      * left. exact Hdk.
    + right. unfold included. simpl.
      rewrite concat_app_dist. simpl. rewrite app_nil_r.
      apply in_or_app. left. exact HB.
  - simpl. intros ftx0 sb0 Hin.
    assert (Hle := Hdb _ _ (In_drop _ _ _ _ Hin)). lia.
  - (* Forced inclusion deadline -- the key proof *)
    unfold forced_inclusion_deadline, included. simpl.
    rewrite concat_app_dist. simpl. rewrite app_nil_r.
    intros ftx0 sb0 Hin Hgt.
    apply in_or_app.
    assert (Hge : sp_blocknum s >= sb0 + ForcedDeadlineBlocks) by lia.
    destruct (Hcons _ _ Hin) as [HQ|HB].
    + (* ftx0 is in the queue: must be in expired prefix *)
      right. apply in_or_app. left.
      destruct (@In_nth _ (sp_fqueue s) (ftx0, sb0) (0,0) HQ) as [i [Hilen Hnth]].
      assert (Hexp : snd (nth i (sp_fqueue s) (0,0)) + ForcedDeadlineBlocks
                      <= sp_blocknum s).
      { rewrite Hnth; simpl; lia. }
      assert (Hi_epc : i < expired_prefix_count (sp_blocknum s) (sp_fqueue s))
        by (apply expired_in_prefix; assumption).
      assert (Hi_nf : i < nf) by lia.
      apply In_map_fst. exists sb0.
      assert (HtI := nth_In_take _ nf (sp_fqueue s) i (0,0) Hi_nf Hilen).
      rewrite Hnth in HtI. exact HtI.
    + (* ftx0 already in blocks *)
      left. exact HB.
Qed.

Theorem forced_deadline_safe : forall s,
  fd_inv s -> forced_inclusion_deadline s.
Proof. intros s [_ [_ [_ H]]]; exact H. Qed.

(* ========================================== *)
(*     COMBINED INVARIANT AND REACHABILITY     *)
(* ========================================== *)

Definition CombinedInv (s : spec_state) : Prop :=
  nd_inv s /\ ei_inv s /\ bs_inv s /\ fd_inv s.

Theorem combined_inv_init : CombinedInv spec_init.
Proof.
  split; [exact nd_inv_init|].
  split; [exact ei_inv_init|].
  split; [exact bs_inv_init|].
  exact fd_inv_init.
Qed.

Theorem combined_inv_step : forall s s',
  CombinedInv s -> spec_step s s' -> CombinedInv s'.
Proof.
  intros s s' [Hnd [Hei [Hbs Hfd]]] Hstep.
  split; [exact (nd_inv_step _ _ Hnd Hei Hstep)|].
  split; [exact (ei_inv_step _ _ Hei Hstep)|].
  split; [exact (bs_inv_step _ _ Hbs Hstep)|].
  exact (fd_inv_step _ _ Hfd Hstep).
Qed.

Inductive reachable : spec_state -> Prop :=
  | reach_init : reachable spec_init
  | reach_step : forall s s',
      reachable s -> spec_step s s' -> reachable s'.

Theorem combined_inv_reachable : forall s,
  reachable s -> CombinedInv s.
Proof.
  intros s Hr; induction Hr.
  - exact combined_inv_init.
  - exact (combined_inv_step _ _ IHHr H).
Qed.

(* ========================================== *)
(*     FINAL SAFETY THEOREMS                   *)
(* ========================================== *)

Theorem thm_no_double_inclusion : forall s,
  reachable s -> no_double_inclusion s.
Proof.
  intros s Hr.
  exact (no_double_inclusion_safe _ (proj1 (combined_inv_reachable s Hr))).
Qed.

Theorem thm_included_were_submitted : forall s,
  reachable s -> included_were_submitted s.
Proof.
  intros s Hr.
  exact (included_submitted_safe _
    (proj1 (proj2 (combined_inv_reachable s Hr)))).
Qed.

Theorem thm_forced_before_mempool : forall s,
  reachable s -> forced_before_mempool s.
Proof.
  intros s Hr.
  exact (forced_before_mempool_safe _
    (proj1 (proj2 (proj2 (combined_inv_reachable s Hr))))).
Qed.

Theorem thm_fifo_within_block : forall s,
  reachable s -> fifo_within_block s.
Proof.
  intros s Hr.
  exact (fifo_within_block_safe _
    (proj1 (proj2 (proj2 (combined_inv_reachable s Hr))))).
Qed.

Theorem thm_forced_inclusion_deadline : forall s,
  reachable s -> forced_inclusion_deadline s.
Proof.
  intros s Hr.
  exact (forced_deadline_safe _
    (proj2 (proj2 (proj2 (combined_inv_reachable s Hr))))).
Qed.

(* ========================================== *)
(*     IMPLEMENTATION REFINEMENT               *)
(* ========================================== *)

(* Every implementation step corresponds to a valid spec step.
   Proved in Impl.v as refinement_step. Restated here for completeness. *)
Theorem impl_refines_spec : forall is is',
  impl_step is is' ->
  spec_step (map_state is) (map_state is').
Proof. exact refinement_step. Qed.

(* ========================================== *)
(*     VERIFICATION SUMMARY                    *)
(* ========================================== *)

(* All safety properties proved without Admitted:

   STRUCTURAL INVARIANTS (preserved inductively):
     1. nd_inv   -- NoDup across mempool + forced_ids + blocks
     2. ei_inv   -- All active elements tracked in everseen
     3. bs_inv   -- Type constraints + block structure (forced prefix)
     4. fd_inv   -- Sorted queue + conservation + forced deadline

   SAFETY THEOREMS (for all reachable states):
     5. thm_no_double_inclusion      -- No tx in multiple blocks
     6. thm_included_were_submitted  -- Only submitted txs in blocks
     7. thm_forced_before_mempool    -- Forced txs precede mempool
     8. thm_fifo_within_block        -- Forced prefix + mempool suffix
     9. thm_forced_inclusion_deadline -- Expired forced txs included

   REFINEMENT:
    10. impl_refines_spec -- Go impl step -> valid TLA+ spec step

   LIVENESS (stated in Spec.v, not proved -- requires temporal logic):
     EventualInclusion: every submitted tx eventually included.
     Guaranteed by WF_vars(ProduceBlock) in the TLA+ spec.

   Proof Architecture:
     - Modular sub-invariants (nd, ei, bs, fd) proved independently
     - nd_inv: Permutation-based for ProduceBlock, NoDup_insert for submissions
     - fd_inv: sorted_snd + expired_in_prefix for deadline enforcement
     - bs_inv: new_block_structure for forced-before-mempool ordering *)
