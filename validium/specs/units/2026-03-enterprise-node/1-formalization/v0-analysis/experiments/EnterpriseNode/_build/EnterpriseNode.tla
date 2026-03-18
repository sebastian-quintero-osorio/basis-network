---- MODULE EnterpriseNode ----
(**************************************************************************)
(* Formal specification of the Enterprise Node Orchestrator for the       *)
(* Basis Network Enterprise ZK Validium.                                  *)
(*                                                                        *)
(* Models the complete pipelined state machine:                            *)
(*   1. ReceiveTx: WAL-first transaction ingestion (concurrent with all)  *)
(*   2. FormBatch: HYBRID (size OR time) batch formation                  *)
(*   3. GenerateWitness: SMT update and witness generation                *)
(*   4. GenerateProof: ZK proof generation                                *)
(*   5. SubmitBatch: L1 submission + DAC attestation                      *)
(*   6. ConfirmBatch: L1 confirmation + WAL checkpoint                    *)
(*   7. Crash / Retry: Crash recovery via WAL replay                      *)
(*   8. L1Reject / Retry: L1 rejection recovery                          *)
(*                                                                        *)
(* State root abstraction: the SMT root hash is modeled as the set of     *)
(* transactions applied to the tree. Each unique set corresponds to a     *)
(* unique root hash (collision-free by construction). This preserves      *)
(* all chain integrity properties without requiring an explicit hash      *)
(* function.                                                              *)
(*                                                                        *)
(* Source: validium/specs/units/2026-03-enterprise-node/0-input/           *)
(**************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

(* ====================================================================== *)
(*                         CONSTANTS                                      *)
(* ====================================================================== *)

CONSTANTS
    AllTxs,            \* Set of all possible transactions
    BatchThreshold,    \* Number of txs triggering size-based batch formation
    MaxCrashes         \* Maximum number of crash events to explore

ASSUME BatchThreshold > 0
ASSUME AllTxs # {}
ASSUME MaxCrashes >= 0

(* ====================================================================== *)
(*                         STATE ENUMERATION                              *)
(* ====================================================================== *)

\* [Source: 0-input/code/src/types.ts, NodeState enum lines 6-13]
States == {"Idle", "Receiving", "Batching", "Proving", "Submitting", "Error"}

\* Data categories for privacy boundary tracking.
\* "proof_signals" = ZK proof (a, b, c) + public signals
\*     (prevRoot, newRoot, batchNum, enterpriseId)
\* "dac_shares" = Shamir secret shares of batch witness data
\* "raw_data" = raw enterprise transaction data (MUST NEVER be exposed)
AllowedExternalData == {"proof_signals", "dac_shares"}
DataKinds == AllowedExternalData \cup {"raw_data"}

(* ====================================================================== *)
(*                         VARIABLES                                      *)
(* ====================================================================== *)

VARIABLES
    nodeState,      \* Current node state \in States
    txQueue,        \* In-memory transaction queue: Seq(AllTxs) -- volatile
    wal,            \* Write-Ahead Log entries: Seq(AllTxs) -- durable (disk)
    walCheckpoint,  \* Last checkpointed WAL position: Nat -- durable (disk)
    smtState,       \* Set of txs applied to Sparse Merkle Tree: SUBSET AllTxs
                    \* Abstracts the SMT root hash. Volatile in memory;
                    \* checkpoint value = l1State (durable on disk).
    batchTxs,       \* Transactions in current batch: Seq(AllTxs) -- volatile
    batchPrevSmt,   \* SMT state before batch applied: SUBSET AllTxs -- volatile
    l1State,        \* Last confirmed state on L1: SUBSET AllTxs -- durable (on-chain)
    dataExposed,    \* Data categories sent outside node boundary: SUBSET DataKinds
    pending,        \* Transactions not yet received by node: SUBSET AllTxs
    crashCount,     \* Number of crashes that have occurred: Nat
    timerExpired    \* Nondeterministic flag: time threshold has elapsed: BOOLEAN

vars == << nodeState, txQueue, wal, walCheckpoint, smtState,
           batchTxs, batchPrevSmt, l1State, dataExposed, pending,
           crashCount, timerExpired >>

(* ====================================================================== *)
(*                         HELPERS                                        *)
(* ====================================================================== *)

\* Set of txs currently in the in-memory queue.
QueueTxSet == {txQueue[i] : i \in 1..Len(txQueue)}

\* Set of txs in the current batch.
BatchTxSet == {batchTxs[i] : i \in 1..Len(batchTxs)}

\* Set of uncommitted txs in WAL (entries after last checkpoint).
\* These are recoverable after a crash via WAL replay.
\* Uses deferred checkpoint pattern from RU-V4 (BatchAggregation v1-fix):
\* checkpoint advances only after L1 confirmation, so batch txs remain
\* in the uncommitted segment until confirmed.
UncommittedWalTxSet ==
    {wal[i] : i \in (walCheckpoint + 1)..Len(wal)}

(* ====================================================================== *)
(*                         TYPE INVARIANT                                 *)
(* ====================================================================== *)

\* [Why]: Structural type constraint. Every variable must inhabit its
\*        declared domain at every reachable state.
TypeOK ==
    /\ nodeState \in States
    /\ txQueue \in Seq(AllTxs)
    /\ wal \in Seq(AllTxs)
    /\ walCheckpoint \in 0..Len(wal)
    /\ smtState \subseteq AllTxs
    /\ batchTxs \in Seq(AllTxs)
    /\ batchPrevSmt \subseteq AllTxs
    /\ l1State \subseteq AllTxs
    /\ dataExposed \subseteq DataKinds
    /\ pending \subseteq AllTxs
    /\ crashCount \in 0..MaxCrashes
    /\ timerExpired \in BOOLEAN

(* ====================================================================== *)
(*                         INITIAL STATE                                  *)
(* ====================================================================== *)

Init ==
    /\ nodeState = "Idle"
    /\ txQueue = << >>
    /\ wal = << >>
    /\ walCheckpoint = 0
    /\ smtState = {}              \* Genesis: empty Merkle tree
    /\ batchTxs = << >>
    /\ batchPrevSmt = {}
    /\ l1State = {}               \* L1 starts at genesis root
    /\ dataExposed = {}
    /\ pending = AllTxs
    /\ crashCount = 0
    /\ timerExpired = FALSE

(* ====================================================================== *)
(*                         ACTIONS                                        *)
(* ====================================================================== *)

\* [Source: 0-input/code/src/orchestrator.ts, submitTransaction() lines 278-301]
\* [Source: 0-input/REPORT.md, Section 2.1 -- "Receiving is concurrent with all states"]
\* Accept a transaction from PLASMA/Trace adapter.
\* WAL-first: persist to durable WAL before adding to volatile queue.
\* Pipelined: accepts transactions in Idle, Receiving, Proving, Submitting.
\* Transitions Idle -> Receiving; other states remain unchanged.
ReceiveTx(tx) ==
    /\ tx \in pending
    /\ nodeState \in {"Idle", "Receiving", "Proving", "Submitting"}
    /\ wal' = Append(wal, tx)
    /\ txQueue' = Append(txQueue, tx)
    /\ pending' = pending \ {tx}
    /\ nodeState' = IF nodeState = "Idle" THEN "Receiving" ELSE nodeState
    /\ UNCHANGED << walCheckpoint, smtState, batchTxs, batchPrevSmt,
                    l1State, dataExposed, crashCount, timerExpired >>

\* [Source: 0-input/REPORT.md, Section 2.2 -- "Batch loop: Monitors queue"]
\* Background queue monitoring: when the node returns to Idle with pending
\* transactions in the queue (from pipelined ingestion during previous
\* batch cycle), the batch loop detects them and resumes the receiving
\* state. Models the concurrent batch loop in the pipelined architecture.
CheckQueue ==
    /\ nodeState = "Idle"
    /\ Len(txQueue) > 0
    /\ nodeState' = "Receiving"
    /\ UNCHANGED << txQueue, wal, walCheckpoint, smtState, batchTxs,
                    batchPrevSmt, l1State, dataExposed, pending,
                    crashCount, timerExpired >>

\* [Source: 0-input/code/src/orchestrator.ts, processBatchCycle() lines 316-321]
\* [Source: 0-input/REPORT.md, Section 2.2 -- "HYBRID: size OR time"]
\* Form a batch using HYBRID strategy: trigger when queue reaches size
\* threshold OR time threshold has elapsed with non-empty queue.
\* Dequeues min(Len(txQueue), BatchThreshold) transactions (FIFO).
\* Records batchPrevSmt = current SMT state for proof verification.
\*
\* WAL checkpoint is NOT advanced here (deferred checkpoint pattern from
\* RU-V4 BatchAggregation v1-fix). Batch txs remain in the uncommitted
\* WAL segment until L1 confirmation, ensuring crash recovery correctness.
FormBatch ==
    /\ nodeState = "Receiving"
    /\ \/ Len(txQueue) >= BatchThreshold
       \/ (timerExpired /\ Len(txQueue) > 0)
    /\ LET batchSize == IF Len(txQueue) >= BatchThreshold
                         THEN BatchThreshold
                         ELSE Len(txQueue)
           batch == SubSeq(txQueue, 1, batchSize)
       IN /\ batchTxs' = batch
          /\ txQueue' = SubSeq(txQueue, batchSize + 1, Len(txQueue))
          /\ batchPrevSmt' = smtState
    /\ nodeState' = "Batching"
    /\ timerExpired' = FALSE
    /\ UNCHANGED << wal, walCheckpoint, smtState, l1State, dataExposed,
                    pending, crashCount >>

\* [Source: 0-input/code/src/orchestrator.ts, lines 329-348 (SMT inserts)]
\* [Source: 0-input/REPORT.md, Section 7.2 -- INV-NO6 "Single Writer"]
\* Apply batch transactions to the Sparse Merkle Tree and generate witness.
\* This is the ONLY action that adds transactions to smtState (single writer
\* invariant enforced by state machine design: only fires in Batching).
\* Abstract SMT: smtState' = smtState \cup BatchTxSet. Each unique set
\* maps to a unique root hash (collision-free hash abstraction).
GenerateWitness ==
    /\ nodeState = "Batching"
    /\ Len(batchTxs) > 0
    /\ smtState' = smtState \cup BatchTxSet
    /\ nodeState' = "Proving"
    /\ UNCHANGED << txQueue, wal, walCheckpoint, batchTxs, batchPrevSmt,
                    l1State, dataExposed, pending, crashCount, timerExpired >>

\* [Source: 0-input/code/src/orchestrator.ts, lines 362-366 (prover.prove)]
\* [Source: 0-input/REPORT.md, Section 2.1 -- "Proving is asynchronous"]
\* ZK proof generation completes. The Groth16 circuit guarantees:
\*   proof.publicSignals.prevRoot = hash(batchPrevSmt)
\*   proof.publicSignals.newRoot = hash(smtState)
\* These are not stored as separate variables because the circuit enforces
\* this mapping by construction (it is a provable computation).
GenerateProof ==
    /\ nodeState = "Proving"
    /\ nodeState' = "Submitting"
    /\ UNCHANGED << txQueue, wal, walCheckpoint, smtState, batchTxs,
                    batchPrevSmt, l1State, dataExposed, pending,
                    crashCount, timerExpired >>

\* [Source: 0-input/code/src/orchestrator.ts, lines 373-389 (DAC + L1)]
\* [Source: 0-input/REPORT.md, Section 2.4 -- Privacy Architecture]
\* Submit proof + state roots to L1 and distribute Shamir shares to DAC.
\* External data boundary crossing: ONLY proof, public signals, and DAC
\* shares leave the node. Raw enterprise data NEVER leaves the node.
\* The adapter layer (validium/adapters/) ensures the node only receives
\* (key, valueHash) pairs, never raw PLASMA/Trace data.
SubmitBatch ==
    /\ nodeState = "Submitting"
    /\ dataExposed' = dataExposed \cup {"proof_signals", "dac_shares"}
    /\ UNCHANGED << nodeState, txQueue, wal, walCheckpoint, smtState,
                    batchTxs, batchPrevSmt, l1State, pending,
                    crashCount, timerExpired >>

\* [Source: 0-input/code/src/orchestrator.ts, lines 392-398 (confirm)]
\* [Source: 0-input/REPORT.md, Section 2.5 -- Checkpoint triggers]
\* L1 confirms the batch. Critical state updates:
\*   - l1State advances to current SMT state (new on-chain root)
\*   - walCheckpoint advances by batch size only (deferred checkpoint)
\*   - batchTxs cleared (batch processing complete)
\*   - Returns to Idle
\*
\* The deferred checkpoint ensures pipelined txs (received during
\* proving/submitting) remain in the uncommitted WAL segment and are
\* recoverable after crash. Learned from RU-V4 BatchAggregation v1-fix.
ConfirmBatch ==
    /\ nodeState = "Submitting"
    /\ l1State' = smtState
    /\ walCheckpoint' = walCheckpoint + Len(batchTxs)
    /\ batchTxs' = << >>
    /\ batchPrevSmt' = {}
    /\ nodeState' = "Idle"
    /\ UNCHANGED << txQueue, wal, smtState, dataExposed, pending,
                    crashCount, timerExpired >>

\* [Source: 0-input/REPORT.md, Section 2.5 -- Crash Recovery Design]
\* System crash: all volatile (in-memory) state is lost.
\* Durable state persists: WAL, walCheckpoint, l1State (on-chain).
\* SMT is reset to last checkpoint value (= l1State).
\* Can occur in any operational state (Receiving through Submitting).
Crash ==
    /\ nodeState \in {"Receiving", "Batching", "Proving", "Submitting"}
    /\ crashCount < MaxCrashes
    /\ txQueue' = << >>
    /\ batchTxs' = << >>
    /\ batchPrevSmt' = {}
    /\ smtState' = l1State
    /\ nodeState' = "Error"
    /\ crashCount' = crashCount + 1
    /\ timerExpired' = FALSE
    /\ UNCHANGED << wal, walCheckpoint, l1State, dataExposed, pending >>

\* [Source: 0-input/REPORT.md, Section 4.3 -- Risk: L1 submission timeout]
\* L1 rejects the submission (nonce conflict, gas issue, contract revert).
\* Batch txs remain in WAL (not checkpointed). Node enters Error for retry.
\* SMT rolls back to last confirmed state (l1State).
L1Reject ==
    /\ nodeState = "Submitting"
    /\ txQueue' = << >>
    /\ batchTxs' = << >>
    /\ batchPrevSmt' = {}
    /\ smtState' = l1State
    /\ nodeState' = "Error"
    /\ timerExpired' = FALSE
    /\ UNCHANGED << wal, walCheckpoint, l1State, dataExposed, pending,
                    crashCount >>

\* [Source: 0-input/code/src/state-machine.ts, line 40 (RetryRequested)]
\* [Source: 0-input/REPORT.md, Section 2.5 -- Recovery protocol steps 1-6]
\* Recovery from error state (crash or L1 rejection):
\*   1. Restore SMT from checkpoint (= l1State)
\*   2. Replay WAL entries after checkpoint to rebuild queue
\*   3. Return to Idle for normal operation
Retry ==
    /\ nodeState = "Error"
    /\ txQueue' = SubSeq(wal, walCheckpoint + 1, Len(wal))
    /\ smtState' = l1State
    /\ nodeState' = "Idle"
    /\ UNCHANGED << wal, walCheckpoint, batchTxs, batchPrevSmt, l1State,
                    dataExposed, pending, crashCount, timerExpired >>

\* [Source: 0-input/REPORT.md, Section 2.2 -- "HYBRID: size OR time"]
\* Nondeterministic timer expiration. Abstracts the passage of real time:
\* at any point during Receiving with a non-empty queue, the time threshold
\* can be considered elapsed. Over-approximation: explores strictly more
\* behaviors than reality (sound for safety checking).
TimerTick ==
    /\ nodeState = "Receiving"
    /\ ~timerExpired
    /\ Len(txQueue) > 0
    /\ timerExpired' = TRUE
    /\ UNCHANGED << nodeState, txQueue, wal, walCheckpoint, smtState,
                    batchTxs, batchPrevSmt, l1State, dataExposed,
                    pending, crashCount >>

\* Terminal state: all transactions have been confirmed on L1.
\* The system has completed all work. Stuttering self-loop prevents
\* TLC from flagging this legitimate end state as a deadlock.
Done ==
    /\ pending = {}
    /\ Len(txQueue) = 0
    /\ Len(batchTxs) = 0
    /\ nodeState = "Idle"
    /\ UNCHANGED vars

(* ====================================================================== *)
(*                         NEXT-STATE RELATION                            *)
(* ====================================================================== *)

Next ==
    \/ \E tx \in pending : ReceiveTx(tx)
    \/ CheckQueue
    \/ FormBatch
    \/ GenerateWitness
    \/ GenerateProof
    \/ SubmitBatch
    \/ ConfirmBatch
    \/ Crash
    \/ L1Reject
    \/ Retry
    \/ TimerTick
    \/ Done

(* ====================================================================== *)
(*                         FAIRNESS                                       *)
(* ====================================================================== *)

\* Fairness constraints for liveness checking.
\*
\* Strong fairness (SF) is required for all progress actions because Crash
\* can intermittently disable them. SF guarantees: if an action is enabled
\* infinitely often, it eventually executes. This models the realistic
\* assumption that crashes are intermittent, not adversarial.
\*
\* Weak fairness (WF) suffices for Retry: it is the only enabled action
\* when nodeState = "Error" (no preemption possible in Error state).
\*
\* Crash and L1Reject have NO fairness: they are adversarial events that
\* may or may not occur (nondeterministic environment).
\*
\* Reference: Lamport, "Specifying Systems", Section 8.9.
Fairness ==
    /\ \A tx \in AllTxs : SF_vars(ReceiveTx(tx))
    /\ SF_vars(CheckQueue)
    /\ SF_vars(FormBatch)
    /\ SF_vars(GenerateWitness)
    /\ SF_vars(GenerateProof)
    /\ SF_vars(SubmitBatch)
    /\ SF_vars(ConfirmBatch)
    /\ WF_vars(Retry)
    /\ SF_vars(TimerTick)

Spec == Init /\ [][Next]_vars /\ Fairness

(* ====================================================================== *)
(*                         SAFETY PROPERTIES                              *)
(* ====================================================================== *)

\* [Why]: INV-NO2 -- Proof-State Root Integrity.
\* When submitting a batch to L1, the batch's recorded pre-state must
\* match the last confirmed state on L1. The Groth16 circuit enforces
\* that the proof's public signals (prevRoot, newRoot) match the witness
\* inputs, and the L1 StateCommitment contract verifies:
\*   submittedPrevRoot == lastConfirmedRoot
\* This invariant ensures the node-side chain is consistent: no gaps,
\* no reversals, no orphaned state transitions.
\* [Source: 0-input/REPORT.md, Section 7.2 -- INV-NO2]
ProofStateIntegrity ==
    nodeState = "Submitting" => batchPrevSmt = l1State

\* [Why]: INV-NO3 -- Privacy / Zero Data Leakage.
\* The only data transmitted outside the node boundary are proofs,
\* public signals (state roots, batch number, enterprise ID), and
\* Shamir shares to DAC nodes. Raw enterprise transaction data NEVER
\* exits the node. The adapter layer ensures the node receives only
\* (key, valueHash) pairs, never raw PLASMA/Trace data.
\* [Source: 0-input/REPORT.md, Section 2.4 -- Privacy Architecture]
NoDataLeakage ==
    dataExposed \subseteq AllowedExternalData

\* [Why]: INV-NO4 -- Crash Recovery / No Transaction Loss.
\* Every transaction is accounted for in exactly one durable partition:
\*   - pending: not yet received by the node
\*   - UncommittedWalTxSet: received but not confirmed (WAL after checkpoint)
\*   - l1State: confirmed on L1 (checkpointed and on-chain)
\* Uses only durable state references, so this holds across crash/recovery
\* boundaries without depending on volatile memory.
\* [Source: 0-input/REPORT.md, Section 7.2 -- INV-NO4]
NoTransactionLoss ==
    pending \cup UncommittedWalTxSet \cup l1State = AllTxs

\* [Why]: INV-NO4 complement -- No transaction exists in two durable
\* partitions simultaneously. Violation indicates double-delivery,
\* recovery duplication, or a checkpoint boundary error.
NoDuplication ==
    /\ pending \cap UncommittedWalTxSet = {}
    /\ pending \cap l1State = {}
    /\ UncommittedWalTxSet \cap l1State = {}

\* [Why]: INV-NO5 -- State Root Continuity.
\* The SMT state is consistent with the node's processing phase:
\*   - Idle/Receiving/Batching/Error: smtState = l1State (no batch applied)
\*   - Proving/Submitting: smtState = l1State + batch txs (batch applied)
\* This ensures no state root gaps, no orphaned transitions, and the SMT
\* is always derivable from the last confirmed state plus the current batch.
\* [Source: 0-input/REPORT.md, Section 7.2 -- INV-NO5]
StateRootContinuity ==
    \/ (nodeState \in {"Idle", "Receiving", "Batching", "Error"}
        /\ smtState = l1State)
    \/ (nodeState \in {"Proving", "Submitting"}
        /\ smtState = l1State \cup BatchTxSet)

\* [Why]: WAL-Queue Consistency (volatile-durable sync).
\* When the system is operational, the concatenation of the current batch
\* and the in-memory queue must exactly equal the uncommitted WAL segment.
\* Verifies: (a) no tx lost between queue and batch, (b) FIFO ordering
\* within the uncommitted segment, (c) crash recovery correctness.
\* Conditioned on operational state (Error clears volatile state).
\* [Source: Derived from RU-V4 QueueWalConsistency invariant]
QueueWalConsistency ==
    nodeState \notin {"Error"} =>
        batchTxs \o txQueue = SubSeq(wal, walCheckpoint + 1, Len(wal))

\* [Why]: Batch size bound. Every batch must respect the threshold to
\* ensure it fits within the ZK circuit's constraint capacity.
\* The state_transition circuit (RU-V2) has a fixed batch size parameter;
\* exceeding it causes witness generation failure.
BatchSizeBound ==
    Len(batchTxs) <= BatchThreshold

(* ====================================================================== *)
(*                         LIVENESS PROPERTIES                            *)
(* ====================================================================== *)

\* [Why]: INV-NO1 -- End-to-end delivery guarantee.
\* Every transaction must eventually be confirmed on L1. This is the
\* strongest liveness property: it implies all txs are eventually received,
\* batched, proved, submitted, and confirmed. Requires fairness on all
\* progress actions and bounded crash count.
\* [Source: 0-input/REPORT.md, Section 7.2 -- INV-NO1]
EventualConfirmation ==
    <>(\A tx \in AllTxs : tx \in l1State)

====
