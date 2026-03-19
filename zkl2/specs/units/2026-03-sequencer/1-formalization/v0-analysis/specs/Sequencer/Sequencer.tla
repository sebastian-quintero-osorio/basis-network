---- MODULE Sequencer ----
(***************************************************************************)
(* Formal specification of an enterprise L2 sequencer with single-operator *)
(* block production, FIFO mempool ordering, and Arbitrum-style forced      *)
(* inclusion via L1.                                                       *)
(*                                                                         *)
(* The sequencer produces blocks at regular intervals, drawing first from  *)
(* a forced inclusion queue (L1-submitted transactions that must be        *)
(* included within a deadline) and then from the mempool (regular FIFO     *)
(* queue). This model verifies:                                            *)
(*   - FIFO ordering within blocks (by category)                           *)
(*   - Forced inclusion deadline enforcement (censorship resistance)       *)
(*   - No double-inclusion across blocks                                   *)
(*   - Forced transactions always precede mempool transactions in blocks   *)
(*                                                                         *)
(* Source: zkl2/specs/units/2026-03-sequencer/0-input/                     *)
(* Target: Basis Network zkEVM L2                                          *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

(***************************************************************************)
(*                            CONSTANTS                                    *)
(***************************************************************************)

CONSTANTS
    Txs,                   \* Set of regular transaction IDs
    ForcedTxs,             \* Set of forced transaction IDs (submitted via L1)
    MaxTxPerBlock,         \* Maximum transactions per block
    MaxBlocks,             \* Maximum blocks to produce (bounds finite model)
    ForcedDeadlineBlocks   \* Blocks within which a forced tx MUST be included

ASSUME Txs \cap ForcedTxs = {}
ASSUME MaxTxPerBlock > 0
ASSUME MaxBlocks > 0
ASSUME ForcedDeadlineBlocks > 0

(***************************************************************************)
(*                            HELPERS                                      *)
(***************************************************************************)

\* Set of elements in a sequence
Range(s) == {s[i] : i \in 1..Len(s)}

\* First n elements of sequence s (capped at sequence length)
Take(s, n) == SubSeq(s, 1, IF n <= Len(s) THEN n ELSE Len(s))

\* Remove first n elements from sequence s
Drop(s, n) == IF n >= Len(s) THEN << >> ELSE SubSeq(s, n + 1, Len(s))

\* Union of all transaction IDs
AllTxIds == Txs \union ForcedTxs

(***************************************************************************)
(*                            VARIABLES                                    *)
(***************************************************************************)

VARIABLES
    mempool,               \* Seq(Txs): FIFO queue of pending regular transactions
    forcedQueue,           \* Seq(ForcedTxs): FIFO queue of pending forced transactions
    blocks,                \* Seq(Seq(AllTxIds)): produced blocks (each a tx sequence)
    blockNum,              \* Nat: number of blocks produced so far
    forcedSubmitBlock,     \* Function: forced tx ID -> block number at submission time
    submitOrder            \* Function: tx ID -> global submission order (monotonic)

vars == << mempool, forcedQueue, blocks, blockNum, forcedSubmitBlock, submitOrder >>

(***************************************************************************)
(*                       DERIVED OPERATORS                                 *)
(***************************************************************************)

\* Set of regular transactions that have been submitted to the mempool
submitted == DOMAIN submitOrder \cap Txs

\* Set of forced transactions that have been submitted via L1
forcedSubmitted == DOMAIN forcedSubmitBlock

\* Set of all transaction IDs included across all produced blocks
\* [Source: 0-input/code/sequencer.go -- Metrics.TxIncluded]
included == UNION {Range(blocks[i]) : i \in 1..Len(blocks)}

(***************************************************************************)
(*                       TYPE INVARIANT                                    *)
(***************************************************************************)

TypeOK ==
    /\ mempool \in Seq(Txs)
    /\ forcedQueue \in Seq(ForcedTxs)
    /\ blocks \in Seq(Seq(AllTxIds))
    /\ blockNum \in 0..MaxBlocks
    /\ DOMAIN forcedSubmitBlock \subseteq ForcedTxs
    /\ DOMAIN submitOrder \subseteq AllTxIds

(***************************************************************************)
(*                       INITIAL STATE                                     *)
(***************************************************************************)

Init ==
    /\ mempool = << >>
    /\ forcedQueue = << >>
    /\ blocks = << >>
    /\ blockNum = 0
    /\ forcedSubmitBlock = << >>
    /\ submitOrder = << >>

(***************************************************************************)
(*                          ACTIONS                                        *)
(***************************************************************************)

\* [Source: 0-input/code/mempool.go, Mempool.Add()]
\* A user submits a regular transaction to the mempool FIFO queue.
\* The transaction receives a monotonic sequence number (submitOrder)
\* that determines its position in the FIFO ordering.
SubmitTx(tx) ==
    /\ tx \in Txs
    /\ tx \notin DOMAIN submitOrder          \* Not previously submitted
    /\ mempool' = Append(mempool, tx)
    /\ submitOrder' = submitOrder @@ (tx :> Cardinality(DOMAIN submitOrder))
    /\ UNCHANGED << forcedQueue, blocks, blockNum, forcedSubmitBlock >>

\* [Source: 0-input/code/forced_inclusion.go, ForcedInclusionQueue.Submit()]
\* A transaction is submitted via L1 for forced inclusion on L2.
\* The current block number is recorded for deadline enforcement.
\* Design: Arbitrum-style FIFO queue prevents selective censorship.
\* [Source: 0-input/REPORT.md, "Arbitrum's Forced Inclusion Model is Best"]
SubmitForcedTx(ftx) ==
    /\ ftx \in ForcedTxs
    /\ ftx \notin DOMAIN forcedSubmitBlock   \* Not previously submitted
    /\ forcedQueue' = Append(forcedQueue, ftx)
    /\ forcedSubmitBlock' = forcedSubmitBlock @@ (ftx :> blockNum)
    /\ submitOrder' = submitOrder @@ (ftx :> Cardinality(DOMAIN submitOrder))
    /\ UNCHANGED << mempool, blocks, blockNum >>

\* [Source: 0-input/code/sequencer.go, Sequencer.ProduceBlock()]
\* The sequencer produces a block following the protocol:
\*   1. Include forced txs from front of queue (FIFO, must include expired)
\*   2. Fill remaining capacity from mempool (FIFO)
\*   3. Seal block and advance block counter
\*
\* "Expired" = blockNum >= forcedSubmitBlock[ftx] + ForcedDeadlineBlocks.
\* FIFO constraint: cannot skip queue items. Delaying one delays all.
\* [Source: 0-input/REPORT.md, "FIFO queue ordering prevents selective censorship"]
ProduceBlock ==
    /\ blockNum < MaxBlocks
    /\ LET
           \* Check if forced tx at position i has an expired deadline
           IsExpired(i) ==
               /\ i <= Len(forcedQueue)
               /\ forcedQueue[i] \in DOMAIN forcedSubmitBlock
               /\ blockNum >= forcedSubmitBlock[forcedQueue[i]] + ForcedDeadlineBlocks
           \* Count consecutive expired forced txs from front of queue.
           \* FIFO: sequencer cannot skip items. Delaying front delays all.
           \* This counts positions i where ALL predecessors 1..i are expired,
           \* yielding the length of the maximal expired prefix.
           minRequired ==
               Cardinality({i \in 1..Len(forcedQueue) : \A j \in 1..i : IsExpired(j)})
       IN
       \E numForced \in 0..Len(forcedQueue) :
           /\ numForced >= minRequired        \* MUST include expired forced txs
           /\ numForced <= MaxTxPerBlock      \* Cannot exceed block capacity
           /\ LET
                  \* Take forced txs from front of queue (FIFO)
                  forcedPart == Take(forcedQueue, numForced)
                  \* Fill remaining capacity from mempool (FIFO)
                  remainCap == MaxTxPerBlock - numForced
                  mempoolCount == IF remainCap > Len(mempool)
                                  THEN Len(mempool)
                                  ELSE remainCap
                  mempoolPart == Take(mempool, mempoolCount)
                  \* Block content: forced first, then mempool
                  blockContent == forcedPart \o mempoolPart
              IN
                  /\ blocks' = Append(blocks, blockContent)
                  /\ forcedQueue' = Drop(forcedQueue, numForced)
                  /\ mempool' = Drop(mempool, mempoolCount)
                  /\ blockNum' = blockNum + 1
                  /\ UNCHANGED << forcedSubmitBlock, submitOrder >>

\* Complete next-state relation
Next ==
    \/ \E tx \in Txs : SubmitTx(tx)
    \/ \E ftx \in ForcedTxs : SubmitForcedTx(ftx)
    \/ ProduceBlock

(***************************************************************************)
(*                      SAFETY PROPERTIES                                  *)
(***************************************************************************)

\* [Why]: A transaction must not appear in more than one block.
\* Violation would indicate a double-execution bug in the sequencer.
NoDoubleInclusion ==
    \A i, j \in 1..Len(blocks) :
        i /= j => Range(blocks[i]) \cap Range(blocks[j]) = {}

\* [Why]: Forced txs submitted at block B must be included by block B + D.
\* This is the censorship resistance guarantee: even if the sequencer is
\* uncooperative, the forced inclusion mechanism guarantees eventual inclusion.
\* [Source: 0-input/REPORT.md, "Arbitrum DelayedInbox: FIFO ordering, 24h deadline"]
ForcedInclusionDeadline ==
    \A ftx \in forcedSubmitted :
        blockNum > forcedSubmitBlock[ftx] + ForcedDeadlineBlocks => ftx \in included

\* [Why]: Only previously submitted transactions may appear in blocks.
\* Prevents the sequencer from fabricating transactions.
IncludedWereSubmitted ==
    included \subseteq (submitted \union forcedSubmitted)

\* [Why]: Within each block, forced txs appear before mempool txs.
\* Forced transactions receive priority placement at the top of the block.
\* [Source: 0-input/code/sequencer.go, lines 75-98]
ForcedBeforeMempool ==
    \A b \in 1..Len(blocks) :
        LET block == blocks[b] IN
        ~ \E i, j \in 1..Len(block) :
            /\ i < j
            /\ block[i] \in Txs
            /\ block[j] \in ForcedTxs

\* [Why]: Transactions within a block respect FIFO ordering within category.
\* Within the forced section, forced txs are ordered by submission time.
\* Within the mempool section, regular txs are ordered by submission time.
\* Cross-category ordering (forced before mempool) is checked by ForcedBeforeMempool.
\* [Source: 0-input/REPORT.md, "FIFO Ordering is Natural for Enterprise"]
FIFOWithinBlock ==
    \A b \in 1..Len(blocks) :
        LET block == blocks[b] IN
        \A i, j \in 1..Len(block) :
            (/\ i < j
             /\ block[i] \in DOMAIN submitOrder
             /\ block[j] \in DOMAIN submitOrder
             /\ \/ (block[i] \in Txs /\ block[j] \in Txs)
                \/ (block[i] \in ForcedTxs /\ block[j] \in ForcedTxs))
            => submitOrder[block[i]] < submitOrder[block[j]]

(***************************************************************************)
(*                     LIVENESS PROPERTIES                                 *)
(***************************************************************************)

\* [Why]: Every submitted regular transaction is eventually included.
\* NOTE: Not model-checked in bounded model (MaxBlocks limits production).
EventualInclusion ==
    \A tx \in Txs :
        (tx \in submitted) ~> (tx \in included)

\* [Why]: Every forced transaction is eventually included.
\* Guaranteed by the forced inclusion deadline and block production fairness.
ForcedEventualInclusion ==
    \A ftx \in ForcedTxs :
        (ftx \in forcedSubmitted) ~> (ftx \in included)

(***************************************************************************)
(*                       SPECIFICATION                                     *)
(***************************************************************************)

\* Weak fairness ensures block production continues when enabled
Fairness == WF_vars(ProduceBlock)

\* The complete temporal specification
Spec == Init /\ [][Next]_vars /\ Fairness

====
