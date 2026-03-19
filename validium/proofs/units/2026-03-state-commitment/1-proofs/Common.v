(* ================================================================ *)
(*  Common.v -- Standard Library for State Commitment Verification   *)
(* ================================================================ *)
(*                                                                  *)
(*  Provides type definitions, function update primitives, and      *)
(*  helper lemmas shared across Spec.v, Impl.v, and Refinement.v.  *)
(*                                                                  *)
(*  Target: validium/proofs/units/2026-03-state-commitment/         *)
(*  Source TLA+: StateCommitment.tla                                *)
(*  Source Impl: StateCommitment.sol                                *)
(* ================================================================ *)

From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.

Open Scope nat_scope.

(* ======================================== *)
(*     DOMAIN TYPES                        *)
(* ======================================== *)

(* Enterprise identifier.
   [TLA: CONSTANTS Enterprises -- line 20]
   [Solidity: address -- line 63]
   Modeled as nat for decidable equality. *)
Definition Enterprise := nat.

(* State root value.
   [TLA: CONSTANTS Roots, None -- lines 22-23]
   [Solidity: bytes32 -- lines 39, 67]
   Modeled as nat with 0 as sentinel for uninitialized slots. *)
Definition Root := nat.

(* Sentinel value for empty/uninitialized slots.
   [TLA: CONSTANTS None, None \notin Roots -- line 25]
   [Solidity: bytes32(0) -- default storage value] *)
Definition NONE : Root := 0.

(* Valid roots are non-NONE (positive). *)
Lemma pos_ne_NONE : forall r : Root, r > 0 -> r <> NONE.
Proof. unfold NONE. lia. Qed.

(* ======================================== *)
(*     FUNCTION UPDATE PRIMITIVES          *)
(* ======================================== *)

(* Models TLA+ [f EXCEPT ![k] = v] and Solidity mapping writes.
   Generic: works for Enterprise -> Root, Enterprise -> nat,
   Enterprise -> bool, etc. *)
Definition fupdate {A : Type} (f : nat -> A) (k : nat) (v : A) : nat -> A :=
  fun k' => if Nat.eq_dec k k' then v else f k'.

(* Two-level update: [f EXCEPT ![k1][k2] = v].
   [TLA: [batchHistory EXCEPT ![e][bid] = newRoot]]
   [Solidity: batchRoots[enterprise][batchId] = newStateRoot] *)
Definition fupdate2 {A : Type} (f : nat -> nat -> A) (k1 k2 : nat) (v : A)
  : nat -> nat -> A :=
  fun k1' k2' =>
    if Nat.eq_dec k1 k1' then
      if Nat.eq_dec k2 k2' then v
      else f k1' k2'
    else f k1' k2'.

(* Prevent simpl from unfolding fupdate/fupdate2.
   Forces proofs to use explicit rewrite lemmas for clarity. *)
Global Arguments fupdate : simpl never.
Global Arguments fupdate2 : simpl never.

(* ======================================== *)
(*     FUNCTION UPDATE LEMMAS              *)
(* ======================================== *)

(* Same key: returns new value *)
Lemma fupdate_same : forall {A : Type} (f : nat -> A) k v,
    fupdate f k v k = v.
Proof.
  intros. unfold fupdate.
  destruct (Nat.eq_dec k k); [reflexivity | contradiction].
Qed.

(* Different key: returns old value *)
Lemma fupdate_other : forall {A : Type} (f : nat -> A) k v k',
    k <> k' -> fupdate f k v k' = f k'.
Proof.
  intros. unfold fupdate.
  destruct (Nat.eq_dec k k'); [contradiction | reflexivity].
Qed.

(* Both keys match: returns new value *)
Lemma fupdate2_same : forall {A : Type} (f : nat -> nat -> A) k1 k2 v,
    fupdate2 f k1 k2 v k1 k2 = v.
Proof.
  intros. unfold fupdate2.
  destruct (Nat.eq_dec k1 k1); [| contradiction].
  destruct (Nat.eq_dec k2 k2); [reflexivity | contradiction].
Qed.

(* Different first key: returns old value *)
Lemma fupdate2_other_k1 : forall {A : Type} (f : nat -> nat -> A) k1 k2 v k1' k2',
    k1 <> k1' -> fupdate2 f k1 k2 v k1' k2' = f k1' k2'.
Proof.
  intros. unfold fupdate2.
  destruct (Nat.eq_dec k1 k1'); [contradiction | reflexivity].
Qed.

(* Same first key, different second key: returns old value *)
Lemma fupdate2_same_k1_other_k2 : forall {A : Type} (f : nat -> nat -> A) k1 k2 v k2',
    k2 <> k2' -> fupdate2 f k1 k2 v k1 k2' = f k1 k2'.
Proof.
  intros. unfold fupdate2.
  destruct (Nat.eq_dec k1 k1); [| contradiction].
  destruct (Nat.eq_dec k2 k2'); [contradiction | reflexivity].
Qed.
