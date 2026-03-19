(* ================================================================ *)
(*  Common.v -- Standard Library for Enterprise Node Verification    *)
(* ================================================================ *)
(*                                                                  *)
(*  Provides type definitions, set operations, and tactics shared   *)
(*  across Spec.v, Impl.v, and Refinement.v.                       *)
(*                                                                  *)
(*  Target: validium/proofs/units/2026-03-enterprise-node/          *)
(*  Source TLA+: EnterpriseNode.tla                                 *)
(*  Source Impl: orchestrator.ts, types.ts                          *)
(* ================================================================ *)

From Stdlib Require Import Lists.List.
From Stdlib Require Import Bool.Bool.
From Stdlib Require Import Lia.

Import ListNotations.

(* ======================================== *)
(*     TRANSACTION TYPE                     *)
(* ======================================== *)

(* Abstract transaction type.
   [TLA: AllTxs -- set of all possible transactions, line 32] *)
Parameter Tx : Type.

(* Decidable equality on transactions.
   Required for list membership and set reasoning. *)
Parameter Tx_eq_dec : forall (x y : Tx), {x = y} + {x <> y}.

(* ======================================== *)
(*     NODE STATE                           *)
(* ======================================== *)

(* [TLA: States == {"Idle", "Receiving", "Batching",
                     "Proving", "Submitting", "Error"}, line 45]
   [Impl: types.ts, enum NodeState, lines 19-26] *)
Inductive NodeState : Type :=
  | Idle | Receiving | Batching | Proving | Submitting | Error.

Definition NodeState_eq_dec :
  forall (x y : NodeState), {x = y} + {x <> y}.
Proof. decide equality. Defined.

(* ======================================== *)
(*     DATA KIND (PRIVACY BOUNDARY)         *)
(* ======================================== *)

(* [TLA: DataKinds == AllowedExternalData \cup {"raw_data"}, line 53]
   [Impl: types.ts, enum DataKind, lines 46-50] *)
Inductive DataKind : Type :=
  | ProofSignals | DACShares | RawData.

(* [TLA: AllowedExternalData == {"proof_signals", "dac_shares"}, line 52]
   [Impl: types.ts, ALLOWED_EXTERNAL_DATA, lines 57-60] *)
Definition allowed_external (dk : DataKind) : Prop :=
  dk = ProofSignals \/ dk = DACShares.

(* ======================================== *)
(*     SET OPERATIONS (Tx -> Prop)          *)
(* ======================================== *)

(* Sets modeled as characteristic predicates.
   Leibniz equality is maintained through careful state construction:
   unchanged fields reuse the same predicate object. *)

Definition TxSet := Tx -> Prop.
Definition DKSet := DataKind -> Prop.

(* [TLA: {} -- empty set] *)
Definition empty_txset : TxSet := fun _ => False.

(* [TLA: AllTxs -- universe] *)
Definition full_txset : TxSet := fun _ => True.

(* [TLA: A \cup B] *)
Definition set_union (A B : TxSet) : TxSet := fun x => A x \/ B x.

(* [TLA: A \ {t}] *)
Definition set_remove (A : TxSet) (t : Tx) : TxSet :=
  fun x => A x /\ x <> t.

(* Set of elements in a list.
   [TLA: {seq[i] : i \in 1..Len(seq)}] *)
Definition list_to_set (l : list Tx) : TxSet := fun x => In x l.

(* DataKind set operations. *)
Definition dk_empty : DKSet := fun _ => False.

(* [TLA: dataExposed \cup {"proof_signals", "dac_shares"}, line 232] *)
Definition dk_add_ps_dac (A : DKSet) : DKSet :=
  fun x => A x \/ x = ProofSignals \/ x = DACShares.

(* [TLA: A \subseteq B] *)
Definition dk_subset (A B : DKSet) : Prop := forall x, A x -> B x.

(* ======================================== *)
(*     CONSTANTS                            *)
(* ======================================== *)

(* [TLA: CONSTANTS BatchThreshold, MaxCrashes, lines 31-34]
   [Impl: types.ts, NodeConfig.maxBatchSize, lines 182] *)
Parameter BatchThreshold : nat.
Parameter MaxCrashes : nat.

(* [TLA: ASSUME BatchThreshold > 0, line 36] *)
Axiom batch_threshold_pos : BatchThreshold > 0.

(* ======================================== *)
(*     HELPER LEMMAS                        *)
(* ======================================== *)

Lemma dk_empty_subset : forall B, dk_subset dk_empty B.
Proof.
  unfold dk_subset, dk_empty. intros B x H. contradiction.
Qed.

Lemma dk_add_ps_dac_subset :
  forall A, dk_subset A allowed_external ->
  dk_subset (dk_add_ps_dac A) allowed_external.
Proof.
  unfold dk_subset, dk_add_ps_dac, allowed_external.
  intros A HA x [H | [H | H]].
  - exact (HA x H).
  - left. exact H.
  - right. exact H.
Qed.
