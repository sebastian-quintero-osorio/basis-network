(* ================================================================ *)
(*  Common.v -- Standard Library for State Transition Circuit       *)
(*              Verification Unit                                   *)
(* ================================================================ *)
(*                                                                  *)
(*  Provides type mappings, helper definitions, and tactics shared  *)
(*  across Spec.v, Impl.v, and Refinement.v.                       *)
(*                                                                  *)
(*  Reused from RU-V1 (Sparse Merkle Tree) with identical content. *)
(*  The hash axioms, tree parameters, and key operations are the    *)
(*  same because RU-V2 builds on the same SMT primitives.          *)
(*                                                                  *)
(*  Target: validium/proofs/units/2026-03-state-transition-circuit/ *)
(*  Source TLA+: StateTransitionCircuit.tla                         *)
(*  Source Impl: state_transition.circom, merkle_proof_verifier.circom *)
(* ================================================================ *)

From Stdlib Require Import ZArith.ZArith.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Bool.Bool.
From Stdlib Require Import Lia.

Open Scope Z_scope.
Import ListNotations.

(* ======================================== *)
(*     FIELD ELEMENT TYPE                   *)
(* ======================================== *)

(* In the TLA+ spec, values are natural numbers (Nat).
   In the implementation, values are BN128 scalar field elements.
   We model field elements as Z (integers), with the understanding
   that all values are non-negative. The hash function is abstract. *)

Definition FieldElement := Z.

(* The empty sentinel value.
   [Spec: EMPTY == 0, line 66]
   [Impl: 0n in Circom signals] *)
Definition EMPTY : FieldElement := 0.

(* ======================================== *)
(*     HASH FUNCTION AXIOMATIZATION         *)
(* ======================================== *)

(* The hash function is modeled as an abstract 2-to-1 function.
   In the TLA+ spec: Hash(a, b) = ((a * 31 + b * 17 + 1) % HASH_MOD) + 1
   In the implementation: Poseidon 2-to-1 hash over BN128 field.

   We axiomatize the properties required for the proofs:
   P1. Hash outputs are positive (non-zero), distinguishing from EMPTY.
   P2. Hash is deterministic.
   P3. Hash is injective (models collision resistance). *)

Parameter Hash : FieldElement -> FieldElement -> FieldElement.

(* P1: Hash outputs are strictly positive (never equal to EMPTY = 0).
   [Spec: Hash(a, b) = ((a*31 + b*17 + 1) % HASH_MOD) + 1 >= 1]
   [Impl: Poseidon outputs are in (0, p) for all inputs in the field] *)
Axiom hash_positive : forall a b : FieldElement, Hash a b > 0.

(* P3: Hash is injective (collision resistance).
   If Hash(a1, b1) = Hash(a2, b2) then a1 = a2 and b1 = b2. *)
Axiom hash_injective : forall a1 b1 a2 b2 : FieldElement,
    Hash a1 b1 = Hash a2 b2 -> a1 = a2 /\ b1 = b2.

(* ======================================== *)
(*     TREE PARAMETERS                      *)
(* ======================================== *)

(* Tree depth. In the TLA+ spec this is a CONSTANT; in the
   implementation it defaults to 10 (test) or 32 (production). *)
Parameter DEPTH : Z.

(* Depth must be positive.
   [Spec: ASSUME DEPTH \in (Nat \ {0}), line 83] *)
Axiom depth_positive : DEPTH > 0.

(* ======================================== *)
(*     POWER OF 2                           *)
(* ======================================== *)

(* [Spec: Pow2(n) == IF n = 0 THEN 1 ELSE 2 * Pow2(n - 1), line 69] *)
Definition pow2 (n : nat) : Z := Z.pow 2 (Z.of_nat n).

Lemma pow2_pos : forall n, pow2 n > 0.
Proof.
  intros n. unfold pow2.
  apply Z.lt_gt.
  apply Z.pow_pos_nonneg; lia.
Qed.

Lemma pow2_double : forall n, pow2 (S n) = 2 * pow2 n.
Proof.
  intros. unfold pow2.
  rewrite Nat2Z.inj_succ.
  rewrite Z.pow_succ_r by lia.
  reflexivity.
Qed.

Lemma pow2_0 : pow2 0 = 1.
Proof.
  unfold pow2. simpl. reflexivity.
Qed.

(* ======================================== *)
(*     KEY-VALUE STORE (ENTRIES)             *)
(* ======================================== *)

(* Both the spec and implementation maintain a mapping from keys to values.
   [Spec: entries \in [Keys -> Values \cup {EMPTY}], line 77]
   We model this as a total function from Z to FieldElement. *)

Definition Entries := Z -> FieldElement.

(* Empty entries: all keys map to EMPTY.
   [Spec: Init == trees = [e \in Enterprises |-> [k \in Keys |-> EMPTY]], line 254] *)
Definition empty_entries : Entries := fun _ => EMPTY.

(* Update a single entry.
   [Spec: [treeEntries EXCEPT ![tx.key] = tx.newValue], line 280] *)
Definition update_entry (e : Entries) (k : Z) (v : FieldElement) : Entries :=
  fun k' => if Z.eq_dec k k' then v else e k'.

Lemma update_entry_same : forall e k v,
    update_entry e k v k = v.
Proof.
  intros. unfold update_entry. destruct (Z.eq_dec k k); [reflexivity | contradiction].
Qed.

Lemma update_entry_other : forall e k v k',
    k <> k' -> update_entry e k v k' = e k'.
Proof.
  intros. unfold update_entry. destruct (Z.eq_dec k k'); [contradiction | reflexivity].
Qed.

(* ======================================== *)
(*     LEAF HASH                            *)
(* ======================================== *)

(* [Spec: LeafHash(key, value) == IF value = EMPTY THEN EMPTY ELSE Hash(key, value), line 119]
   [Impl: Poseidon(2) applied to key and value in the circuit] *)
Definition LeafHash (key value : FieldElement) : FieldElement :=
  if Z.eq_dec value EMPTY then EMPTY else Hash key value.

Lemma leaf_hash_empty : forall k, LeafHash k EMPTY = EMPTY.
Proof.
  intros. unfold LeafHash, EMPTY.
  destruct (Z.eq_dec 0 0); [reflexivity | contradiction].
Qed.

Lemma leaf_hash_nonempty : forall k v,
    v <> EMPTY -> LeafHash k v = Hash k v.
Proof.
  intros. unfold LeafHash.
  destruct (Z.eq_dec v EMPTY); [contradiction | reflexivity].
Qed.

Lemma leaf_hash_nonneg : forall k v, LeafHash k v >= 0.
Proof.
  intros k v. unfold LeafHash.
  destruct (Z.eq_dec v EMPTY).
  - unfold EMPTY. lia.
  - pose proof (hash_positive k v). lia.
Qed.

(* ======================================== *)
(*     PATH BIT EXTRACTION                  *)
(* ======================================== *)

(* [Spec: PathBit(key, level) == (key \div Pow2(level)) % 2, line 178]
   [Impl: Num2Bits(depth) in the circuit, bit j = (key >> j) & 1] *)

Definition PathBit (key : Z) (level : nat) : Z :=
  (key / pow2 level) mod 2.

(* ======================================== *)
(*     SIBLING INDEX                        *)
(* ======================================== *)

(* [Spec: SiblingIndex(key, level), lines 181-185] *)

Definition SiblingIndex (key : Z) (level : nat) : Z :=
  let ancestorIdx := key / pow2 level in
  if Z.eq_dec (ancestorIdx mod 2) 0
  then ancestorIdx + 1
  else ancestorIdx - 1.

(* ======================================== *)
(*     TACTICS                              *)
(* ======================================== *)

(* Destruct match expressions in the goal *)
Ltac destruct_match :=
  match goal with
  | [ |- context[if ?c then _ else _] ] => destruct c
  | [ H : context[if ?c then _ else _] |- _ ] => destruct c
  | [ |- context[match ?x with _ => _ end] ] => destruct x
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x
  end.

(* Unfold common type wrappers *)
Ltac unfold_wrappers :=
  unfold FieldElement, Entries, EMPTY, LeafHash, PathBit, SiblingIndex in *.

(* Combined auto tactic for specification-level goals *)
Ltac auto_spec :=
  intros; try unfold_wrappers; simpl;
  try destruct_match; try reflexivity; try assumption; try lia.
