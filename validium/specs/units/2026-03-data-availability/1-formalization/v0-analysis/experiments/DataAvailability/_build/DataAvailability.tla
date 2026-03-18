---- MODULE DataAvailability ----
(**************************************************************************)
(* Formal specification of the Data Availability Committee (DAC) protocol *)
(* for the Basis Network Enterprise ZK Validium.                          *)
(*                                                                        *)
(* Models the complete lifecycle:                                          *)
(*   1. DistributeShares: Shamir (k,n)-SSS share distribution to nodes    *)
(*   2. NodeAttest: Individual node attestation signing                    *)
(*   3. ProduceCertificate: Threshold attestation -> valid certificate     *)
(*   4. TriggerFallback: On-chain DA when threshold structurally blocked   *)
(*   5. RecoverData: Lagrange reconstruction from k nodes' shares         *)
(*   6. NodeFail / NodeRecover: Crash and Byzantine fault simulation       *)
(*                                                                        *)
(* Security model:                                                         *)
(*   - (k,n)-threshold Shamir Secret Sharing (information-theoretic)       *)
(*   - Malicious nodes can attest validly but corrupt shares on recovery   *)
(*   - AnyTrust fallback: posts batch data on L1 if < k attestations      *)
(*                                                                        *)
(* Source: validium/specs/units/2026-03-data-availability/0-input/         *)
(**************************************************************************)

EXTENDS Integers, FiniteSets, TLC

(* ====================================================================== *)
(*                         CONSTANTS                                      *)
(* ====================================================================== *)

CONSTANTS
    Nodes,          \* Set of DAC committee members (e.g., {n1, n2, n3})
    Batches,        \* Set of batch identifiers (e.g., {b1})
    Threshold,      \* Reconstruction/attestation threshold k (e.g., 2 for 2-of-3)
    Malicious       \* Subset of Nodes that may behave adversarially

ASSUME Threshold >= 1
ASSUME Threshold <= Cardinality(Nodes)
ASSUME Malicious \subseteq Nodes

(* ====================================================================== *)
(*                         VARIABLES                                      *)
(* ====================================================================== *)

VARIABLES
    nodeOnline,     \* [Nodes -> BOOLEAN] -- operational status of each node
    shareHolders,   \* [Batches -> SUBSET Nodes] -- nodes holding valid Shamir shares
    attested,       \* [Batches -> SUBSET Nodes] -- nodes that have attested for batch
    certState,      \* [Batches -> {"none", "valid", "fallback"}] -- certificate state
    recoveryNodes,  \* [Batches -> SUBSET Nodes] -- nodes used in last recovery attempt
    recoverState    \* [Batches -> {"none", "success", "corrupted", "failed"}]

vars == << nodeOnline, shareHolders, attested, certState, recoveryNodes, recoverState >>

(* ====================================================================== *)
(*                         HELPERS                                        *)
(* ====================================================================== *)

\* Honest nodes: committee members not in the adversarial set.
Honest == Nodes \ Malicious

(* ====================================================================== *)
(*                         TYPE INVARIANT                                 *)
(* ====================================================================== *)

\* [Why]: Structural type constraint. Every variable must inhabit its declared domain.
TypeOK ==
    /\ nodeOnline \in [Nodes -> BOOLEAN]
    /\ shareHolders \in [Batches -> SUBSET Nodes]
    /\ attested \in [Batches -> SUBSET Nodes]
    /\ certState \in [Batches -> {"none", "valid", "fallback"}]
    /\ recoveryNodes \in [Batches -> SUBSET Nodes]
    /\ recoverState \in [Batches -> {"none", "success", "corrupted", "failed"}]

(* ====================================================================== *)
(*                         INITIAL STATE                                  *)
(* ====================================================================== *)

Init ==
    /\ nodeOnline = [n \in Nodes |-> TRUE]
    /\ shareHolders = [b \in Batches |-> {}]
    /\ attested = [b \in Batches |-> {}]
    /\ certState = [b \in Batches |-> "none"]
    /\ recoveryNodes = [b \in Batches |-> {}]
    /\ recoverState = [b \in Batches |-> "none"]

(* ====================================================================== *)
(*                         ACTIONS                                        *)
(* ====================================================================== *)

\* [Source: 0-input/code/src/dac-protocol.ts, distributeShares()]
\* [Source: 0-input/code/src/shamir.ts, shareData()]
\* Phase 1: Split batch data via Shamir (k,n)-SSS and distribute one share
\* per field element to each online DAC node. Offline nodes do not receive
\* shares and cannot participate in attestation or recovery for this batch.
\* The commitment (SHA-256 of original data) is sent alongside shares.
DistributeShares(b) ==
    /\ shareHolders[b] = {}                     \* Not yet distributed
    /\ shareHolders' = [shareHolders EXCEPT ![b] = {n \in Nodes : nodeOnline[n]}]
    /\ UNCHANGED << nodeOnline, attested, certState, recoveryNodes, recoverState >>

\* [Source: 0-input/code/src/dac-node.ts, attest()]
\* [Source: 0-input/code/src/dac-protocol.ts, collectAttestations()]
\* Phase 2: An online node with shares signs an ECDSA attestation certifying
\* it holds shares for the batch. Both honest and malicious nodes can produce
\* valid attestations (they hold real shares and valid signing keys). The
\* adversarial threat from malicious nodes manifests during recovery, not
\* attestation -- the signature is over the correct data commitment.
NodeAttest(n, b) ==
    /\ nodeOnline[n]                            \* Node must be online
    /\ n \in shareHolders[b]                    \* Node must hold shares
    /\ n \notin attested[b]                     \* Not already attested
    /\ certState[b] = "none"                    \* Certificate not yet produced
    /\ attested' = [attested EXCEPT ![b] = attested[b] \cup {n}]
    /\ UNCHANGED << nodeOnline, shareHolders, certState, recoveryNodes, recoverState >>

\* [Source: 0-input/code/src/dac-protocol.ts, collectAttestations() line 116]
\* [Source: 0-input/code/src/dac-protocol.ts, verifyOnChain()]
\* Produce a valid DACCertificate when at least Threshold attestations have
\* been collected. The on-chain verifier checks: signatureCount >= k, all
\* signatures valid, no duplicate signers, all signers are committee members.
ProduceCertificate(b) ==
    /\ certState[b] = "none"                    \* No certificate yet
    /\ Cardinality(attested[b]) >= Threshold    \* Threshold met
    /\ certState' = [certState EXCEPT ![b] = "valid"]
    /\ UNCHANGED << nodeOnline, shareHolders, attested, recoveryNodes, recoverState >>

\* [Source: 0-input/code/src/dac-protocol.ts, line 117 -- fallbackTriggered]
\* [Source: 0-input/REPORT.md, Section "AnyTrust Fallback"]
\* Trigger on-chain fallback (validium -> rollup mode): post batch data to L1.
\* Fires when threshold is structurally unreachable: fewer than k nodes received
\* shares during distribution. Nodes that missed distribution cannot attest
\* even if they come back online -- they lack shares for this batch.
\* Once shareHolders is set, it never changes, making this condition permanent.
TriggerFallback(b) ==
    /\ certState[b] = "none"                    \* No certificate yet
    /\ shareHolders[b] /= {}                    \* Shares were distributed
    /\ Cardinality(shareHolders[b]) < Threshold \* Permanently insufficient
    /\ certState' = [certState EXCEPT ![b] = "fallback"]
    /\ UNCHANGED << nodeOnline, shareHolders, attested, recoveryNodes, recoverState >>

\* [Source: 0-input/code/src/dac-protocol.ts, recoverData()]
\* [Source: 0-input/code/src/shamir.ts, reconstructData() -- Lagrange interpolation]
\* Phase 3: Attempt data recovery via Lagrange interpolation from a chosen
\* subset S of online share-holding nodes. Three possible outcomes:
\*
\*   "success":   |S| >= k and all nodes in S are honest (valid shares).
\*                Lagrange interpolation reconstructs exact original data.
\*                SHA-256(recovered) == commitment. Data integrity confirmed.
\*
\*   "corrupted": |S| >= k but S contains a malicious node that provided
\*                altered share values. Lagrange interpolation produces
\*                incorrect data. Detected by commitment mismatch.
\*                [Source: 0-input/code/src/shamir.ts, verifyShareConsistency()]
\*
\*   "failed":    |S| < k. Lagrange interpolation is underdetermined and
\*                produces a random field element, not the original secret.
\*                This models the information-theoretic privacy guarantee
\*                of (k,n)-Shamir SSS: k-1 shares reveal zero information.
\*                [Source: Shamir, "How to Share a Secret", CACM 1979]
RecoverData(b, S) ==
    /\ certState[b] = "valid"                   \* Valid certificate exists
    /\ recoverState[b] = "none"                 \* No prior recovery attempt
    /\ S \subseteq {n \in Nodes : nodeOnline[n] /\ n \in shareHolders[b]}
    /\ S /= {}                                  \* Non-empty recovery set
    /\ recoveryNodes' = [recoveryNodes EXCEPT ![b] = S]
    /\ recoverState' = [recoverState EXCEPT ![b] =
         IF Cardinality(S) < Threshold THEN "failed"
         ELSE IF S \cap Malicious /= {} THEN "corrupted"
         ELSE "success"]
    /\ UNCHANGED << nodeOnline, shareHolders, attested, certState >>

\* [Source: 0-input/code/src/dac-node.ts, setOnline(false)]
\* Node goes offline: crash, network partition, or adversarial shutdown.
\* Nondeterministic -- can happen at any time to any online node.
\* No fairness constraint: the environment is not obligated to crash nodes.
NodeFail(n) ==
    /\ nodeOnline[n]
    /\ nodeOnline' = [nodeOnline EXCEPT ![n] = FALSE]
    /\ UNCHANGED << shareHolders, attested, certState, recoveryNodes, recoverState >>

\* [Source: 0-input/code/src/dac-node.ts, setOnline(true)]
\* Node comes back online after a failure. Shares received before the crash
\* are still stored (persistent storage assumption from DACNodeState design).
\* The node can resume attestation and share retrieval for stored batches.
NodeRecover(n) ==
    /\ ~nodeOnline[n]
    /\ nodeOnline' = [nodeOnline EXCEPT ![n] = TRUE]
    /\ UNCHANGED << shareHolders, attested, certState, recoveryNodes, recoverState >>

(* ====================================================================== *)
(*                         NEXT-STATE RELATION                            *)
(* ====================================================================== *)

Next ==
    \/ \E b \in Batches : DistributeShares(b)
    \/ \E n \in Nodes, b \in Batches : NodeAttest(n, b)
    \/ \E b \in Batches : ProduceCertificate(b)
    \/ \E b \in Batches : TriggerFallback(b)
    \/ \E b \in Batches, S \in SUBSET Nodes : RecoverData(b, S)
    \/ \E n \in Nodes : NodeFail(n)
    \/ \E n \in Nodes : NodeRecover(n)

(* ====================================================================== *)
(*                         FAIRNESS                                       *)
(* ====================================================================== *)

\* Fairness constraints for liveness checking.
\*
\* Honest nodes use strong fairness (SF): node failures intermittently disable
\* attestation, but SF guarantees eventual execution when repeatedly enabled.
\* This models honest, cooperative behavior despite transient failures.
\* Reference: Lamport, "Specifying Systems", Section 8.9.
\*
\* ProduceCertificate and TriggerFallback use weak fairness (WF): once their
\* guards hold, they hold continuously. Certificate production is instantaneous
\* once threshold is met. Fallback condition is permanent once shareHolders is
\* set (shareHolders never changes after DistributeShares).
\*
\* NodeRecover uses weak fairness: a crashed node is continuously down until
\* recovery fires, and nothing can preempt recovery (NodeFail requires online).
\*
\* NodeFail has NO fairness: crashes are nondeterministic environmental events.
\* Malicious nodes have NO fairness on NodeAttest: they may refuse to cooperate.
Fairness ==
    /\ \A n \in Honest, b \in Batches : SF_vars(NodeAttest(n, b))
    /\ \A b \in Batches : WF_vars(ProduceCertificate(b))
    /\ \A b \in Batches : WF_vars(TriggerFallback(b))
    /\ \A n \in Nodes : WF_vars(NodeRecover(n))

Spec == Init /\ [][Next]_vars /\ Fairness

(* ====================================================================== *)
(*                         SAFETY PROPERTIES                              *)
(* ====================================================================== *)

\* [Why]: Certificate soundness. A valid DACCertificate can only be produced
\*        when at least Threshold nodes have signed attestations. This mirrors
\*        the on-chain verification logic: contract checks signatureCount >= k,
\*        verifies each signature, rejects duplicates, validates membership.
\* [Source: 0-input/code/src/dac-protocol.ts, verifyOnChain()]
CertificateSoundness ==
    \A b \in Batches :
        certState[b] = "valid" => Cardinality(attested[b]) >= Threshold

\* [Why]: Data availability guarantee. If recovery is attempted with at least
\*        Threshold honest nodes (all providing valid Shamir shares), the
\*        Lagrange interpolation succeeds and the recovered data matches the
\*        original (commitment check passes). Violation would mean honest
\*        shares are insufficient for reconstruction, contradicting the
\*        fundamental theorem of Shamir's secret sharing scheme.
\* [Source: 0-input/code/src/shamir.ts, reconstructSecret()]
DataAvailability ==
    \A b \in Batches :
        (recoverState[b] /= "none"
         /\ recoveryNodes[b] \subseteq Honest
         /\ Cardinality(recoveryNodes[b]) >= Threshold)
        => recoverState[b] = "success"

\* [Why]: Information-theoretic privacy. Successful data reconstruction requires
\*        at least Threshold shares. With (k,n)-Shamir SSS, k-1 shares reveal
\*        zero information about the secret -- unconditional security that holds
\*        even against computationally unbounded adversaries. In the model, this
\*        is captured structurally: RecoverData produces "failed" for |S| < k.
\*        No set of fewer than Threshold nodes can produce a successful recovery.
\* [Source: Shamir, "How to Share a Secret", CACM 22(11):612-613, 1979]
Privacy ==
    \A b \in Batches :
        recoverState[b] = "success" => Cardinality(recoveryNodes[b]) >= Threshold

\* [Why]: Recovery integrity. A "success" outcome guarantees the recovered data
\*        matches the original batch. This requires all contributing nodes to
\*        provide authentic (unmodified) shares. If a malicious node provides
\*        corrupted shares, Lagrange interpolation produces incorrect data,
\*        detectable via commitment mismatch (SHA-256(recovered) != commitment).
\*        The model enforces: success implies no malicious node in recovery set.
\* [Source: 0-input/code/src/shamir.ts, verifyShareConsistency()]
RecoveryIntegrity ==
    \A b \in Batches :
        recoverState[b] = "success" => recoveryNodes[b] \cap Malicious = {}

\* [Why]: Attestation integrity. Only nodes that received and stored shares
\*        during Phase 1 can attest in Phase 2. A node without shares cannot
\*        fabricate an attestation because the on-chain verifier checks that
\*        the signer is a registered committee member with a valid signature
\*        over the correct data commitment.
\* [Source: 0-input/code/src/dac-node.ts, attest() -- requires nodeState]
AttestationIntegrity ==
    \A b \in Batches :
        attested[b] \subseteq shareHolders[b]

(* ====================================================================== *)
(*                         LIVENESS PROPERTIES                            *)
(* ====================================================================== *)

\* [Why]: Eventual certification. If shares were distributed to at least
\*        Threshold honest nodes, the protocol eventually produces a valid
\*        certificate. This requires: (1) honest nodes eventually attest (SF
\*        on NodeAttest -- fires when repeatedly enabled despite crashes),
\*        (2) certificate produced once threshold met (WF on ProduceCertificate),
\*        (3) crashed honest nodes eventually recover (WF on NodeRecover).
\*        Note: malicious nodes have no fairness and may never attest.
\*        With Threshold <= |honest share-holders|, honest nodes alone suffice.
EventualCertification ==
    \A b \in Batches :
        (shareHolders[b] /= {} /\ Cardinality(shareHolders[b] \cap Honest) >= Threshold)
        ~> certState[b] = "valid"

\* [Why]: Eventual fallback. If shares were distributed but fewer than Threshold
\*        nodes received them, the fallback mechanism eventually triggers, posting
\*        batch data on-chain (validium degrades to rollup mode temporarily).
\*        This ensures data availability even when the DAC cannot certify.
\*        The condition is permanent (shareHolders is immutable after distribution),
\*        so WF on TriggerFallback is sufficient.
EventualFallback ==
    \A b \in Batches :
        (shareHolders[b] /= {} /\ Cardinality(shareHolders[b]) < Threshold)
        ~> certState[b] = "fallback"

====
