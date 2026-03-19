---- MODULE BatchAggregation ----
(**************************************************************************)
(* Formal specification of the Transaction Queue and Batch Aggregation    *)
(* protocol for the Basis Network Enterprise ZK Validium Node.            *)
(*                                                                        *)
(* Models the complete lifecycle:                                          *)
(*   1. Enqueue: WAL-first transaction persistence                        *)
(*   2. FormBatch: HYBRID (size OR time) batch formation with checkpoint  *)
(*   3. ProcessBatch: Downstream consumption (circuit proving, L1 submit) *)
(*   4. Crash / Recover: In-memory state loss and WAL-based recovery      *)
(*                                                                        *)
(* Source: validium/specs/units/2026-03-batch-aggregation/0-input/         *)
(**************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

(* ====================================================================== *)
(*                         CONSTANTS                                      *)
(* ====================================================================== *)

CONSTANTS
    AllTxs,             \* Set of all transaction identifiers
    BatchSizeThreshold  \* Number of txs triggering size-based batch formation

ASSUME BatchSizeThreshold > 0
ASSUME AllTxs # {}

(* ====================================================================== *)
(*                         VARIABLES                                      *)
(* ====================================================================== *)

VARIABLES
    queue,          \* In-memory FIFO queue: Seq(AllTxs)
    wal,            \* Persisted WAL entries (on disk): Seq(AllTxs)
    checkpointSeq,  \* Highest WAL sequence number committed via checkpoint
    batches,        \* Formed but unprocessed batches: Seq(Seq(AllTxs))
    processed,      \* Downstream-consumed batches: Seq(Seq(AllTxs))
    pending,        \* Transactions not yet enqueued: SUBSET AllTxs
    systemUp,       \* TRUE = running, FALSE = crashed
    timerExpired    \* Nondeterministic flag: time threshold has elapsed

vars == << queue, wal, checkpointSeq, batches, processed, pending, systemUp, timerExpired >>

(* ====================================================================== *)
(*                         HELPERS                                        *)
(* ====================================================================== *)

\* Flatten a sequence of sequences into a single sequence.
RECURSIVE Flatten(_)
Flatten(seqs) ==
    IF Len(seqs) = 0 THEN << >>
    ELSE seqs[1] \o Flatten(Tail(seqs))

\* Set of all txs across formed (unprocessed) batches.
BatchedTxSet ==
    LET flat == Flatten(batches)
    IN {flat[i] : i \in 1..Len(flat)}

\* Set of all txs across processed batches.
ProcessedTxSet ==
    LET flat == Flatten(processed)
    IN {flat[i] : i \in 1..Len(flat)}

\* Set of all txs currently in the in-memory queue.
QueueTxSet ==
    {queue[i] : i \in 1..Len(queue)}

\* Set of uncommitted txs in the WAL (entries after last checkpoint).
\* These txs are recoverable after a crash.
UncommittedWalTxSet ==
    {wal[i] : i \in (checkpointSeq + 1)..Len(wal)}

(* ====================================================================== *)
(*                         TYPE INVARIANT                                 *)
(* ====================================================================== *)

\* [Why]: Structural type constraint. Every variable must inhabit its declared domain.
TypeOK ==
    /\ queue \in Seq(AllTxs)
    /\ wal \in Seq(AllTxs)
    /\ checkpointSeq \in 0..Len(wal)
    /\ batches \in Seq(Seq(AllTxs))
    /\ processed \in Seq(Seq(AllTxs))
    /\ pending \subseteq AllTxs
    /\ systemUp \in BOOLEAN
    /\ timerExpired \in BOOLEAN

(* ====================================================================== *)
(*                         INITIAL STATE                                  *)
(* ====================================================================== *)

Init ==
    /\ queue = << >>
    /\ wal = << >>
    /\ checkpointSeq = 0
    /\ batches = << >>
    /\ processed = << >>
    /\ pending = AllTxs
    /\ systemUp = TRUE
    /\ timerExpired = FALSE

(* ====================================================================== *)
(*                         ACTIONS                                        *)
(* ====================================================================== *)

\* [Source: 0-input/code/src/persistent-queue.ts, enqueue()]
\* [Source: 0-input/code/src/wal.ts, append()]
\* Enqueue a transaction: persist to WAL (disk), then add to in-memory queue.
\* The WAL-first protocol ensures that if the system crashes after the WAL write
\* but before the in-memory queue update, the transaction is still recoverable.
Enqueue(tx) ==
    /\ systemUp
    /\ tx \in pending
    /\ wal' = Append(wal, tx)
    /\ queue' = Append(queue, tx)
    /\ pending' = pending \ {tx}
    /\ UNCHANGED << checkpointSeq, batches, processed, systemUp, timerExpired >>

\* [Source: 0-input/code/src/batch-aggregator.ts, shouldFormBatch() lines 37-53]
\* [Source: 0-input/code/src/batch-aggregator.ts, formBatch() lines 56-91]
\* [Source: 0-input/REPORT.md, Section "Batch Formation Strategies -- HYBRID"]
\* Form a batch using the HYBRID strategy: trigger when the queue reaches
\* the size threshold OR the time threshold has elapsed with a non-empty queue.
\* Dequeues min(Len(queue), BatchSizeThreshold) txs from the front (FIFO).
\* Advances the WAL checkpoint, marking those txs as committed.
\*
\* CRITICAL DESIGN CHOICE: The WAL checkpoint is written at batch formation time,
\* not at batch processing time. This means checkpointed txs are not recoverable
\* from the WAL -- their durability depends on the batch object surviving in memory
\* until ProcessBatch executes.
FormBatch ==
    /\ systemUp
    /\ \/ Len(queue) >= BatchSizeThreshold
       \/ (timerExpired /\ Len(queue) > 0)
    /\ LET batchSize == IF Len(queue) >= BatchSizeThreshold
                         THEN BatchSizeThreshold
                         ELSE Len(queue)
           batch == SubSeq(queue, 1, batchSize)
       IN /\ batches' = Append(batches, batch)
          /\ queue' = SubSeq(queue, batchSize + 1, Len(queue))
          /\ checkpointSeq' = checkpointSeq + batchSize
          /\ timerExpired' = FALSE
    /\ UNCHANGED << wal, processed, pending, systemUp >>

\* [Source: 0-input/REPORT.md, Section "Recommendations for Downstream"]
\* Process a formed batch: hand off to downstream (circuit prover, L1 submission).
\* Moves the oldest unprocessed batch from the pending queue to the processed set.
\* In the real system, this represents successful ZK proof generation and
\* on-chain verification.
ProcessBatch ==
    /\ systemUp
    /\ Len(batches) > 0
    /\ processed' = Append(processed, Head(batches))
    /\ batches' = Tail(batches)
    /\ UNCHANGED << queue, wal, checkpointSeq, pending, systemUp, timerExpired >>

\* [Source: 0-input/REPORT.md, Section "Crash Recovery Protocol"]
\* System crash: all volatile (in-memory) state is lost.
\* The WAL and its checkpoints persist on disk (durable storage).
\* In-memory queue is cleared. Formed-but-unprocessed batches are lost.
\* Already-processed batches survive (they have been handed to downstream).
Crash ==
    /\ systemUp
    /\ systemUp' = FALSE
    /\ queue' = << >>
    /\ batches' = << >>
    /\ timerExpired' = FALSE
    /\ UNCHANGED << wal, checkpointSeq, processed, pending >>

\* [Source: 0-input/code/src/wal.ts, recover() lines 110-147]
\* [Source: 0-input/REPORT.md, Section "Crash Recovery Protocol"]
\* Recovery: replay WAL entries after the last checkpoint to reconstruct the queue.
\* Entries at or before checkpointSeq are considered committed (included in a batch
\* that was checkpointed). Only uncommitted entries are restored to the queue.
Recover ==
    /\ ~systemUp
    /\ systemUp' = TRUE
    /\ queue' = SubSeq(wal, checkpointSeq + 1, Len(wal))
    /\ UNCHANGED << wal, checkpointSeq, batches, processed, pending, timerExpired >>

\* [Source: 0-input/REPORT.md, Section "HYBRID -- size OR time, whichever first"]
\* Nondeterministic timer expiration. Abstracts the passage of real time:
\* at any point during normal operation with a non-empty queue, the time
\* threshold can be considered elapsed. This over-approximation is sound
\* for safety checking (explores strictly more behaviors than reality).
TimerTick ==
    /\ systemUp
    /\ ~timerExpired
    /\ Len(queue) > 0
    /\ timerExpired' = TRUE
    /\ UNCHANGED << queue, wal, checkpointSeq, batches, processed, pending, systemUp >>

(* ====================================================================== *)
(*                         NEXT-STATE RELATION                            *)
(* ====================================================================== *)

Next ==
    \/ \E tx \in pending : Enqueue(tx)
    \/ FormBatch
    \/ ProcessBatch
    \/ Crash
    \/ Recover
    \/ TimerTick

(* ====================================================================== *)
(*                         FAIRNESS                                       *)
(* ====================================================================== *)

\* Weak fairness ensures continuously enabled actions eventually execute.
\* Required for liveness properties. Not required for safety checking.
Fairness ==
    /\ WF_vars(FormBatch)
    /\ WF_vars(Recover)
    /\ WF_vars(ProcessBatch)
    /\ \A tx \in AllTxs : WF_vars(Enqueue(tx))
    /\ WF_vars(TimerTick)

Spec == Init /\ [][Next]_vars /\ Fairness

(* ====================================================================== *)
(*                         SAFETY PROPERTIES                              *)
(* ====================================================================== *)

\* [Why]: Transaction conservation. Every transaction is always accounted for
\*        in exactly one of four states: pending, uncommitted in WAL, in a
\*        formed batch, or processed. Uses the WAL (not the volatile in-memory
\*        queue) as source of truth, so the property must hold across crash
\*        and recovery cycles.
\*        FAILURE indicates irrecoverable transaction loss.
NoLoss ==
    pending \cup UncommittedWalTxSet \cup BatchedTxSet \cup ProcessedTxSet = AllTxs

\* [Why]: No transaction is assigned to multiple states simultaneously.
\*        Violation indicates non-deterministic batch assignment, double-batching,
\*        or a recovery bug that duplicates transactions.
NoDuplication ==
    /\ pending \cap UncommittedWalTxSet = {}
    /\ pending \cap BatchedTxSet = {}
    /\ pending \cap ProcessedTxSet = {}
    /\ UncommittedWalTxSet \cap BatchedTxSet = {}
    /\ UncommittedWalTxSet \cap ProcessedTxSet = {}
    /\ BatchedTxSet \cap ProcessedTxSet = {}

\* [Why]: Queue-WAL synchronization. When the system is running, the in-memory
\*        queue must exactly mirror the uncommitted segment of the WAL.
\*        This guarantees: (a) FIFO ordering, (b) crash recovery correctness,
\*        (c) no phantom transactions in memory without WAL backing.
\*        Only checked when system is up (crash clears the in-memory queue).
QueueWalConsistency ==
    systemUp => queue = SubSeq(wal, checkpointSeq + 1, Len(wal))

\* [Why]: FIFO ordering. The concatenation of all batches (processed then pending)
\*        must equal the WAL prefix up to checkpointSeq, preserving the exact
\*        order of transaction arrival. Guarantees deterministic batching:
\*        same transactions in same order produce the same batch sequence.
FIFOOrdering ==
    systemUp =>
        LET allBatched == Flatten(processed) \o Flatten(batches)
        IN allBatched = SubSeq(wal, 1, checkpointSeq)

\* [Why]: Circuit capacity bound. Every batch must respect the maximum batch
\*        size to ensure it fits within the ZK circuit's constraint capacity.
\*        Violation means the prover would receive an oversized batch.
BatchSizeBound ==
    /\ \A i \in 1..Len(batches) : Len(batches[i]) <= BatchSizeThreshold
    /\ \A i \in 1..Len(processed) : Len(processed[i]) <= BatchSizeThreshold

(* ====================================================================== *)
(*                         LIVENESS PROPERTIES                            *)
(* ====================================================================== *)

\* [Why]: End-to-end delivery guarantee. Every transaction must eventually
\*        be included in a processed batch. Requires fairness on all actions.
\*        FAILURE indicates permanent transaction loss (e.g., crash between
\*        batch formation and processing with premature WAL checkpoint).
EventualProcessing ==
    <>(\A tx \in AllTxs : tx \in ProcessedTxSet)

====
