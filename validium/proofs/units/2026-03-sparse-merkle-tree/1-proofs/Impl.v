(* ================================================================ *)
(*  Impl.v -- Abstract Model of sparse-merkle-tree.ts               *)
(* ================================================================ *)
(*                                                                  *)
(*  Models the TypeScript SparseMerkleTree class as Coq records     *)
(*  and functions. Each definition references the source code.      *)
(*                                                                  *)
(*  Source: 0-input-impl/sparse-merkle-tree.ts                      *)
(*  Source: 0-input-impl/types.ts                                   *)
(*                                                                  *)
(*  Modeling approach for TypeScript:                                *)
(*  - async/Promise -> pure state transitions (no side effects)     *)
(*  - Map<string, FieldElement> -> total function Z -> FieldElement  *)
(*  - Sparse storage (absent = default) -> explicit default logic   *)
(*  - Class instance -> record type                                 *)
(* ================================================================ *)

From SMT Require Import Common.
From SMT Require Import Spec.
From Stdlib Require Import ZArith.ZArith.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Lia.

Open Scope Z_scope.

Module Impl.

(* ======================================== *)
(*     NODE STORAGE MODEL                   *)
(* ======================================== *)

(* [Impl: sparse-merkle-tree.ts, lines 89]
   The implementation stores nodes in a Map<string, FieldElement>.
   Key format: "level:index". Only non-default nodes are stored.

   We model this as a total function (level, index) -> FieldElement,
   where lookups for absent entries return the default hash for
   that level. This faithfully captures the getNode/setNode behavior. *)

Definition NodeStore := nat -> Z -> FieldElement.

(* ======================================== *)
(*     STATE                                *)
(* ======================================== *)

(* [Impl: sparse-merkle-tree.ts, class SparseMerkleTree, lines 63-95]
   Models the class instance as an immutable record.
   - depth: tree depth (readonly, set at construction)
   - defaultHashes: precomputed default hashes per level
   - nodes: sparse node storage
   - entryCount: metadata counter (not part of cryptographic state)

   We omit entryCount and poseidon/F as they do not affect
   the cryptographic correctness being verified. *)
Record State := mkState {
  depth_nat   : nat;
  nodes       : NodeStore;
}.

(* ======================================== *)
(*     NODE ACCESS                          *)
(* ======================================== *)

(* [Impl: sparse-merkle-tree.ts, lines 166-169, getNode]
   Get node hash at (level, index), returning default if absent.
   getNode(level, index) {
     const key = nodeKey(level, index);
     return this.nodes.get(key) ?? this.defaultHashes[level]!;
   }

   In our model, nodes is already a total function that returns
   the default for absent entries. *)
Definition getNode (s : State) (level : nat) (index : Z) : FieldElement :=
  nodes s level index.

(* [Impl: sparse-merkle-tree.ts, lines 175-182, setNode]
   Set node hash. Deletes if value equals default (sparse invariant).
   We model this as a pointwise update to the NodeStore function. *)
Definition setNode (ns : NodeStore) (level : nat) (index : Z)
           (value : FieldElement) : NodeStore :=
  fun l i => if Nat.eq_dec l level then
               if Z.eq_dec i index then value
               else ns l i
             else ns l i.

(* ======================================== *)
(*     ROOT ACCESS                          *)
(* ======================================== *)

(* [Impl: sparse-merkle-tree.ts, lines 193-195, get root()]
   get root(): FieldElement {
     return this.getNode(this.depth, 0n);
   } *)
Definition root (s : State) : FieldElement :=
  getNode s (depth_nat s) 0.

(* ======================================== *)
(*     DEFAULT HASHES                       *)
(* ======================================== *)

(* [Impl: sparse-merkle-tree.ts, lines 108-114, constructor]
   this.defaultHashes[0] = EMPTY_VALUE;
   for (let i = 1; i <= depth; i++) {
     const prev = this.defaultHashes[i - 1]!;
     this.defaultHashes[i] = this.hash2(prev, prev);
   }

   This is exactly Spec.DefaultHash. We reuse it. *)
Definition defaultHash := Spec.DefaultHash.

(* ======================================== *)
(*     INITIAL STATE                        *)
(* ======================================== *)

(* [Impl: sparse-merkle-tree.ts, lines 101-115, constructor + create]
   A fresh SMT has no nodes stored. All lookups return defaults.
   The root is DefaultHash(depth). *)
Definition Init (d : nat) : State :=
  mkState d (fun level _ => defaultHash level).

(* Verify initial root equals DefaultHash(depth). *)
Lemma init_root : forall d, root (Init d) = defaultHash d.
Proof.
  intros. unfold root, getNode, Init. simpl. reflexivity.
Qed.

(* ======================================== *)
(*     INSERT OPERATION                     *)
(* ======================================== *)

(* [Impl: sparse-merkle-tree.ts, lines 249-293, insert method]
   The insert method:
   1. Computes leafHash = LeafHash(key, value)
   2. Sets leaf node at (0, index)
   3. Walks up from level 0 to depth-1, at each level:
      a. Gets current node and sibling
      b. Computes parent hash
      c. Sets parent node

   We model this as an iterative walk-up that produces a new State. *)

(* Single level update: compute parent from current and sibling.
   [Impl: sparse-merkle-tree.ts, lines 274-291] *)
Definition updateLevel (ns : NodeStore) (level : nat) (currentIndex : Z) : NodeStore :=
  let bit := PathBit currentIndex 0 in
  let siblingIndex := Z.lxor currentIndex 1 in
  let sibling := ns level siblingIndex in
  let current := ns level currentIndex in
  let parentHash := if Z.eq_dec bit 0
                    then Hash current sibling
                    else Hash sibling current in
  let parentIndex := Z.shiftr currentIndex 1 in
  setNode ns (S level) parentIndex parentHash.

(* [Impl: sparse-merkle-tree.ts, lines 273-291]
   Iterative walk from level 0 to depth-1.
   At each level, update the parent based on current and sibling.
   currentIndex tracks the position, halving at each level. *)
Fixpoint walkUpLoop (ns : NodeStore) (currentIndex : Z)
         (level : nat) (remaining : nat) : NodeStore :=
  match remaining with
  | O => ns
  | S r =>
    let bit := PathBit currentIndex 0 in
    let siblingIndex := Z.lxor currentIndex 1 in
    let sibling := ns level siblingIndex in
    let current := ns level currentIndex in
    let parentHash := if Z.eq_dec bit 0
                      then Hash current sibling
                      else Hash sibling current in
    let parentIndex := Z.shiftr currentIndex 1 in
    let ns' := setNode ns (S level) parentIndex parentHash in
    walkUpLoop ns' parentIndex (S level) r
  end.

(* Full insert operation: set leaf, then walk up.
   [Impl: sparse-merkle-tree.ts, lines 249-293] *)
Definition insert (s : State) (key value : FieldElement) : State :=
  let index := key in  (* simplified: keyToIndex is identity for our model *)
  let leafHash := LeafHash key value in
  let ns' := setNode (nodes s) 0 index leafHash in
  let ns'' := walkUpLoop ns' index 0 (depth_nat s) in
  mkState (depth_nat s) ns''.

(* ======================================== *)
(*     DELETE OPERATION                     *)
(* ======================================== *)

(* [Impl: sparse-merkle-tree.ts, lines 316-318, delete method]
   async delete(key: bigint): Promise<FieldElement> {
     return this.insert(key, EMPTY_VALUE);
   } *)
Definition delete (s : State) (key : FieldElement) : State :=
  insert s key EMPTY.

(* ======================================== *)
(*     PROOF GENERATION                     *)
(* ======================================== *)

(* [Impl: sparse-merkle-tree.ts, lines 336-359, getProof method]
   Generates a Merkle proof by collecting siblings along the path.
   Returns (siblings, pathBits, leafHash, root).

   In our model, we generate siblings and pathBits as functions. *)
Definition getProofSiblings (s : State) (key : Z) (level : nat) : FieldElement :=
  let currentIndex := Z.shiftr key (Z.of_nat level) in
  (* At this level, the sibling is at currentIndex XOR 1 *)
  (* But we must track the shifting correctly.
     At level 0: sibling is at (key XOR 1) on level 0
     At level l: sibling is at ((key >> l) XOR 1) on level l *)
  getNode s level (Z.lxor (Z.shiftr key (Z.of_nat level)) 1).

Definition getProofPathBits (key : Z) (level : nat) : Z :=
  PathBit key level.

(* ======================================== *)
(*     PROOF VERIFICATION                   *)
(* ======================================== *)

(* [Impl: sparse-merkle-tree.ts, lines 384-407, verifyProof method]
   Iterative walk-up from leaf hash using provided siblings.
   let currentHash = leafHash;
   for (let level = 0; level < this.depth; level++) {
     const sibling = proof.siblings[level]!;
     const bit = proof.pathBits[level]!;
     currentHash = bit === 0
       ? this.hash2(currentHash, sibling)
       : this.hash2(sibling, currentHash);
   }
   return currentHash === root; *)
Fixpoint verifyWalkUp (currentHash : FieldElement)
         (siblings : nat -> FieldElement) (pathBits : nat -> Z)
         (level : nat) (remaining : nat) : FieldElement :=
  match remaining with
  | O => currentHash
  | S r =>
    let parent := if Z.eq_dec (pathBits level) 0
                  then Hash currentHash (siblings level)
                  else Hash (siblings level) currentHash in
    verifyWalkUp parent siblings pathBits (S level) r
  end.

Definition verifyProof (expectedRoot leafHash : FieldElement)
           (siblings : nat -> FieldElement) (pathBits : nat -> Z)
           (depth_nat : nat) : bool :=
  Z.eqb (verifyWalkUp leafHash siblings pathBits 0 depth_nat) expectedRoot.

(* ======================================== *)
(*     STEP RELATION                        *)
(* ======================================== *)

(* The implementation step relation mirrors the spec:
   either an insert with a non-empty value, or a delete. *)
Inductive step : State -> State -> Prop :=
  | step_insert : forall s key value,
      value <> EMPTY ->
      step s (insert s key value)
  | step_delete : forall s key,
      step s (delete s key).

End Impl.
