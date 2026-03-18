---- MODULE BatchAggregation ----
(**************************************************************************)
(* Formal specification of the Transaction Queue and Batch Aggregation    *)
(* protocol for the Basis Network Enterprise ZK Validium Node.            *)
(*                                                                        *)
(* v1-fix: Corrected checkpoint timing.                                   *)
(*                                                                        *)
(* CHANGE FROM v0: The WAL checkpoint is deferred from FormBatch to       *)
(* ProcessBatch. In v0, checkpointSeq advanced at batch formation,        *)
(* creating a durability gap where a crash between FormBatch and           *)
(* ProcessBatch caused irrecoverable transaction loss (NoLoss violated).   *)
(* In v1-fix, checkpointSeq advances only after downstream consumption,   *)
(* so all uncommitted WAL entries (including batched txs) are recoverable  *)
(* after crash.                                                            *)
(*                                                                        *)
(* Models the complete lifecycle:                                          *)
(*   1. Enqueue: WAL-first transaction persistence                        *)
(*   2. FormBatch: HYBRID (size OR time) batch formation (NO checkpoint)   *)
(*   3. ProcessBatch: Downstream consumption + WAL checkpoint              *)
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
    queue,          \* In-memory FIFO queue: Seq(AllTxs) -- volatile
    wal,            \* Persisted WAL entries (on disk): Seq(AllTxs) -- durable
    checkpointSeq,  \* Highest WAL sequence number committed via checkpoint -- durable
    batches,        \* Formed but unprocessed batches: Seq(Seq(AllTxs)) -- volatile
    processed,      \* Downstream-consumed batches: Seq(Seq(AllTxs)) -- durable
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
\* [v1-fix]: This now includes BOTH queued and batched txs, since the
\* checkpoint only advances at ProcessBatch. All entries in this set
\* are recoverable after a crash via WAL replay.
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
\*
\* [FIX v1]: The WAL checkpoint is NO LONGER advanced at batch formation time.
\* The batch is formed and held in volatile memory. If the system crashes before
\* ProcessBatch, the batch txs are still in the WAL after checkpointSeq and will
\* be recovered by WAL replay. This closes the durability gap identified in v0.
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
          /\ timerExpired' = FALSE
    /\ UNCHANGED << wal, checkpointSeq, processed, pending, systemUp >>

\* [Source: 0-input/REPORT.md, Section "Recommendations for Downstream"]
\* Process a formed batch: hand off to downstream (circuit prover, L1 submission).
\* Moves the oldest unprocessed batch from the pending queue to the processed set.
\* In the real system, this represents successful ZK proof generation and
\* on-chain verification.
\*
\* [FIX v1]: The WAL checkpoint advances HERE, at batch processing time.
\* Only after the batch has been fully consumed by downstream (proof generated
\* + state root submitted to L1 + confirmation received), we advance the WAL
\* checkpoint. This guarantees that checkpointed txs have been durably delivered
\* to the next stage, and the WAL can safely consider them committed.
ProcessBatch ==
    /\ systemUp
    /\ Len(batches) > 0
    /\ processed' = Append(processed, Head(batches))
    /\ batches' = Tail(batches)
    /\ checkpointSeq' = checkpointSeq + Len(Head(batches))
    /\ UNCHANGED << queue, wal, pending, systemUp, timerExpired >>

\* [Source: 0-input/REPORT.md, Section "Crash Recovery Protocol"]
\* System crash: all volatile (in-memory) state is lost.
\* The WAL and its checkpoints persist on disk (durable storage).
\* In-memory queue is cleared. Formed-but-unprocessed batches are lost.
\* Already-processed batches survive (they have been handed to downstream).
\*
\* [v1-fix]: Same crash semantics as v0. The critical difference is that
\* batch txs are now STILL in the uncommitted WAL segment (checkpointSeq
\* has not advanced), so they will be recovered.
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
\* Entries at or before checkpointSeq are considered committed (included in a
\* processed batch with checkpoint advanced past them). Only uncommitted entries
\* are restored to the queue.
\*
\* [v1-fix]: This action is UNCHANGED from v0, but its behavior is now correct.
\* Since checkpointSeq only advances at ProcessBatch, all txs that were in
\* batches (but not yet processed) are STILL after checkpointSeq in the WAL.
\* Recovery correctly restores them to the queue for re-batching and re-processing.
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

\* Fairness constraints for liveness. Not required for safety checking.
\*
\* In a crash-recovery system, the Crash action can fire at any point and
\* disable all progress actions (Enqueue, FormBatch, ProcessBatch, TimerTick).
\* After recovery, these actions are re-enabled -- but Crash can fire again
\* immediately. This means every progress action is INTERMITTENTLY enabled
\* (enabled, then disabled by Crash, then re-enabled by Recover, then disabled
\* again). Weak fairness (WF) only guarantees execution for CONTINUOUSLY
\* enabled actions, making WF vacuous for progress actions in this model.
\*
\* Strong fairness (SF) is required: if an action is enabled INFINITELY OFTEN,
\* it must eventually execute. This models the realistic assumption that crashes
\* are intermittent, not adversarially targeted -- a system that repeatedly
\* recovers will eventually make progress between crash events.
\*
\* Recover uses weak fairness (WF) because it is the only action enabled when
\* systemUp=FALSE, and nothing can preempt it (Crash requires systemUp=TRUE).
\* Therefore Recover IS continuously enabled when the system is down.
\*
\* Crash has NO fairness constraint. It is a nondeterministic environmental
\* event: the system CAN crash at any time but is not REQUIRED to crash.
\*
\* Reference: Lamport, "Specifying Systems", Section 8.9 -- strong fairness
\* is standard for fault-tolerant system specifications.
Fairness ==
    /\ SF_vars(FormBatch)
    /\ WF_vars(Recover)
    /\ SF_vars(ProcessBatch)
    /\ \A tx \in AllTxs : SF_vars(Enqueue(tx))
    /\ SF_vars(TimerTick)

Spec == Init /\ [][Next]_vars /\ Fairness

(* ====================================================================== *)
(*                         SAFETY PROPERTIES                              *)
(* ====================================================================== *)

\* [Why]: Transaction conservation. Every tx is accounted for in exactly one of
\*        three durable states: pending (not yet in WAL), uncommitted in WAL
\*        (entries after checkpoint -- includes both queued and batched txs),
\*        or processed (in a completed batch with checkpoint advanced past it).
\*        This formulation uses only durable state references (WAL positions +
\*        checkpoint + processed), so it holds across crash/recovery boundaries
\*        without depending on volatile memory.
\* [Fix]: In v0, this was a 4-way partition including BatchedTxSet (volatile).
\*        That violated on crash because batched txs were checkpointed but only
\*        in volatile memory. In v1-fix, batched txs remain in the uncommitted
\*        WAL segment (recoverable), so the 3-way partition holds.
NoLoss ==
    pending \cup UncommittedWalTxSet \cup ProcessedTxSet = AllTxs

\* [Why]: No transaction exists in two durable states simultaneously.
\*        Violation indicates double-delivery, recovery duplication, or
\*        a checkpoint boundary error.
\* [Fix]: Reduced from 6 pairwise checks (4 sets) to 3 pairwise checks (3 sets).
\*        BatchedTxSet is a subset of UncommittedWalTxSet, not a separate partition.
NoDuplication ==
    /\ pending \cap UncommittedWalTxSet = {}
    /\ pending \cap ProcessedTxSet = {}
    /\ UncommittedWalTxSet \cap ProcessedTxSet = {}

\* [Why]: Queue-WAL synchronization (extended for deferred checkpoint).
\*        When the system is running, the concatenation of all formed batches
\*        followed by the in-memory queue must exactly equal the uncommitted
\*        WAL segment (entries after checkpoint). This verifies:
\*        (a) no tx lost between queue and batches,
\*        (b) FIFO ordering within the uncommitted segment,
\*        (c) crash recovery correctness (crash clears both volatile stores,
\*            WAL preserves all uncommitted entries for replay).
\* [Fix]: In v0, this was: queue = SubSeq(wal, checkpointSeq+1, Len(wal))
\*        because all batch txs were before the checkpoint. In v1-fix, batched
\*        txs are ALSO after the checkpoint, so the invariant includes them.
QueueWalConsistency ==
    systemUp => Flatten(batches) \o queue = SubSeq(wal, checkpointSeq + 1, Len(wal))

\* [Why]: Global FIFO ordering. The full sequence of all transactions -- processed,
\*        then batched, then queued -- must equal the complete WAL in exact
\*        arrival order. This is the strongest ordering invariant: it implies
\*        QueueWalConsistency and additionally verifies that processed txs
\*        match the WAL prefix up to checkpointSeq.
\* [Fix]: In v0, this covered only processed + batches = WAL prefix (up to
\*        checkpointSeq). In v1-fix, it covers the ENTIRE WAL.
FIFOOrdering ==
    systemUp =>
        Flatten(processed) \o Flatten(batches) \o queue = wal

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
EventualProcessing ==
    <>(\A tx \in AllTxs : tx \in ProcessedTxSet)

====
