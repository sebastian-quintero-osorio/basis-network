---- MODULE StateCommitment ----
(*
 * Formal specification of the Basis Network L1 State Commitment Protocol.
 *
 * Models per-enterprise state root chains with integrated ZK verification.
 * Each enterprise maintains an independent chain of state roots, advanced
 * atomically by batch submissions that include a valid ZK proof.
 *
 * [Source: 0-input/REPORT.md -- "L1 State Commitment Protocol (RU-V3)"]
 * [Source: 0-input/code/StateCommitmentV1.sol -- "Minimal Layout"]
 *)

EXTENDS Integers, FiniteSets, TLC

(* ========================================
              CONSTANTS
   ======================================== *)

CONSTANTS
    Enterprises,    \* Set of enterprise identifiers (e.g., {"e1", "e2"})
    MaxBatches,     \* Upper bound on batches per enterprise (finite model)
    Roots,          \* Finite set of abstract state root values (hash domain)
    None            \* Sentinel value for empty slots (must not be in Roots)

ASSUME None \notin Roots
ASSUME MaxBatches \in Nat /\ MaxBatches > 0
ASSUME Enterprises # {}
ASSUME Roots # {}

(* ========================================
              VARIABLES
   ======================================== *)

VARIABLES
    currentRoot,    \* [Enterprises -> Roots \cup {None}]: current chain head per enterprise
    batchCount,     \* [Enterprises -> 0..MaxBatches]: next batch ID (auto-incrementing)
    initialized,    \* [Enterprises -> BOOLEAN]: enterprise initialization status
    batchHistory,   \* [Enterprises -> [0..(MaxBatches-1) -> Roots \cup {None}]]: root log
    totalCommitted  \* Nat: global counter of all committed batches

vars == <<currentRoot, batchCount, initialized, batchHistory, totalCommitted>>

(* ========================================
              TYPE INVARIANT
   ======================================== *)

\* [Why]: Ensures all variables remain within their declared domains.
\* A TypeOK violation indicates a modeling error in the specification itself.
TypeOK ==
    /\ currentRoot \in [Enterprises -> Roots \cup {None}]
    /\ batchCount \in [Enterprises -> 0..MaxBatches]
    /\ initialized \in [Enterprises -> BOOLEAN]
    /\ totalCommitted \in 0..(Cardinality(Enterprises) * MaxBatches)
    /\ batchHistory \in [Enterprises -> [0..(MaxBatches - 1) -> Roots \cup {None}]]

(* ========================================
              INITIAL STATE
   ======================================== *)

\* [Source: 0-input/code/StateCommitmentV1.sol, constructor]
\* All enterprises start uninitialized. No roots, no history, no batches.
Init ==
    /\ currentRoot = [e \in Enterprises |-> None]
    /\ batchCount = [e \in Enterprises |-> 0]
    /\ initialized = [e \in Enterprises |-> FALSE]
    /\ batchHistory = [e \in Enterprises |-> [i \in 0..(MaxBatches - 1) |-> None]]
    /\ totalCommitted = 0

(* ========================================
              ACTIONS
   ======================================== *)

\* [Source: 0-input/code/StateCommitmentV1.sol, lines 109-118]
\* Admin initializes an enterprise's state chain with a genesis root.
\* Guard: enterprise must not already be initialized (EnterpriseAlreadyInitialized error).
\* Effect: sets currentRoot to genesisRoot, marks initialized = TRUE.
\* The genesis root represents the initial state of the enterprise's Sparse Merkle Tree.
InitializeEnterprise(e, genesisRoot) ==
    /\ e \in Enterprises
    /\ ~initialized[e]
    /\ genesisRoot \in Roots
    /\ initialized' = [initialized EXCEPT ![e] = TRUE]
    /\ currentRoot' = [currentRoot EXCEPT ![e] = genesisRoot]
    /\ UNCHANGED <<batchCount, batchHistory, totalCommitted>>

\* [Source: 0-input/code/StateCommitmentV1.sol, lines 132-181]
\* Enterprise submits a batch with ZK proof. Atomic proof verification + state update.
\*
\* Guards (faithfully modeled from Solidity):
\*   1. Enterprise must be initialized          [line 148: es.initialized check]
\*   2. prevRoot must match currentRoot          [line 151: ChainContinuity / INV-S1]
\*   3. Proof must be valid                      [line 156: ProofBeforeState / INV-S2]
\*
\* Structural guarantee (not a guard -- inherent in the protocol):
\*   4. batchId = batchCount (auto-incremented)  [line 160: NoGap]
\*
\* The model non-deterministically generates both valid and invalid proofs.
\* Invalid proofs are blocked by guard (3), so they never lead to state changes.
\* This allows the model checker to verify ProofBeforeState exhaustively.
SubmitBatch(e, prevRoot, newRoot, proofIsValid) ==
    /\ e \in Enterprises
    /\ initialized[e]                           \* Guard 1: must be initialized
    /\ batchCount[e] < MaxBatches               \* Finite model bound
    /\ prevRoot = currentRoot[e]                 \* Guard 2: ChainContinuity (INV-S1)
    /\ proofIsValid = TRUE                       \* Guard 3: ProofBeforeState (INV-S2)
    /\ newRoot \in Roots                         \* New root is in the hash domain
    /\ LET bid == batchCount[e]
       IN
        /\ currentRoot' = [currentRoot EXCEPT ![e] = newRoot]
        /\ batchCount' = [batchCount EXCEPT ![e] = bid + 1]
        /\ batchHistory' = [batchHistory EXCEPT ![e][bid] = newRoot]
        /\ totalCommitted' = totalCommitted + 1
    /\ UNCHANGED <<initialized>>

(* ========================================
              NEXT STATE RELATION
   ======================================== *)

\* The model non-deterministically chooses:
\*   - Which enterprise acts (any e in Enterprises)
\*   - Action type (initialize or submit batch)
\*   - Root values (any r in Roots for genesis/newRoot, any prev in Roots \cup {None})
\*   - Proof validity (TRUE or FALSE -- FALSE is blocked by the guard)
\*
\* Attack simulation:
\*   - Gap attack: impossible because batchId is not a parameter (structural NoGap).
\*     TLC explores all interleavings and confirms no batch ID can be skipped.
\*   - Replay attack: blocked by ChainContinuity. After SubmitBatch(e, rA, rB, TRUE),
\*     currentRoot[e] = rB. A replay with prevRoot = rA fails because rA # rB = currentRoot.
\*     Exception: if newRoot = prevRoot (no-op), replays succeed but are harmless
\*     (batchCount still increments, no state corruption).
\*   - Cross-enterprise attack: EXCEPT ![e] semantics ensure enterprise e's action
\*     only modifies enterprise e's state. TLC verifies this across all interleavings.
Next ==
    \/ \E e \in Enterprises, r \in Roots :
        InitializeEnterprise(e, r)
    \/ \E e \in Enterprises, prev \in Roots \cup {None}, new \in Roots, valid \in BOOLEAN :
        SubmitBatch(e, prev, new, valid)

(* ========================================
              SPECIFICATION
   ======================================== *)

Spec == Init /\ [][Next]_vars

(* ========================================
              SAFETY PROPERTIES
   ======================================== *)

\* [Why]: The current root must always reflect the latest committed batch.
\*        If currentRoot[e] diverges from batchHistory[e][batchCount[e]-1],
\*        the state chain has been corrupted -- a downstream verifier would
\*        accept batches against a stale or forged root.
\* [Source: 0-input/REPORT.md, "INV-S1: ChainContinuity"]
\* [Source: 0-input/code/StateCommitmentV1.sol, line 151]
ChainContinuity ==
    \A e \in Enterprises :
        (initialized[e] /\ batchCount[e] > 0) =>
            currentRoot[e] = batchHistory[e][batchCount[e] - 1]

\* [Why]: Batch IDs must form a dense sequence [0, 1, 2, ...] with no gaps.
\*        A gap would mean a batch was skipped, breaking the audit trail.
\*        All slots below batchCount must be filled; all slots at or above must be empty.
\* [Source: 0-input/REPORT.md, "NoGap: Sequential batch IDs"]
\* [Source: 0-input/code/StateCommitmentV1.sol, line 160 -- batchId = es.batchCount]
NoGap ==
    \A e \in Enterprises :
        /\ \A i \in 0..(MaxBatches - 1) :
            (i < batchCount[e]) => (batchHistory[e][i] # None)
        /\ \A i \in 0..(MaxBatches - 1) :
            (i >= batchCount[e]) => (batchHistory[e][i] = None)

\* [Why]: An initialized enterprise must always have a valid state root (not None).
\*        Without an explicit rollback action in the protocol, the chain head
\*        can only advance to new roots -- it must never revert to the uninitialized
\*        sentinel. A None currentRoot on an initialized enterprise would mean the
\*        state chain has been destroyed.
\* [Source: 0-input/REPORT.md, "NoReversal"]
NoReversal ==
    \A e \in Enterprises :
        initialized[e] => (currentRoot[e] \in Roots)

\* [Why]: Batches can only exist for initialized enterprises.
\*        If an uninitialized enterprise has batchCount > 0, authorization
\*        was bypassed -- a critical security violation.
\* [Source: 0-input/code/StateCommitmentV1.sol, line 148 -- es.initialized check]
InitBeforeBatch ==
    \A e \in Enterprises :
        (batchCount[e] > 0) => initialized[e]

\* Helper: sum of batchCounts across all enterprises.
RECURSIVE SumBatchesHelper(_, _)
SumBatchesHelper(S, acc) ==
    IF S = {} THEN acc
    ELSE LET e == CHOOSE x \in S : TRUE
         IN SumBatchesHelper(S \ {e}, acc + batchCount[e])

SumBatches(S) == SumBatchesHelper(S, 0)

\* [Why]: totalCommitted must equal the sum of all enterprises' batchCounts.
\*        A mismatch indicates a batch was counted for the wrong enterprise
\*        or counted multiple times -- both are state corruption.
\* [Source: 0-input/code/StateCommitmentV1.sol, line 170 -- totalBatchesCommitted++]
GlobalCountIntegrity ==
    totalCommitted = SumBatches(Enterprises)

====
