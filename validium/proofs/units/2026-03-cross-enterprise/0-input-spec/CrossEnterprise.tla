---- MODULE CrossEnterprise ----
(**************************************************************************)
(* Cross-Enterprise Verification Protocol -- Basis Network Validium      *)
(*                                                                        *)
(* Formalizes the hub-and-spoke proof aggregation model where an L1       *)
(* smart contract aggregates ZK proofs from multiple enterprises and      *)
(* verifies cross-enterprise interactions without revealing private data.  *)
(*                                                                        *)
(* [Source: 0-input/REPORT.md -- RU-V7 Cross-Enterprise Verification]     *)
(* [Source: 0-input/hypothesis.json -- Hub-and-spoke model hypothesis]    *)
(**************************************************************************)

EXTENDS Integers, FiniteSets, TLC

(**************************************************************************)
(*                         CONSTANTS                                      *)
(**************************************************************************)
CONSTANTS
    Enterprises,      \* Set of registered enterprise identifiers
    BatchIds,         \* Set of batch identifiers per enterprise
    StateRoots,       \* Finite domain of state root hash values
    GenesisRoot       \* Initial state root for all enterprises

ASSUME GenesisRoot \in StateRoots

(**************************************************************************)
(*                       DERIVED SETS                                     *)
(**************************************************************************)

\* [Source: 0-input/REPORT.md, Section "Cross-Reference Circuit Design"]
\* Valid cross-reference identifiers: ordered pairs of DISTINCT enterprises
\* with their respective batch identifiers. Self-referencing is excluded
\* structurally by the r.src # r.dst filter.
CrossRefIds ==
    { r \in [src : Enterprises, dst : Enterprises,
             srcBatch : BatchIds, dstBatch : BatchIds] : r.src # r.dst }

(**************************************************************************)
(*                         VARIABLES                                      *)
(**************************************************************************)
VARIABLES
    currentRoot,      \* [Enterprises -> StateRoots] current verified state root per enterprise
    batchStatus,      \* [Enterprises -> [BatchIds -> {"idle","submitted","verified"}]]
    batchNewRoot,     \* [Enterprises -> [BatchIds -> StateRoots]] state root claimed per batch
    crossRefStatus    \* [CrossRefIds -> {"none","pending","verified","rejected"}]

vars == << currentRoot, batchStatus, batchNewRoot, crossRefStatus >>

(**************************************************************************)
(*                       TYPE INVARIANT                                   *)
(**************************************************************************)
TypeOK ==
    /\ currentRoot \in [Enterprises -> StateRoots]
    /\ batchStatus \in [Enterprises -> [BatchIds -> {"idle", "submitted", "verified"}]]
    /\ batchNewRoot \in [Enterprises -> [BatchIds -> StateRoots]]
    /\ crossRefStatus \in [CrossRefIds -> {"none", "pending", "verified", "rejected"}]

(**************************************************************************)
(*                       INITIAL STATE                                    *)
(**************************************************************************)

\* [Source: 0-input/REPORT.md -- all enterprises begin with genesis state root]
Init ==
    /\ currentRoot = [e \in Enterprises |-> GenesisRoot]
    /\ batchStatus = [e \in Enterprises |-> [b \in BatchIds |-> "idle"]]
    /\ batchNewRoot = [e \in Enterprises |-> [b \in BatchIds |-> GenesisRoot]]
    /\ crossRefStatus = [r \in CrossRefIds |-> "none"]

(**************************************************************************)
(*               INDIVIDUAL ENTERPRISE ACTIONS                            *)
(**************************************************************************)

\* [Source: 0-input/REPORT.md, "Sequential Verification" baseline]
\* Enterprise submits a batch claiming a new state root.
\* The new root must differ from the current root (non-trivial transition).
\* Transition: idle -> submitted
SubmitBatch(enterprise, batch, newRoot) ==
    /\ batchStatus[enterprise][batch] = "idle"
    /\ newRoot # currentRoot[enterprise]
    /\ batchStatus' = [batchStatus EXCEPT ![enterprise][batch] = "submitted"]
    /\ batchNewRoot' = [batchNewRoot EXCEPT ![enterprise][batch] = newRoot]
    /\ UNCHANGED << currentRoot, crossRefStatus >>

\* [Source: 0-input/REPORT.md, "Groth16 Individual Verification Cost" -- 205,600 gas]
\* Batch ZK proof is verified on L1. The enterprise state root advances to the
\* root claimed by the batch. This models the Groth16 proof verification
\* succeeding on the L1 verifier contract.
\* Transition: submitted -> verified
VerifyBatch(enterprise, batch) ==
    /\ batchStatus[enterprise][batch] = "submitted"
    /\ batchStatus' = [batchStatus EXCEPT ![enterprise][batch] = "verified"]
    /\ currentRoot' = [currentRoot EXCEPT ![enterprise] = batchNewRoot[enterprise][batch]]
    /\ UNCHANGED << batchNewRoot, crossRefStatus >>

\* Batch ZK proof fails verification (invalid proof). The batch reverts to idle,
\* allowing the enterprise to resubmit. Models Groth16 proof rejection.
\* Transition: submitted -> idle
FailBatch(enterprise, batch) ==
    /\ batchStatus[enterprise][batch] = "submitted"
    /\ batchStatus' = [batchStatus EXCEPT ![enterprise][batch] = "idle"]
    /\ UNCHANGED << currentRoot, batchNewRoot, crossRefStatus >>

(**************************************************************************)
(*                CROSS-ENTERPRISE ACTIONS                                *)
(**************************************************************************)

\* [Source: 0-input/REPORT.md, Section "Cross-Reference Circuit Design"]
\* Request verification of a cross-enterprise interaction.
\* Both enterprises must have active batches (submitted or verified).
\* The cross-reference proof will later verify Merkle inclusion in both
\* enterprise state trees and check the interaction commitment.
\* Transition: none -> pending
RequestCrossRef(src, dst, srcBatch, dstBatch) ==
    LET ref == [src |-> src, dst |-> dst,
                srcBatch |-> srcBatch, dstBatch |-> dstBatch]
    IN
    /\ ref \in CrossRefIds
    /\ crossRefStatus[ref] = "none"
    /\ batchStatus[src][srcBatch] \in {"submitted", "verified"}
    /\ batchStatus[dst][dstBatch] \in {"submitted", "verified"}
    /\ crossRefStatus' = [crossRefStatus EXCEPT ![ref] = "pending"]
    /\ UNCHANGED << currentRoot, batchStatus, batchNewRoot >>

\* [Source: 0-input/REPORT.md, "Cross-Reference Circuit Design" + "Privacy Analysis"]
\* Verify the cross-enterprise reference proof on L1.
\*
\* Public inputs (visible on-chain):
\*   - stateRootA (= currentRoot[src], already public from individual submission)
\*   - stateRootB (= currentRoot[dst], already public from individual submission)
\*   - interactionCommitment (Poseidon hash, reveals only existence of interaction)
\*
\* Private inputs (NOT revealed -- guaranteed by Groth16 ZK property, 128-bit):
\*   - keyA, valueA, siblingsA[32], pathBitsA[32] (Enterprise A Merkle proof)
\*   - keyB, valueB, siblingsB[32], pathBitsB[32] (Enterprise B Merkle proof)
\*
\* CONSISTENCY GATE: Both individual enterprise proofs MUST be verified first.
\* ISOLATION: No enterprise state is modified. Only crossRefStatus changes.
\*
\* Transition: pending -> verified
VerifyCrossRef(src, dst, srcBatch, dstBatch) ==
    LET ref == [src |-> src, dst |-> dst,
                srcBatch |-> srcBatch, dstBatch |-> dstBatch]
    IN
    /\ ref \in CrossRefIds
    /\ crossRefStatus[ref] = "pending"
    \* Both individual enterprise proofs must be independently verified on L1
    /\ batchStatus[src][srcBatch] = "verified"
    /\ batchStatus[dst][dstBatch] = "verified"
    /\ crossRefStatus' = [crossRefStatus EXCEPT ![ref] = "verified"]
    \* ISOLATION: Only crossRefStatus changes. No enterprise state is touched.
    /\ UNCHANGED << currentRoot, batchStatus, batchNewRoot >>

\* Reject a pending cross-reference. Triggered when at least one constituent
\* batch proof has not been verified (still submitted, or reverted to idle
\* after a FailBatch).
\* Transition: pending -> rejected
RejectCrossRef(src, dst, srcBatch, dstBatch) ==
    LET ref == [src |-> src, dst |-> dst,
                srcBatch |-> srcBatch, dstBatch |-> dstBatch]
    IN
    /\ ref \in CrossRefIds
    /\ crossRefStatus[ref] = "pending"
    /\ \/ batchStatus[src][srcBatch] # "verified"
       \/ batchStatus[dst][dstBatch] # "verified"
    /\ crossRefStatus' = [crossRefStatus EXCEPT ![ref] = "rejected"]
    /\ UNCHANGED << currentRoot, batchStatus, batchNewRoot >>

(**************************************************************************)
(*                    NEXT-STATE RELATION                                 *)
(**************************************************************************)

Next ==
    \/ \E e \in Enterprises, b \in BatchIds, r \in StateRoots :
           SubmitBatch(e, b, r)
    \/ \E e \in Enterprises, b \in BatchIds :
           VerifyBatch(e, b)
    \/ \E e \in Enterprises, b \in BatchIds :
           FailBatch(e, b)
    \/ \E s, d \in Enterprises, sb, db \in BatchIds :
           RequestCrossRef(s, d, sb, db)
    \/ \E s, d \in Enterprises, sb, db \in BatchIds :
           VerifyCrossRef(s, d, sb, db)
    \/ \E s, d \in Enterprises, sb, db \in BatchIds :
           RejectCrossRef(s, d, sb, db)

\* Weak fairness ensures progress for verification and resolution actions.
\* Required for liveness checking (CrossRefTermination).
Fairness ==
    /\ \A e \in Enterprises, b \in BatchIds :
           WF_vars(VerifyBatch(e, b))
    /\ \A e \in Enterprises, b \in BatchIds :
           WF_vars(FailBatch(e, b))
    /\ \A s, d \in Enterprises, sb, db \in BatchIds :
           WF_vars(VerifyCrossRef(s, d, sb, db))
    /\ \A s, d \in Enterprises, sb, db \in BatchIds :
           WF_vars(RejectCrossRef(s, d, sb, db))

Spec == Init /\ [][Next]_vars

LiveSpec == Spec /\ Fairness

(**************************************************************************)
(*                     SAFETY PROPERTIES                                  *)
(**************************************************************************)

\* [Why]: Enterprise privacy isolation -- the core validium guarantee.
\* Each enterprise's state root is determined SOLELY by its own verified
\* batches. No cross-enterprise action can modify or corrupt another
\* enterprise's state root. This simultaneously guarantees proof-before-state:
\* state roots advance only through verified ZK proofs, never through
\* unverified or cross-enterprise actions.
\* [Source: 0-input/REPORT.md, "Privacy Analysis" -- ZK guarantees, 128-bit]
Isolation ==
    \A e \in Enterprises :
        \/ currentRoot[e] = GenesisRoot
        \/ \E b \in BatchIds :
               /\ batchStatus[e][b] = "verified"
               /\ batchNewRoot[e][b] = currentRoot[e]

\* [Why]: A cross-reference is marked verified ONLY when both constituent
\* enterprise proofs have been independently verified on L1. This prevents
\* accepting cross-enterprise interactions based on unverified or fraudulent
\* state. The interaction commitment binds both parties' state roots.
\* [Source: 0-input/REPORT.md, Recommendations -- "valid only if both proofs valid"]
Consistency ==
    \A ref \in CrossRefIds :
        crossRefStatus[ref] = "verified" =>
            /\ batchStatus[ref.src][ref.srcBatch] = "verified"
            /\ batchStatus[ref.dst][ref.dstBatch] = "verified"

\* [Why]: Cross-references structurally cannot self-loop.
\* Enforced by the CrossRefIds construction (src # dst filter).
\* Self-referencing would be meaningless and could mask consistency violations.
NoCrossRefSelfLoop ==
    \A ref \in CrossRefIds : ref.src # ref.dst

(**************************************************************************)
(*                    LIVENESS PROPERTIES                                 *)
(**************************************************************************)

\* [Why]: Under fairness, every pending cross-reference eventually resolves
\* to either verified (both proofs valid) or rejected (at least one invalid).
\* The protocol must not leave cross-references in limbo indefinitely.
\* Requires LiveSpec (fairness on VerifyBatch, FailBatch, VerifyCrossRef,
\* RejectCrossRef) for model checking.
CrossRefTermination ==
    \A ref \in CrossRefIds :
        crossRefStatus[ref] = "pending" ~>
            crossRefStatus[ref] \in {"verified", "rejected"}

====
