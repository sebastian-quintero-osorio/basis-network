(* ================================================================ *)
(*  Refinement.v -- Proof that Implementation Refines Specification *)
(* ================================================================ *)
(*                                                                  *)
(*  Proves that the batch aggregation implementation (Impl.v)       *)
(*  correctly implements BatchAggregation.tla v1-fix (Spec.v).      *)
(*                                                                  *)
(*  Structure:                                                      *)
(*    Part 1: Invariant Initialization                              *)
(*    Part 2: FIFOOrdering Preservation (master invariant)          *)
(*    Part 3: CheckpointConsistency Preservation                    *)
(*    Part 4: DurableConsistency Preservation                       *)
(*    Part 5: Supporting Invariant Preservation                     *)
(*    Part 6: NoLoss Derivation                                     *)
(*    Part 7: Combined Inductive Invariant                          *)
(*                                                                  *)
(*  Key Theorems:                                                   *)
(*    - fifo_recover: crash recovery restores FIFO ordering         *)
(*    - no_loss_derived: NoLoss follows from invariant suite        *)
(*    - all_invariants_preserved: inductive step theorem            *)
(*                                                                  *)
(*  Source Spec: 0-input-spec/BatchAggregation.tla (v1-fix)         *)
(*  Source Impl: 0-input-impl/transaction-queue.ts,                 *)
(*               0-input-impl/wal.ts, 0-input-impl/batch-aggregator.ts *)
(* ================================================================ *)

From BA Require Import Common.
From BA Require Import Spec.
From BA Require Import Impl.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Arith.Arith.
From Stdlib Require Import Bool.Bool.
From Stdlib Require Import Lia.

Import ListNotations.

(* ================================================================ *)
(*  PART 1: INVARIANT INITIALIZATION                                *)
(* ================================================================ *)

(* All invariants hold at the initial state. *)

Theorem fifo_init : forall allTxs,
    Spec.FIFOOrdering (Spec.Init allTxs).
Proof.
  intros allTxs. unfold Spec.FIFOOrdering, Spec.processedTxs, Spec.Init. simpl.
  intros _. reflexivity.
Qed.

Theorem checkpoint_consistency_init : forall allTxs,
    Spec.CheckpointConsistency (Spec.Init allTxs).
Proof.
  intros. unfold Spec.CheckpointConsistency, Spec.processedTxs, Spec.Init. simpl.
  reflexivity.
Qed.

Theorem durable_consistency_init : forall allTxs,
    Spec.DurableConsistency (Spec.Init allTxs).
Proof.
  intros. unfold Spec.DurableConsistency, Spec.processedTxs, Spec.Init. simpl.
  reflexivity.
Qed.

Theorem checkpoint_bound_init : forall allTxs,
    Spec.CheckpointBound (Spec.Init allTxs).
Proof.
  intros. unfold Spec.CheckpointBound, Spec.Init. simpl. lia.
Qed.

Theorem down_state_clean_init : forall allTxs,
    Spec.DownStateClean (Spec.Init allTxs).
Proof.
  intros. unfold Spec.DownStateClean, Spec.Init. simpl. discriminate.
Qed.

Theorem wal_complete_init : forall allTxs,
    Spec.WalComplete (Spec.Init allTxs) allTxs.
Proof.
  intros allTxs. unfold Spec.WalComplete, Spec.Init. simpl.
  intros tx. split.
  - intros H. left. exact H.
  - intros [H | []]. exact H.
Qed.

Theorem batch_size_bound_init : forall allTxs,
    Spec.BatchSizeBound (Spec.Init allTxs).
Proof.
  intros. unfold Spec.BatchSizeBound, Spec.Init. simpl.
  split; intros b [].
Qed.

(* ================================================================ *)
(*  PART 2: FIFO ORDERING PRESERVATION                              *)
(* ================================================================ *)

(* The master structural invariant:
   systemUp => flatten(processed) ++ flatten(batches) ++ queue = wal

   This is the strongest safety property. It implies both
   QueueWalConsistency and (combined with DurableConsistency) NoLoss.

   Proof strategy per action:
   - Enqueue: wal and queue both grow by [tx]. Batches, processed unchanged.
   - FormBatch: queue splits into firstn (-> batch) and skipn (-> new queue).
     Uses firstn_skipn to recombine.
   - ProcessBatch: head of batches moves to processed. Uses flatten_cons
     and app_assoc to reassociate.
   - Crash: systemUp becomes false, so invariant is vacuously true.
   - Recover: uses DurableConsistency to reconstruct FIFO from durable state.
   - TimerTick: only timerExpired changes. *)

Theorem fifo_enqueue : forall s tx,
    Spec.FIFOOrdering s ->
    Spec.canEnqueue s tx ->
    Spec.FIFOOrdering (Spec.Enqueue s tx).
Proof.
  intros s tx Hfifo [Hup _].
  unfold Spec.FIFOOrdering in *.
  unfold Spec.Enqueue, Spec.processedTxs in *. simpl.
  intros Hup'.
  specialize (Hfifo Hup).
  (* Hfifo: flatten (processed s) ++ flatten (batches s) ++ queue s = wal s *)
  (* Goal:  flatten (processed s) ++ flatten (batches s) ++ (queue s ++ [tx])
            = wal s ++ [tx] *)
  rewrite <- Hfifo.
  repeat rewrite <- app_assoc. reflexivity.
Qed.

Theorem fifo_form_batch : forall s,
    Spec.FIFOOrdering s ->
    Spec.canFormBatch s ->
    Spec.FIFOOrdering (Spec.FormBatch s).
Proof.
  intros s Hfifo [Hup _].
  unfold Spec.FIFOOrdering in *.
  unfold Spec.FormBatch, Spec.processedTxs in *. simpl.
  intros Hup'.
  specialize (Hfifo Hup).
  (* Key step: flatten(batches ++ [firstn n queue]) ++ skipn n queue
     = flatten(batches) ++ firstn n queue ++ skipn n queue
     = flatten(batches) ++ queue                                    *)
  rewrite flatten_snoc.
  repeat rewrite <- app_assoc.
  rewrite firstn_skipn.
  exact Hfifo.
Qed.

Theorem fifo_process_batch : forall s,
    Spec.FIFOOrdering s ->
    Spec.canProcessBatch s ->
    Spec.FIFOOrdering (Spec.ProcessBatch s).
Proof.
  intros s Hfifo [Hup Hne].
  unfold Spec.FIFOOrdering in *.
  unfold Spec.ProcessBatch.
  destruct (Spec.batches s) as [| b rest] eqn:Hbat.
  - exfalso. apply Hne. reflexivity.
  - simpl. unfold Spec.processedTxs in *. simpl.
    intros Hup'.
    specialize (Hfifo Hup).
    rewrite flatten_cons in Hfifo.
    rewrite flatten_snoc.
    repeat rewrite <- app_assoc.
    repeat rewrite <- app_assoc in Hfifo.
    exact Hfifo.
Qed.

(* Crash: systemUp becomes false, invariant is vacuously true. *)
Theorem fifo_crash : forall s,
    Spec.FIFOOrdering (Spec.Crash s).
Proof.
  intros s. unfold Spec.FIFOOrdering, Spec.Crash. simpl. discriminate.
Qed.

(* Recover: the critical crash-recovery theorem.
   After crash, DurableConsistency ensures processedTxs is a WAL prefix.
   Recovery replays the WAL suffix into the queue, restoring FIFO ordering.

   Proof strategy:
   1. DownStateClean gives batches = [] after crash.
   2. DurableConsistency gives processedTxs = firstn(cpS, wal).
   3. queue' = skipn(cpS, wal), so processedTxs ++ queue' = wal
      by firstn_skipn. *)
Theorem fifo_recover : forall s,
    Spec.DurableConsistency s ->
    Spec.DownStateClean s ->
    Spec.canRecover s ->
    Spec.FIFOOrdering (Spec.Recover s).
Proof.
  intros s Hdur Hdown Hcan.
  unfold Spec.canRecover in Hcan.
  unfold Spec.DownStateClean in Hdown.
  destruct (Hdown Hcan) as [Hq Hb].
  unfold Spec.FIFOOrdering, Spec.Recover, Spec.processedTxs in *. simpl.
  intros _.
  rewrite Hb. simpl.
  unfold Spec.DurableConsistency, Spec.processedTxs in Hdur.
  rewrite Hdur.
  apply firstn_skipn.
Qed.

(* TimerTick: only timerExpired changes. *)
Theorem fifo_timer_tick : forall s,
    Spec.FIFOOrdering s ->
    Spec.canTimerTick s ->
    Spec.FIFOOrdering (Spec.TimerTick s).
Proof.
  intros s Hfifo [Hup _].
  unfold Spec.FIFOOrdering in *.
  unfold Spec.TimerTick, Spec.processedTxs in *. simpl.
  exact Hfifo.
Qed.

(* ================================================================ *)
(*  PART 3: CHECKPOINT CONSISTENCY PRESERVATION                     *)
(* ================================================================ *)

(* CheckpointConsistency: checkpointSeq = length(processedTxs).
   Only ProcessBatch changes both variables. *)

Theorem checkpoint_enqueue : forall s tx,
    Spec.CheckpointConsistency s ->
    Spec.CheckpointConsistency (Spec.Enqueue s tx).
Proof.
  intros s tx H. unfold Spec.CheckpointConsistency, Spec.processedTxs in *.
  unfold Spec.Enqueue. simpl. exact H.
Qed.

Theorem checkpoint_form_batch : forall s,
    Spec.CheckpointConsistency s ->
    Spec.CheckpointConsistency (Spec.FormBatch s).
Proof.
  intros s H. unfold Spec.CheckpointConsistency, Spec.processedTxs in *.
  unfold Spec.FormBatch. simpl. exact H.
Qed.

Theorem checkpoint_process_batch : forall s,
    Spec.CheckpointConsistency s ->
    Spec.canProcessBatch s ->
    Spec.CheckpointConsistency (Spec.ProcessBatch s).
Proof.
  intros s Hcp [_ Hne].
  unfold Spec.CheckpointConsistency, Spec.processedTxs in *.
  unfold Spec.ProcessBatch.
  destruct (Spec.batches s) as [| b rest] eqn:Hbat.
  - exfalso. apply Hne. reflexivity.
  - simpl. rewrite flatten_snoc. rewrite length_app. lia.
Qed.

Theorem checkpoint_crash : forall s,
    Spec.CheckpointConsistency s ->
    Spec.CheckpointConsistency (Spec.Crash s).
Proof.
  intros s H. unfold Spec.CheckpointConsistency, Spec.processedTxs, Spec.Crash in *.
  simpl. exact H.
Qed.

Theorem checkpoint_recover : forall s,
    Spec.CheckpointConsistency s ->
    Spec.CheckpointConsistency (Spec.Recover s).
Proof.
  intros s H. unfold Spec.CheckpointConsistency, Spec.processedTxs, Spec.Recover in *.
  simpl. exact H.
Qed.

Theorem checkpoint_timer_tick : forall s,
    Spec.CheckpointConsistency s ->
    Spec.CheckpointConsistency (Spec.TimerTick s).
Proof.
  intros s H. unfold Spec.CheckpointConsistency, Spec.processedTxs, Spec.TimerTick in *.
  simpl. exact H.
Qed.

(* ================================================================ *)
(*  PART 4: DURABLE CONSISTENCY PRESERVATION                        *)
(* ================================================================ *)

(* DurableConsistency: processedTxs = firstn(checkpointSeq, wal).
   Only involves durable variables. Crash/Recover do not change them.
   ProcessBatch extends both processedTxs and checkpointSeq together. *)

Theorem durable_enqueue : forall s tx,
    Spec.DurableConsistency s ->
    Spec.CheckpointBound s ->
    Spec.DurableConsistency (Spec.Enqueue s tx).
Proof.
  intros s tx Hdur Hbound.
  unfold Spec.DurableConsistency, Spec.processedTxs in *.
  unfold Spec.Enqueue. simpl.
  unfold Spec.CheckpointBound in Hbound.
  rewrite firstn_app_le by exact Hbound.
  exact Hdur.
Qed.

Theorem durable_form_batch : forall s,
    Spec.DurableConsistency s ->
    Spec.DurableConsistency (Spec.FormBatch s).
Proof.
  intros s H. unfold Spec.DurableConsistency, Spec.processedTxs in *.
  unfold Spec.FormBatch. simpl. exact H.
Qed.

(* ProcessBatch: the critical case.
   Uses FIFOOrdering to establish that processedTxs ++ b is a WAL prefix. *)
Theorem durable_process_batch : forall s,
    Spec.DurableConsistency s ->
    Spec.FIFOOrdering s ->
    Spec.CheckpointConsistency s ->
    Spec.canProcessBatch s ->
    Spec.DurableConsistency (Spec.ProcessBatch s).
Proof.
  intros s Hdur Hfifo Hcp [Hup Hne].
  unfold Spec.DurableConsistency, Spec.processedTxs in *.
  unfold Spec.ProcessBatch.
  destruct (Spec.batches s) as [| b rest] eqn:Hbat.
  - exfalso. apply Hne. reflexivity.
  - simpl.
    rewrite flatten_snoc.
    unfold Spec.FIFOOrdering in Hfifo.
    specialize (Hfifo Hup).
    unfold Spec.processedTxs in Hfifo.
    rewrite Hbat in Hfifo. rewrite flatten_cons in Hfifo.
    unfold Spec.CheckpointConsistency, Spec.processedTxs in Hcp.
    (* Hfifo: flatten (processed s) ++ (b ++ flatten rest) ++ queue s = wal s
       Hcp:   checkpointSeq s = length (flatten (processed s))
       Goal:  flatten (processed s) ++ b =
              firstn (checkpointSeq s + length b) (wal s) *)
    rewrite Hcp.
    rewrite <- Hfifo.
    rewrite <- length_app.
    replace (flatten (Spec.processed s) ++ (b ++ flatten rest) ++ Spec.queue s)
      with ((flatten (Spec.processed s) ++ b) ++ (flatten rest ++ Spec.queue s))
      by (repeat rewrite <- app_assoc; reflexivity).
    rewrite firstn_exact. reflexivity.
Qed.

Theorem durable_crash : forall s,
    Spec.DurableConsistency s ->
    Spec.DurableConsistency (Spec.Crash s).
Proof.
  intros s H. unfold Spec.DurableConsistency, Spec.processedTxs, Spec.Crash in *.
  simpl. exact H.
Qed.

Theorem durable_recover : forall s,
    Spec.DurableConsistency s ->
    Spec.DurableConsistency (Spec.Recover s).
Proof.
  intros s H. unfold Spec.DurableConsistency, Spec.processedTxs, Spec.Recover in *.
  simpl. exact H.
Qed.

Theorem durable_timer_tick : forall s,
    Spec.DurableConsistency s ->
    Spec.DurableConsistency (Spec.TimerTick s).
Proof.
  intros s H. unfold Spec.DurableConsistency, Spec.processedTxs, Spec.TimerTick in *.
  simpl. exact H.
Qed.

(* ================================================================ *)
(*  PART 5: SUPPORTING INVARIANT PRESERVATION                       *)
(* ================================================================ *)

(* --- CheckpointBound --- *)

Theorem bound_enqueue : forall s tx,
    Spec.CheckpointBound s ->
    Spec.CheckpointBound (Spec.Enqueue s tx).
Proof.
  intros s tx H. unfold Spec.CheckpointBound in *.
  unfold Spec.Enqueue. simpl. rewrite length_app. simpl. lia.
Qed.

Theorem bound_form_batch : forall s,
    Spec.CheckpointBound s ->
    Spec.CheckpointBound (Spec.FormBatch s).
Proof.
  intros s H. unfold Spec.CheckpointBound in *.
  unfold Spec.FormBatch. simpl. exact H.
Qed.

Theorem bound_process_batch : forall s,
    Spec.CheckpointBound s ->
    Spec.CheckpointConsistency s ->
    Spec.FIFOOrdering s ->
    Spec.canProcessBatch s ->
    Spec.CheckpointBound (Spec.ProcessBatch s).
Proof.
  intros s Hbound Hcp Hfifo [Hup Hne].
  unfold Spec.CheckpointBound in *.
  unfold Spec.ProcessBatch.
  destruct (Spec.batches s) as [| b rest] eqn:Hbat.
  - exfalso. apply Hne. reflexivity.
  - simpl.
    unfold Spec.FIFOOrdering in Hfifo.
    specialize (Hfifo Hup).
    unfold Spec.processedTxs in Hfifo.
    rewrite Hbat in Hfifo. rewrite flatten_cons in Hfifo.
    unfold Spec.CheckpointConsistency, Spec.processedTxs in Hcp.
    assert (Hlen : length (Spec.wal s) =
                   length (flatten (Spec.processed s)) +
                   length b + length (flatten rest) +
                   length (Spec.queue s)).
    { rewrite <- Hfifo. repeat rewrite length_app. lia. }
    lia.
Qed.

Theorem bound_crash : forall s,
    Spec.CheckpointBound s ->
    Spec.CheckpointBound (Spec.Crash s).
Proof.
  intros s H. unfold Spec.CheckpointBound, Spec.Crash in *. simpl. exact H.
Qed.

Theorem bound_recover : forall s,
    Spec.CheckpointBound s ->
    Spec.CheckpointBound (Spec.Recover s).
Proof.
  intros s H. unfold Spec.CheckpointBound, Spec.Recover in *. simpl. exact H.
Qed.

Theorem bound_timer_tick : forall s,
    Spec.CheckpointBound s ->
    Spec.CheckpointBound (Spec.TimerTick s).
Proof.
  intros s H. unfold Spec.CheckpointBound, Spec.TimerTick in *. simpl. exact H.
Qed.

(* --- DownStateClean --- *)

Theorem down_clean_enqueue : forall s tx,
    Spec.canEnqueue s tx ->
    Spec.DownStateClean (Spec.Enqueue s tx).
Proof.
  intros s tx [Hup _].
  unfold Spec.DownStateClean, Spec.Enqueue. simpl.
  intros Habs. congruence.
Qed.

Theorem down_clean_form_batch : forall s,
    Spec.canFormBatch s ->
    Spec.DownStateClean (Spec.FormBatch s).
Proof.
  intros s [Hup _].
  unfold Spec.DownStateClean, Spec.FormBatch. simpl.
  intros Habs. congruence.
Qed.

Theorem down_clean_process_batch : forall s,
    Spec.canProcessBatch s ->
    Spec.DownStateClean (Spec.ProcessBatch s).
Proof.
  intros s [Hup _].
  unfold Spec.DownStateClean, Spec.ProcessBatch.
  destruct (Spec.batches s); simpl; intros Habs; congruence.
Qed.

Theorem down_clean_crash : forall s,
    Spec.DownStateClean (Spec.Crash s).
Proof.
  intros s. unfold Spec.DownStateClean, Spec.Crash. simpl. auto.
Qed.

Theorem down_clean_recover : forall s,
    Spec.DownStateClean (Spec.Recover s).
Proof.
  intros s. unfold Spec.DownStateClean, Spec.Recover. simpl. discriminate.
Qed.

Theorem down_clean_timer_tick : forall s,
    Spec.canTimerTick s ->
    Spec.DownStateClean (Spec.TimerTick s).
Proof.
  intros s [Hup _].
  unfold Spec.DownStateClean, Spec.TimerTick. simpl.
  intros Habs. congruence.
Qed.

(* --- WalComplete --- *)

Theorem wal_complete_enqueue : forall s tx allTxs,
    Spec.WalComplete s allTxs ->
    Spec.canEnqueue s tx ->
    Spec.WalComplete (Spec.Enqueue s tx) allTxs.
Proof.
  intros s tx allTxs Hwc [Hup Hin].
  unfold Spec.WalComplete in *. unfold Spec.Enqueue. simpl.
  intros tx'. split.
  - (* Forward: tx' in allTxs -> tx' in pending' \/ tx' in wal' *)
    intros Htx.
    apply Hwc in Htx. destruct Htx as [Hpend | Hwal].
    + (* tx' was in pending *)
      destruct (Nat.eq_dec tx' tx) as [Heq | Hneq].
      * (* tx' = tx: now in wal *)
        right. subst. apply in_app_iff. right. simpl. auto.
      * (* tx' <> tx: still in pending after remove *)
        left. apply in_remove_neq; assumption.
    + (* tx' was in wal: still in wal (wal grows) *)
      right. apply in_app_iff. left. exact Hwal.
  - (* Backward: tx' in pending' \/ tx' in wal' -> tx' in allTxs *)
    intros [Hpend | Hwal].
    + (* tx' in remove(tx, pending) -> tx' in pending -> tx' in allTxs *)
      apply Hwc. left. exact (remove_in_orig _ _ _ Hpend).
    + (* tx' in wal ++ [tx] *)
      apply in_app_iff in Hwal. destruct Hwal as [Hwal | Heq].
      * apply Hwc. right. exact Hwal.
      * (* tx' = tx: tx was in pending -> tx in allTxs *)
        simpl in Heq. destruct Heq as [Heq | []].
        subst. apply Hwc. left. exact Hin.
Qed.

Theorem wal_complete_form_batch : forall s allTxs,
    Spec.WalComplete s allTxs ->
    Spec.WalComplete (Spec.FormBatch s) allTxs.
Proof.
  intros s allTxs H. unfold Spec.WalComplete in *.
  unfold Spec.FormBatch. simpl. exact H.
Qed.

Theorem wal_complete_process_batch : forall s allTxs,
    Spec.WalComplete s allTxs ->
    Spec.WalComplete (Spec.ProcessBatch s) allTxs.
Proof.
  intros s allTxs H. unfold Spec.WalComplete in *.
  unfold Spec.ProcessBatch.
  destruct (Spec.batches s); simpl; exact H.
Qed.

Theorem wal_complete_crash : forall s allTxs,
    Spec.WalComplete s allTxs ->
    Spec.WalComplete (Spec.Crash s) allTxs.
Proof.
  intros s allTxs H. unfold Spec.WalComplete in *.
  unfold Spec.Crash. simpl. exact H.
Qed.

Theorem wal_complete_recover : forall s allTxs,
    Spec.WalComplete s allTxs ->
    Spec.WalComplete (Spec.Recover s) allTxs.
Proof.
  intros s allTxs H. unfold Spec.WalComplete in *.
  unfold Spec.Recover. simpl. exact H.
Qed.

Theorem wal_complete_timer_tick : forall s allTxs,
    Spec.WalComplete s allTxs ->
    Spec.WalComplete (Spec.TimerTick s) allTxs.
Proof.
  intros s allTxs H. unfold Spec.WalComplete in *.
  unfold Spec.TimerTick. simpl. exact H.
Qed.

(* --- BatchSizeBound --- *)

Theorem bsb_enqueue : forall s tx,
    Spec.BatchSizeBound s ->
    Spec.BatchSizeBound (Spec.Enqueue s tx).
Proof.
  intros s tx [Hb Hp]. unfold Spec.BatchSizeBound in *.
  unfold Spec.Enqueue. simpl. auto.
Qed.

Theorem bsb_form_batch : forall s,
    Spec.BatchSizeBound s ->
    Spec.canFormBatch s ->
    Spec.BatchSizeBound (Spec.FormBatch s).
Proof.
  intros s [Hb Hp] [Hup _].
  unfold Spec.BatchSizeBound in *.
  unfold Spec.FormBatch. simpl.
  split.
  - intros b' Hin.
    apply in_app_iff in Hin. destruct Hin as [Hin | [Heq | []]].
    + apply Hb. exact Hin.
    + subst.
      pose proof (length_firstn_le
        (if BST <=? length (Spec.queue s) then BST
         else length (Spec.queue s)) (Spec.queue s)) as Hle.
      destruct (BST <=? length (Spec.queue s)) eqn:Hge.
      * lia.
      * apply Nat.leb_gt in Hge. lia.
  - exact Hp.
Qed.

Theorem bsb_process_batch : forall s,
    Spec.BatchSizeBound s ->
    Spec.canProcessBatch s ->
    Spec.BatchSizeBound (Spec.ProcessBatch s).
Proof.
  intros s [Hb Hp] [_ Hne].
  unfold Spec.BatchSizeBound in *.
  unfold Spec.ProcessBatch.
  destruct (Spec.batches s) as [| b rest] eqn:Hbat.
  - exfalso. apply Hne. reflexivity.
  - simpl. split.
    + intros b' Hin. apply Hb. right. exact Hin.
    + intros b' Hin. apply in_app_iff in Hin.
      destruct Hin as [Hin | [Heq | []]].
      * apply Hp. exact Hin.
      * subst. apply Hb. left. reflexivity.
Qed.

Theorem bsb_crash : forall s,
    Spec.BatchSizeBound s ->
    Spec.BatchSizeBound (Spec.Crash s).
Proof.
  intros s [Hb Hp]. unfold Spec.BatchSizeBound, Spec.Crash. simpl.
  split.
  - intros b [].
  - exact Hp.
Qed.

Theorem bsb_recover : forall s,
    Spec.BatchSizeBound s ->
    Spec.BatchSizeBound (Spec.Recover s).
Proof.
  intros s H. unfold Spec.BatchSizeBound in *.
  unfold Spec.Recover. simpl. exact H.
Qed.

Theorem bsb_timer_tick : forall s,
    Spec.BatchSizeBound s ->
    Spec.BatchSizeBound (Spec.TimerTick s).
Proof.
  intros s H. unfold Spec.BatchSizeBound in *.
  unfold Spec.TimerTick. simpl. exact H.
Qed.

(* ================================================================ *)
(*  PART 6: NO LOSS DERIVATION                                      *)
(* ================================================================ *)

(* NoLoss: every tx in AllTxs is in exactly one of:
   - pending (not yet enqueued)
   - uncommitted WAL (entries after checkpoint)
   - processedTxs (flatten of processed batches)

   Derivation from:
   - WalComplete: AllTxs = pending U wal
   - DurableConsistency: processedTxs = firstn(cpS, wal)
   - CheckpointBound: cpS <= length(wal)

   The WAL splits into:
     wal = firstn(cpS, wal) ++ skipn(cpS, wal)
         = processedTxs     ++ uncommitted

   So: AllTxs = pending U wal
              = pending U processedTxs U uncommitted *)

Theorem no_loss_derived : forall s allTxs,
    Spec.WalComplete s allTxs ->
    Spec.DurableConsistency s ->
    Spec.CheckpointBound s ->
    Spec.NoLoss s allTxs.
Proof.
  intros s allTxs Hwc Hdur Hbound.
  unfold Spec.NoLoss, Spec.WalComplete in *.
  unfold Spec.uncommitted.
  intros tx. split.
  - (* Forward: tx in allTxs -> tx in pending \/ uncommitted \/ processed *)
    intros Htx.
    apply Hwc in Htx. destruct Htx as [Hpend | Hwal].
    + left. exact Hpend.
    + (* tx in wal: either in firstn(cpS, wal) or skipn(cpS, wal) *)
      assert (Hsplit : Spec.wal s =
                firstn (Spec.checkpointSeq s) (Spec.wal s) ++
                skipn (Spec.checkpointSeq s) (Spec.wal s))
        by (symmetry; apply firstn_skipn).
      rewrite Hsplit in Hwal.
      apply in_app_iff in Hwal. destruct Hwal as [Hfirst | Hskip].
      * (* tx in firstn = processedTxs *)
        unfold Spec.DurableConsistency, Spec.processedTxs in Hdur.
        right. right. rewrite <- Hdur in Hfirst. exact Hfirst.
      * (* tx in skipn = uncommitted *)
        right. left. exact Hskip.
  - (* Backward: tx in pending \/ uncommitted \/ processed -> tx in allTxs *)
    intros [Hpend | [Huncom | Hproc]].
    + apply Hwc. left. exact Hpend.
    + apply Hwc. right.
      assert (Hsplit : Spec.wal s =
                firstn (Spec.checkpointSeq s) (Spec.wal s) ++
                skipn (Spec.checkpointSeq s) (Spec.wal s))
        by (symmetry; apply firstn_skipn).
      rewrite Hsplit. apply in_app_iff. right. exact Huncom.
    + apply Hwc. right.
      unfold Spec.DurableConsistency, Spec.processedTxs in Hdur.
      assert (Hsplit : Spec.wal s =
                firstn (Spec.checkpointSeq s) (Spec.wal s) ++
                skipn (Spec.checkpointSeq s) (Spec.wal s))
        by (symmetry; apply firstn_skipn).
      rewrite Hsplit. apply in_app_iff. left.
      rewrite <- Hdur. exact Hproc.
Qed.

(* QueueWalConsistency is derivable from FIFOOrdering + DurableConsistency. *)
Theorem qwc_derived : forall s,
    Spec.FIFOOrdering s ->
    Spec.DurableConsistency s ->
    Spec.QueueWalConsistency s.
Proof.
  intros s Hfifo Hdur.
  unfold Spec.QueueWalConsistency, Spec.uncommitted.
  intros Hup.
  unfold Spec.FIFOOrdering in Hfifo. specialize (Hfifo Hup).
  unfold Spec.DurableConsistency, Spec.processedTxs in Hdur.
  unfold Spec.processedTxs in Hfifo. rewrite Hdur in Hfifo.
  (* Hfifo: firstn cpS (wal s) ++ flatten (batches s) ++ queue s = wal s *)
  pose proof (firstn_skipn (Spec.checkpointSeq s) (Spec.wal s)) as Hsplit.
  (* Hsplit: firstn cpS (wal s) ++ skipn cpS (wal s) = wal s *)
  apply (app_inv_head (firstn (Spec.checkpointSeq s) (Spec.wal s))).
  transitivity (Spec.wal s).
  - exact Hfifo.
  - symmetry. exact Hsplit.
Qed.

(* ================================================================ *)
(*  PART 7: COMBINED INDUCTIVE INVARIANT                            *)
(* ================================================================ *)

(* The full invariant suite for inductive reasoning. *)
Definition Invariants (s : Spec.State) (allTxs : list Tx) : Prop :=
  Spec.FIFOOrdering s /\
  Spec.CheckpointConsistency s /\
  Spec.DurableConsistency s /\
  Spec.CheckpointBound s /\
  Spec.DownStateClean s /\
  Spec.WalComplete s allTxs /\
  Spec.BatchSizeBound s.

(* All invariants hold at initialization. *)
Theorem all_invariants_init : forall allTxs,
    Invariants (Spec.Init allTxs) allTxs.
Proof.
  intros. unfold Invariants.
  exact (conj (fifo_init allTxs)
    (conj (checkpoint_consistency_init allTxs)
    (conj (durable_consistency_init allTxs)
    (conj (checkpoint_bound_init allTxs)
    (conj (down_state_clean_init allTxs)
    (conj (wal_complete_init allTxs)
          (batch_size_bound_init allTxs))))))).
Qed.

(* All invariants are preserved by every action. *)
Theorem all_invariants_preserved : forall s s' allTxs,
    Invariants s allTxs ->
    Spec.Step s s' ->
    Invariants s' allTxs.
Proof.
  intros s s' allTxs HI Hstep.
  destruct HI as [Hfifo [Hcp [Hdur [Hbound [Hdown [Hwc Hbsb]]]]]].
  unfold Invariants.
  destruct Hstep.
  - (* Enqueue *)
    exact (conj (fifo_enqueue s tx Hfifo H)
      (conj (checkpoint_enqueue s tx Hcp)
      (conj (durable_enqueue s tx Hdur Hbound)
      (conj (bound_enqueue s tx Hbound)
      (conj (down_clean_enqueue s tx H)
      (conj (wal_complete_enqueue s tx allTxs Hwc H)
            (bsb_enqueue s tx Hbsb))))))).
  - (* FormBatch *)
    exact (conj (fifo_form_batch s Hfifo H)
      (conj (checkpoint_form_batch s Hcp)
      (conj (durable_form_batch s Hdur)
      (conj (bound_form_batch s Hbound)
      (conj (down_clean_form_batch s H)
      (conj (wal_complete_form_batch s allTxs Hwc)
            (bsb_form_batch s Hbsb H))))))).
  - (* ProcessBatch *)
    exact (conj (fifo_process_batch s Hfifo H)
      (conj (checkpoint_process_batch s Hcp H)
      (conj (durable_process_batch s Hdur Hfifo Hcp H)
      (conj (bound_process_batch s Hbound Hcp Hfifo H)
      (conj (down_clean_process_batch s H)
      (conj (wal_complete_process_batch s allTxs Hwc)
            (bsb_process_batch s Hbsb H))))))).
  - (* Crash *)
    exact (conj (fifo_crash s)
      (conj (checkpoint_crash s Hcp)
      (conj (durable_crash s Hdur)
      (conj (bound_crash s Hbound)
      (conj (down_clean_crash s)
      (conj (wal_complete_crash s allTxs Hwc)
            (bsb_crash s Hbsb))))))).
  - (* Recover *)
    exact (conj (fifo_recover s Hdur Hdown H)
      (conj (checkpoint_recover s Hcp)
      (conj (durable_recover s Hdur)
      (conj (bound_recover s Hbound)
      (conj (down_clean_recover s)
      (conj (wal_complete_recover s allTxs Hwc)
            (bsb_recover s Hbsb))))))).
  - (* TimerTick *)
    exact (conj (fifo_timer_tick s Hfifo H)
      (conj (checkpoint_timer_tick s Hcp)
      (conj (durable_timer_tick s Hdur)
      (conj (bound_timer_tick s Hbound)
      (conj (down_clean_timer_tick s H)
      (conj (wal_complete_timer_tick s allTxs Hwc)
            (bsb_timer_tick s Hbsb))))))).
Qed.

(* NoLoss holds for all reachable states. *)
Corollary no_loss_reachable : forall s allTxs,
    Invariants s allTxs ->
    Spec.NoLoss s allTxs.
Proof.
  intros s allTxs [_ [_ [Hdur [Hbound [_ [Hwc _]]]]]].
  exact (no_loss_derived s allTxs Hwc Hdur Hbound).
Qed.

(* QueueWalConsistency holds for all reachable states. *)
Corollary qwc_reachable : forall s allTxs,
    Invariants s allTxs ->
    Spec.QueueWalConsistency s.
Proof.
  intros s allTxs [Hfifo [_ [Hdur _]]].
  exact (qwc_derived s Hfifo Hdur).
Qed.

(* ================================================================ *)
(*  SUMMARY OF VERIFIED THEOREMS                                    *)
(* ================================================================ *)

(* REFINEMENT MAPPING (Impl -> Spec):
   1. map_enqueue:       impl_enqueue    = Spec.Enqueue     PROVED (Qed)
   2. map_formBatch:     impl_formBatch  = Spec.FormBatch   PROVED (Qed)
   3. map_processBatch:  impl_processBatch = Spec.ProcessBatch PROVED (Qed)
   4. map_crash:         impl_crash      = Spec.Crash       PROVED (Qed)
   5. map_recover:       impl_recover    = Spec.Recover     PROVED (Qed)
   6. map_timerTick:     impl_timerTick  = Spec.TimerTick   PROVED (Qed)

   FIFO ORDERING (master invariant):
   7.  fifo_init:            Init satisfies FIFOOrdering       PROVED (Qed)
   8.  fifo_enqueue:         Enqueue preserves FIFOOrdering    PROVED (Qed)
   9.  fifo_form_batch:      FormBatch preserves FIFOOrdering  PROVED (Qed)
   10. fifo_process_batch:   ProcessBatch preserves FIFO       PROVED (Qed)
   11. fifo_crash:           Crash preserves FIFO (vacuous)    PROVED (Qed)
   12. fifo_recover:         Recover restores FIFO             PROVED (Qed)
   13. fifo_timer_tick:      TimerTick preserves FIFO          PROVED (Qed)

   CHECKPOINT CONSISTENCY:
   14-19. checkpoint_* for all 6 actions                       PROVED (Qed)

   DURABLE CONSISTENCY:
   20-25. durable_* for all 6 actions                          PROVED (Qed)

   SUPPORTING INVARIANTS:
   26-31. bound_* (CheckpointBound) for all 6 actions          PROVED (Qed)
   32-37. down_clean_* (DownStateClean) for all 6 actions      PROVED (Qed)
   38-43. wal_complete_* (WalComplete) for all 6 actions       PROVED (Qed)
   44-49. bsb_* (BatchSizeBound) for all 6 actions             PROVED (Qed)

   DERIVED PROPERTIES:
   50. no_loss_derived:      NoLoss from invariant suite       PROVED (Qed)
   51. qwc_derived:          QueueWalConsistency from FIFO     PROVED (Qed)

   COMBINED INVARIANT:
   52. all_invariants_init:      Init satisfies all invariants PROVED (Qed)
   53. all_invariants_preserved: Step preserves all invariants PROVED (Qed)
   54. no_loss_reachable:        NoLoss for reachable states   PROVED (Qed)
   55. qwc_reachable:            QWC for reachable states      PROVED (Qed)

   AXIOM TRUST BASE:
   - bst_positive: BST > 0

   PRECONDITIONS:
   - All actions guarded by canXxx preconditions matching TLA+ spec *)
