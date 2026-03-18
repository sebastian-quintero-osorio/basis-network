(* ================================================================ *)
(*  Spec.v -- Faithful Translation of BatchAggregation.tla (v1-fix) *)
(* ================================================================ *)
(*                                                                  *)
(*  Translates the TLA+ specification into Coq inductive types,     *)
(*  record types, and propositions.                                 *)
(*                                                                  *)
(*  Source: 0-input-spec/BatchAggregation.tla (338 lines)           *)
(*  Every definition is tagged with the source TLA+ line number.    *)
(* ================================================================ *)

From BA Require Import Common.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Arith.Arith.
From Stdlib Require Import Bool.Bool.
From Stdlib Require Import Lia.

Import ListNotations.

(* ======================================== *)
(*     STATE                                *)
(* ======================================== *)

(* [Spec: VARIABLES, lines 42-51] *)
Record State := mkState {
  queue : list Tx;            (* In-memory FIFO queue -- volatile *)
  wal : list Tx;              (* Persisted WAL entries -- durable *)
  checkpointSeq : nat;        (* Highest committed WAL seq -- durable *)
  batches : list (list Tx);   (* Formed but unprocessed -- volatile *)
  processed : list (list Tx); (* Downstream-consumed -- durable *)
  pending : list Tx;          (* Not yet enqueued *)
  systemUp : bool;            (* TRUE = running *)
  timerExpired : bool         (* Timer flag *)
}.

(* ======================================== *)
(*     HELPERS                              *)
(* ======================================== *)

(* [Spec: UncommittedWalTxSet, lines 82-83]
   Elements of wal after checkpointSeq.
   TLA+ SubSeq(wal, checkpointSeq + 1, Len(wal)) is 1-indexed.
   Coq skipn is 0-indexed: skipn n l drops first n elements. *)
Definition uncommitted (s : State) : list Tx :=
  skipn (checkpointSeq s) (wal s).

(* [Spec: ProcessedTxSet, lines 69-72]
   Flatten of all processed batches. *)
Definition processedTxs (s : State) : list Tx :=
  flatten (processed s).

(* ======================================== *)
(*     INITIAL STATE                        *)
(* ======================================== *)

(* [Spec: Init, lines 104-112] *)
Definition Init (allTxs : list Tx) : State :=
  mkState [] [] 0 [] [] allTxs true false.

(* ======================================== *)
(*     ACTIONS                              *)
(* ======================================== *)

(* [Spec: Enqueue(tx), lines 123-129]
   WAL-first: append to wal AND queue, remove from pending. *)
Definition Enqueue (s : State) (tx : Tx) : State :=
  mkState
    (queue s ++ [tx])
    (wal s ++ [tx])
    (checkpointSeq s)
    (batches s)
    (processed s)
    (remove Nat.eq_dec tx (pending s))
    (systemUp s)
    (timerExpired s).

(* [Spec: FormBatch, lines 142-153]
   Dequeue min(len(queue), BST) txs from front, form batch.
   NO checkpoint advancement (v1-fix). *)
Definition FormBatch (s : State) : State :=
  let batchSize := if BST <=? length (queue s)
                    then BST
                    else length (queue s) in
  mkState
    (skipn batchSize (queue s))
    (wal s)
    (checkpointSeq s)
    (batches s ++ [firstn batchSize (queue s)])
    (processed s)
    (pending s)
    (systemUp s)
    false.

(* [Spec: ProcessBatch, lines 166-172]
   Move head batch to processed, advance checkpoint.
   Returns s unchanged if batches is empty (guarded by precondition). *)
Definition ProcessBatch (s : State) : State :=
  match batches s with
  | [] => s
  | b :: rest =>
    mkState
      (queue s)
      (wal s)
      (checkpointSeq s + length b)
      rest
      (processed s ++ [b])
      (pending s)
      (systemUp s)
      (timerExpired s)
  end.

(* [Spec: Crash, lines 183-189]
   Clear volatile state, preserve durable state. *)
Definition Crash (s : State) : State :=
  mkState
    []
    (wal s)
    (checkpointSeq s)
    []
    (processed s)
    (pending s)
    false
    false.

(* [Spec: Recover, lines 202-206]
   Replay WAL from checkpoint to reconstruct queue.
   batches, processed, wal, checkpointSeq, pending, timerExpired UNCHANGED. *)
Definition Recover (s : State) : State :=
  mkState
    (skipn (checkpointSeq s) (wal s))
    (wal s)
    (checkpointSeq s)
    (batches s)
    (processed s)
    (pending s)
    true
    (timerExpired s).

(* [Spec: TimerTick, lines 213-218] *)
Definition TimerTick (s : State) : State :=
  mkState
    (queue s)
    (wal s)
    (checkpointSeq s)
    (batches s)
    (processed s)
    (pending s)
    (systemUp s)
    true.

(* ======================================== *)
(*     ACTION PRECONDITIONS                 *)
(* ======================================== *)

(* [Spec: Enqueue precondition, lines 124-125] *)
Definition canEnqueue (s : State) (tx : Tx) : Prop :=
  systemUp s = true /\ In tx (pending s).

(* [Spec: FormBatch precondition, lines 143-145] *)
Definition canFormBatch (s : State) : Prop :=
  systemUp s = true /\
  (length (queue s) >= BST \/
   (timerExpired s = true /\ length (queue s) > 0)).

(* [Spec: ProcessBatch precondition, lines 167-168] *)
Definition canProcessBatch (s : State) : Prop :=
  systemUp s = true /\ batches s <> [].

(* [Spec: Crash precondition, line 184] *)
Definition canCrash (s : State) : Prop :=
  systemUp s = true.

(* [Spec: Recover precondition, line 203] *)
Definition canRecover (s : State) : Prop :=
  systemUp s = false.

(* [Spec: TimerTick precondition, lines 214-216] *)
Definition canTimerTick (s : State) : Prop :=
  systemUp s = true /\
  timerExpired s = false /\
  length (queue s) > 0.

(* ======================================== *)
(*     STEP RELATION                        *)
(* ======================================== *)

(* [Spec: Next, lines 224-230] *)
Inductive Step : State -> State -> Prop :=
  | step_enqueue : forall s tx,
      canEnqueue s tx -> Step s (Enqueue s tx)
  | step_form_batch : forall s,
      canFormBatch s -> Step s (FormBatch s)
  | step_process_batch : forall s,
      canProcessBatch s -> Step s (ProcessBatch s)
  | step_crash : forall s,
      canCrash s -> Step s (Crash s)
  | step_recover : forall s,
      canRecover s -> Step s (Recover s)
  | step_timer_tick : forall s,
      canTimerTick s -> Step s (TimerTick s).

(* ======================================== *)
(*     SAFETY INVARIANTS                    *)
(* ======================================== *)

(* [Spec: FIFOOrdering, lines 318-320]
   systemUp => flatten(processed) ++ flatten(batches) ++ queue = wal.
   This is the master structural invariant. *)
Definition FIFOOrdering (s : State) : Prop :=
  systemUp s = true ->
  processedTxs s ++ flatten (batches s) ++ queue s = wal s.

(* [Spec: QueueWalConsistency, lines 308-309]
   systemUp => flatten(batches) ++ queue = uncommitted.
   Derivable from FIFOOrdering + DurableConsistency. *)
Definition QueueWalConsistency (s : State) : Prop :=
  systemUp s = true ->
  flatten (batches s) ++ queue s = uncommitted s.

(* CheckpointConsistency: checkpointSeq tracks the length of processed txs.
   This is an auxiliary invariant not in the TLA+ but needed for Coq proofs. *)
Definition CheckpointConsistency (s : State) : Prop :=
  checkpointSeq s = length (processedTxs s).

(* DurableConsistency: the processed prefix matches the WAL prefix.
   Holds for all states (including crashed). *)
Definition DurableConsistency (s : State) : Prop :=
  processedTxs s = firstn (checkpointSeq s) (wal s).

(* CheckpointBound: checkpoint does not exceed WAL length. *)
Definition CheckpointBound (s : State) : Prop :=
  checkpointSeq s <= length (wal s).

(* DownStateClean: when system is down, volatile state is empty.
   Established by Crash, preserved by Recover. *)
Definition DownStateClean (s : State) : Prop :=
  systemUp s = false -> queue s = [] /\ batches s = [].

(* WalComplete: tracks the partition of AllTxs into pending and WAL.
   Every tx is either still pending or has been written to WAL. *)
Definition WalComplete (s : State) (allTxs : list Tx) : Prop :=
  forall tx, In tx allTxs <-> (In tx (pending s) \/ In tx (wal s)).

(* [Spec: NoLoss, lines 284-285]
   pending U UncommittedWalTxSet U ProcessedTxSet = AllTxs.
   Three-way partition using only durable references. *)
Definition NoLoss (s : State) (allTxs : list Tx) : Prop :=
  forall tx, In tx allTxs <->
    (In tx (pending s) \/ In tx (uncommitted s) \/ In tx (processedTxs s)).

(* [Spec: BatchSizeBound, lines 325-327] *)
Definition BatchSizeBound (s : State) : Prop :=
  (forall b, In b (batches s) -> length b <= BST) /\
  (forall b, In b (processed s) -> length b <= BST).
