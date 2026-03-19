(* ========================================== *)
(*     Refinement.v -- Verification Proofs     *)
(*     Implementation Refines Specification    *)
(*     zkl2/proofs/units/2026-03-witness-generation *)
(* ========================================== *)

(* This file proves the core safety properties of the Witness Generator:
   1. Completeness          (S1) -- Correct row counts per operation type
   2. Soundness             (S2) -- Every row traces to a valid source entry
   3. RowWidthConsistency   (S3) -- Fixed column counts per table
   4. GlobalCounterMonotonic(S4) -- Counter equals entries processed
   5. DeterminismGuard      (S5) -- Exactly one action enabled per state
   6. SequentialOrder       (S6) -- Source indices ordered within tables

   All theorems proved without Admitted.

   Source: WitnessGeneration.tla (spec),
           generator.rs + arithmetic.rs + storage.rs + call_context.rs (impl) *)

From WG Require Import Common.
From WG Require Import Spec.
From WG Require Import Impl.
From Stdlib Require Import List.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
Import ListNotations.

(* ========================================== *)
(*     COUNT PREFIX LEMMAS                     *)
(* ========================================== *)

(* How count_in_prefix changes when processing one more entry.
   This is the key lemma connecting take (n+1) to take n. *)
Lemma count_take_succ :
  forall (p : op_type -> bool) (n : nat) (e : trace_entry),
  nth_error Trace n = Some e ->
  count_in_prefix p (n + 1) =
    count_in_prefix p n + (if p (entry_op e) then 1 else 0).
Proof.
  intros p n e Hnth. unfold count_in_prefix.
  replace (n + 1) with (S n) by lia.
  rewrite (take_succ_nth_error Trace n e Hnth).
  rewrite map_app, count_pred_app. simpl.
  destruct (p (entry_op e)); lia.
Qed.

(* When an entry does NOT match predicate p, the count is unchanged. *)
Lemma count_unchanged :
  forall (p : op_type -> bool) (n : nat) (e : trace_entry),
  nth_error Trace n = Some e ->
  p (entry_op e) = false ->
  count_in_prefix p (n + 1) = count_in_prefix p n.
Proof.
  intros p n e Hnth Hp.
  rewrite (count_take_succ p n e Hnth). rewrite Hp. lia.
Qed.

(* When an entry DOES match predicate p, the count increments by 1. *)
Lemma count_incremented :
  forall (p : op_type -> bool) (n : nat) (e : trace_entry),
  nth_error Trace n = Some e ->
  p (entry_op e) = true ->
  count_in_prefix p (n + 1) = count_in_prefix p n + 1.
Proof.
  intros p n e Hnth Hp.
  rewrite (count_take_succ p n e Hnth). rewrite Hp. lia.
Qed.

(* ========================================== *)
(*     STRENGTHENED INVARIANT                  *)
(* ========================================== *)

(* The strengthened invariant captures all structural properties needed
   to prove the safety properties as inductive invariants. Each field
   corresponds to a necessary intermediate fact.

   The invariant holds in the initial state and is preserved by every
   step of the next-state relation. *)
Record Inv (s : spec_state) : Prop := mkInv {
  (* I1: Counter tracks index. [S4] *)
  inv_gc : sp_global_counter s = sp_idx s;

  (* I2: Index within bounds. *)
  inv_bound : sp_idx s <= trace_len;

  (* I3: Arithmetic row count matches processed arith ops. [S1] *)
  inv_ac : length (sp_arith_rows s) =
    count_in_prefix is_arith_op (sp_idx s);

  (* I4: Storage row count matches processed storage ops. [S1]
     SLOAD -> 1 row, SSTORE -> 2 rows. *)
  inv_sc : length (sp_storage_rows s) =
    count_in_prefix is_storage_read_op (sp_idx s) +
    2 * count_in_prefix is_storage_write_op (sp_idx s);

  (* I5: Call row count matches processed call ops. [S1] *)
  inv_cc : length (sp_call_rows s) =
    count_in_prefix is_call_op (sp_idx s);

  (* I6: All arithmetic rows have correct width. [S3] *)
  inv_aw : forall r, In r (sp_arith_rows s) ->
    row_width r = ArithColCount;

  (* I7: All storage rows have correct width. [S3] *)
  inv_sw : forall r, In r (sp_storage_rows s) ->
    row_width r = StorageColCount;

  (* I8: All call rows have correct width. [S3] *)
  inv_cw : forall r, In r (sp_call_rows s) ->
    row_width r = CallColCount;

  (* I9: Arithmetic rows are sound -- each traces to a valid arith entry. [S2] *)
  inv_as : forall r, In r (sp_arith_rows s) ->
    row_src_idx r < sp_idx s /\
    exists e, nth_error Trace (row_src_idx r) = Some e /\
              is_arith_op (entry_op e) = true;

  (* I10: Storage rows are sound. [S2] *)
  inv_ss : forall r, In r (sp_storage_rows s) ->
    row_src_idx r < sp_idx s /\
    exists e, nth_error Trace (row_src_idx r) = Some e /\
              (is_storage_read_op (entry_op e) = true \/
               is_storage_write_op (entry_op e) = true);

  (* I11: Call rows are sound. [S2] *)
  inv_cs : forall r, In r (sp_call_rows s) ->
    row_src_idx r < sp_idx s /\
    exists e, nth_error Trace (row_src_idx r) = Some e /\
              is_call_op (entry_op e) = true;

  (* I12: Arithmetic source indices are strictly increasing. [S6] *)
  inv_ao : strictly_increasing (map row_src_idx (sp_arith_rows s));

  (* I13: Storage source indices are non-decreasing. [S6]
     Non-decreasing (not strictly increasing) because SSTORE
     produces 2 rows with the same source index. *)
  inv_so : non_decreasing (map row_src_idx (sp_storage_rows s));

  (* I14: Call source indices are strictly increasing. [S6] *)
  inv_co : strictly_increasing (map row_src_idx (sp_call_rows s));
}.

(* ========================================== *)
(*     INVARIANT: INITIAL STATE                *)
(* ========================================== *)

Theorem Inv_init : Inv spec_init.
Proof.
  unfold spec_init; constructor; simpl;
    try lia; try constructor;
    intros r Hr; contradiction.
Qed.

(* ========================================== *)
(*     INVARIANT: STEP PRESERVATION            *)
(* ========================================== *)

(* Ordering proofs use in_map_iff to extract the source row,
   then soundness to get the index bound. Inlined below. *)

(* Helper tactics for width proofs. *)
Ltac solve_width_unchanged H :=
  exact H.

Ltac solve_width_appended Hwold :=
  intros r Hr; apply in_app_or in Hr; destruct Hr as [Hr | Hr];
  [ exact (Hwold r Hr)
  | simpl in Hr; destruct Hr as [<- | Hr];
    [ simpl; reflexivity
    | destruct Hr as [<- | Hr];
      [ simpl; reflexivity | contradiction ] ] ].

(* Helper tactics for soundness proofs. *)
Ltac solve_sound_unchanged Hsold :=
  intros r Hr; destruct (Hsold r Hr) as [Hlt [e' [Hnth' Hop']]];
  split; [ lia | exists e'; auto ].

Theorem Inv_step : forall s s',
  Inv s -> spec_step s s' -> Inv s'.
Proof.
  intros s s' HI Hstep.
  destruct HI as [Hgc Hbd Hac Hsc Hcc Haw Hsw Hcw Has Hss Hcs Hao Hso Hco].
  inversion Hstep; subst; constructor; simpl.

  (* ================================================ *)
  (* CASE 1: SpProcessArith (BALANCE_CHANGE / NONCE_CHANGE) *)
  (* ================================================ *)

  (* I1: gc = idx *)
  - lia.
  (* I2: bound *)
  - lia.
  (* I3: arith count -- incremented by 1 *)
  - rewrite length_app. simpl.
    rewrite (count_incremented is_arith_op _ e H0 H1). lia.
  (* I4: storage count -- unchanged *)
  - rewrite (count_unchanged is_storage_read_op _ e H0
      (arith_not_sread _ H1)).
    rewrite (count_unchanged is_storage_write_op _ e H0
      (arith_not_swrite _ H1)).
    exact Hsc.
  (* I5: call count -- unchanged *)
  - rewrite (count_unchanged is_call_op _ e H0
      (arith_not_call _ H1)).
    exact Hcc.
  (* I6: arith width -- new row has ArithColCount *)
  - intros r Hr. apply in_app_or in Hr. destruct Hr as [Hr | Hr].
    + exact (Haw r Hr).
    + simpl in Hr. destruct Hr as [<- | []]. simpl. reflexivity.
  (* I7: storage width -- unchanged *)
  - exact Hsw.
  (* I8: call width -- unchanged *)
  - exact Hcw.
  (* I9: arith soundness -- new row points to valid arith entry *)
  - intros r Hr. apply in_app_or in Hr. destruct Hr as [Hr | Hr].
    + destruct (Has r Hr) as [Hlt [e' [Hn' Ho']]].
      split; [lia | exists e'; auto].
    + simpl in Hr. destruct Hr as [<- | []]. simpl.
      split; [lia | exists e; auto].
  (* I10: storage soundness -- unchanged *)
  - solve_sound_unchanged Hss.
  (* I11: call soundness -- unchanged *)
  - solve_sound_unchanged Hcs.
  (* I12: arith order -- append new idx, strictly increasing *)
  - rewrite map_app. simpl.
    apply si_app_single; [exact Hao |].
    intros x Hx. rewrite in_map_iff in Hx.
    destruct Hx as [r [<- Hr]]. exact (proj1 (Has r Hr)).
  (* I13: storage order -- unchanged *)
  - exact Hso.
  (* I14: call order -- unchanged *)
  - exact Hco.

  (* ================================================ *)
  (* CASE 2: SpProcessStorageRead (SLOAD)              *)
  (* ================================================ *)

  (* I1: gc = idx *)
  - lia.
  (* I2: bound *)
  - lia.
  (* I3: arith count -- unchanged *)
  - rewrite (count_unchanged is_arith_op _ e H0
      (sread_not_arith _ H1)).
    exact Hac.
  (* I4: storage count -- read +1, write unchanged *)
  - rewrite length_app. simpl.
    rewrite (count_incremented is_storage_read_op _ e H0 H1).
    rewrite (count_unchanged is_storage_write_op _ e H0
      (sread_not_swrite _ H1)).
    lia.
  (* I5: call count -- unchanged *)
  - rewrite (count_unchanged is_call_op _ e H0
      (sread_not_call _ H1)).
    exact Hcc.
  (* I6: arith width -- unchanged *)
  - exact Haw.
  (* I7: storage width -- new row has StorageColCount *)
  - intros r Hr. apply in_app_or in Hr. destruct Hr as [Hr | Hr].
    + exact (Hsw r Hr).
    + simpl in Hr. destruct Hr as [<- | []]. simpl. reflexivity.
  (* I8: call width -- unchanged *)
  - exact Hcw.
  (* I9: arith soundness -- unchanged *)
  - solve_sound_unchanged Has.
  (* I10: storage soundness -- new row points to valid storage entry *)
  - intros r Hr. apply in_app_or in Hr. destruct Hr as [Hr | Hr].
    + destruct (Hss r Hr) as [Hlt [e' [Hn' Ho']]].
      split; [lia | exists e'; auto].
    + simpl in Hr. destruct Hr as [<- | []]. simpl.
      split; [lia | exists e; auto].
  (* I11: call soundness -- unchanged *)
  - solve_sound_unchanged Hcs.
  (* I12: arith order -- unchanged *)
  - exact Hao.
  (* I13: storage order -- append new idx, non-decreasing *)
  - rewrite map_app. simpl.
    apply nd_app_single; [exact Hso |].
    intros x Hx. rewrite in_map_iff in Hx.
    destruct Hx as [r [<- Hr]].
    assert (Hlt := proj1 (Hss r Hr)). lia.
  (* I14: call order -- unchanged *)
  - exact Hco.

  (* ================================================ *)
  (* CASE 3: SpProcessStorageWrite (SSTORE)            *)
  (* ================================================ *)

  (* I1: gc = idx *)
  - lia.
  (* I2: bound *)
  - lia.
  (* I3: arith count -- unchanged *)
  - rewrite (count_unchanged is_arith_op _ e H0
      (swrite_not_arith _ H1)).
    exact Hac.
  (* I4: storage count -- read unchanged, write +1 (= +2 rows) *)
  - rewrite length_app. simpl.
    rewrite (count_unchanged is_storage_read_op _ e H0
      (swrite_not_sread _ H1)).
    rewrite (count_incremented is_storage_write_op _ e H0 H1).
    lia.
  (* I5: call count -- unchanged *)
  - rewrite (count_unchanged is_call_op _ e H0
      (swrite_not_call _ H1)).
    exact Hcc.
  (* I6: arith width -- unchanged *)
  - exact Haw.
  (* I7: storage width -- two new rows both have StorageColCount *)
  - intros r Hr. apply in_app_or in Hr. destruct Hr as [Hr | Hr].
    + exact (Hsw r Hr).
    + simpl in Hr.
      destruct Hr as [<- | [<- | []]]; simpl; reflexivity.
  (* I8: call width -- unchanged *)
  - exact Hcw.
  (* I9: arith soundness -- unchanged *)
  - solve_sound_unchanged Has.
  (* I10: storage soundness -- two new rows both valid *)
  - intros r Hr. apply in_app_or in Hr. destruct Hr as [Hr | Hr].
    + destruct (Hss r Hr) as [Hlt [e' [Hn' Ho']]].
      split; [lia | exists e'; auto].
    + simpl in Hr. destruct Hr as [<- | [<- | []]].
      * simpl. split; [lia | exists e; split; [assumption | right; assumption]].
      * simpl. split; [lia | exists e; split; [assumption | right; assumption]].
  (* I11: call soundness -- unchanged *)
  - solve_sound_unchanged Hcs.
  (* I12: arith order -- unchanged *)
  - exact Hao.
  (* I13: storage order -- append pair [idx; idx], non-decreasing *)
  - rewrite map_app. simpl.
    apply nd_app_pair; [exact Hso |].
    intros x Hx. rewrite in_map_iff in Hx.
    destruct Hx as [r [<- Hr]].
    assert (Hlt := proj1 (Hss r Hr)). lia.
  (* I14: call order -- unchanged *)
  - exact Hco.

  (* ================================================ *)
  (* CASE 4: SpProcessCall (CALL)                      *)
  (* ================================================ *)

  (* I1: gc = idx *)
  - lia.
  (* I2: bound *)
  - lia.
  (* I3: arith count -- unchanged *)
  - rewrite (count_unchanged is_arith_op _ e H0
      (call_not_arith _ H1)).
    exact Hac.
  (* I4: storage count -- unchanged *)
  - rewrite (count_unchanged is_storage_read_op _ e H0
      (call_not_sread _ H1)).
    rewrite (count_unchanged is_storage_write_op _ e H0
      (call_not_swrite _ H1)).
    exact Hsc.
  (* I5: call count -- incremented by 1 *)
  - rewrite length_app. simpl.
    rewrite (count_incremented is_call_op _ e H0 H1). lia.
  (* I6: arith width -- unchanged *)
  - exact Haw.
  (* I7: storage width -- unchanged *)
  - exact Hsw.
  (* I8: call width -- new row has CallColCount *)
  - intros r Hr. apply in_app_or in Hr. destruct Hr as [Hr | Hr].
    + exact (Hcw r Hr).
    + simpl in Hr. destruct Hr as [<- | []]. simpl. reflexivity.
  (* I9: arith soundness -- unchanged *)
  - solve_sound_unchanged Has.
  (* I10: storage soundness -- unchanged *)
  - solve_sound_unchanged Hss.
  (* I11: call soundness -- new row points to valid call entry *)
  - intros r Hr. apply in_app_or in Hr. destruct Hr as [Hr | Hr].
    + destruct (Hcs r Hr) as [Hlt [e' [Hn' Ho']]].
      split; [lia | exists e'; auto].
    + simpl in Hr. destruct Hr as [<- | []]. simpl.
      split; [lia | exists e; auto].
  (* I12: arith order -- unchanged *)
  - exact Hao.
  (* I13: storage order -- unchanged *)
  - exact Hso.
  (* I14: call order -- append new idx, strictly increasing *)
  - rewrite map_app. simpl.
    apply si_app_single; [exact Hco |].
    intros x Hx. rewrite in_map_iff in Hx.
    destruct Hx as [r [<- Hr]]. exact (proj1 (Hcs r Hr)).

  (* ================================================ *)
  (* CASE 5: SpProcessSkip (LOG)                       *)
  (* ================================================ *)

  (* I1: gc = idx *)
  - lia.
  (* I2: bound *)
  - lia.
  (* I3: arith count -- unchanged *)
  - destruct (not_witness_implies _ H1) as [Hna [Hnsr [Hnsw Hncl]]].
    rewrite (count_unchanged is_arith_op _ e H0 Hna). exact Hac.
  (* I4: storage count -- unchanged *)
  - destruct (not_witness_implies _ H1) as [Hna [Hnsr [Hnsw Hncl]]].
    rewrite (count_unchanged is_storage_read_op _ e H0 Hnsr).
    rewrite (count_unchanged is_storage_write_op _ e H0 Hnsw).
    exact Hsc.
  (* I5: call count -- unchanged *)
  - destruct (not_witness_implies _ H1) as [Hna [Hnsr [Hnsw Hncl]]].
    rewrite (count_unchanged is_call_op _ e H0 Hncl). exact Hcc.
  (* I6-I8: widths unchanged *)
  - exact Haw.
  - exact Hsw.
  - exact Hcw.
  (* I9-I11: soundness -- idx incremented but no new rows *)
  - intros r Hr. destruct (Has r Hr) as [Hlt [e' [Hn' Ho']]].
    split; [lia | exists e'; auto].
  - intros r Hr. destruct (Hss r Hr) as [Hlt [e' [Hn' Ho']]].
    split; [lia | exists e'; auto].
  - intros r Hr. destruct (Hcs r Hr) as [Hlt [e' [Hn' Ho']]].
    split; [lia | exists e'; auto].
  (* I12-I14: ordering unchanged *)
  - exact Hao.
  - exact Hso.
  - exact Hco.
Qed.

(* ========================================== *)
(*     INVARIANT FOR REACHABLE STATES          *)
(* ========================================== *)

Theorem Inv_reachable : forall s,
  reachable s -> Inv s.
Proof.
  intros s Hr; induction Hr.
  - exact Inv_init.
  - exact (Inv_step _ _ IHHr H).
Qed.

(* ========================================== *)
(*     S5: DETERMINISM GUARD                   *)
(* ========================================== *)

(* Proved by exhaustive case analysis on op_type.
   No invariant needed -- this is a property of the type system.
   [Source: WitnessGeneration.tla lines 297-305] *)
Theorem thm_determinism_guard : determinism_guard.
Proof.
  unfold determinism_guard. destruct op; reflexivity.
Qed.

(* ========================================== *)
(*     S4: GLOBAL COUNTER MONOTONICITY         *)
(* ========================================== *)

Theorem thm_global_counter : forall s,
  reachable s -> global_counter_monotonic s.
Proof.
  intros s Hr. unfold global_counter_monotonic.
  exact (inv_gc _ (Inv_reachable s Hr)).
Qed.

(* ========================================== *)
(*     S1: COMPLETENESS                        *)
(* ========================================== *)

Theorem thm_completeness : forall s,
  reachable s -> completeness s.
Proof.
  intros s Hr. unfold completeness.
  destruct (Inv_reachable s Hr) as [_ _ Hac Hsc Hcc _ _ _ _ _ _ _ _ _].
  intro Heq. rewrite Heq in *. auto.
Qed.

(* ========================================== *)
(*     S2: SOUNDNESS                           *)
(* ========================================== *)

Theorem thm_soundness : forall s,
  reachable s -> soundness s.
Proof.
  intros s Hr. unfold soundness.
  destruct (Inv_reachable s Hr) as [_ Hbd _ _ _ _ _ _ Has Hss Hcs _ _ _].
  refine (conj _ (conj _ _)).
  - intros r0 Hin. destruct (Has r0 Hin) as [Hlt Hex].
    split; [lia | exact Hex].
  - intros r0 Hin. destruct (Hss r0 Hin) as [Hlt Hex].
    split; [lia | exact Hex].
  - intros r0 Hin. destruct (Hcs r0 Hin) as [Hlt Hex].
    split; [lia | exact Hex].
Qed.

(* ========================================== *)
(*     S3: ROW WIDTH CONSISTENCY               *)
(* ========================================== *)

Theorem thm_row_width : forall s,
  reachable s -> row_width_consistency s.
Proof.
  intros s Hr. unfold row_width_consistency.
  destruct (Inv_reachable s Hr) as [_ _ _ _ _ Haw Hsw Hcw _ _ _ _ _ _].
  auto.
Qed.

(* ========================================== *)
(*     S6: SEQUENTIAL ORDER                    *)
(* ========================================== *)

Theorem thm_sequential_order : forall s,
  reachable s -> sequential_order s.
Proof.
  intros s Hr. unfold sequential_order.
  destruct (Inv_reachable s Hr) as [_ _ _ _ _ _ _ _ _ _ _ Hao Hso Hco].
  auto.
Qed.

(* ========================================== *)
(*     IMPLEMENTATION REFINEMENT               *)
(* ========================================== *)

(* Every implementation step corresponds to a valid spec step.
   Proved in Impl.v as refinement_step. Restated here for completeness. *)
Theorem impl_refines_spec : forall is is',
  impl_step is is' ->
  spec_step is is'.
Proof. exact refinement_step. Qed.

(* ========================================== *)
(*     VERIFICATION SUMMARY                    *)
(* ========================================== *)

(* All safety properties proved without Admitted:

   STRUCTURAL INVARIANT (preserved inductively):
     I1:  inv_gc    -- Global counter equals index
     I2:  inv_bound -- Index within trace length
     I3:  inv_ac    -- Arithmetic row count correct
     I4:  inv_sc    -- Storage row count correct (reads + 2*writes)
     I5:  inv_cc    -- Call row count correct
     I6:  inv_aw    -- Arithmetic row widths correct
     I7:  inv_sw    -- Storage row widths correct
     I8:  inv_cw    -- Call row widths correct
     I9:  inv_as    -- Arithmetic rows traceable to arith entries
     I10: inv_ss    -- Storage rows traceable to storage entries
     I11: inv_cs    -- Call rows traceable to call entries
     I12: inv_ao    -- Arithmetic source indices strictly increasing
     I13: inv_so    -- Storage source indices non-decreasing
     I14: inv_co    -- Call source indices strictly increasing

   SAFETY THEOREMS (for all reachable states):
     S1: thm_completeness        -- Row counts match op type counts
     S2: thm_soundness           -- Every row traces to valid source
     S3: thm_row_width           -- Column counts consistent per table
     S4: thm_global_counter      -- Counter = entries processed
     S5: thm_determinism_guard   -- Exactly one action enabled
     S6: thm_sequential_order    -- Source indices ordered

   REFINEMENT:
     impl_refines_spec -- Rust dispatch-all-three pattern refines
                          TLA+ exclusive guard pattern

   Proof Architecture:
     - Single strengthened invariant (14 fields) proved inductively
     - 5 cases per step (Arith, StorageRead, StorageWrite, Call, Skip)
     - count_take_succ bridges take(n) to take(n+1) for counting
     - Mutual exclusion lemmas ensure unchanged counts for non-matching ops
     - si_app_single / nd_app_single / nd_app_pair for ordering
     - Determinism proved by case analysis, independent of invariant *)
