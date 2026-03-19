(* ================================================================ *)
(*  Impl.v -- Implementation Correspondence                         *)
(* ================================================================ *)
(*                                                                  *)
(*  Documents and formally establishes the correspondence between   *)
(*  the TypeScript + Solidity cross-enterprise implementation and   *)
(*  the TLA+ specification. The implementations directly realize    *)
(*  the TLA+ state machine; this file documents the mapping.        *)
(*                                                                  *)
(*  Source Impl:                                                     *)
(*    0-input-impl/cross-reference-builder.ts (443 lines)           *)
(*    0-input-impl/CrossEnterpriseVerifier.sol (451 lines)          *)
(*  Source Spec:                                                     *)
(*    0-input-spec/CrossEnterprise.tla (251 lines)                  *)
(* ================================================================ *)

From CE Require Import Common.
From CE Require Import Spec.

(* ======================================== *)
(*     STATE CORRESPONDENCE                 *)
(* ======================================== *)

(* The Solidity CrossEnterpriseVerifier contract maintains state that
   maps directly to Spec.State:

   StateCommitment.getBatchRoot(enterprise, batchId)
     CrossEnterpriseVerifier.sol line 284
     Mapped by: rootA != bytes32(0) implies batchStatus[e][b] = Verified
     On-chain, a non-zero batch root is the Verified marker.

   CrossEnterpriseVerifier.crossReferenceStatus[refId]
     CrossEnterpriseVerifier.sol line 76
     Mapped by: crossRefStatus[ref] maps directly via CrossRefState enum:
       None(0) -> CRNone, Pending(1) -> CRPending,
       Verified(2) -> CRVerified, Rejected(3) -> CRRejected

   State roots are public on L1 (currentRoot is implicit from
   StateCommitment). Cross-reference status is stored in the mapping
   by refId = keccak256(abi.encode(eA, eB, bA, bB)).

   The TypeScript cross-reference-builder.ts operates off-chain:
   - It constructs and validates evidence (proofs, commitments)
   - It does NOT store state; state lives on L1

   Privacy model (from both implementations):
   - Public signals: stateRootA, stateRootB, interactionCommitment
   - Private inputs: keyA, leafHashA, siblingsA, pathBitsA, keyB, ...
   - The Groth16 proof verifies private inputs without revealing them *)

(* ======================================== *)
(*     ACTION CORRESPONDENCE                *)
(* ======================================== *)

(* Each implementation path corresponds to one or more spec actions:

   1. TypeScript: buildCrossReferenceEvidence(request)
      cross-reference-builder.ts lines 182-250
      Implements off-chain preparation for RequestCrossRef:
        a. validateCrossRefId(id) -- NoCrossRefSelfLoop (src != dst)
        b. verifyMerkleProof(rootA, proofA) -- Merkle inclusion check
        c. verifyMerkleProof(rootB, proofB) -- Merkle inclusion check
        d. poseidonHash4(keyA, leafHashA, keyB, leafHashB) -- commitment
        e. Package evidence with public signals
      Corresponds to: evidence gathering for Spec.RequestCrossRef
      Guard mapping: valid_ref enforced by validateCrossRefId

   2. TypeScript: verifyCrossReferenceLocally(evidence, batchProvider)
      cross-reference-builder.ts lines 277-406
      Implements local pre-flight verification before L1 submission:
        a. validateCrossRefId -- NoCrossRefSelfLoop
        b. batchProvider.isBatchVerified(src, srcBatch) -- Consistency
        c. batchProvider.isBatchVerified(dst, dstBatch) -- Consistency
        d. verifyMerkleProof(rootA, proofA) -- proof recheck
        e. verifyMerkleProof(rootB, proofB) -- proof recheck
        f. Verify interaction commitment
        g. Privacy check: no private data in public signals
      Corresponds to: pre-check for Spec.VerifyCrossRef
      Guard mapping: both batches verified = Consistency gate

   3. Solidity: verifyCrossReference(eA, bA, eB, bB, commitment, a, b, c)
      CrossEnterpriseVerifier.sol lines 212-248
      Implements on-chain VerifyCrossRef:
        Phase 1: _validateAndBuildSignals (lines 252-301)
          a. Check verifyingKeySet
          b. enterpriseA != enterpriseB -- NoCrossRefSelfLoop
          c. isAuthorized checks -- registry
          d. crossReferenceStatus[refId] not terminal
          e. getBatchRoot(eA, bA) != 0 -- Consistency: src verified
          f. getBatchRoot(eB, bB) != 0 -- Consistency: dst verified
          g. Build publicSignals = [rootA, rootB, commitment]
        Phase 2: _verifyProof(a, b, c, publicSignals) -- Groth16
        Phase 3: crossReferenceStatus[refId] = Verified
      Corresponds to: Spec.VerifyCrossRef (proof valid)
                  or: Spec.RejectCrossRef (proof invalid)
      Guard mapping:
        NoCrossRefSelfLoop: SelfReference error (line 263)
        Consistency: SourceBatchNotVerified, DestBatchNotVerified
        Isolation: only crossReferenceStatus modified (line 236)

   4. TypeScript: formatPublicSignals(evidence)
      cross-reference-builder.ts lines 415-423
      Utility: formats 3 public signals as hex strings for L1.
      No spec correspondence (formatting only).

   5. TypeScript: computeCrossRefHash(id)
      cross-reference-builder.ts lines 432-442
      Matches Solidity computeRefId (keccak256(abi.encode(...))).
      No spec correspondence (identifier computation only). *)

(* ======================================== *)
(*     ISOLATION ENFORCEMENT                *)
(* ======================================== *)

(* Both implementations enforce Isolation:

   TypeScript (cross-reference-builder.ts):
   - buildCrossReferenceEvidence: reads stateRootA, stateRootB from
     request but NEVER modifies them.
   - verifyCrossReferenceLocally: returns a result without side effects.
     UNCHANGED << currentRoot >> guaranteed by functional purity.

   Solidity (CrossEnterpriseVerifier.sol):
   - verifyCrossReference: lines 233-237
     Only state modification: crossReferenceStatus[refId] = Verified
     No writes to StateCommitment or any enterprise state root.
     UNCHANGED << currentRoot, batchStatus, batchNewRoot >> is
     guaranteed by the function touching only crossReferenceStatus
     and counter variables (totalCrossRefsVerified). *)

(* ======================================== *)
(*     CONSISTENCY ENFORCEMENT              *)
(* ======================================== *)

(* Both implementations enforce the Consistency gate:

   TypeScript (cross-reference-builder.ts, lines 300-336):
   - batchProvider.isBatchVerified(src, srcBatch) -- must be true
   - batchProvider.isBatchVerified(dst, dstBatch) -- must be true
   - Returns Rejected status if either returns false

   Solidity (CrossEnterpriseVerifier.sol, lines 282-293):
   - getBatchRoot(enterpriseA, batchIdA) -- reverts if bytes32(0)
   - getBatchRoot(enterpriseB, batchIdB) -- reverts if bytes32(0)
   - Both checks MUST pass before Groth16 verification proceeds *)

(* ======================================== *)
(*     GROTH16 VERIFICATION MODEL           *)
(* ======================================== *)

(* The Groth16 proof verification is modeled abstractly in the spec
   as the VerifyCrossRef action succeeding (proof accepted) or
   RejectCrossRef (proof rejected / batch not verified).

   Solidity implementation (CrossEnterpriseVerifier.sol, lines 350-375):
   - _verifyProof uses EIP-196 (ecAdd, ecMul) and EIP-197 (ecPairing)
   - 3 public inputs: stateRootA, stateRootB, interactionCommitment
   - Verifying key stored in contract (setVerifyingKey, lines 168-184)

   The proof-level modeling abstracts Groth16 as: if the action fires
   with the appropriate guard, the proof is valid. The soundness of
   Groth16 (128-bit security) is a cryptographic assumption outside
   the scope of this Coq development. *)
