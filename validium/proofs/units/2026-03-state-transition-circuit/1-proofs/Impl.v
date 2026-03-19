(* ================================================================ *)
(*  Impl.v -- Abstract Model of state_transition.circom             *)
(* ================================================================ *)
(*                                                                  *)
(*  Models the Circom ZK circuit as Coq functions and predicates.   *)
(*  Each definition references the source circuit code.             *)
(*                                                                  *)
(*  Modeling approach for Circom:                                    *)
(*  - Signals modeled as field elements (Z)                         *)
(*  - Constraints modeled as equality checks (Z.eq_dec)             *)
(*  - MerkleProofVerifier modeled as iterative hash walk-up         *)
(*  - Chained roots modeled as sequential function composition      *)
(*  - Circuit satisfaction modeled as option type (Some = sat)      *)
(*                                                                  *)
(*  Source: 0-input-impl/state_transition.circom                    *)
(*  Source: 0-input-impl/merkle_proof_verifier.circom               *)
(* ================================================================ *)

From STC Require Import Common.
From Stdlib Require Import ZArith.ZArith.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Lia.

Open Scope Z_scope.
Import ListNotations.

Module Impl.

(* ======================================== *)
(*     CIRCUIT WITNESS                      *)
(* ======================================== *)

(* Each transaction in the circuit has these witness values.
   [Impl: state_transition.circom, lines 36-39]
   signal input txKeys[batchSize];
   signal input txOldValues[batchSize];
   signal input txNewValues[batchSize];
   signal input txSiblings[batchSize][depth]; *)
Record TxWitness := mkTxWitness {
  w_key      : Z;
  w_oldValue : FieldElement;
  w_newValue : FieldElement;
  w_siblings : nat -> FieldElement;
}.

(* ======================================== *)
(*     MERKLE PATH VERIFIER                 *)
(* ======================================== *)

(* Models MerkleProofVerifier(depth) template.
   [Impl: merkle_proof_verifier.circom, lines 25-64]

   Given a leaf hash, sibling hashes, and path direction bits,
   computes the Merkle root by hashing up the tree. At each level
   the path bit determines ordering: 0 = left, 1 = right.

   This directly models the circuit's iterative hash computation:
   intermediateHashes[0] = leaf
   for i in 0..depth-1:
     left = muxLeft(intermediateHashes[i], siblings[i], pathBits[i])
     right = muxRight(siblings[i], intermediateHashes[i], pathBits[i])
     intermediateHashes[i+1] = Poseidon(left, right)
   root = intermediateHashes[depth] *)
Fixpoint MerklePathVerifier (currentHash : FieldElement)
         (siblings : nat -> FieldElement) (pathBits : nat -> Z)
         (level : nat) (remaining : nat) : FieldElement :=
  match remaining with
  | O => currentHash
  | S r =>
    let parent := if Z.eq_dec (pathBits level) 0
                  then Hash currentHash (siblings level)
                  else Hash (siblings level) currentHash in
    MerklePathVerifier parent siblings pathBits (S level) r
  end.

(* ======================================== *)
(*     PER-TRANSACTION CIRCUIT              *)
(* ======================================== *)

(* Models one iteration of the StateTransition loop.
   [Impl: state_transition.circom, lines 56-108]

   Steps per transaction i:
   1. keyBits = Num2Bits(txKeys[i])          -- path bit derivation
   2. oldLeafHash = Poseidon(key, oldValue)  -- old leaf hash
   3. oldRoot = MerklePathVerifier(...)      -- walk up from old leaf
   4. CONSTRAINT: oldRoot == chainedRoots[i] -- old root check
   5. newLeafHash = Poseidon(key, newValue)  -- new leaf hash
   6. newRoot = MerklePathVerifier(...)      -- walk up from new leaf
   7. chainedRoots[i+1] = newRoot            -- chain to next tx

   Returns Some(newRoot) if constraint passes, None otherwise. *)
Definition PerTxCircuit (chainedRoot : FieldElement) (w : TxWitness)
           (d : nat) : option FieldElement :=
  let pathBits := fun l => PathBit (w_key w) l in
  let oldLeafHash := LeafHash (w_key w) (w_oldValue w) in
  let oldRoot := MerklePathVerifier oldLeafHash (w_siblings w) pathBits 0 d in
  if Z.eq_dec oldRoot chainedRoot
  then let newLeafHash := LeafHash (w_key w) (w_newValue w) in
       let newRoot := MerklePathVerifier newLeafHash (w_siblings w) pathBits 0 d in
       Some newRoot
  else None.

(* ======================================== *)
(*     BATCH CIRCUIT                        *)
(* ======================================== *)

(* Models the full StateTransition(depth, batchSize) template.
   [Impl: state_transition.circom, lines 53-108]

   chainedRoots[0] = prevStateRoot
   for i in 0..batchSize-1:
     ... per-tx circuit ...
     chainedRoots[i+1] = newRoot
   CONSTRAINT: chainedRoots[batchSize] == newStateRoot *)
Fixpoint BatchCircuit (chainedRoot : FieldElement)
         (witnesses : list TxWitness) (d : nat) : option FieldElement :=
  match witnesses with
  | nil => Some chainedRoot
  | w :: rest =>
    match PerTxCircuit chainedRoot w d with
    | Some newRoot => BatchCircuit newRoot rest d
    | None => None
    end
  end.

(* ======================================== *)
(*     CIRCUIT SATISFACTION                 *)
(* ======================================== *)

(* The full circuit accepts: batch produces the declared newStateRoot.
   [Impl: state_transition.circom, lines 113-116]
   finalCheck: chainedRoots[batchSize] == newStateRoot *)
Definition CircuitAccepts (prevStateRoot newStateRoot : FieldElement)
           (witnesses : list TxWitness) (d : nat) : Prop :=
  BatchCircuit prevStateRoot witnesses d = Some newStateRoot.

End Impl.
