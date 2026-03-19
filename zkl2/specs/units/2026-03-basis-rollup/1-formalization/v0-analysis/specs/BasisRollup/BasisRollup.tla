---- MODULE BasisRollup ----
(*
 * Formal specification of the Basis Network L1 Rollup Contract (BasisRollup.sol).
 *
 * Extends the validium StateCommitment (RU-V3) single-phase model to a three-phase
 * commit-prove-execute lifecycle for the full zkEVM L2. Each enterprise maintains
 * an independent batch chain with per-batch status tracking.
 *
 * Lifecycle per batch:
 *   CommitBatch  -> status = "Committed"  (sequencer posts metadata)
 *   ProveBatch   -> status = "Proven"     (prover submits Groth16 validity proof)
 *   ExecuteBatch -> status = "Executed"   (state root finalized)
 *   RevertBatch  -> batch deleted          (admin reverts unexecuted batch)
 *
 * [Source: 0-input/REPORT.md -- "Design: BasisRollup.sol"]
 * [Source: 0-input/code/contracts/BasisRollup.sol]
 * [Reference: validium/specs/units/2026-03-state-commitment/ -- StateCommitment.tla]
 *)

EXTENDS Integers, FiniteSets, Sequences, TLC

(* ========================================
              CONSTANTS
   ======================================== *)

CONSTANTS
    Enterprises,    \* Set of enterprise identifiers (e.g., {"e1", "e2"})
    MaxBatches,     \* Upper bound on batches per enterprise (finite model)
    Roots,          \* Finite set of abstract state root values (hash domain)
    None            \* Sentinel value for empty/uninitialized slots

ASSUME None \notin Roots
ASSUME MaxBatches \in Nat /\ MaxBatches > 0
ASSUME Enterprises # {}
ASSUME Roots # {}

(* ========================================
              DERIVED CONSTANTS
   ======================================== *)

\* Batch status values -- modeled as strings for readability.
\* [Source: 0-input/code/contracts/BasisRollup.sol, line 34]
\* enum BatchStatus { None, Committed, Proven, Executed }
StatusNone      == "None"
StatusCommitted == "Committed"
StatusProven    == "Proven"
StatusExecuted  == "Executed"

AllStatuses == {StatusNone, StatusCommitted, StatusProven, StatusExecuted}

\* Batch index domain
BatchIds == 0..(MaxBatches - 1)

(* ========================================
              VARIABLES
   ======================================== *)

VARIABLES
    currentRoot,            \* [Enterprises -> Roots \cup {None}]: finalized state root per enterprise
    initialized,            \* [Enterprises -> BOOLEAN]: enterprise initialization status
    totalBatchesCommitted,  \* [Enterprises -> 0..MaxBatches]: next batch to commit
    totalBatchesProven,     \* [Enterprises -> 0..MaxBatches]: next batch to prove
    totalBatchesExecuted,   \* [Enterprises -> 0..MaxBatches]: next batch to execute
    batchStatus,            \* [Enterprises -> [BatchIds -> AllStatuses]]: per-batch lifecycle status
    batchRoot,              \* [Enterprises -> [BatchIds -> Roots \cup {None}]]: per-batch target state root
    globalCommitted,        \* Nat: global counter across all enterprises (committed)
    globalProven,           \* Nat: global counter across all enterprises (proven)
    globalExecuted          \* Nat: global counter across all enterprises (executed)

vars == <<currentRoot, initialized, totalBatchesCommitted, totalBatchesProven,
          totalBatchesExecuted, batchStatus, batchRoot, globalCommitted,
          globalProven, globalExecuted>>

(* ========================================
              TYPE INVARIANT
   ======================================== *)

\* [Why]: Ensures all variables remain within their declared domains.
\* A TypeOK violation indicates a modeling error in the specification itself.
TypeOK ==
    /\ currentRoot \in [Enterprises -> Roots \cup {None}]
    /\ initialized \in [Enterprises -> BOOLEAN]
    /\ totalBatchesCommitted \in [Enterprises -> 0..MaxBatches]
    /\ totalBatchesProven \in [Enterprises -> 0..MaxBatches]
    /\ totalBatchesExecuted \in [Enterprises -> 0..MaxBatches]
    /\ batchStatus \in [Enterprises -> [BatchIds -> AllStatuses]]
    /\ batchRoot \in [Enterprises -> [BatchIds -> Roots \cup {None}]]
    /\ globalCommitted \in 0..(Cardinality(Enterprises) * MaxBatches)
    /\ globalProven \in 0..(Cardinality(Enterprises) * MaxBatches)
    /\ globalExecuted \in 0..(Cardinality(Enterprises) * MaxBatches)

(* ========================================
              INITIAL STATE
   ======================================== *)

\* [Source: 0-input/code/contracts/BasisRollup.sol, constructor]
\* All enterprises start uninitialized. No roots, no batches, no history.
Init ==
    /\ currentRoot = [e \in Enterprises |-> None]
    /\ initialized = [e \in Enterprises |-> FALSE]
    /\ totalBatchesCommitted = [e \in Enterprises |-> 0]
    /\ totalBatchesProven = [e \in Enterprises |-> 0]
    /\ totalBatchesExecuted = [e \in Enterprises |-> 0]
    /\ batchStatus = [e \in Enterprises |-> [i \in BatchIds |-> StatusNone]]
    /\ batchRoot = [e \in Enterprises |-> [i \in BatchIds |-> None]]
    /\ globalCommitted = 0
    /\ globalProven = 0
    /\ globalExecuted = 0

(* ========================================
              ACTIONS
   ======================================== *)

\* ------------------------------------------------------------------
\* InitializeEnterprise(e, genesisRoot)
\* ------------------------------------------------------------------
\* [Source: 0-input/code/contracts/BasisRollup.sol, lines 213-229]
\* Admin initializes an enterprise's state chain with a genesis root.
\* Guard: enterprise must not already be initialized (EnterpriseAlreadyInitialized).
\* Effect: sets currentRoot to genesisRoot, marks initialized = TRUE.
InitializeEnterprise(e, genesisRoot) ==
    /\ e \in Enterprises
    /\ ~initialized[e]
    /\ genesisRoot \in Roots
    /\ initialized' = [initialized EXCEPT ![e] = TRUE]
    /\ currentRoot' = [currentRoot EXCEPT ![e] = genesisRoot]
    /\ UNCHANGED <<totalBatchesCommitted, totalBatchesProven, totalBatchesExecuted,
                   batchStatus, batchRoot, globalCommitted, globalProven, globalExecuted>>

\* ------------------------------------------------------------------
\* CommitBatch(e, newRoot)
\* ------------------------------------------------------------------
\* [Source: 0-input/code/contracts/BasisRollup.sol, lines 240-293]
\* Phase 1: Sequencer commits batch metadata. No proof verification.
\*
\* Guards:
\*   1. Enterprise must be initialized              [line 244: es.initialized check]
\*   2. Batch ID auto-incremented from counter      [line 255: NoGap structural]
\*   3. totalBatchesCommitted < MaxBatches           [finite model bound]
\*
\* Effect:
\*   - Stores batch with status Committed and target state root
\*   - Increments totalBatchesCommitted for enterprise
\*   - Increments globalCommitted
\*
\* Note: Block range tracking (l2BlockStart, l2BlockEnd) is abstracted away.
\* The TLA+ model focuses on the batch lifecycle state machine, not L2 block
\* numbering. INV-R4 MonotonicBlockRange is a data-level constraint enforced
\* by uint64 comparisons in Solidity; it does not affect the lifecycle invariants.
CommitBatch(e, newRoot) ==
    /\ e \in Enterprises
    /\ initialized[e]
    /\ totalBatchesCommitted[e] < MaxBatches
    /\ newRoot \in Roots
    /\ LET bid == totalBatchesCommitted[e]
       IN
        /\ batchStatus' = [batchStatus EXCEPT ![e][bid] = StatusCommitted]
        /\ batchRoot' = [batchRoot EXCEPT ![e][bid] = newRoot]
        /\ totalBatchesCommitted' = [totalBatchesCommitted EXCEPT ![e] = bid + 1]
        /\ globalCommitted' = globalCommitted + 1
    /\ UNCHANGED <<currentRoot, initialized, totalBatchesProven,
                   totalBatchesExecuted, globalProven, globalExecuted>>

\* ------------------------------------------------------------------
\* ProveBatch(e, proofIsValid)
\* ------------------------------------------------------------------
\* [Source: 0-input/code/contracts/BasisRollup.sol, lines 308-337]
\* Phase 2: Prover submits Groth16 validity proof for committed batch.
\*
\* Guards:
\*   1. Enterprise must be initialized              [line 319]
\*   2. batchId == totalBatchesProven (sequential)   [line 322: BatchNotNextToProve]
\*   3. Batch status must be Committed               [line 325: BatchNotCommitted]
\*   4. Proof must be valid                          [line 329: INV-S2 ProofBeforeState]
\*
\* Effect:
\*   - Transitions batch status: Committed -> Proven
\*   - Increments totalBatchesProven
\*   - Increments globalProven
\*
\* The model non-deterministically generates both valid and invalid proofs.
\* Invalid proofs are blocked by guard (4), exercising the ProofBeforeState invariant.
ProveBatch(e, proofIsValid) ==
    /\ e \in Enterprises
    /\ initialized[e]
    /\ totalBatchesProven[e] < totalBatchesCommitted[e]
    /\ LET bid == totalBatchesProven[e]
       IN
        /\ batchStatus[e][bid] = StatusCommitted
        /\ proofIsValid = TRUE                      \* Guard 4: proof verification
        /\ batchStatus' = [batchStatus EXCEPT ![e][bid] = StatusProven]
        /\ totalBatchesProven' = [totalBatchesProven EXCEPT ![e] = bid + 1]
        /\ globalProven' = globalProven + 1
    /\ UNCHANGED <<currentRoot, initialized, totalBatchesCommitted,
                   totalBatchesExecuted, batchRoot, globalCommitted, globalExecuted>>

\* ------------------------------------------------------------------
\* ExecuteBatch(e)
\* ------------------------------------------------------------------
\* [Source: 0-input/code/contracts/BasisRollup.sol, lines 349-375]
\* Phase 3: Finalizes a proven batch, advancing the enterprise state root.
\*
\* Guards:
\*   1. Enterprise must be initialized              [line 352]
\*   2. batchId == totalBatchesExecuted (sequential) [line 356: INV-R1 SequentialExecution]
\*   3. Batch status must be Proven                  [line 359: INV-R2 ProveBeforeExecute]
\*
\* Effect:
\*   - Advances currentRoot to the batch's committed state root
\*   - Transitions batch status: Proven -> Executed
\*   - Increments totalBatchesExecuted
\*   - Increments globalExecuted
\*
\* This is where INV-S1 ChainContinuity is enforced: currentRoot is only
\* mutated here, and only to a root that was committed in CommitBatch.
ExecuteBatch(e) ==
    /\ e \in Enterprises
    /\ initialized[e]
    /\ totalBatchesExecuted[e] < totalBatchesProven[e]
    /\ LET bid == totalBatchesExecuted[e]
       IN
        /\ batchStatus[e][bid] = StatusProven
        /\ currentRoot' = [currentRoot EXCEPT ![e] = batchRoot[e][bid]]
        /\ batchStatus' = [batchStatus EXCEPT ![e][bid] = StatusExecuted]
        /\ totalBatchesExecuted' = [totalBatchesExecuted EXCEPT ![e] = bid + 1]
        /\ globalExecuted' = globalExecuted + 1
    /\ UNCHANGED <<initialized, totalBatchesCommitted, totalBatchesProven,
                   batchRoot, globalCommitted, globalProven>>

\* ------------------------------------------------------------------
\* RevertBatch(e)
\* ------------------------------------------------------------------
\* [Source: 0-input/code/contracts/BasisRollup.sol, lines 386-416]
\* Admin reverts the last committed (but not executed) batch.
\*
\* Guards:
\*   1. Enterprise must be initialized              [line 388]
\*   2. There must be uncommitted batches            [line 389: NothingToRevert]
\*      i.e., totalBatchesCommitted > totalBatchesExecuted
\*   3. The last batch must NOT be Executed           [line 395: INV-R5 RevertSafety]
\*
\* Effect:
\*   - If batch was Proven: also decrements totalBatchesProven and globalProven
\*   - Clears batch data (status -> None, root -> None)
\*   - Decrements totalBatchesCommitted and globalCommitted
\*
\* Note: In Solidity, revert always targets batchId = totalBatchesCommitted - 1
\* (the most recently committed batch). This is a stack-like LIFO revert.
RevertBatch(e) ==
    /\ e \in Enterprises
    /\ initialized[e]
    /\ totalBatchesCommitted[e] > totalBatchesExecuted[e]
    /\ LET bid == totalBatchesCommitted[e] - 1
       IN
        /\ batchStatus[e][bid] # StatusExecuted     \* INV-R5: cannot revert executed
        \* If the batch was proven, revert the proven counter too
        /\ IF batchStatus[e][bid] = StatusProven
           THEN
             /\ totalBatchesProven' = [totalBatchesProven EXCEPT ![e] = bid]
             /\ globalProven' = globalProven - 1
           ELSE
             /\ totalBatchesProven' = totalBatchesProven
             /\ globalProven' = globalProven
        /\ batchStatus' = [batchStatus EXCEPT ![e][bid] = StatusNone]
        /\ batchRoot' = [batchRoot EXCEPT ![e][bid] = None]
        /\ totalBatchesCommitted' = [totalBatchesCommitted EXCEPT ![e] = bid]
        /\ globalCommitted' = globalCommitted - 1
    /\ UNCHANGED <<currentRoot, initialized, totalBatchesExecuted, globalExecuted>>

(* ========================================
              NEXT STATE RELATION
   ======================================== *)

\* The model non-deterministically chooses:
\*   - Which enterprise acts (any e in Enterprises)
\*   - Action type (initialize, commit, prove, execute, or revert)
\*   - Root values (any r in Roots for genesis/newRoot)
\*   - Proof validity (TRUE or FALSE -- FALSE is blocked by guard)
\*
\* Attack simulation coverage:
\*   - Out-of-order execution: TLC explores all interleavings. The sequential
\*     counter guards (totalBatchesProven, totalBatchesExecuted) prevent skipping.
\*   - Proof bypass: proofIsValid = FALSE is generated but blocked by ProveBatch guard.
\*   - Cross-enterprise: EXCEPT ![e] semantics isolate enterprise state.
\*   - Revert of executed: blocked by RevertBatch guard on StatusExecuted.
\*   - Double prove/execute: blocked by status checks (Committed->Proven->Executed).
Next ==
    \/ \E e \in Enterprises, r \in Roots :
        InitializeEnterprise(e, r)
    \/ \E e \in Enterprises, r \in Roots :
        CommitBatch(e, r)
    \/ \E e \in Enterprises, valid \in BOOLEAN :
        ProveBatch(e, valid)
    \/ \E e \in Enterprises :
        ExecuteBatch(e)
    \/ \E e \in Enterprises :
        RevertBatch(e)

(* ========================================
              SPECIFICATION
   ======================================== *)

Spec == Init /\ [][Next]_vars

(* ========================================
              SAFETY PROPERTIES
   ======================================== *)

\* ------------------------------------------------------------------
\* BatchChainContinuity (extends INV-S1 from StateCommitment)
\* ------------------------------------------------------------------
\* [Why]: After execution, the currentRoot must equal the state root of the
\*        most recently executed batch. If they diverge, the chain head is
\*        corrupted -- downstream verifiers would accept batches against a
\*        stale or forged root.
\* [Source: 0-input/REPORT.md, "INV-S1 ChainContinuity"]
\* [Source: 0-input/code/contracts/BasisRollup.sol, line 363]
BatchChainContinuity ==
    \A e \in Enterprises :
        (initialized[e] /\ totalBatchesExecuted[e] > 0) =>
            currentRoot[e] = batchRoot[e][totalBatchesExecuted[e] - 1]

\* ------------------------------------------------------------------
\* ProveBeforeExecute (INV-R2)
\* ------------------------------------------------------------------
\* [Why]: A batch must be in Proven status before it can transition to Executed.
\*        Without this, a malicious sequencer could finalize state without a
\*        validity proof, defeating the purpose of the rollup.
\* [Source: 0-input/REPORT.md, "INV-R2 ProveBeforeExecute"]
\* [Source: 0-input/code/contracts/BasisRollup.sol, line 359]
ProveBeforeExecute ==
    \A e \in Enterprises, i \in BatchIds :
        (batchStatus[e][i] = StatusExecuted) =>
            \* The batch must have passed through Proven before reaching Executed.
            \* Structurally enforced: ExecuteBatch requires StatusProven.
            \* Counter-level: the batch index must be below the proven watermark.
            (i < totalBatchesProven[e])

\* ------------------------------------------------------------------
\* ExecuteInOrder (INV-R1)
\* ------------------------------------------------------------------
\* [Why]: Batches must be executed in strict sequential order. Skipping a batch
\*        would leave a gap in the state root chain, allowing an unverified
\*        state transition to be finalized.
\* [Source: 0-input/REPORT.md, "INV-R1 SequentialExecution"]
\* [Source: 0-input/code/contracts/BasisRollup.sol, line 356]
ExecuteInOrder ==
    \A e \in Enterprises :
        \A i \in BatchIds :
            (batchStatus[e][i] = StatusExecuted) =>
                \* All batches before this one must also be executed
                \A j \in BatchIds :
                    (j < i) => (batchStatus[e][j] = StatusExecuted)

\* ------------------------------------------------------------------
\* RevertSafety (INV-R5)
\* ------------------------------------------------------------------
\* [Why]: Executed batches are finalized -- their state root has already been
\*        applied to the enterprise chain head. Reverting an executed batch
\*        would corrupt the chain by creating a gap between the chain head
\*        and the batch history.
\* [Source: 0-input/REPORT.md, "INV-R5 RevertSafety"]
\* [Source: 0-input/code/contracts/BasisRollup.sol, line 395]
\* Formulated as: executed batches can never return to None (deleted) status.
\* Since RevertBatch sets status to None, this invariant ensures no executed
\* batch is ever the target of a revert.
RevertSafety ==
    \A e \in Enterprises :
        \A i \in BatchIds :
            (i < totalBatchesExecuted[e]) =>
                batchStatus[e][i] = StatusExecuted

\* ------------------------------------------------------------------
\* CommitBeforeProve (INV-R3)
\* ------------------------------------------------------------------
\* [Why]: A batch must be committed before it can be proven. Without this,
\*        a prover could submit a proof for a non-existent batch.
\* [Source: 0-input/REPORT.md, "INV-R3 CommitBeforeProve"]
\* [Source: 0-input/code/contracts/BasisRollup.sol, line 325]
CommitBeforeProve ==
    \A e \in Enterprises :
        totalBatchesProven[e] <= totalBatchesCommitted[e]

\* ------------------------------------------------------------------
\* CounterMonotonicity
\* ------------------------------------------------------------------
\* [Why]: The three counters form a pipeline: executed <= proven <= committed.
\*        A violation means the lifecycle was bypassed -- a batch was proven
\*        without being committed, or executed without being proven.
\* [Source: 0-input/code/contracts/BasisRollup.sol, lines 322, 356]
CounterMonotonicity ==
    \A e \in Enterprises :
        /\ totalBatchesExecuted[e] <= totalBatchesProven[e]
        /\ totalBatchesProven[e] <= totalBatchesCommitted[e]
        /\ totalBatchesCommitted[e] <= MaxBatches

\* ------------------------------------------------------------------
\* NoReversal (preserved from StateCommitment)
\* ------------------------------------------------------------------
\* [Why]: An initialized enterprise must always have a valid state root.
\*        A None currentRoot on an initialized enterprise would mean the
\*        state chain has been destroyed.
\* [Source: validium StateCommitment.tla, NoReversal invariant]
NoReversal ==
    \A e \in Enterprises :
        initialized[e] => (currentRoot[e] \in Roots)

\* ------------------------------------------------------------------
\* InitBeforeBatch (preserved from StateCommitment)
\* ------------------------------------------------------------------
\* [Why]: Batches can only exist for initialized enterprises.
\*        If an uninitialized enterprise has batches, authorization was bypassed.
\* [Source: validium StateCommitment.tla, InitBeforeBatch invariant]
InitBeforeBatch ==
    \A e \in Enterprises :
        (totalBatchesCommitted[e] > 0) => initialized[e]

\* ------------------------------------------------------------------
\* StatusConsistency
\* ------------------------------------------------------------------
\* [Why]: Batch statuses must be consistent with the counter watermarks.
\*        Slots below the executed watermark must be Executed.
\*        Slots between executed and proven must be Proven.
\*        Slots between proven and committed must be Committed.
\*        Slots at or above committed must be None.
\*        Any violation means the status state machine was corrupted.
StatusConsistency ==
    \A e \in Enterprises :
        \A i \in BatchIds :
            /\ (i < totalBatchesExecuted[e]) => (batchStatus[e][i] = StatusExecuted)
            /\ (i >= totalBatchesExecuted[e] /\ i < totalBatchesProven[e]) =>
                    (batchStatus[e][i] = StatusProven)
            /\ (i >= totalBatchesProven[e] /\ i < totalBatchesCommitted[e]) =>
                    (batchStatus[e][i] = StatusCommitted)
            /\ (i >= totalBatchesCommitted[e]) => (batchStatus[e][i] = StatusNone)

\* ------------------------------------------------------------------
\* GlobalCountIntegrity (preserved from StateCommitment, extended)
\* ------------------------------------------------------------------
\* [Why]: Global counters must equal the sum of per-enterprise counters.
\*        A mismatch indicates a batch was counted for the wrong enterprise
\*        or counted multiple times -- both are state corruption.
\* [Source: 0-input/code/contracts/BasisRollup.sol, lines 96-98]

RECURSIVE SumHelper(_, _, _)
SumHelper(S, f, acc) ==
    IF S = {} THEN acc
    ELSE LET e == CHOOSE x \in S : TRUE
         IN SumHelper(S \ {e}, f, acc + f[e])

GlobalCountIntegrity ==
    /\ globalCommitted = SumHelper(Enterprises, totalBatchesCommitted, 0)
    /\ globalProven = SumHelper(Enterprises, totalBatchesProven, 0)
    /\ globalExecuted = SumHelper(Enterprises, totalBatchesExecuted, 0)

\* ------------------------------------------------------------------
\* BatchRootIntegrity
\* ------------------------------------------------------------------
\* [Why]: Every committed (or further) batch must have a valid root.
\*        Every uncommitted batch must have None as its root.
\*        A committed batch with a None root means the commit was incomplete;
\*        an uncommitted batch with a non-None root means phantom data exists.
BatchRootIntegrity ==
    \A e \in Enterprises :
        \A i \in BatchIds :
            /\ (batchStatus[e][i] \in {StatusCommitted, StatusProven, StatusExecuted}) =>
                    (batchRoot[e][i] \in Roots)
            /\ (batchStatus[e][i] = StatusNone) =>
                    (batchRoot[e][i] = None)

====
