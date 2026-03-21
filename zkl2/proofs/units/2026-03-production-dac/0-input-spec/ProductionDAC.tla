---- MODULE ProductionDAC ----
(**************************************************************************)
(* Formal specification of the Production Data Availability Committee     *)
(* (DAC) protocol for the Basis Network Enterprise zkEVM L2.             *)
(*                                                                        *)
(* Extends the Validium RU-V6 DAC model with:                            *)
(*   1. Reed-Solomon (k,n) erasure coding for storage-efficient data     *)
(*      dispersal (1.4x overhead vs 7x with pure Shamir SSS)            *)
(*   2. AES-256-GCM encryption + Shamir key sharing for two-layer        *)
(*      enterprise privacy (computational data privacy +                  *)
(*      information-theoretic key secrecy)                                *)
(*   3. KZG polynomial commitments for verifiable chunk dispersal        *)
(*   4. Explicit corruption model: malicious nodes may corrupt stored    *)
(*      RS chunks at any time after distribution                          *)
(*   5. Two-phase integrity: KZG check at dispersal gates attestation,   *)
(*      commitment hash check at recovery detects corruption              *)
(*                                                                        *)
(* Architecture (Hybrid AES + RS + Shamir):                              *)
(*   Disperse: encrypt(AES-256-GCM) -> RS-encode(5,7)                   *)
(*          -> Shamir-share(key, 5-of-7) -> KZG-commit                   *)
(*          -> distribute {chunk_i, keyShare_i, kzgProof_i}              *)
(*   Verify:  node verifies RS chunk against KZG polynomial commitment   *)
(*   Attest:  node signs attestation (only after KZG verification)       *)
(*   Certify: aggregate >= k attestations into DACCertificate            *)
(*   Recover: collect k chunks -> RS-decode -> collect k key shares      *)
(*          -> Shamir-recover(key) -> AES-decrypt -> verify hash         *)
(*                                                                        *)
(* Security model:                                                        *)
(*   - (k,n)-threshold for attestation and recovery (production: k=5)    *)
(*   - Malicious nodes can attest validly then corrupt stored chunks     *)
(*   - Corrupted chunks detected by commitment check at recovery         *)
(*   - KZG verification prevents attestation of invalid chunks           *)
(*   - AnyTrust fallback: posts batch on L1 if < k attestations          *)
(*                                                                        *)
(* Source: zkl2/specs/units/2026-03-production-dac/0-input/              *)
(* Extends: validium/specs/units/2026-03-data-availability/ (RU-V6)      *)
(**************************************************************************)

EXTENDS Integers, FiniteSets, TLC

(* ====================================================================== *)
(*                         CONSTANTS                                      *)
(* ====================================================================== *)

CONSTANTS
    Nodes,          \* Set of DAC committee members (e.g., {n1, ..., n7})
    Batches,        \* Set of batch identifiers (e.g., {b1})
    Threshold,      \* Reconstruction/attestation threshold k (e.g., 5 for 5-of-7)
    Malicious       \* Subset of Nodes that may behave adversarially (|Malicious| <= n-k)

ASSUME Threshold >= 1
ASSUME Threshold <= Cardinality(Nodes)
ASSUME Malicious \subseteq Nodes

(* ====================================================================== *)
(*                         VARIABLES                                      *)
(* ====================================================================== *)

VARIABLES
    nodeOnline,       \* [Nodes -> BOOLEAN] -- operational status of each node
    distributedTo,    \* [Batches -> SUBSET Nodes] -- nodes that received {RS chunk, Shamir key share, KZG proof}
    chunkVerified,    \* [Batches -> SUBSET Nodes] -- nodes that verified RS chunk against KZG commitment
    chunkCorrupted,   \* [Batches -> SUBSET Nodes] -- nodes whose stored RS chunk (or key share) is corrupted
    attested,         \* [Batches -> SUBSET Nodes] -- nodes that signed attestation for batch
    certState,        \* [Batches -> {"none", "valid", "fallback"}] -- certificate state
    recoveryNodes,    \* [Batches -> SUBSET Nodes] -- nodes contributing to last recovery attempt
    recoverState      \* [Batches -> {"none", "success", "corrupted", "failed"}] -- recovery outcome

vars == << nodeOnline, distributedTo, chunkVerified, chunkCorrupted,
           attested, certState, recoveryNodes, recoverState >>

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
    /\ distributedTo \in [Batches -> SUBSET Nodes]
    /\ chunkVerified \in [Batches -> SUBSET Nodes]
    /\ chunkCorrupted \in [Batches -> SUBSET Nodes]
    /\ attested \in [Batches -> SUBSET Nodes]
    /\ certState \in [Batches -> {"none", "valid", "fallback"}]
    /\ recoveryNodes \in [Batches -> SUBSET Nodes]
    /\ recoverState \in [Batches -> {"none", "success", "corrupted", "failed"}]

(* ====================================================================== *)
(*                         INITIAL STATE                                  *)
(* ====================================================================== *)

Init ==
    /\ nodeOnline = [n \in Nodes |-> TRUE]
    /\ distributedTo = [b \in Batches |-> {}]
    /\ chunkVerified = [b \in Batches |-> {}]
    /\ chunkCorrupted = [b \in Batches |-> {}]
    /\ attested = [b \in Batches |-> {}]
    /\ certState = [b \in Batches |-> "none"]
    /\ recoveryNodes = [b \in Batches |-> {}]
    /\ recoverState = [b \in Batches |-> "none"]

(* ====================================================================== *)
(*                         ACTIONS                                        *)
(* ====================================================================== *)

\* [Source: 0-input/REPORT.md, Section 8.1 "Architecture: Hybrid AES+RS+Shamir"]
\* [Source: 0-input/code/erasure.go, Encoder.Encode()]
\* [Source: 0-input/code/shamir.go, Split()]
\* [Source: 0-input/code/dac.go, Committee.Disperse() lines 152-238]
\* Phase 1: Encrypt batch data with AES-256-GCM (random key per batch),
\* Reed-Solomon encode ciphertext into n chunks (k data + n-k parity),
\* Shamir (k,n)-share the 32-byte AES key, generate KZG polynomial
\* commitment, and distribute {chunk_i, keyShare_i, kzgProof_i} to each
\* online node. Offline nodes do not receive packages and cannot
\* participate in attestation or recovery for this batch.
\*
\* Storage: each node stores 1/k of the ciphertext (vs 1x for Shamir).
\* Total overhead: n/k = 7/5 = 1.4x (vs n * 1x = 7x for pure Shamir).
DistributeChunks(b) ==
    /\ distributedTo[b] = {}                     \* Not yet distributed
    /\ distributedTo' = [distributedTo EXCEPT ![b] = {n \in Nodes : nodeOnline[n]}]
    /\ UNCHANGED << nodeOnline, chunkVerified, chunkCorrupted,
                    attested, certState, recoveryNodes, recoverState >>

\* [Source: 0-input/REPORT.md, Section 4 "KZG Commitments for Verifiable Encoding"]
\* [Source: 0-input/REPORT.md, INV-DA-P1 "Verifiable Encoding"]
\* A node that received its package verifies the RS chunk against the KZG
\* polynomial commitment. The KZG opening proof confirms the chunk is a
\* valid evaluation of the committed polynomial at the node's index.
\*
\* Guard: the node must NOT have a corrupted chunk. If a malicious node
\* corrupts its stored chunk before verification, the KZG check fails
\* and the node cannot proceed to attestation. This captures the
\* verifiable encoding guarantee: invalid chunks are always detected.
\*
\* In the honest disperser model, all distributed chunks are initially
\* valid. Corruption occurs only via the CorruptChunk action.
VerifyChunk(n, b) ==
    /\ nodeOnline[n]                              \* Node must be online
    /\ n \in distributedTo[b]                     \* Node must have received a chunk
    /\ n \notin chunkVerified[b]                  \* Not yet verified
    /\ n \notin chunkCorrupted[b]                 \* Corrupted chunk fails KZG check
    /\ chunkVerified' = [chunkVerified EXCEPT ![b] = chunkVerified[b] \cup {n}]
    /\ UNCHANGED << nodeOnline, distributedTo, chunkCorrupted,
                    attested, certState, recoveryNodes, recoverState >>

\* [Source: 0-input/code/dac.go, Node.attest() lines 361-385]
\* [Source: 0-input/code/dac.go, Committee.Disperse() attestation loop lines 206-217]
\* [Source: 0-input/REPORT.md, Section 8.3 "Signature Scheme"]
\* Phase 2: An online node that has verified its RS chunk (KZG check
\* passed) signs an attestation (ECDSA in prototype, BLS in production)
\* certifying it holds a valid chunk and key share for the batch.
\*
\* Both honest and malicious nodes produce valid attestations -- they hold
\* verified chunks and valid signing keys at attestation time. The
\* adversarial threat from malicious nodes manifests post-attestation via
\* the CorruptChunk action, not during attestation. The attestation
\* signature covers the data commitment hash (SHA-256 of original data).
NodeAttest(n, b) ==
    /\ nodeOnline[n]                              \* Node must be online
    /\ n \in chunkVerified[b]                     \* Must have verified chunk (KZG gate)
    /\ n \notin attested[b]                       \* Not already attested
    /\ certState[b] = "none"                      \* Certificate not yet produced
    /\ attested' = [attested EXCEPT ![b] = attested[b] \cup {n}]
    /\ UNCHANGED << nodeOnline, distributedTo, chunkVerified, chunkCorrupted,
                    certState, recoveryNodes, recoverState >>

\* [Source: 0-input/REPORT.md, Section 8.2 "Committee Configuration"]
\* A malicious node corrupts its stored RS chunk (or Shamir key share)
\* at any time after receiving the distribution package. This models the
\* adversarial capability of data withholding or intentional corruption.
\*
\* Effects of corruption:
\*   - If corrupted BEFORE VerifyChunk: KZG check fails, node cannot
\*     verify or attest. Attestation count is reduced.
\*   - If corrupted AFTER VerifyChunk/NodeAttest: attestation was valid
\*     (chunk was authentic at signing time), but recovery with this
\*     node's chunk produces wrong data. Detected by commitment check.
\*
\* Only malicious nodes can corrupt. Honest nodes always store authentic
\* data. Corruption is irreversible (no "un-corrupt" action).
\* Guard: corruption is only meaningful before recovery. Once recovery
\* completes, the result is final and post-recovery corruption does not
\* retroactively affect the recovered data.
CorruptChunk(n, b) ==
    /\ n \in Malicious                            \* Only adversarial nodes corrupt
    /\ n \in distributedTo[b]                     \* Must have received a chunk
    /\ n \notin chunkCorrupted[b]                 \* Not already corrupted
    /\ recoverState[b] = "none"                   \* Only before recovery attempt
    /\ chunkCorrupted' = [chunkCorrupted EXCEPT ![b] = chunkCorrupted[b] \cup {n}]
    /\ UNCHANGED << nodeOnline, distributedTo, chunkVerified,
                    attested, certState, recoveryNodes, recoverState >>

\* [Source: 0-input/code/dac.go, Committee.Disperse() lines 222-234]
\* [Source: 0-input/REPORT.md, Section 2.2 "AnyTrust" model]
\* Produce a valid DACCertificate when at least Threshold attestations
\* have been collected. On-chain verification (BasisDAC.sol) checks:
\*   - signatureCount >= k (threshold met)
\*   - all signatures valid (ECDSA/BLS verification)
\*   - no duplicate signers (signer bitmap check)
\*   - all signers are registered committee members
ProduceCertificate(b) ==
    /\ certState[b] = "none"                      \* No certificate yet
    /\ Cardinality(attested[b]) >= Threshold       \* Threshold met
    /\ certState' = [certState EXCEPT ![b] = "valid"]
    /\ UNCHANGED << nodeOnline, distributedTo, chunkVerified, chunkCorrupted,
                    attested, recoveryNodes, recoverState >>

\* [Source: 0-input/REPORT.md, Section 2.2 "AnyTrust" fallback]
\* [Source: 0-input/REPORT.md, INV-DA-P5 "Fallback Safety"]
\* Trigger on-chain fallback (validium -> rollup mode): post batch data
\* to L1 directly. Fires when threshold is structurally unreachable:
\* fewer than k nodes received chunks during distribution. Nodes that
\* missed distribution cannot verify or attest even if they come back
\* online -- they lack chunks for this batch.
\* Once distributedTo is set, it never changes, making this permanent.
TriggerFallback(b) ==
    /\ certState[b] = "none"                          \* No certificate yet
    /\ distributedTo[b] /= {}                          \* Chunks were distributed
    /\ Cardinality(distributedTo[b]) < Threshold       \* Permanently insufficient
    /\ certState' = [certState EXCEPT ![b] = "fallback"]
    /\ UNCHANGED << nodeOnline, distributedTo, chunkVerified, chunkCorrupted,
                    attested, recoveryNodes, recoverState >>

\* [Source: 0-input/code/dac.go, Committee.Recover() lines 256-327]
\* [Source: 0-input/code/erasure.go, Encoder.Decode() lines 141-188]
\* [Source: 0-input/code/shamir.go, Recover() lines 89-141]
\* [Source: 0-input/REPORT.md, INV-DA-P2 "Data Recoverability"]
\* Phase 3: Attempt data recovery from a subset S of online nodes that
\* received chunks. Recovery is a three-step process:
\*
\*   Step 1 -- RS Decode: Collect RS chunks from S. Reed-Solomon decode
\*   reconstructs the complete ciphertext from any k valid chunks
\*   (MDS property). If fewer than k valid chunks, reconstruction is
\*   impossible. If any chunk is corrupted, RS decode produces wrong
\*   ciphertext (detected in Step 3).
\*
\*   Step 2 -- Shamir Recovery: Collect Shamir key shares from S.
\*   Lagrange interpolation at x=0 recovers the AES-256 key from k
\*   shares. Information-theoretic privacy: k-1 shares reveal nothing
\*   about the key (Shamir 1979). Corrupted key shares produce wrong
\*   key (detected in Step 3).
\*
\*   Step 3 -- Decrypt and Verify: AES-256-GCM decrypt the ciphertext
\*   with the recovered key. Verify SHA-256(plaintext) matches the data
\*   commitment stored on-chain. Any corruption in Steps 1 or 2
\*   produces a commitment mismatch.
\*
\* Three possible outcomes:
\*   "success":   |S| >= k AND all chunks/shares in S are authentic.
\*                RS decode + Shamir recovery + AES decrypt succeed.
\*                SHA-256(recovered) == commitment.
\*
\*   "corrupted": |S| >= k BUT S contains a node with a corrupted chunk
\*                or key share. RS decode or Shamir recovery produces
\*                incorrect output. SHA-256(result) != commitment.
\*                Detected by commitment check.
\*
\*   "failed":    |S| < k. RS decode is underdetermined (insufficient
\*                chunks for MDS reconstruction). Shamir recovery with
\*                < k shares reveals nothing about the key.
RecoverData(b, S) ==
    /\ certState[b] = "valid"                      \* Valid certificate exists
    /\ recoverState[b] = "none"                    \* No prior recovery attempt
    /\ S \subseteq {n \in Nodes : nodeOnline[n] /\ n \in distributedTo[b]}
    /\ S /= {}                                     \* Non-empty recovery set
    /\ recoveryNodes' = [recoveryNodes EXCEPT ![b] = S]
    /\ recoverState' = [recoverState EXCEPT ![b] =
         IF Cardinality(S) < Threshold THEN "failed"
         ELSE IF S \cap chunkCorrupted[b] /= {} THEN "corrupted"
         ELSE "success"]
    /\ UNCHANGED << nodeOnline, distributedTo, chunkVerified, chunkCorrupted,
                    attested, certState >>

\* [Source: 0-input/REPORT.md, Section 11.5 "Failure Tolerance"]
\* Node goes offline: crash, network partition, or adversarial shutdown.
\* Nondeterministic -- can happen at any time to any online node.
\* No fairness constraint: crashes are environmental events.
NodeFail(n) ==
    /\ nodeOnline[n]
    /\ nodeOnline' = [nodeOnline EXCEPT ![n] = FALSE]
    /\ UNCHANGED << distributedTo, chunkVerified, chunkCorrupted,
                    attested, certState, recoveryNodes, recoverState >>

\* Node comes back online after a failure. Chunks and key shares received
\* before the crash are still stored (persistent storage assumption from
\* the Node.stored map in dac.go). The node can resume verification and
\* attestation for stored batches.
NodeRecover(n) ==
    /\ ~nodeOnline[n]
    /\ nodeOnline' = [nodeOnline EXCEPT ![n] = TRUE]
    /\ UNCHANGED << distributedTo, chunkVerified, chunkCorrupted,
                    attested, certState, recoveryNodes, recoverState >>

(* ====================================================================== *)
(*                         NEXT-STATE RELATION                            *)
(* ====================================================================== *)

Next ==
    \/ \E b \in Batches : DistributeChunks(b)
    \/ \E n \in Nodes, b \in Batches : VerifyChunk(n, b)
    \/ \E n \in Nodes, b \in Batches : NodeAttest(n, b)
    \/ \E n \in Nodes, b \in Batches : CorruptChunk(n, b)
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
\* VerifyChunk for honest nodes: strong fairness. Node crashes
\* intermittently disable verification (guard requires nodeOnline), but
\* SF guarantees eventual execution when repeatedly enabled. This models
\* the real protocol: KZG verification is a fast local operation (~10 ms)
\* that completes between crash/recovery episodes.
\*
\* NodeAttest for honest nodes: strong fairness. Node failures may
\* intermittently disable attestation, but SF guarantees eventual
\* execution when repeatedly enabled. This models honest, cooperative
\* behavior despite transient failures.
\*
\* ProduceCertificate and TriggerFallback: weak fairness. Once their
\* guards hold, they hold continuously (threshold met or permanently
\* insufficient, respectively).
\*
\* NodeRecover: weak fairness. A crashed node is continuously down until
\* recovery fires.
\*
\* NodeFail: NO fairness. Crashes are nondeterministic environmental
\* events.
\*
\* CorruptChunk: NO fairness. Malicious nodes choose when (or whether)
\* to corrupt. No obligation to corrupt or to cooperate.
\*
\* Malicious nodes have NO fairness on VerifyChunk or NodeAttest: they
\* may refuse to participate in the protocol.
Fairness ==
    /\ \A n \in Honest, b \in Batches : SF_vars(VerifyChunk(n, b))
    /\ \A n \in Honest, b \in Batches : SF_vars(NodeAttest(n, b))
    /\ \A b \in Batches : WF_vars(ProduceCertificate(b))
    /\ \A b \in Batches : WF_vars(TriggerFallback(b))
    /\ \A n \in Nodes : WF_vars(NodeRecover(n))

Spec == Init /\ [][Next]_vars /\ Fairness

(* ====================================================================== *)
(*                         SAFETY PROPERTIES                              *)
(* ====================================================================== *)

\* [Why]: Certificate soundness. A valid DACCertificate can only exist
\*        when at least Threshold nodes have signed attestations. Mirrors
\*        the on-chain verification logic in BasisDAC.sol: the contract
\*        checks signatureCount >= k, verifies each signature, rejects
\*        duplicates, and validates committee membership.
\* [Source: 0-input/code/dac.go, Committee.VerifyCertificate()]
CertificateSoundness ==
    \A b \in Batches :
        certState[b] = "valid" => Cardinality(attested[b]) >= Threshold

\* [Why]: Data recoverability via Reed-Solomon erasure coding. If
\*        recovery is attempted with at least Threshold nodes that all
\*        hold authentic (non-corrupted) RS chunks and valid Shamir key
\*        shares, the three-step recovery succeeds:
\*          (a) RS decode reconstructs ciphertext from k valid chunks
\*              (MDS property of Reed-Solomon codes)
\*          (b) Shamir interpolation recovers AES key from k shares
\*          (c) AES-GCM decryption recovers plaintext
\*        SHA-256(recovered) == commitment. This is the fundamental
\*        guarantee of (k,n)-RS MDS codes combined with (k,n)-Shamir SS.
\* [Source: 0-input/REPORT.md, Section 3.1 "RS Mathematical Foundation"]
\* [Source: 0-input/REPORT.md, INV-DA-P2 "Data Recoverability"]
DataRecoverability ==
    \A b \in Batches :
        (recoverState[b] /= "none"
         /\ recoveryNodes[b] \subseteq (distributedTo[b] \ chunkCorrupted[b])
         /\ Cardinality(recoveryNodes[b]) >= Threshold)
        => recoverState[b] = "success"

\* [Why]: Erasure soundness. If recovery is attempted with at least
\*        Threshold chunks (sufficient for RS decoding) AND any node
\*        in the recovery set has a corrupted RS chunk or Shamir key
\*        share, the commitment check detects it:
\*          - Corrupted RS chunk -> RS decode produces wrong ciphertext
\*            -> SHA-256(wrong_data) != commitment
\*          - Corrupted key share -> Shamir recovery produces wrong key
\*            -> AES-GCM decrypt fails or produces wrong plaintext
\*            -> SHA-256(wrong_data) != commitment
\*        The condition |S| >= Threshold is required because with fewer
\*        than k chunks, RS decoding is impossible regardless of
\*        corruption -- the outcome is "failed", not "corrupted".
\*        RS with d = n-k+1 = 3 detects up to 2 corrupted chunks.
\* [Source: 0-input/REPORT.md, INV-DA-P1 "Verifiable Encoding"]
\* [Source: 0-input/REPORT.md, Section 3.1 "MDS codes"]
ErasureSoundness ==
    \A b \in Batches :
        (recoverState[b] /= "none"
         /\ Cardinality(recoveryNodes[b]) >= Threshold
         /\ recoveryNodes[b] \cap chunkCorrupted[b] /= {})
        => recoverState[b] = "corrupted"

\* [Why]: Enterprise privacy. Successful data recovery requires at
\*        least Threshold participants. This captures two independent
\*        privacy layers:
\*          (a) AES-256-GCM: RS chunks are encrypted ciphertext --
\*              no plaintext exposure even with all chunks
\*          (b) Shamir (k,n)-SS: k-1 key shares reveal zero information
\*              about the AES key (information-theoretic guarantee)
\*        Combined: no coalition of fewer than k nodes can decrypt.
\*        254-bit key entropy (BN254 scalar field modular reduction).
\* [Source: Shamir, "How to Share a Secret", CACM 22(11), 1979]
\* [Source: 0-input/REPORT.md, INV-DA-P3 "Enterprise Privacy"]
Privacy ==
    \A b \in Batches :
        recoverState[b] = "success" => Cardinality(recoveryNodes[b]) >= Threshold

\* [Why]: Recovery integrity. A "success" outcome guarantees recovered
\*        data matches the original batch (commitment check passes).
\*        This requires all contributing nodes to provide authentic
\*        (non-corrupted) RS chunks AND authentic Shamir key shares.
\*        If any participant has corrupted data, commitment mismatch
\*        is detected (see ErasureSoundness).
\* [Source: 0-input/REPORT.md, Section 11.4 "Recovery Time" -- 100% match]
RecoveryIntegrity ==
    \A b \in Batches :
        recoverState[b] = "success" => recoveryNodes[b] \cap chunkCorrupted[b] = {}

\* [Why]: Attestation integrity. Only nodes that received AND verified
\*        their RS chunk against the KZG polynomial commitment can
\*        attest. This two-gate requirement prevents:
\*          (a) nodes without chunks from fabricating attestations
\*          (b) nodes with unverified (or corrupted) chunks from
\*              attesting potentially invalid data
\*        The KZG verification is the first integrity check; the
\*        commitment hash check at recovery is the second.
\* [Source: 0-input/REPORT.md, Section 4.1 "Why KZG?"]
AttestationIntegrity ==
    \A b \in Batches :
        attested[b] \subseteq chunkVerified[b]

\* [Why]: Chunk verification requires prior distribution. A node cannot
\*        verify a chunk it never received. This structural constraint
\*        ensures the KZG verification gate cannot be bypassed.
VerificationIntegrity ==
    \A b \in Batches :
        chunkVerified[b] \subseteq distributedTo[b]

(* ====================================================================== *)
(*                         LIVENESS PROPERTIES                            *)
(* ====================================================================== *)

\* [Why]: Attestation liveness. If chunks were distributed to at least
\*        Threshold honest nodes, the protocol eventually produces a
\*        valid DACCertificate. This requires:
\*          (1) honest nodes eventually verify chunks (WF on VerifyChunk)
\*          (2) honest nodes eventually attest (SF on NodeAttest --
\*              fires when repeatedly enabled despite crashes)
\*          (3) certificate produced once threshold met (WF)
\*          (4) crashed honest nodes eventually recover (WF)
\*        Malicious nodes have no fairness and may never verify/attest.
\*        With Threshold <= |honest distributed nodes|, honest alone
\*        suffice. Corruption (CorruptChunk) has no fairness and does
\*        not affect honest nodes.
\* [Source: 0-input/REPORT.md, INV-DA-P4 "Attestation Liveness"]
AttestationLiveness ==
    \A b \in Batches :
        (distributedTo[b] /= {} /\ Cardinality(distributedTo[b] \cap Honest) >= Threshold)
        ~> certState[b] = "valid"

\* [Why]: Eventual fallback. If chunks were distributed but fewer than
\*        Threshold nodes received them, the fallback mechanism
\*        eventually triggers, posting batch data on-chain (validium
\*        degrades to rollup mode temporarily). This ensures data
\*        availability even when the DAC cannot certify.
\*        The condition is permanent (distributedTo is immutable after
\*        distribution), so WF on TriggerFallback is sufficient.
\* [Source: 0-input/REPORT.md, INV-DA-P5 "Fallback Safety"]
EventualFallback ==
    \A b \in Batches :
        (distributedTo[b] /= {} /\ Cardinality(distributedTo[b]) < Threshold)
        ~> certState[b] = "fallback"

====
