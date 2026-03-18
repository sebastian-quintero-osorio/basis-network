(* ================================================================ *)
(*  Spec.v -- Faithful Translation of DataAvailability.tla          *)
(* ================================================================ *)
(*                                                                  *)
(*  Translates the TLA+ formal specification of the Data            *)
(*  Availability Committee (DAC) protocol into Coq. Every           *)
(*  definition is tagged with its source line in the TLA+ file.     *)
(*                                                                  *)
(*  Source: 0-input-spec/DataAvailability.tla, lines 1-318          *)
(*  Verified by: TLC model checker (3 nodes, 1 batch, 1 malicious) *)
(* ================================================================ *)

From DA Require Import Common.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Arith.Arith.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.Bool.

Import ListNotations.

(* ======================================== *)
(*     CONSTANTS                            *)
(* ======================================== *)

(* [Spec: CONSTANTS Nodes, Batches, Threshold, Malicious, lines 28-32]
   Threshold is imported from Common.v. *)
Parameter Nodes : NodeSet.
Parameter Malicious : NodeSet.

(* [Spec: ASSUME Malicious \subseteq Nodes, line 36] *)
Axiom malicious_subset : subset Malicious Nodes.

(* [Spec: Honest == Nodes \ Malicious, line 57] *)
Definition Honest : NodeSet := set_diff Nodes Malicious.

(* ======================================== *)
(*     STATE                                *)
(* ======================================== *)

(* [Spec: VARIABLES, lines 42-49] *)
Record State := mkState {
  nodeOnline    : Node -> bool;
  shareHolders  : Batch -> NodeSet;
  attested      : Batch -> NodeSet;
  certState     : Batch -> cert_state;
  recoveryNodes : Batch -> NodeSet;
  recoverState  : Batch -> recover_state;
}.

(* ======================================== *)
(*     INITIAL STATE                        *)
(* ======================================== *)

(* [Spec: Init, lines 76-82] *)
Definition Init : State := mkState
  (fun _ => true)
  (fun _ => [])
  (fun _ => [])
  (fun _ => CertNone)
  (fun _ => [])
  (fun _ => RecNone).

(* ======================================== *)
(*     RECOVERY OUTCOME                     *)
(* ======================================== *)

(* [Spec: RecoverData outcome, lines 164-167]
   IF |S| < Threshold THEN "failed"
   ELSE IF S \cap Malicious /= {} THEN "corrupted"
   ELSE "success"

   Uses le_lt_dec for clean proof decomposition. *)
Definition recover_outcome (S : NodeSet) : recover_state :=
  match le_lt_dec Threshold (length S) with
  | left _ =>
    if has_member_in S Malicious then RecCorrupted
    else RecSuccess
  | right _ => RecFailed
  end.

(* ======================================== *)
(*     ACTION PRECONDITIONS                 *)
(* ======================================== *)

(* [Spec: DistributeShares(b), lines 94-97] *)
Definition can_distribute (s : State) (b : Batch) : Prop :=
  shareHolders s b = [].

(* [Spec: NodeAttest(n, b), lines 106-112] *)
Definition can_attest (s : State) (n : Node) (b : Batch) : Prop :=
  nodeOnline s n = true /\
  In n (shareHolders s b) /\
  ~ In n (attested s b) /\
  certState s b = CertNone.

(* [Spec: ProduceCertificate(b), lines 119-123] *)
Definition can_produce_cert (s : State) (b : Batch) : Prop :=
  certState s b = CertNone /\
  length (attested s b) >= Threshold.

(* [Spec: TriggerFallback(b), lines 132-137] *)
Definition can_fallback (s : State) (b : Batch) : Prop :=
  certState s b = CertNone /\
  shareHolders s b <> [] /\
  length (shareHolders s b) < Threshold.

(* [Spec: RecoverData(b, S), lines 158-168] *)
Definition can_recover_data (s : State) (b : Batch) (S : NodeSet) : Prop :=
  certState s b = CertValid /\
  recoverState s b = RecNone /\
  (forall n, In n S -> nodeOnline s n = true /\ In n (shareHolders s b)) /\
  S <> [].

(* [Spec: NodeFail(n), lines 174-177] *)
Definition can_node_fail (s : State) (n : Node) : Prop :=
  nodeOnline s n = true.

(* [Spec: NodeRecover(n), lines 183-186] *)
Definition can_node_recover (s : State) (n : Node) : Prop :=
  nodeOnline s n = false.

(* ======================================== *)
(*     ACTIONS                              *)
(* ======================================== *)

(* [Spec: DistributeShares(b), lines 94-97]
   Phase 1: distribute Shamir shares to all online nodes. *)
Definition DistributeShares (s : State) (b : Batch) : State :=
  mkState
    (nodeOnline s)
    (fupdate (shareHolders s) b (set_filter (nodeOnline s) Nodes))
    (attested s)
    (certState s)
    (recoveryNodes s)
    (recoverState s).

(* [Spec: NodeAttest(n, b), lines 106-112]
   Phase 2: node n attests for batch b. *)
Definition NodeAttest (s : State) (n : Node) (b : Batch) : State :=
  mkState
    (nodeOnline s)
    (shareHolders s)
    (fupdate (attested s) b (n :: attested s b))
    (certState s)
    (recoveryNodes s)
    (recoverState s).

(* [Spec: ProduceCertificate(b), lines 119-123]
   Produce valid certificate when threshold met. *)
Definition ProduceCertificate (s : State) (b : Batch) : State :=
  mkState
    (nodeOnline s)
    (shareHolders s)
    (attested s)
    (fupdate_cert (certState s) b CertValid)
    (recoveryNodes s)
    (recoverState s).

(* [Spec: TriggerFallback(b), lines 132-137]
   Trigger on-chain fallback when threshold structurally unreachable. *)
Definition TriggerFallback (s : State) (b : Batch) : State :=
  mkState
    (nodeOnline s)
    (shareHolders s)
    (attested s)
    (fupdate_cert (certState s) b CertFallback)
    (recoveryNodes s)
    (recoverState s).

(* [Spec: RecoverData(b, S), lines 158-168]
   Phase 3: attempt data recovery from subset S. *)
Definition RecoverData (s : State) (b : Batch) (S : NodeSet) : State :=
  mkState
    (nodeOnline s)
    (shareHolders s)
    (attested s)
    (certState s)
    (fupdate (recoveryNodes s) b S)
    (fupdate_rec (recoverState s) b (recover_outcome S)).

(* [Spec: NodeFail(n), lines 174-177]
   Node goes offline. *)
Definition NodeFail (s : State) (n : Node) : State :=
  mkState
    (fun n' => if Nat.eqb n' n then false else nodeOnline s n')
    (shareHolders s)
    (attested s)
    (certState s)
    (recoveryNodes s)
    (recoverState s).

(* [Spec: NodeRecover(n), lines 183-186]
   Node comes back online. *)
Definition NodeRecover (s : State) (n : Node) : State :=
  mkState
    (fun n' => if Nat.eqb n' n then true else nodeOnline s n')
    (shareHolders s)
    (attested s)
    (certState s)
    (recoveryNodes s)
    (recoverState s).

(* ======================================== *)
(*     NEXT-STATE RELATION                  *)
(* ======================================== *)

(* [Spec: Next, lines 192-199] *)
Inductive Step : State -> State -> Prop :=
  | step_distribute : forall s b,
      can_distribute s b ->
      Step s (DistributeShares s b)
  | step_attest : forall s n b,
      can_attest s n b ->
      Step s (NodeAttest s n b)
  | step_produce_cert : forall s b,
      can_produce_cert s b ->
      Step s (ProduceCertificate s b)
  | step_fallback : forall s b,
      can_fallback s b ->
      Step s (TriggerFallback s b)
  | step_recover : forall s b S,
      can_recover_data s b S ->
      Step s (RecoverData s b S)
  | step_node_fail : forall s n,
      can_node_fail s n ->
      Step s (NodeFail s n)
  | step_node_recover : forall s n,
      can_node_recover s n ->
      Step s (NodeRecover s n).

(* ======================================== *)
(*     SAFETY PROPERTIES                    *)
(* ======================================== *)

(* [Spec: CertificateSoundness, lines 239-241]
   Valid certificate implies at least Threshold attestations. *)
Definition CertificateSoundness (s : State) : Prop :=
  forall b, certState s b = CertValid ->
    length (attested s b) >= Threshold.

(* [Spec: DataAvailability, lines 250-255]
   Honest recovery set of sufficient size guarantees success. *)
Definition DataAvailability (s : State) : Prop :=
  forall b,
    recoverState s b <> RecNone ->
    subset (recoveryNodes s b) Honest ->
    length (recoveryNodes s b) >= Threshold ->
    recoverState s b = RecSuccess.

(* [Spec: Privacy, lines 264-266]
   Successful recovery requires at least Threshold nodes. *)
Definition Privacy (s : State) : Prop :=
  forall b, recoverState s b = RecSuccess ->
    length (recoveryNodes s b) >= Threshold.

(* [Spec: RecoveryIntegrity, lines 275-277]
   Successful recovery implies no malicious node in recovery set. *)
Definition RecoveryIntegrity (s : State) : Prop :=
  forall b, recoverState s b = RecSuccess ->
    disjoint (recoveryNodes s b) Malicious.

(* [Spec: AttestationIntegrity, lines 285-287]
   Only share-holders can attest. *)
Definition AttestationIntegrity (s : State) : Prop :=
  forall b, subset (attested s b) (shareHolders s b).
