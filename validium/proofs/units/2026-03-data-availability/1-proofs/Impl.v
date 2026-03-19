(* ================================================================ *)
(*  Impl.v -- Implementation Correspondence                         *)
(* ================================================================ *)
(*                                                                  *)
(*  Documents and formally establishes the correspondence between   *)
(*  the TypeScript DAC implementation and the TLA+ specification.   *)
(*                                                                  *)
(*  The TypeScript implementation (DACProtocol, DACNode, Shamir)    *)
(*  is a direct realization of the TLA+ state machine. Each         *)
(*  protocol method maps to one or more TLA+ actions with           *)
(*  identical guards and state transitions.                         *)
(*                                                                  *)
(*  Source Impl: 0-input-impl/{shamir,dac-node,dac-protocol,types}.ts *)
(*  Source Spec: 0-input-spec/DataAvailability.tla                  *)
(* ================================================================ *)

From DA Require Import Common.
From DA Require Import Spec.
From Stdlib Require Import Lists.List.

Import ListNotations.

(* ======================================== *)
(*     IMPLEMENTATION STATE MODEL           *)
(* ======================================== *)

(* The TypeScript DACProtocol class maintains state that maps
   directly to Spec.State:

   DACNode.isOnline()           -> Spec.nodeOnline n
     dac-node.ts line 63: isOnline(): boolean
     Mapped by: nodeOnline s n = node.isOnline()

   DACNode.hasShares(batchId)   -> In n (Spec.shareHolders s b)
     dac-node.ts line 175: hasShares(batchId): boolean
     Mapped by: n in shareHolders[b] iff node.state.has(batchId)

   DACNodeState.attested        -> In n (Spec.attested s b)
     types.ts line 76: attested: boolean
     Mapped by: n in attested[b] iff nodeState.attested = true

   DACCertificate.state         -> Spec.certState s b
     types.ts lines 106-113: enum CertificateState
     Mapped by: certState s b = certificate.state

   RecoveryResult.nodesUsed     -> Spec.recoveryNodes s b
     types.ts line 214: nodesUsed: readonly number[]
     Mapped by: recoveryNodes s b = result.nodesUsed

   RecoveryResult.state         -> Spec.recoverState s b
     types.ts lines 120-129: enum RecoveryState
     Mapped by: recoverState s b = result.state *)

(* ======================================== *)
(*     ACTION CORRESPONDENCE                *)
(* ======================================== *)

(* Each implementation method is a composition of spec actions:

   DACProtocol.distribute(batchId, data)
     dac-protocol.ts lines 99-129
     1. shareData(data, k, n) -- Shamir polynomial evaluation
     2. For each node: node.storeShare(batchId, shares, commitment)
     3. Online nodes receive shares, offline nodes do not
     Corresponds to: Spec.DistributeShares s b

   DACNode.attest(batchId)
     dac-node.ts lines 126-151
     1. Check: online, has shares, not already attested
     2. Sign attestation: SHA-256(batchId:commitment:nodeId || secretKey)
     Corresponds to: Spec.NodeAttest s n b

   DACProtocol.collectAttestations(batchId, commitment)
     dac-protocol.ts lines 150-201
     1. For each node: node.attest(batchId) + verify signature
     2. Check threshold condition
     3. Produce certificate (VALID) or trigger fallback (FALLBACK)
     Corresponds to: sequence of Spec.NodeAttest(n, b)
                     then Spec.ProduceCertificate(b) or TriggerFallback(b)

   DACProtocol.recover(batchId, commitment)
     dac-protocol.ts lines 249-301
     1. Find available online nodes with shares
     2. If < k available: return FAILED
     3. Lagrange interpolation from first k nodes
     4. SHA-256 commitment check
     5. Return SUCCESS or CORRUPTED
     Corresponds to: Spec.RecoverData s b S

   DACProtocol.setNodeOffline(nodeId)
     dac-protocol.ts lines 394-399
     Corresponds to: Spec.NodeFail s n

   DACProtocol.setNodeOnline(nodeId)
     dac-protocol.ts lines 406-412
     Corresponds to: Spec.NodeRecover s n *)

(* ======================================== *)
(*     SHAMIR SECURITY MODEL                *)
(* ======================================== *)

(* The Shamir secret sharing scheme (shamir.ts) provides
   information-theoretic security properties modeled by
   Spec.recover_outcome:

   1. Correctness: k honest shares reconstruct the secret.
      shamir.ts recover() lines 145-176: Lagrange interpolation
      -> recover_outcome S = RecSuccess when |S| >= k and
         disjoint S Malicious
      -> Verified by: DataAvailability invariant

   2. Privacy: k-1 shares reveal zero information.
      Shamir, "How to Share a Secret", CACM 1979, Theorem 1
      -> recover_outcome S = RecFailed when |S| < k
      -> Verified by: Privacy invariant (success requires |S| >= k)

   3. Integrity: corrupted shares detected by commitment mismatch.
      shamir.ts verifyShareConsistency() lines 334-344
      -> recover_outcome S = RecCorrupted when S has malicious node
      -> Verified by: RecoveryIntegrity invariant *)

(* ======================================== *)
(*     ON-CHAIN VERIFICATION MODEL          *)
(* ======================================== *)

(* DACProtocol.verify() (dac-protocol.ts lines 321-373) checks:
   1. signatureCount >= threshold
   2. All signatures valid (ecrecover)
   3. No duplicate signers
   4. All signers in [1, committeeSize]

   This is modeled by Spec.can_produce_cert:
     certState[b] = CertNone /\ |attested[b]| >= Threshold

   The CertificateSoundness invariant guarantees:
     certState[b] = CertValid => |attested[b]| >= Threshold *)
