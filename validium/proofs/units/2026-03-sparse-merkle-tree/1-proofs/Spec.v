(* ================================================================ *)
(*  Spec.v -- Faithful Translation of SparseMerkleTree.tla to Coq   *)
(* ================================================================ *)
(*                                                                  *)
(*  Every definition in this file corresponds to a definition in    *)
(*  the TLA+ specification. Source references are provided as:      *)
(*  [TLA: <operator name>, line <number>]                           *)
(*                                                                  *)
(*  Source: 0-input-spec/SparseMerkleTree.tla                       *)
(*  TLC Result: 1,572,865 states, 65,536 distinct, PASS            *)
(* ================================================================ *)

From SMT Require Import Common.
From Stdlib Require Import ZArith.ZArith.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Lia.

Open Scope Z_scope.

Module Spec.

(* ======================================== *)
(*     STATE                                *)
(* ======================================== *)

(* [TLA: VARIABLES entries, root -- line 248-250]
   The state consists of a key-value mapping and a root hash.
   entries is a function from keys to values (EMPTY for unoccupied).
   root is the current Merkle root hash, maintained incrementally. *)
Record State := mkState {
  entries : Entries;
  root    : FieldElement;
}.

(* ======================================== *)
(*     DEFAULT HASHES                       *)
(* ======================================== *)

(* [TLA: DefaultHash(level), lines 124-128]
   Precomputed hashes for all-empty subtrees at each level.
   DefaultHash(0) = EMPTY = 0
   DefaultHash(level) = Hash(DefaultHash(level-1), DefaultHash(level-1)) *)
Fixpoint DefaultHash (level : nat) : FieldElement :=
  match level with
  | O => EMPTY
  | S l => Hash (DefaultHash l) (DefaultHash l)
  end.

Lemma default_hash_0 : DefaultHash 0 = EMPTY.
Proof. reflexivity. Qed.

Lemma default_hash_S : forall l,
    DefaultHash (S l) = Hash (DefaultHash l) (DefaultHash l).
Proof. reflexivity. Qed.

(* DefaultHash(level) is non-negative for level >= 1 because
   Hash returns positive values. For level 0, it equals EMPTY = 0. *)
Lemma default_hash_nonneg : forall l,
    DefaultHash l >= 0.
Proof.
  induction l as [| l' IH].
  - simpl. unfold EMPTY. lia.
  - simpl. pose proof (hash_positive (DefaultHash l') (DefaultHash l')). lia.
Qed.

(* ======================================== *)
(*     ENTRY VALUE LOOKUP                   *)
(* ======================================== *)

(* [TLA: EntryValue(e, idx), line 141]
   Look up the value at a leaf index. The entries function is
   total; all keys return a value (EMPTY for unoccupied). *)
Definition EntryValue (e : Entries) (idx : Z) : FieldElement :=
  e idx.

(* ======================================== *)
(*     TREE COMPUTATION (REFERENCE)         *)
(* ======================================== *)

(* [TLA: ComputeNode(e, level, index), lines 148-153]
   Recursively compute the hash of the node at (level, index)
   by hashing its two children. This is the full-rebuild reference
   computation used to verify the incremental root.

   Proof strategy: Structural recursion on level (nat). At level 0,
   return the leaf hash. Otherwise, hash the two children. *)
Fixpoint ComputeNode (e : Entries) (level : nat) (index : Z) : FieldElement :=
  match level with
  | O => LeafHash index (EntryValue e index)
  | S l => Hash (ComputeNode e l (2 * index))
                (ComputeNode e l (2 * index + 1))
  end.

(* [TLA: ComputeRoot(e), line 156]
   Compute the root hash from entries by full tree rebuild. *)
Definition ComputeRoot (e : Entries) : FieldElement :=
  ComputeNode e (Z.to_nat DEPTH) 0.

(* ======================================== *)
(*     SIBLING HASH (FOR PATH OPERATIONS)   *)
(* ======================================== *)

(* [TLA: SiblingHash(e, key, level), lines 181-182]
   Compute the hash of the sibling subtree at a given level.
   Uses the ComputeNode reference to get the sibling's hash. *)
Definition SiblingHash (e : Entries) (key : Z) (level : nat) : FieldElement :=
  ComputeNode e level (SiblingIndex key level).

(* ======================================== *)
(*     WALKUP -- INCREMENTAL ROOT UPDATE    *)
(* ======================================== *)

(* [TLA: WalkUp(oldEntries, currentHash, key, level), lines 196-204]
   After modifying a single leaf, recompute only the path from that
   leaf to the root using siblings from the OLD tree.
   This is the O(depth) update algorithm.

   Proof strategy: Recursion on remaining levels (depth_nat - level).
   At each step, hash with the sibling from the old tree, moving up. *)
Fixpoint WalkUp (oldEntries : Entries) (currentHash : FieldElement)
         (key : Z) (level : nat) (remaining : nat) : FieldElement :=
  match remaining with
  | O => currentHash
  | S r =>
    let bit := PathBit key level in
    let sibling := SiblingHash oldEntries key level in
    let parent := if Z.eq_dec bit 0
                  then Hash currentHash sibling
                  else Hash sibling currentHash in
    WalkUp oldEntries parent key (S level) r
  end.

(* Convenience: WalkUp from level 0 to DEPTH *)
Definition WalkUpFromLeaf (oldEntries : Entries) (leafHash : FieldElement)
           (key : Z) (depth_nat : nat) : FieldElement :=
  WalkUp oldEntries leafHash key 0 depth_nat.

(* ======================================== *)
(*     INITIAL STATE                        *)
(* ======================================== *)

(* [TLA: Init, lines 269-271]
   All entries are empty. Root is the default hash for an all-empty tree.
   Init == entries = [k \in Keys |-> EMPTY] /\ root = DefaultHash(DEPTH) *)
Definition Init (depth_nat : nat) : State :=
  mkState empty_entries (DefaultHash depth_nat).

(* ======================================== *)
(*     ACTIONS                              *)
(* ======================================== *)

(* [TLA: Insert(k, v), lines 283-290]
   Insert or update a key-value pair.
   Preconditions: v <> entries[k] (the value actually changes).
   Computes new leaf hash, walks up from leaf to root using old siblings. *)
Definition Insert (s : State) (k v : FieldElement) (depth_nat : nat) : State :=
  let newLeafHash := LeafHash k v in
  let newRoot := WalkUpFromLeaf (entries s) newLeafHash k depth_nat in
  mkState (update_entry (entries s) k v) newRoot.

(* [TLA: Delete(k), lines 297-303]
   Delete an entry (set value to EMPTY).
   Equivalent to Insert(k, EMPTY). *)
Definition Delete (s : State) (k : FieldElement) (depth_nat : nat) : State :=
  Insert s k EMPTY depth_nat.

(* ======================================== *)
(*     STEP RELATION                        *)
(* ======================================== *)

(* [TLA: Next, lines 309-311]
   Next == \/ \E k, v : Insert(k, v) \/ \E k : Delete(k)
   We model this as an inductive step relation. *)
Inductive step (depth_nat : nat) : State -> State -> Prop :=
  | step_insert : forall s k v,
      v <> EMPTY ->
      v <> entries s k ->
      step depth_nat s (Insert s k v depth_nat)
  | step_delete : forall s k,
      entries s k <> EMPTY ->
      step depth_nat s (Delete s k depth_nat).

(* ======================================== *)
(*     PROOF VERIFICATION                   *)
(* ======================================== *)

(* [TLA: ProofSiblings(e, key), lines 217-218]
   Generate the sequence of sibling hashes for a Merkle proof.
   ProofSiblings(e, key) == [level \in 0..(DEPTH-1) |-> SiblingHash(e, key, level)] *)
Definition ProofSiblings (e : Entries) (key : Z) (level : nat) : FieldElement :=
  SiblingHash e key level.

(* [TLA: PathBitsForKey(key), lines 221-222]
   Generate path bit sequence for a key.
   PathBitsForKey(key) == [level \in 0..(DEPTH-1) |-> PathBit(key, level)] *)
Definition PathBitsForKey (key : Z) (level : nat) : Z :=
  PathBit key level.

(* [TLA: VerifyWalkUp(currentHash, siblings, pathBits, level), lines 232-238]
   Walk up from leaf hash using provided siblings and path bits.
   This models external proof verification (no access to the tree). *)
Fixpoint VerifyWalkUp (currentHash : FieldElement)
         (siblings : nat -> FieldElement) (pathBits : nat -> Z)
         (level : nat) (remaining : nat) : FieldElement :=
  match remaining with
  | O => currentHash
  | S r =>
    let parent := if Z.eq_dec (pathBits level) 0
                  then Hash currentHash (siblings level)
                  else Hash (siblings level) currentHash in
    VerifyWalkUp parent siblings pathBits (S level) r
  end.

(* [TLA: VerifyProofOp(expectedRoot, leafHash, siblings, pathBits), lines 241-242]
   Full proof verification: walk up from leaf hash and compare to root. *)
Definition VerifyProofOp (expectedRoot leafHash : FieldElement)
           (siblings : nat -> FieldElement) (pathBits : nat -> Z)
           (depth_nat : nat) : Prop :=
  VerifyWalkUp leafHash siblings pathBits 0 depth_nat = expectedRoot.

(* ======================================== *)
(*     INVARIANTS                           *)
(* ======================================== *)

(* [TLA: ConsistencyInvariant, line 332]
   The root hash must be a deterministic function of tree contents.
   root = ComputeRoot(entries)
   This verifies that incremental WalkUp always produces the same
   result as full tree rebuild. *)
Definition ConsistencyInvariant (s : State) (depth_nat : nat) : Prop :=
  root s = ComputeNode (entries s) depth_nat 0.

(* Key validity: a key is valid if it is a leaf index in [0, 2^DEPTH).
   This corresponds to [TLA: Keys \subseteq LeafIndices == 0..(Pow2(DEPTH)-1)]
   In the implementation: keyToIndex extracts the lower depth bits. *)
Definition ValidKey (k : Z) (depth_nat : nat) : Prop :=
  k >= 0 /\ k / pow2 depth_nat = 0.

(* [TLA: SoundnessInvariant, lines 350-357]
   An invalid proof must never be accepted as valid.
   For any valid key k and any value v different from the actual entry,
   proof verification with the correct siblings must reject.

   Restricted to ValidKey to match TLA+ ASSUME Keys \subseteq LeafIndices. *)
Definition SoundnessInvariant (s : State) (depth_nat : nat) : Prop :=
  forall k v,
    ValidKey k depth_nat ->
    v <> EntryValue (entries s) k ->
    ~ VerifyProofOp (root s)
                    (LeafHash k v)
                    (ProofSiblings (entries s) k)
                    (PathBitsForKey k)
                    depth_nat.

(* [TLA: CompletenessInvariant, lines 369-374]
   Every valid leaf position must have a valid Merkle proof.
   GetProof followed by VerifyProof must succeed for every valid key.

   Restricted to ValidKey to match TLA+ \A k \in LeafIndices. *)
Definition CompletenessInvariant (s : State) (depth_nat : nat) : Prop :=
  forall k,
    ValidKey k depth_nat ->
    VerifyProofOp (root s)
                  (LeafHash k (EntryValue (entries s) k))
                  (ProofSiblings (entries s) k)
                  (PathBitsForKey k)
                  depth_nat.

End Spec.
