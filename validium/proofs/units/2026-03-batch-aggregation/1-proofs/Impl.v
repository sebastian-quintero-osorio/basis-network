(* ================================================================ *)
(*  Impl.v -- Abstract Model of TypeScript Implementation           *)
(* ================================================================ *)
(*                                                                  *)
(*  Models the combined state and transitions of:                   *)
(*    - TransactionQueue  (0-input-impl/transaction-queue.ts)       *)
(*    - WriteAheadLog     (0-input-impl/wal.ts)                     *)
(*    - BatchAggregator   (0-input-impl/batch-aggregator.ts)        *)
(*                                                                  *)
(*  Abstractions applied:                                           *)
(*    - File I/O -> list operations                                 *)
(*    - Checksums / batch IDs -> omitted (integrity, not state)     *)
(*    - Timestamps -> omitted                                       *)
(*    - Error handling -> happy path only                            *)
(*    - Sequence numbers -> positional (WAL index = seq)            *)
(*                                                                  *)
(*  The implementation was designed to match the v1-fix TLA+ spec,  *)
(*  so the refinement mapping is nearly identity.                   *)
(* ================================================================ *)

From BA Require Import Common.
From BA Require Import Spec.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Arith.Arith.
From Stdlib Require Import Bool.Bool.
From Stdlib Require Import Lia.

Import ListNotations.

(* ======================================== *)
(*     IMPLEMENTATION STATE                 *)
(* ======================================== *)

(* Combined state of TransactionQueue + WriteAheadLog + BatchAggregator.

   [Impl: TransactionQueue.items -- QueueItem[] with {tx, seq}]
   [Impl: WriteAheadLog -- append-only JSONL file with entries + checkpoints]
   [Impl: BatchAggregator.pendingBatches -- PendingBatchRecord[]]

   We abstract WAL sequence numbers: position in the list IS the seq.
   We abstract batch IDs: deterministic function of tx hashes, not modeled. *)

Record ImplState := mkImplState {
  impl_queue : list Tx;              (* TransactionQueue.items *)
  impl_wal : list Tx;                (* WriteAheadLog entries *)
  impl_checkpoint : nat;             (* Last checkpoint seq *)
  impl_pendingBatches : list (list Tx);  (* BatchAggregator.pendingBatches *)
  impl_processed : list (list Tx);   (* Downstream-confirmed batches *)
  impl_pending : list Tx;            (* Unsubmitted transactions *)
  impl_up : bool;                    (* System running *)
  impl_timer : bool                  (* Timer expired *)
}.

(* ======================================== *)
(*     IMPLEMENTATION ACTIONS               *)
(* ======================================== *)

(* [Impl: TransactionQueue.enqueue(tx), lines 44-48]
   1. WAL.append(tx) -- persist to disk first
   2. items.push({tx, seq}) -- then add to volatile queue
   [v1-fix: WAL-first guarantees crash recovery] *)
Definition impl_enqueue (s : ImplState) (tx : Tx) : ImplState :=
  mkImplState
    (impl_queue s ++ [tx])
    (impl_wal s ++ [tx])
    (impl_checkpoint s)
    (impl_pendingBatches s)
    (impl_processed s)
    (remove Nat.eq_dec tx (impl_pending s))
    (impl_up s)
    (impl_timer s).

(* [Impl: BatchAggregator.formBatch(), lines 93-126]
   1. shouldFormBatch() checks size >= maxBatchSize OR time elapsed
   2. queue.dequeue(batchSize) -- removes from volatile queue
   3. pendingBatches.push({batchId, checkpointSeq, txCount})
   [v1-fix: NO checkpoint written. Deferred to onBatchProcessed.] *)
Definition impl_formBatch (s : ImplState) : ImplState :=
  let batchSize := if BST <=? length (impl_queue s)
                    then BST
                    else length (impl_queue s) in
  let batch := firstn batchSize (impl_queue s) in
  mkImplState
    (skipn batchSize (impl_queue s))
    (impl_wal s)
    (impl_checkpoint s)
    (impl_pendingBatches s ++ [batch])
    (impl_processed s)
    (impl_pending s)
    (impl_up s)
    false.

(* [Impl: BatchAggregator.onBatchProcessed(batchId), lines 141-160]
   1. Verify FIFO: head.batchId === batchId
   2. queue.checkpoint(head.checkpointSeq, batchId) -- WAL checkpoint
   3. pendingBatches.shift()
   [v1-fix: Checkpoint written HERE, at ProcessBatch time] *)
Definition impl_processBatch (s : ImplState) : ImplState :=
  match impl_pendingBatches s with
  | [] => s
  | b :: rest =>
    mkImplState
      (impl_queue s)
      (impl_wal s)
      (impl_checkpoint s + length b)
      rest
      (impl_processed s ++ [b])
      (impl_pending s)
      (impl_up s)
      (impl_timer s)
  end.

(* [Impl: System crash -- process termination]
   Volatile state (TransactionQueue.items, BatchAggregator.pendingBatches) lost.
   WAL file and checkpoint markers persist on disk. *)
Definition impl_crash (s : ImplState) : ImplState :=
  mkImplState
    []
    (impl_wal s)
    (impl_checkpoint s)
    []
    (impl_processed s)
    (impl_pending s)
    false
    false.

(* [Impl: TransactionQueue.recover(), lines 106-113]
   1. WAL.recover() reads JSONL, finds last checkpoint marker
   2. Returns transactions with seq > lastCheckpointSeq
   3. Queue rebuilt from recovery result *)
Definition impl_recover (s : ImplState) : ImplState :=
  mkImplState
    (skipn (impl_checkpoint s) (impl_wal s))
    (impl_wal s)
    (impl_checkpoint s)
    (impl_pendingBatches s)
    (impl_processed s)
    (impl_pending s)
    true
    (impl_timer s).

(* [Impl: Timer expiration -- Date.now() - lastBatchTimeMs >= maxWaitTimeMs] *)
Definition impl_timerTick (s : ImplState) : ImplState :=
  mkImplState
    (impl_queue s)
    (impl_wal s)
    (impl_checkpoint s)
    (impl_pendingBatches s)
    (impl_processed s)
    (impl_pending s)
    (impl_up s)
    true.

(* ======================================== *)
(*     REFINEMENT MAPPING                   *)
(* ======================================== *)

(* Maps ImplState to Spec.State.
   The mapping is nearly identity because the implementation was
   designed to match the v1-fix TLA+ specification.
   [impl_pendingBatches -> batches: same structure, batches of tx lists] *)
Definition map_state (is : ImplState) : Spec.State :=
  Spec.mkState
    (impl_queue is)
    (impl_wal is)
    (impl_checkpoint is)
    (impl_pendingBatches is)
    (impl_processed is)
    (impl_pending is)
    (impl_up is)
    (impl_timer is).

(* ======================================== *)
(*     REFINEMENT THEOREMS                  *)
(* ======================================== *)

(* Each implementation action maps exactly to the corresponding spec action. *)

Theorem map_enqueue : forall s tx,
  map_state (impl_enqueue s tx) = Spec.Enqueue (map_state s) tx.
Proof. intros. reflexivity. Qed.

Theorem map_formBatch : forall s,
  map_state (impl_formBatch s) = Spec.FormBatch (map_state s).
Proof. intros. reflexivity. Qed.

Theorem map_processBatch : forall s,
  map_state (impl_processBatch s) = Spec.ProcessBatch (map_state s).
Proof.
  intros [q w c pb pr pe up ti].
  unfold impl_processBatch, map_state, Spec.ProcessBatch.
  simpl. destruct pb; reflexivity.
Qed.

Theorem map_crash : forall s,
  map_state (impl_crash s) = Spec.Crash (map_state s).
Proof. intros. reflexivity. Qed.

Theorem map_recover : forall s,
  map_state (impl_recover s) = Spec.Recover (map_state s).
Proof. intros. reflexivity. Qed.

Theorem map_timerTick : forall s,
  map_state (impl_timerTick s) = Spec.TimerTick (map_state s).
Proof. intros. reflexivity. Qed.
