(* ========================================== *)
(*     Common.v -- Standard Library            *)
(*     BasisRollup Verification Unit           *)
(*     zkl2/proofs/units/2026-03-basis-rollup  *)
(* ========================================== *)

(* Shared types, functional map utilities, and tactics for the
   BasisRollup commit-prove-execute lifecycle verification.

   Models Solidity storage as functional maps (nat -> A) with
   pointwise update, matching the TLA+ EXCEPT operator semantics.

   Source: BasisRollup.tla, BasisRollup.sol *)

From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.

(* ========================================== *)
(*     ABSTRACT TYPES                          *)
(* ========================================== *)

(* Enterprise identifier. Nat for decidable equality.
   [Source: BasisRollup.tla, line 27 -- Enterprises constant]
   [Source: BasisRollup.sol, line 101 -- mapping(address => ...)] *)
Definition Enterprise := nat.

(* State root value. Nat for decidable equality.
   None is modeled via option nat.
   [Source: BasisRollup.tla, line 29 -- Roots constant, None sentinel]
   [Source: BasisRollup.sol, line 56 -- bytes32 currentRoot] *)
Definition Root := nat.

(* Batch identifier. Sequential indices from 0.
   [Source: BasisRollup.tla, line 52 -- BatchIds == 0..(MaxBatches-1)]
   [Source: BasisRollup.sol, line 273 -- batchId = es.totalBatchesCommitted] *)
Definition BatchId := nat.

(* ========================================== *)
(*     BATCH STATUS                            *)
(* ========================================== *)

(* Batch lifecycle status. Maps to BasisRollup.sol enum.
   [Source: BasisRollup.tla, lines 44-47 -- StatusNone..StatusExecuted]
   [Source: BasisRollup.sol, line 41 -- enum BatchStatus] *)
Inductive BatchStatus : Type :=
  | BSNone       (* Unallocated or reverted batch slot *)
  | BSCommitted  (* Sequencer has committed batch metadata *)
  | BSProven     (* Prover has submitted validity proof *)
  | BSExecuted.  (* Batch finalized, state root applied *)

(* Boolean equality for BatchStatus.
   Used in update_map conditionals and proof automation. *)
Definition BatchStatus_eqb (a b : BatchStatus) : bool :=
  match a, b with
  | BSNone, BSNone           => true
  | BSCommitted, BSCommitted => true
  | BSProven, BSProven       => true
  | BSExecuted, BSExecuted   => true
  | _, _                     => false
  end.

Lemma BatchStatus_eqb_refl : forall s, BatchStatus_eqb s s = true.
Proof. destruct s; reflexivity. Qed.

Lemma BatchStatus_eqb_eq : forall a b, BatchStatus_eqb a b = true <-> a = b.
Proof.
  intros a b; split; intro H.
  - destruct a, b; simpl in H; try discriminate; reflexivity.
  - subst. apply BatchStatus_eqb_refl.
Qed.

(* ========================================== *)
(*     FUNCTIONAL MAP OPERATIONS               *)
(* ========================================== *)

(* Pointwise update of a function at a single key.
   Models TLA+ [f EXCEPT ![k] = v] and Solidity storage writes.
   [Source: BasisRollup.tla -- EXCEPT operator throughout]
   [Source: BasisRollup.sol -- mapping writes] *)
Definition update_map {A : Type} (f : nat -> A) (k : nat) (v : A) : nat -> A :=
  fun n => if Nat.eqb n k then v else f n.

(* Update at the target key returns the new value. *)
Lemma update_map_eq : forall (A : Type) (f : nat -> A) k v,
  update_map f k v k = v.
Proof.
  intros. unfold update_map. rewrite Nat.eqb_refl. reflexivity.
Qed.

(* Update at a different key returns the original value. *)
Lemma update_map_neq : forall (A : Type) (f : nat -> A) k v n,
  n <> k -> update_map f k v n = f n.
Proof.
  intros A f k v n Hneq. unfold update_map.
  destruct (Nat.eqb_spec n k) as [Heq | _].
  - exfalso. exact (Hneq Heq).
  - reflexivity.
Qed.

(* ========================================== *)
(*     TACTICS                                 *)
(* ========================================== *)

(* Destruct the outermost match expression in goal or hypothesis. *)
Ltac destruct_match :=
  match goal with
  | [ |- context[match ?x with _ => _ end] ] => destruct x eqn:?
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x eqn:?
  end.
