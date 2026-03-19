(* ========================================================================= *)
(* Spec.v -- Faithful Translation of ProductionDAC.tla into Coq             *)
(* ========================================================================= *)
(* Source: 0-input-spec/ProductionDAC.tla                                    *)
(* TLC Evidence:                                                             *)
(*   Safety:  141,526,225 states, 16,882,176 distinct, depth 27 -- PASS      *)
(*   Liveness: 2,365,825 states, 395,520 distinct, depth 21 -- PASS          *)
(*                                                                           *)
(* Translation methodology:                                                  *)
(*   - TLA+ VARIABLES -> Coq Record fields                                   *)
(*   - TLA+ CONSTANTS -> Coq Parameters with Axiom assumptions               *)
(*   - TLA+ actions -> Coq Definitions as Prop relations on State pairs      *)
(*   - TLA+ SUBSET Nodes -> NSet (axiomatized finite sets)                   *)
(*   - TLA+ Cardinality -> card : NSet -> nat                                *)
(*   - TLA+ safety invariants -> Coq Definitions as State predicates         *)
(*                                                                           *)
(* Each definition is tagged with the source TLA+ line numbers.              *)
(* ========================================================================= *)

From ProductionDAC Require Import Common.

(* ========================================================================= *)
(*                         PROTOCOL PARAMETERS                               *)
(* ========================================================================= *)

(* [TLA+ lines 45-49: CONSTANTS Nodes, Batches, Threshold, Malicious] *)
Parameter AllNodes : NSet.
Parameter AllBatches : NSet.
Parameter Threshold : nat.
Parameter MaliciousNodes : NSet.

(* [TLA+ line 51: ASSUME Threshold >= 1] *)
Axiom threshold_pos : Threshold >= 1.

(* [TLA+ line 52: ASSUME Threshold <= Cardinality(Nodes)] *)
Axiom threshold_bounded : Threshold <= card AllNodes.

(* [TLA+ line 53: ASSUME Malicious \subseteq Nodes] *)
Axiom malicious_subset : is_subset MaliciousNodes AllNodes.

(* [TLA+ line 77: Honest == Nodes \ Malicious] *)
Definition HonestNodes : NSet := set_diff AllNodes MaliciousNodes.

(* ========================================================================= *)
(*                               STATE                                       *)
(* ========================================================================= *)

(* [TLA+ lines 59-68: VARIABLES]
   Each TLA+ variable that is a function [Domain -> Range] becomes a
   Coq function in the record. Set-valued variables use NSet. *)
Record State := mkState {
  nodeOnline     : Node -> bool;
  distributedTo  : Batch -> NSet;
  chunkVerified  : Batch -> NSet;
  chunkCorrupted : Batch -> NSet;
  attested       : Batch -> NSet;
  certSt         : Batch -> CertStateVal;
  recoveryNodes  : Batch -> NSet;
  recoverSt      : Batch -> RecoverStateVal
}.

(* ========================================================================= *)
(*                           INITIAL STATE                                   *)
(* ========================================================================= *)

(* [TLA+ lines 98-106: Init] *)
Definition Init (s : State) : Prop :=
  (forall n, mem n AllNodes -> nodeOnline s n = true) /\
  (forall b, mem b AllBatches -> distributedTo s b = empty_set) /\
  (forall b, mem b AllBatches -> chunkVerified s b = empty_set) /\
  (forall b, mem b AllBatches -> chunkCorrupted s b = empty_set) /\
  (forall b, mem b AllBatches -> attested s b = empty_set) /\
  (forall b, mem b AllBatches -> certSt s b = CertNone) /\
  (forall b, mem b AllBatches -> recoveryNodes s b = empty_set) /\
  (forall b, mem b AllBatches -> recoverSt s b = RecNone).

(* ========================================================================= *)
(*                              ACTIONS                                      *)
(* ========================================================================= *)
(* Convention: each action is a Prop relating pre-state s and post-state s'. *)
(* Fields not mentioned in the TLA+ UNCHANGED clause are asserted pointwise  *)
(* equal between s and s'. Fields that change for one batch use per-batch    *)
(* equality for other batches.                                               *)

(* [TLA+ lines 125-129: DistributeChunks(b)]
   Phase 1: Encrypt, RS-encode, Shamir-share, distribute to online nodes.
   Guard: batch not yet distributed.
   Effect: distributedTo[b] <- {n in Nodes : nodeOnline[n]}. *)
Definition DistributeChunks (b : Batch) (s s' : State) : Prop :=
  mem b AllBatches /\
  distributedTo s b = empty_set /\
  (forall n, mem n (distributedTo s' b) <->
    (mem n AllNodes /\ nodeOnline s n = true)) /\
  (forall b', b' <> b -> distributedTo s' b' = distributedTo s b') /\
  (forall n, nodeOnline s' n = nodeOnline s n) /\
  (forall b', chunkVerified s' b' = chunkVerified s b') /\
  (forall b', chunkCorrupted s' b' = chunkCorrupted s b') /\
  (forall b', attested s' b' = attested s b') /\
  (forall b', certSt s' b' = certSt s b') /\
  (forall b', recoveryNodes s' b' = recoveryNodes s b') /\
  (forall b', recoverSt s' b' = recoverSt s b').

(* [TLA+ lines 144-151: VerifyChunk(n, b)]
   Node verifies RS chunk against KZG polynomial commitment.
   Guards: online, distributed, not verified, not corrupted.
   Effect: chunkVerified[b] <- chunkVerified[b] \cup {n}. *)
Definition VerifyChunk (n : Node) (b : Batch) (s s' : State) : Prop :=
  mem n AllNodes /\ mem b AllBatches /\
  nodeOnline s n = true /\
  mem n (distributedTo s b) /\
  ~ mem n (chunkVerified s b) /\
  ~ mem n (chunkCorrupted s b) /\
  chunkVerified s' b = add_elem n (chunkVerified s b) /\
  (forall b', b' <> b -> chunkVerified s' b' = chunkVerified s b') /\
  (forall nn, nodeOnline s' nn = nodeOnline s nn) /\
  (forall b', distributedTo s' b' = distributedTo s b') /\
  (forall b', chunkCorrupted s' b' = chunkCorrupted s b') /\
  (forall b', attested s' b' = attested s b') /\
  (forall b', certSt s' b' = certSt s b') /\
  (forall b', recoveryNodes s' b' = recoveryNodes s b') /\
  (forall b', recoverSt s' b' = recoverSt s b').

(* [TLA+ lines 165-172: NodeAttest(n, b)]
   Online, verified node signs attestation.
   Guards: online, chunk verified (KZG gate), not attested, cert=none.
   Effect: attested[b] <- attested[b] \cup {n}. *)
Definition NodeAttest (n : Node) (b : Batch) (s s' : State) : Prop :=
  mem n AllNodes /\ mem b AllBatches /\
  nodeOnline s n = true /\
  mem n (chunkVerified s b) /\
  ~ mem n (attested s b) /\
  certSt s b = CertNone /\
  attested s' b = add_elem n (attested s b) /\
  (forall b', b' <> b -> attested s' b' = attested s b') /\
  (forall nn, nodeOnline s' nn = nodeOnline s nn) /\
  (forall b', distributedTo s' b' = distributedTo s b') /\
  (forall b', chunkVerified s' b' = chunkVerified s b') /\
  (forall b', chunkCorrupted s' b' = chunkCorrupted s b') /\
  (forall b', certSt s' b' = certSt s b') /\
  (forall b', recoveryNodes s' b' = recoveryNodes s b') /\
  (forall b', recoverSt s' b' = recoverSt s b').

(* [TLA+ lines 191-198: CorruptChunk(n, b)]
   Malicious node corrupts stored RS chunk or Shamir key share.
   Guards: malicious, distributed, not corrupted, recovery not started.
   Effect: chunkCorrupted[b] <- chunkCorrupted[b] \cup {n}. *)
Definition CorruptChunk (n : Node) (b : Batch) (s s' : State) : Prop :=
  mem n MaliciousNodes /\ mem b AllBatches /\
  mem n (distributedTo s b) /\
  ~ mem n (chunkCorrupted s b) /\
  recoverSt s b = RecNone /\
  chunkCorrupted s' b = add_elem n (chunkCorrupted s b) /\
  (forall b', b' <> b -> chunkCorrupted s' b' = chunkCorrupted s b') /\
  (forall nn, nodeOnline s' nn = nodeOnline s nn) /\
  (forall b', distributedTo s' b' = distributedTo s b') /\
  (forall b', chunkVerified s' b' = chunkVerified s b') /\
  (forall b', attested s' b' = attested s b') /\
  (forall b', certSt s' b' = certSt s b') /\
  (forall b', recoveryNodes s' b' = recoveryNodes s b') /\
  (forall b', recoverSt s' b' = recoverSt s b').

(* [TLA+ lines 208-213: ProduceCertificate(b)]
   Aggregate >= Threshold attestations into a valid DACCertificate.
   Guards: certState = none, |attested| >= Threshold.
   Effect: certState[b] <- valid. *)
Definition ProduceCertificate (b : Batch) (s s' : State) : Prop :=
  mem b AllBatches /\
  certSt s b = CertNone /\
  card (attested s b) >= Threshold /\
  certSt s' b = CertValid /\
  (forall b', b' <> b -> certSt s' b' = certSt s b') /\
  (forall nn, nodeOnline s' nn = nodeOnline s nn) /\
  (forall b', distributedTo s' b' = distributedTo s b') /\
  (forall b', chunkVerified s' b' = chunkVerified s b') /\
  (forall b', chunkCorrupted s' b' = chunkCorrupted s b') /\
  (forall b', attested s' b' = attested s b') /\
  (forall b', recoveryNodes s' b' = recoveryNodes s b') /\
  (forall b', recoverSt s' b' = recoverSt s b').

(* [TLA+ lines 223-229: TriggerFallback(b)]
   AnyTrust fallback: post batch data on L1 (validium -> rollup mode).
   Guards: certState = none, distributed non-empty, |distributed| < Threshold.
   Effect: certState[b] <- fallback. *)
Definition TriggerFallback (b : Batch) (s s' : State) : Prop :=
  mem b AllBatches /\
  certSt s b = CertNone /\
  ~ is_empty (distributedTo s b) /\
  card (distributedTo s b) < Threshold /\
  certSt s' b = CertFallback /\
  (forall b', b' <> b -> certSt s' b' = certSt s b') /\
  (forall nn, nodeOnline s' nn = nodeOnline s nn) /\
  (forall b', distributedTo s' b' = distributedTo s b') /\
  (forall b', chunkVerified s' b' = chunkVerified s b') /\
  (forall b', chunkCorrupted s' b' = chunkCorrupted s b') /\
  (forall b', attested s' b' = attested s b') /\
  (forall b', recoveryNodes s' b' = recoveryNodes s b') /\
  (forall b', recoverSt s' b' = recoverSt s b').

(* [TLA+ lines 268-278: RecoverData(b, S)]
   Three-step recovery: RS-decode -> Shamir key recovery -> AES-GCM decrypt.
   Guards: valid certificate, no prior recovery, S subset of online distributed.
   Effect: recoveryNodes[b] <- S, recoverState[b] determined by three cases:
     - |S| < Threshold                     => failed
     - |S| >= Threshold, S intersect corrupted non-empty  => corrupted
     - |S| >= Threshold, S intersect corrupted empty      => success *)
Definition RecoverData (b : Batch) (S : NSet) (s s' : State) : Prop :=
  mem b AllBatches /\
  certSt s b = CertValid /\
  recoverSt s b = RecNone /\
  (forall n, mem n S -> mem n AllNodes /\
    nodeOnline s n = true /\ mem n (distributedTo s b)) /\
  ~ is_empty S /\
  recoveryNodes s' b = S /\
  (* Three mutually exclusive, exhaustive cases for recovery outcome *)
  ((card S < Threshold /\ recoverSt s' b = RecFailed) \/
   (card S >= Threshold /\
    ~ is_empty (set_inter S (chunkCorrupted s b)) /\
    recoverSt s' b = RecCorrupted) \/
   (card S >= Threshold /\
    is_empty (set_inter S (chunkCorrupted s b)) /\
    recoverSt s' b = RecSuccess)) /\
  (forall b', b' <> b -> recoveryNodes s' b' = recoveryNodes s b') /\
  (forall b', b' <> b -> recoverSt s' b' = recoverSt s b') /\
  (forall nn, nodeOnline s' nn = nodeOnline s nn) /\
  (forall b', distributedTo s' b' = distributedTo s b') /\
  (forall b', chunkVerified s' b' = chunkVerified s b') /\
  (forall b', chunkCorrupted s' b' = chunkCorrupted s b') /\
  (forall b', attested s' b' = attested s b') /\
  (forall b', certSt s' b' = certSt s b').

(* [TLA+ lines 285-289: NodeFail(n)] *)
Definition NodeFail (n : Node) (s s' : State) : Prop :=
  mem n AllNodes /\
  nodeOnline s n = true /\
  nodeOnline s' n = false /\
  (forall m, m <> n -> nodeOnline s' m = nodeOnline s m) /\
  (forall b', distributedTo s' b' = distributedTo s b') /\
  (forall b', chunkVerified s' b' = chunkVerified s b') /\
  (forall b', chunkCorrupted s' b' = chunkCorrupted s b') /\
  (forall b', attested s' b' = attested s b') /\
  (forall b', certSt s' b' = certSt s b') /\
  (forall b', recoveryNodes s' b' = recoveryNodes s b') /\
  (forall b', recoverSt s' b' = recoverSt s b').

(* [TLA+ lines 295-299: NodeRecover(n)] *)
Definition NodeRecover (n : Node) (s s' : State) : Prop :=
  mem n AllNodes /\
  nodeOnline s n = false /\
  nodeOnline s' n = true /\
  (forall m, m <> n -> nodeOnline s' m = nodeOnline s m) /\
  (forall b', distributedTo s' b' = distributedTo s b') /\
  (forall b', chunkVerified s' b' = chunkVerified s b') /\
  (forall b', chunkCorrupted s' b' = chunkCorrupted s b') /\
  (forall b', attested s' b' = attested s b') /\
  (forall b', certSt s' b' = certSt s b') /\
  (forall b', recoveryNodes s' b' = recoveryNodes s b') /\
  (forall b', recoverSt s' b' = recoverSt s b').

(* ========================================================================= *)
(*                         NEXT-STATE RELATION                               *)
(* ========================================================================= *)

(* [TLA+ lines 305-314: Next] *)
Definition Next (s s' : State) : Prop :=
  (exists b, DistributeChunks b s s') \/
  (exists n b, VerifyChunk n b s s') \/
  (exists n b, NodeAttest n b s s') \/
  (exists n b, CorruptChunk n b s s') \/
  (exists b, ProduceCertificate b s s') \/
  (exists b, TriggerFallback b s s') \/
  (exists b S, RecoverData b S s s') \/
  (exists n, NodeFail n s s') \/
  (exists n, NodeRecover n s s').

(* ========================================================================= *)
(*                         SAFETY PROPERTIES                                 *)
(* ========================================================================= *)

(* [TLA+ lines 367-369: CertificateSoundness]
   A valid DACCertificate implies >= Threshold attestations.
   Corresponds to on-chain verification in BasisDAC.sol:submitCertificate. *)
Definition CertificateSoundness (s : State) : Prop :=
  forall b, mem b AllBatches ->
    certSt s b = CertValid -> card (attested s b) >= Threshold.

(* [TLA+ lines 383-388: DataRecoverability]
   Recovery from >= Threshold non-corrupted nodes always succeeds.
   Captures the MDS property of (k,n) Reed-Solomon erasure codes
   combined with Shamir (k,n) secret sharing correctness. *)
Definition DataRecoverability (s : State) : Prop :=
  forall b, mem b AllBatches ->
    recoverSt s b <> RecNone ->
    is_subset (recoveryNodes s b)
      (set_diff (distributedTo s b) (chunkCorrupted s b)) ->
    card (recoveryNodes s b) >= Threshold ->
    recoverSt s b = RecSuccess.

(* [TLA+ lines 405-410: ErasureSoundness]
   Recovery with corrupted nodes is always detected.
   Captures AES-256-GCM authentication tag + SHA-256 commitment check. *)
Definition ErasureSoundness (s : State) : Prop :=
  forall b, mem b AllBatches ->
    recoverSt s b <> RecNone ->
    card (recoveryNodes s b) >= Threshold ->
    ~ is_empty (set_inter (recoveryNodes s b) (chunkCorrupted s b)) ->
    recoverSt s b = RecCorrupted.

(* [TLA+ lines 423-425: Privacy]
   Successful recovery requires >= Threshold participants.
   Captures information-theoretic Shamir (k,n)-SS guarantee:
   k-1 shares reveal zero information about the key. *)
Definition Privacy (s : State) : Prop :=
  forall b, mem b AllBatches ->
    recoverSt s b = RecSuccess ->
    card (recoveryNodes s b) >= Threshold.

(* [TLA+ lines 434-436: RecoveryIntegrity]
   Success implies all contributing nodes have authentic data.
   No corrupted chunks or key shares in the recovery set. *)
Definition RecoveryIntegrity (s : State) : Prop :=
  forall b, mem b AllBatches ->
    recoverSt s b = RecSuccess ->
    is_empty (set_inter (recoveryNodes s b) (chunkCorrupted s b)).

(* [TLA+ lines 447-449: AttestationIntegrity]
   Only chunk-verified nodes can attest.
   KZG verification is the first integrity gate. *)
Definition AttestationIntegrity (s : State) : Prop :=
  forall b, mem b AllBatches ->
    is_subset (attested s b) (chunkVerified s b).

(* [TLA+ lines 454-456: VerificationIntegrity]
   Only distributed nodes can verify.
   A node cannot verify a chunk it never received. *)
Definition VerificationIntegrity (s : State) : Prop :=
  forall b, mem b AllBatches ->
    is_subset (chunkVerified s b) (distributedTo s b).

(* Structural invariant: recovery requires prior distribution.
   If distributedTo[b] is empty (batch never distributed), then no
   verification, attestation, certification, or recovery can have
   occurred for that batch. This follows from the action guard chain:
   RecoverData requires CertValid, which requires ProduceCertificate,
   which requires attested, which requires VerifyChunk, which requires
   n in distributedTo. Empty distributedTo blocks the entire chain. *)
Definition NoRecoveryBeforeDistribution (s : State) : Prop :=
  forall b, mem b AllBatches ->
    distributedTo s b = empty_set -> recoverSt s b = RecNone.
