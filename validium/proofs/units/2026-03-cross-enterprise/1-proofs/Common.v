(* ================================================================ *)
(*  Common.v -- Standard Library for Cross-Enterprise Unit          *)
(* ================================================================ *)
(*                                                                  *)
(*  Provides type mappings, cross-reference identifier operations,  *)
(*  functional update lemmas, and tactics shared across Spec.v,     *)
(*  Impl.v, and Refinement.v.                                      *)
(*                                                                  *)
(*  Target: validium/proofs/units/2026-03-cross-enterprise/         *)
(*  Source TLA+: CrossEnterprise.tla, lines 1-251                   *)
(*  Source Impl: cross-reference-builder.ts,                        *)
(*               CrossEnterpriseVerifier.sol                        *)
(* ================================================================ *)

From Stdlib Require Import Lists.List.
From Stdlib Require Import Arith.Arith.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.Bool.

Import ListNotations.

(* ======================================== *)
(*     BASE TYPES                           *)
(* ======================================== *)

(* [Spec: Enterprises -- finite set of enterprise identifiers, line 19]
   [Impl TS: string identifier]
   [Impl Sol: address -- 20-byte Ethereum address] *)
Definition Enterprise := nat.

(* [Spec: BatchIds -- finite set of batch identifiers, line 20]
   [Impl TS: string batchId]
   [Impl Sol: uint256 batchId] *)
Definition BatchId := nat.

(* [Spec: StateRoots -- finite domain of state root values, line 21]
   [Impl TS: FieldElement (bigint)]
   [Impl Sol: bytes32] *)
Definition StateRoot := nat.

(* [Spec: GenesisRoot \in StateRoots, lines 23-24]
   [Impl: initial state root for all enterprises] *)
Parameter GenesisRoot : StateRoot.

(* ======================================== *)
(*     STATUS TYPES                         *)
(* ======================================== *)

(* [Spec: batchStatus range {"idle","submitted","verified"}, line 43]
   [Impl Sol: getBatchRoot != 0 means verified] *)
Inductive batch_status : Type :=
  | Idle | Submitted | Verified.

(* [Spec: crossRefStatus range {"none","pending","verified","rejected"}, line 45]
   [Impl Sol: CrossRefState enum, lines 38-43] *)
Inductive crossref_status : Type :=
  | CRNone | CRPending | CRVerified | CRRejected.

(* ======================================== *)
(*     CROSS-REFERENCE IDENTIFIER           *)
(* ======================================== *)

(* [Spec: CrossRefIds, lines 34-36]
   Record r in [src, dst, srcBatch, dstBatch] with src # dst.
   [Impl Sol: keccak256(abi.encode(eA, eB, bA, bB)), line 274]
   [Impl TS: CrossReferenceId type] *)
Record CrossRefId := mkCrossRefId {
  cr_src : Enterprise;
  cr_dst : Enterprise;
  cr_srcBatch : BatchId;
  cr_dstBatch : BatchId;
}.

(* [Spec: r.src # r.dst filter, line 36]
   [Impl TS: validateCrossRefId, lines 115-122]
   [Impl Sol: SelfReference error, line 263] *)
Definition valid_ref (r : CrossRefId) : Prop :=
  cr_src r <> cr_dst r.

(* Boolean equality for CrossRefId. All fields are nat. *)
Definition crossrefid_eqb (r1 r2 : CrossRefId) : bool :=
  Nat.eqb (cr_src r1) (cr_src r2) &&
  Nat.eqb (cr_dst r1) (cr_dst r2) &&
  Nat.eqb (cr_srcBatch r1) (cr_srcBatch r2) &&
  Nat.eqb (cr_dstBatch r1) (cr_dstBatch r2).

Lemma crossrefid_eqb_refl : forall r, crossrefid_eqb r r = true.
Proof.
  intros [s d sb db]. unfold crossrefid_eqb. simpl.
  repeat rewrite Nat.eqb_refl. reflexivity.
Qed.

Lemma crossrefid_eqb_true_iff : forall r1 r2,
  crossrefid_eqb r1 r2 = true <-> r1 = r2.
Proof.
  intros [s1 d1 sb1 db1] [s2 d2 sb2 db2]. split.
  - unfold crossrefid_eqb. simpl. intros H.
    destruct (Nat.eqb s1 s2) eqn:E1; simpl in H; [| discriminate].
    destruct (Nat.eqb d1 d2) eqn:E2; simpl in H; [| discriminate].
    destruct (Nat.eqb sb1 sb2) eqn:E3; simpl in H; [| discriminate].
    apply Nat.eqb_eq in E1. apply Nat.eqb_eq in E2.
    apply Nat.eqb_eq in E3. apply Nat.eqb_eq in H.
    subst. reflexivity.
  - intros ->. apply crossrefid_eqb_refl.
Qed.

Lemma crossrefid_eqb_false_iff : forall r1 r2,
  crossrefid_eqb r1 r2 = false <-> r1 <> r2.
Proof.
  intros r1 r2. split.
  - intros H Heq. subst. rewrite crossrefid_eqb_refl in H. discriminate.
  - intros H. destruct (crossrefid_eqb r1 r2) eqn:E; auto.
    apply crossrefid_eqb_true_iff in E. contradiction.
Qed.

(* ======================================== *)
(*     FUNCTIONAL UPDATES                   *)
(* ======================================== *)

(* Single-level: Enterprise -> A.
   Models TLA+ [f EXCEPT ![e] = v].
   [Spec: currentRoot update in VerifyBatch, line 92] *)
Definition fupdate1 {A : Type} (f : Enterprise -> A)
  (e : Enterprise) (v : A) : Enterprise -> A :=
  fun e' => if Nat.eqb e' e then v else f e'.

(* Two-level: Enterprise -> BatchId -> A.
   Models TLA+ [f EXCEPT ![e][b] = v].
   [Spec: batchStatus, batchNewRoot updates] *)
Definition fupdate2 {A : Type} (f : Enterprise -> BatchId -> A)
  (e : Enterprise) (b : BatchId) (v : A)
  : Enterprise -> BatchId -> A :=
  fun e' b' => if (Nat.eqb e' e) && (Nat.eqb b' b) then v else f e' b'.

(* CrossRefId-level: CrossRefId -> A.
   Models TLA+ [crossRefStatus EXCEPT ![ref] = v].
   [Spec: crossRefStatus updates in all cross-ref actions] *)
Definition fupdate_cr {A : Type} (f : CrossRefId -> A)
  (r : CrossRefId) (v : A) : CrossRefId -> A :=
  fun r' => if crossrefid_eqb r' r then v else f r'.

(* --- fupdate1 lemmas --- *)

Lemma fupdate1_eq : forall {A : Type} (f : Enterprise -> A) e v,
  fupdate1 f e v e = v.
Proof. intros. unfold fupdate1. rewrite Nat.eqb_refl. reflexivity. Qed.

Lemma fupdate1_neq : forall {A : Type} (f : Enterprise -> A) e e' v,
  e' <> e -> fupdate1 f e v e' = f e'.
Proof.
  intros. unfold fupdate1.
  destruct (Nat.eqb e' e) eqn:E; auto.
  apply Nat.eqb_eq in E. contradiction.
Qed.

(* --- fupdate2 lemmas --- *)

Lemma fupdate2_eq : forall {A : Type} (f : Enterprise -> BatchId -> A) e b v,
  fupdate2 f e b v e b = v.
Proof. intros. unfold fupdate2. rewrite !Nat.eqb_refl. reflexivity. Qed.

Lemma fupdate2_neq_e : forall {A : Type}
    (f : Enterprise -> BatchId -> A) e b v e' b',
  e' <> e -> fupdate2 f e b v e' b' = f e' b'.
Proof.
  intros. unfold fupdate2.
  destruct (Nat.eqb e' e) eqn:E.
  - apply Nat.eqb_eq in E. contradiction.
  - reflexivity.
Qed.

Lemma fupdate2_neq_b : forall {A : Type}
    (f : Enterprise -> BatchId -> A) e b v e' b',
  b' <> b -> fupdate2 f e b v e' b' = f e' b'.
Proof.
  intros. unfold fupdate2.
  destruct (Nat.eqb e' e) eqn:Ee; simpl.
  - destruct (Nat.eqb b' b) eqn:Eb.
    + apply Nat.eqb_eq in Eb. contradiction.
    + reflexivity.
  - reflexivity.
Qed.

(* If (e', b') cannot both equal (e, b), the update is invisible. *)
Lemma fupdate2_neq_pair : forall {A : Type}
    (f : Enterprise -> BatchId -> A) e b v e' b',
  ~ (e' = e /\ b' = b) -> fupdate2 f e b v e' b' = f e' b'.
Proof.
  intros A f e b v e' b' H. unfold fupdate2.
  destruct (Nat.eqb e' e) eqn:Ee.
  - apply Nat.eqb_eq in Ee. subst.
    destruct (Nat.eqb b' b) eqn:Eb; simpl.
    + apply Nat.eqb_eq in Eb. subst.
      exfalso. apply H. split; reflexivity.
    + reflexivity.
  - simpl. reflexivity.
Qed.

(* If the old value already equals v, updating to v preserves the value
   regardless of position. Key lemma for VerifyBatch + Consistency. *)
Lemma fupdate2_to_same : forall {A : Type}
    (f : Enterprise -> BatchId -> A) e b v e' b',
  f e' b' = v -> fupdate2 f e b v e' b' = v.
Proof.
  intros. unfold fupdate2.
  destruct ((Nat.eqb e' e) && (Nat.eqb b' b)); auto.
Qed.

(* --- fupdate_cr lemmas --- *)

Lemma fupdate_cr_eq : forall {A : Type} (f : CrossRefId -> A) r v,
  fupdate_cr f r v r = v.
Proof. intros. unfold fupdate_cr. rewrite crossrefid_eqb_refl. reflexivity. Qed.

Lemma fupdate_cr_neq : forall {A : Type} (f : CrossRefId -> A) r r' v,
  r' <> r -> fupdate_cr f r v r' = f r'.
Proof.
  intros. unfold fupdate_cr.
  destruct (crossrefid_eqb r' r) eqn:E; auto.
  apply crossrefid_eqb_true_iff in E. contradiction.
Qed.

(* ======================================== *)
(*     TACTICS                              *)
(* ======================================== *)

(* Destruct match/if expressions in goal or hypotheses. *)
Ltac destruct_match :=
  match goal with
  | [ |- context[if ?c then _ else _] ] => destruct c
  | [ H : context[if ?c then _ else _] |- _ ] => destruct c
  | [ |- context[match ?x with _ => _ end] ] => destruct x
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x
  end.
