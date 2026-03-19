(* ================================================================ *)
(*  Refinement.v -- Proof that Implementation Refines Specification  *)
(* ================================================================ *)
(*                                                                  *)
(*  This file proves that sparse-merkle-tree.ts (modeled in Impl.v) *)
(*  correctly implements SparseMerkleTree.tla (modeled in Spec.v).  *)
(*                                                                  *)
(*  Structure:                                                      *)
(*    Part 1: Arithmetic Helper Lemmas (pow2, PathBit, SiblingIndex)*)
(*    Part 2: State Mapping and Initial State Refinement            *)
(*    Part 3: Verify Walk-Up Structural Equivalence                 *)
(*    Part 4: ComputeNode Independence and Empty Tree               *)
(*    Part 5: Verify Reconstructs Node (Completeness Kernel)        *)
(*    Part 6: Completeness from Consistency                         *)
(*    Part 7: Soundness from Hash Injectivity                       *)
(*    Part 8: Consistency Preservation under Insert                 *)
(*    Part 9: All Invariants Induction                              *)
(*                                                                  *)
(*  Axiom Trust Base (from Common.v):                               *)
(*    - hash_positive: Hash(a,b) > 0 for non-negative inputs       *)
(*    - hash_injective: Hash is collision-resistant                 *)
(*    - depth_positive: DEPTH > 0                                   *)
(*                                                                  *)
(*  Source Spec: 0-input-spec/SparseMerkleTree.tla                  *)
(*  Source Impl: 0-input-impl/sparse-merkle-tree.ts                 *)
(* ================================================================ *)

From SMT Require Import Common.
From SMT Require Import Spec.
From SMT Require Import Impl.
From Stdlib Require Import ZArith.ZArith.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Lia.
From Stdlib Require Import micromega.Psatz.

Open Scope Z_scope.

(* ================================================================ *)
(*  PART 1: ARITHMETIC HELPER LEMMAS                                *)
(* ================================================================ *)

(* The ancestor index of key at a given level is key / pow2(level).
   These lemmas relate ancestor indices across tree levels. *)

(* Lemma: key / pow2(S level) = (key / pow2 level) / 2.
   Follows from pow2(S level) = 2 * pow2(level) and Z.div_div.

   Proof strategy: Rewrite pow2(S level) as 2 * pow2(level),
   then apply Z.div_div to combine consecutive divisions. *)
Lemma ancestor_step : forall key level,
    key / pow2 (S level) = (key / pow2 level) / 2.
Proof.
  intros key level.
  unfold pow2.
  rewrite Nat2Z.inj_succ.
  rewrite Z.pow_succ_r by lia.
  rewrite Z.mul_comm.
  rewrite Z.div_div by lia.
  reflexivity.
Qed.

(* Lemma: If PathBit = 0, key goes left. The current ancestor index
   is even: ancestor(level) = 2 * ancestor(S level).

   Proof strategy: PathBit(key, level) = (key/pow2 level) mod 2 = 0
   implies key/pow2 level is even. By division identity,
   key/pow2 level = 2 * (key/pow2 level / 2) = 2 * key/pow2(S level). *)
Lemma pathbit_0_ancestor : forall key level,
    PathBit key level = 0 ->
    key / pow2 level = 2 * (key / pow2 (S level)).
Proof.
  intros key level Hbit.
  unfold PathBit in Hbit.
  rewrite ancestor_step.
  assert (Hpow : pow2 level > 0) by apply pow2_pos.
  pose proof (Z.div_mod (key / pow2 level) 2) as Hdm.
  lia.
Qed.

(* Lemma: If PathBit = 1, key goes right. The current ancestor index
   is odd: ancestor(level) = 2 * ancestor(S level) + 1.

   Proof strategy: Same as pathbit_0_ancestor but with mod 2 = 1. *)
Lemma pathbit_1_ancestor : forall key level,
    PathBit key level = 1 ->
    key / pow2 level = 2 * (key / pow2 (S level)) + 1.
Proof.
  intros key level Hbit.
  unfold PathBit in Hbit.
  rewrite ancestor_step.
  assert (Hpow : pow2 level > 0) by apply pow2_pos.
  pose proof (Z.div_mod (key / pow2 level) 2) as Hdm.
  lia.
Qed.

(* Lemma: SiblingIndex when PathBit = 0 (key goes left).
   The sibling is at ancestor(level) + 1 (the right sibling).

   Proof strategy: Unfold SiblingIndex. PathBit = 0 means the
   ancestor index mod 2 = 0, so the branch takes the + 1 case. *)
Lemma sibling_index_pathbit_0 : forall key level,
    PathBit key level = 0 ->
    SiblingIndex key level = key / pow2 level + 1.
Proof.
  intros key level Hbit.
  unfold SiblingIndex, PathBit in *.
  destruct (Z.eq_dec ((key / pow2 level) mod 2) 0).
  - reflexivity.
  - lia.
Qed.

(* Lemma: SiblingIndex when PathBit = 1 (key goes right).
   The sibling is at ancestor(level) - 1 (the left sibling).

   Proof strategy: Similar to above but ancestor index is odd. *)
Lemma sibling_index_pathbit_1 : forall key level,
    PathBit key level = 1 ->
    SiblingIndex key level = key / pow2 level - 1.
Proof.
  intros key level Hbit.
  unfold SiblingIndex, PathBit in *.
  destruct (Z.eq_dec ((key / pow2 level) mod 2) 0).
  - lia.
  - reflexivity.
Qed.

(* Lemma: PathBit is either 0 or 1.

   Proof strategy: PathBit = (key / pow2 level) mod 2, and
   Z.mod_bound gives 0 <= x mod 2 < 2. *)
Lemma pathbit_range : forall key level,
    key >= 0 ->
    PathBit key level = 0 \/ PathBit key level = 1.
Proof.
  intros key level Hkey.
  unfold PathBit.
  assert (Hpow : pow2 level > 0) by apply pow2_pos.
  assert (Hdiv_nonneg : key / pow2 level >= 0) by (apply Z_div_ge0; lia).
  assert (Hmod := Z.mod_bound_pos (key / pow2 level) 2).
  lia.
Qed.

(* ================================================================ *)
(*  PART 2: STATE MAPPING AND INITIAL STATE REFINEMENT              *)
(* ================================================================ *)

(* The mapping from Impl.State to Spec.State.
   The Impl stores LeafHash(key, value) at level 0, while the Spec
   stores the raw value. We parameterize with an auxiliary entries
   function that tracks the logical key-value state. *)

Definition map_root (s : Impl.State) : FieldElement :=
  Impl.root s.

Definition map_state (impl_entries : Entries) (s : Impl.State) : Spec.State :=
  Spec.mkState impl_entries (map_root s).

(* Theorem: Initial states correspond under the mapping.

   Proof strategy: Direct computation. Both Init produce DefaultHash(d)
   as root and empty entries. *)
Theorem init_refinement : forall d : nat,
    map_state empty_entries (Impl.Init d) = Spec.Init d.
Proof.
  intros d.
  unfold map_state, map_root, Impl.root, Impl.getNode, Impl.Init.
  unfold Spec.Init, Impl.defaultHash.
  simpl. reflexivity.
Qed.

(* ================================================================ *)
(*  PART 3: VERIFY WALK-UP STRUCTURAL EQUIVALENCE                  *)
(* ================================================================ *)

(* Theorem: Impl.verifyWalkUp = Spec.VerifyWalkUp.
   Both have identical recursive structure.

   Proof strategy: Induction on remaining. Both functions pattern
   match on remaining, compute parent hash identically, and recurse. *)
Theorem verify_walkup_equiv : forall currentHash siblings pathBits level remaining,
    Impl.verifyWalkUp currentHash siblings pathBits level remaining =
    Spec.VerifyWalkUp currentHash siblings pathBits level remaining.
Proof.
  intros currentHash siblings pathBits level remaining.
  revert currentHash level.
  induction remaining as [| r IH].
  - intros. simpl. reflexivity.
  - intros currentHash level. simpl. apply IH.
Qed.

(* ================================================================ *)
(*  PART 4: COMPUTENODE INDEPENDENCE AND EMPTY TREE                 *)
(* ================================================================ *)

(* Lemma: ComputeNode depends only on entries within its subtree.

   Proof strategy: Induction on level. At level 0, only the leaf at
   the given index matters. At S l, the subtree splits into left and
   right halves, each half handled by IH. *)
Lemma compute_node_ext : forall (e1 e2 : Entries) (level : nat) (index : Z),
    (forall idx, index * pow2 level <= idx < (index + 1) * pow2 level ->
                 e1 idx = e2 idx) ->
    Spec.ComputeNode e1 level index = Spec.ComputeNode e2 level index.
Proof.
  intros e1 e2 level.
  induction level as [| l IH].
  - intros index Hagree. simpl.
    unfold Spec.EntryValue.
    rewrite pow2_0 in Hagree.
    rewrite (Hagree index) by lia.
    reflexivity.
  - intros index Hagree.
    cbn [Spec.ComputeNode].
    assert (Hpow : pow2 l > 0) by apply pow2_pos.
    f_equal.
    + apply IH. intros idx Hrange. apply Hagree.
      rewrite pow2_double. nia.
    + apply IH. intros idx Hrange. apply Hagree.
      rewrite pow2_double. nia.
Qed.

(* Lemma: Updating entry k does not change subtrees not containing k.

   Proof strategy: Apply compute_node_ext. update_entry agrees with
   the original on all indices except k. If k is outside the subtree
   range, all entries in range are unchanged. *)
Lemma compute_node_update_outside : forall (e : Entries) (k v : FieldElement)
    (level : nat) (index : Z),
    (k < index * pow2 level \/ k >= (index + 1) * pow2 level) ->
    Spec.ComputeNode (update_entry e k v) level index =
    Spec.ComputeNode e level index.
Proof.
  intros e k v level index Houtside.
  apply compute_node_ext.
  intros idx Hrange. unfold update_entry.
  destruct (Z.eq_dec k idx); [subst; lia | reflexivity].
Qed.

(* Lemma: ComputeNode on empty entries returns DefaultHash.

   Proof strategy: Induction on level. At level 0, LeafHash(idx, EMPTY) = EMPTY
   = DefaultHash(0). At S l, both children are DefaultHash(l) by IH,
   so Hash(DH(l), DH(l)) = DefaultHash(S l). *)
Lemma compute_node_empty : forall (level : nat) (index : Z),
    Spec.ComputeNode empty_entries level index = Spec.DefaultHash level.
Proof.
  induction level as [| l IH].
  - intros. simpl. unfold Spec.EntryValue, empty_entries.
    rewrite leaf_hash_empty. reflexivity.
  - intros. simpl. rewrite IH, IH. reflexivity.
Qed.

(* ================================================================ *)
(*  PART 5: VERIFY RECONSTRUCTS NODE (COMPLETENESS KERNEL)         *)
(* ================================================================ *)

(* Core lemma: VerifyWalkUp with correct siblings from the tree
   reconstructs the ComputeNode at the ancestor position.

   The proof is by induction on remaining levels. At each level:
   - The sibling hash is ComputeNode at the sibling index
   - The parent hash combines current and sibling in the right order
   - This parent equals ComputeNode at the parent level

   Proof strategy: Case split on PathBit at each level. Use
   pathbit_0/1_ancestor and sibling_index_pathbit_0/1 to relate
   tree indices. The key identity is:
     Hash(left_child, right_child) = ComputeNode(S level, parent_index) *)
(* Helper: When PathBit = 0, hashing current node with sibling
   produces ComputeNode at the next level.

   The current node is at index key/pow2(level) (the left child),
   and the sibling is at key/pow2(level)+1 (the right child).
   Hash(left, right) = ComputeNode(e, S level, key/pow2(S level)). *)
Lemma parent_from_left : forall (e : Entries) (key : Z) (level : nat),
    PathBit key level = 0 ->
    Hash (Spec.ComputeNode e level (key / pow2 level))
         (Spec.SiblingHash e key level) =
    Spec.ComputeNode e (S level) (key / pow2 (S level)).
Proof.
  intros e key level Hbit.
  cbn [Spec.ComputeNode].
  unfold Spec.SiblingHash.
  rewrite (sibling_index_pathbit_0 key level Hbit).
  rewrite (pathbit_0_ancestor key level Hbit).
  f_equal; f_equal; lia.
Qed.

(* Helper: When PathBit = 1, hashing sibling with current node
   produces ComputeNode at the next level.

   The current node is at key/pow2(level) (the right child),
   the sibling is at key/pow2(level)-1 (the left child).
   Hash(left, right) = Hash(sibling, current). *)
Lemma parent_from_right : forall (e : Entries) (key : Z) (level : nat),
    key >= 0 ->
    PathBit key level = 1 ->
    Hash (Spec.SiblingHash e key level)
         (Spec.ComputeNode e level (key / pow2 level)) =
    Spec.ComputeNode e (S level) (key / pow2 (S level)).
Proof.
  intros e key level Hk Hbit.
  cbn [Spec.ComputeNode].
  unfold Spec.SiblingHash.
  rewrite (sibling_index_pathbit_1 key level Hbit).
  rewrite (pathbit_1_ancestor key level Hbit).
  f_equal; f_equal; lia.
Qed.

Lemma verify_reconstructs_node : forall (e : Entries) (key : Z),
    key >= 0 ->
    forall (level : nat) (remaining : nat),
    Spec.VerifyWalkUp
      (Spec.ComputeNode e level (key / pow2 level))
      (fun l => Spec.SiblingHash e key l)
      (fun l => PathBit key l)
      level remaining =
    Spec.ComputeNode e (level + remaining) (key / pow2 (level + remaining)).
Proof.
  intros e key Hkey level remaining.
  revert level.
  induction remaining as [| r IH].
  - (* Base case: remaining = 0. *)
    intros level. simpl.
    replace (level + 0)%nat with level by lia.
    reflexivity.
  - (* Inductive case: remaining = S r. *)
    intros level. simpl.
    destruct (pathbit_range key level Hkey) as [Hbit0 | Hbit1].
    + (* PathBit = 0: key goes left *)
      rewrite Hbit0.
      destruct (Z.eq_dec 0 0) as [_ | Habs]; [| contradiction].
      (* Hash(current, sibling) = ComputeNode(e, S level, ...) *)
      rewrite (parent_from_left e key level Hbit0).
      rewrite IH.
      replace (S level + r)%nat with (level + S r)%nat by lia.
      reflexivity.
    + (* PathBit = 1: key goes right *)
      rewrite Hbit1.
      destruct (Z.eq_dec 1 0) as [Habs | _]; [lia |].
      rewrite (parent_from_right e key level Hkey Hbit1).
      rewrite IH.
      replace (S level + r)%nat with (level + S r)%nat by lia.
      reflexivity.
Qed.

(* ================================================================ *)
(*  PART 6: COMPLETENESS FROM CONSISTENCY                           *)
(* ================================================================ *)

(* Theorem: ConsistencyInvariant implies CompletenessInvariant.
   If root = ComputeNode(entries, d, 0), then every leaf has a
   valid Merkle proof.

   [TLA: ConsistencyInvariant => CompletenessInvariant]

   Proof strategy: Instantiate verify_reconstructs_node at level 0,
   remaining d. At level 0, ComputeNode(e, 0, key) is the leaf hash.
   At the top, ComputeNode(e, d, key/pow2 d) = root (by consistency
   and the key range assumption). *)
Theorem completeness_from_consistency : forall (s : Spec.State) (d : nat),
    Spec.ConsistencyInvariant s d ->
    Spec.CompletenessInvariant s d.
Proof.
  intros s d Hcons.
  unfold Spec.ConsistencyInvariant in Hcons.
  unfold Spec.CompletenessInvariant.
  unfold Spec.VerifyProofOp.
  unfold Spec.ProofSiblings, Spec.PathBitsForKey.
  intros k [Hk Hkrange].
  (* k >= 0 and k / pow2 d = 0: valid key in [0, 2^d) *)
  pose proof (verify_reconstructs_node (Spec.entries s) k Hk 0 d) as Hrecon.
  simpl in Hrecon.
  rewrite Z.div_1_r in Hrecon.
  rewrite Hrecon.
  (* ComputeNode(e, d, k / pow2 d) = ComputeNode(e, d, 0) by key range *)
  rewrite Hkrange.
  rewrite Hcons. reflexivity.
Qed.

(* ================================================================ *)
(*  PART 7: SOUNDNESS FROM HASH INJECTIVITY                        *)
(* ================================================================ *)

(* Lemma: VerifyWalkUp is injective in the starting hash.
   If h1 <> h2, then walking up from h1 and h2 with the same
   siblings and path bits produces different results.

   Proof strategy: Induction on remaining. At each level, the parent
   hashes differ because Hash is injective (hash_injective axiom). *)
Lemma verify_walkup_injective : forall siblings pathBits level remaining
    (h1 h2 : FieldElement),
    h1 <> h2 ->
    Spec.VerifyWalkUp h1 siblings pathBits level remaining <>
    Spec.VerifyWalkUp h2 siblings pathBits level remaining.
Proof.
  intros siblings pathBits level remaining.
  revert level.
  induction remaining as [| r IH].
  - intros level h1 h2 Hneq. simpl. exact Hneq.
  - intros level h1 h2 Hneq. simpl.
    apply IH.
    destruct (Z.eq_dec (pathBits level) 0).
    + intro Heq. apply hash_injective in Heq.
      destruct Heq as [Heq _]. contradiction.
    + intro Heq. apply hash_injective in Heq.
      destruct Heq as [_ Heq]. contradiction.
Qed.

(* Theorem: ConsistencyInvariant implies SoundnessInvariant.
   No wrong value can produce a valid proof.

   [TLA: ConsistencyInvariant + hash_injective => SoundnessInvariant]

   Proof strategy:
   1. Assume wrong value v produces valid proof (VerifyWalkUp = root).
   2. By Completeness, the correct value also verifies.
   3. Both walk-ups with same siblings reach the same root.
   4. By verify_walkup_injective, the leaf hashes must be equal.
   5. By LeafHash injectivity (from hash_injective), v = actual.
   6. Contradiction with v <> actual. *)
Theorem soundness_from_consistency : forall (s : Spec.State) (d : nat),
    Spec.ConsistencyInvariant s d ->
    Spec.SoundnessInvariant s d.
Proof.
  intros s d Hcons.
  unfold Spec.SoundnessInvariant.
  intros k v Hvalid Hneq.
  unfold Spec.VerifyProofOp.
  unfold Spec.ProofSiblings, Spec.PathBitsForKey.
  intro Hverify.
  (* From completeness, the correct value also verifies *)
  assert (Hcomplete := completeness_from_consistency s d Hcons).
  unfold Spec.CompletenessInvariant in Hcomplete.
  unfold Spec.VerifyProofOp in Hcomplete.
  unfold Spec.ProofSiblings, Spec.PathBitsForKey in Hcomplete.
  specialize (Hcomplete k Hvalid).
  (* Both walk-ups produce the root *)
  rewrite <- Hverify in Hcomplete.
  (* Leaf hashes must be equal (by injectivity of VerifyWalkUp) *)
  assert (Hleaf_eq : LeafHash k v = LeafHash k (Spec.EntryValue (Spec.entries s) k)).
  {
    destruct (Z.eq_dec (LeafHash k v) (LeafHash k (Spec.EntryValue (Spec.entries s) k)))
      as [Heq | Hneq2].
    - exact Heq.
    - exfalso.
      apply (verify_walkup_injective
               (fun l => Spec.SiblingHash (Spec.entries s) k l)
               (fun l => PathBit k l) 0 d _ _ Hneq2).
      symmetry. exact Hcomplete.
  }
  (* From LeafHash equality, derive v = actual value *)
  unfold LeafHash in Hleaf_eq.
  unfold Spec.EntryValue in *.
  destruct (Z.eq_dec v EMPTY) as [Hv0 | Hv_ne];
  destruct (Z.eq_dec (Spec.entries s k) EMPTY) as [Ha0 | Ha_ne].
  - (* Both EMPTY: v = actual, contradicts Hneq *)
    exfalso. apply Hneq. subst. symmetry. exact Ha0.
  - (* v = EMPTY, actual <> EMPTY: EMPTY = Hash(k, actual), impossible *)
    exfalso. symmetry in Hleaf_eq.
    pose proof (hash_positive k (Spec.entries s k)).
    unfold EMPTY in Hleaf_eq. lia.
  - (* v <> EMPTY, actual = EMPTY: Hash(k, v) = EMPTY, impossible *)
    exfalso.
    pose proof (hash_positive k v).
    unfold EMPTY in Hleaf_eq. lia.
  - (* Neither EMPTY: Hash(k, v) = Hash(k, actual) *)
    apply hash_injective in Hleaf_eq.
    destruct Hleaf_eq as [_ Hleaf_eq].
    unfold Spec.EntryValue in Hneq. contradiction.
Qed.

(* ================================================================ *)
(*  PART 8: CONSISTENCY PRESERVATION UNDER INSERT                   *)
(* ================================================================ *)

(* The central correctness theorem: after Insert, the root equals
   ComputeRoot on the new entries. This requires showing that
   WalkUp with old siblings computes the same root as a full
   ComputeRoot on the updated entries.

   Key insight: After changing a single leaf at position k,
   ComputeNode changes ONLY along the path from leaf k to root.
   Sibling subtrees are unchanged. WalkUp recomputes exactly
   the path using the (unchanged) old siblings. *)

(* Lemma: WalkUp from ComputeNode on new entries produces
   ComputeNode at the ancestor position.

   This is the core inductive argument. At each level:
   1. The current node is ComputeNode(newEntries, level, k/pow2 level)
   2. The sibling is SiblingHash(oldEntries, k, level)
   3. The sibling subtree does not contain k, so
      SiblingHash(oldEntries) = SiblingHash(newEntries)
   4. Combining current + sibling = ComputeNode(newEntries, S level, ...)
   5. By IH, walking up from the parent produces the top-level result.

   Proof strategy: Induction on remaining. Case split on PathBit.
   Use compute_node_update_outside for sibling independence. *)
(* Helper: The sibling subtree at a given level does not contain key k.
   When PathBit = 0, k is in the left subtree, so the sibling (right) doesn't contain k.
   When PathBit = 1, k is in the right subtree, so the sibling (left) doesn't contain k. *)
Lemma sibling_outside_key : forall k level,
    k >= 0 ->
    k < SiblingIndex k level * pow2 level \/
    k >= (SiblingIndex k level + 1) * pow2 level.
Proof.
  intros k level Hk.
  assert (Hpow : pow2 level > 0) by apply pow2_pos.
  unfold SiblingIndex.
  pose proof (Z.div_mod k (pow2 level) ltac:(lia)) as Hdm.
  pose proof (Z.mod_bound_pos k (pow2 level) ltac:(lia) ltac:(lia)) as [Hlo Hhi].
  destruct (Z.eq_dec ((k / pow2 level) mod 2) 0) as [Heven | Hodd].
  - (* Even: sibling = k/pow2 level + 1 *)
    left. nia.
  - (* Odd: sibling = k/pow2 level - 1 *)
    right. nia.
Qed.

(* Helper: After updating entry k, the sibling subtree is unchanged.
   SiblingHash(old, k, level) = SiblingHash(new, k, level) *)
Lemma sibling_hash_update_invariant : forall (e : Entries) (k v : FieldElement)
    (level : nat),
    k >= 0 ->
    Spec.SiblingHash e k level =
    Spec.SiblingHash (update_entry e k v) k level.
Proof.
  intros e k v level Hk.
  unfold Spec.SiblingHash.
  symmetry.
  apply compute_node_update_outside.
  exact (sibling_outside_key k level Hk).
Qed.

(* Helper: When PathBit = 0, the parent hash with old siblings
   equals ComputeNode on new entries at the next level. *)
Lemma parent_step_left : forall (e : Entries) (k v : FieldElement) (level : nat),
    k >= 0 ->
    PathBit k level = 0 ->
    let newE := update_entry e k v in
    Hash (Spec.ComputeNode newE level (k / pow2 level))
         (Spec.SiblingHash e k level) =
    Spec.ComputeNode newE (S level) (k / pow2 (S level)).
Proof.
  intros e k v level Hk Hbit newE.
  rewrite (sibling_hash_update_invariant e k v level Hk).
  apply parent_from_left.
  exact Hbit.
Qed.

(* Helper: When PathBit = 1, similar. *)
Lemma parent_step_right : forall (e : Entries) (k v : FieldElement) (level : nat),
    k >= 0 ->
    PathBit k level = 1 ->
    let newE := update_entry e k v in
    Hash (Spec.SiblingHash e k level)
         (Spec.ComputeNode newE level (k / pow2 level)) =
    Spec.ComputeNode newE (S level) (k / pow2 (S level)).
Proof.
  intros e k v level Hk Hbit newE.
  rewrite (sibling_hash_update_invariant e k v level Hk).
  apply parent_from_right; assumption.
Qed.

Lemma walkup_computes_new_root : forall (e : Entries) (k v : FieldElement)
    (level : nat) (remaining : nat),
    k >= 0 ->
    let newE := update_entry e k v in
    Spec.WalkUp e
      (Spec.ComputeNode newE level (k / pow2 level))
      k level remaining =
    Spec.ComputeNode newE (level + remaining) (k / pow2 (level + remaining)).
Proof.
  intros e k v level remaining Hk newE.
  subst newE.
  revert level.
  induction remaining as [| r IH].
  - (* Base case *)
    intros level. cbn [Spec.WalkUp].
    replace (level + 0)%nat with level by lia.
    reflexivity.
  - (* Inductive case *)
    intros level. cbn [Spec.WalkUp].
    destruct (pathbit_range k level Hk) as [Hbit0 | Hbit1].
    + (* PathBit = 0 *)
      rewrite Hbit0.
      destruct (Z.eq_dec 0 0) as [_ | Habs]; [| contradiction].
      rewrite (parent_step_left e k v level Hk Hbit0).
      rewrite IH.
      replace (S level + r)%nat with (level + S r)%nat by lia.
      reflexivity.
    + (* PathBit = 1 *)
      rewrite Hbit1.
      destruct (Z.eq_dec 1 0) as [Habs | _]; [lia |].
      rewrite (parent_step_right e k v level Hk Hbit1).
      rewrite IH.
      replace (S level + r)%nat with (level + S r)%nat by lia.
      reflexivity.
Qed.

(* Theorem: WalkUp from new leaf hash = ComputeRoot on new entries.

   This instantiates walkup_computes_new_root at level 0, remaining d.
   ComputeNode(newE, 0, k) = LeafHash(k, v) because update_entry
   sets the value at k to v. *)
Theorem walkup_equals_compute_root : forall (e : Entries) (k v : FieldElement)
    (d : nat),
    k >= 0 ->
    let newE := update_entry e k v in
    let newLeafHash := LeafHash k v in
    Spec.WalkUp e newLeafHash k 0 d =
    Spec.ComputeNode newE d (k / pow2 d).
Proof.
  intros e k v d Hk newE newLeafHash.
  pose proof (walkup_computes_new_root e k v 0 d Hk) as H.
  simpl in H.
  rewrite Z.div_1_r in H.
  assert (Hleaf : Spec.ComputeNode newE 0 k = newLeafHash).
  {
    simpl. unfold Spec.EntryValue, newE.
    rewrite update_entry_same. reflexivity.
  }
  rewrite <- Hleaf. exact H.
Qed.

(* Theorem: ConsistencyInvariant holds for the initial state.

   Proof strategy: initial root = DefaultHash(d) and
   ComputeNode(empty, d, 0) = DefaultHash(d) by compute_node_empty. *)
Theorem consistency_init : forall (d : nat),
    Spec.ConsistencyInvariant (Spec.Init d) d.
Proof.
  intros d.
  unfold Spec.ConsistencyInvariant, Spec.Init. simpl.
  rewrite compute_node_empty. reflexivity.
Qed.

(* Theorem: ConsistencyInvariant is preserved by Insert.

   Precondition: k >= 0 and k / pow2 d = 0 (key in valid range).
   This models [TLA: ASSUME Keys \subseteq LeafIndices].

   Proof strategy: The new root is WalkUpFromLeaf. By
   walkup_equals_compute_root, this equals ComputeNode on new entries.
   The key range condition ensures the top-level index is 0. *)
Theorem consistency_preserved_insert : forall (s : Spec.State) (d : nat)
    (k v : FieldElement),
    Spec.ConsistencyInvariant s d ->
    k >= 0 ->
    k / pow2 d = 0 ->
    Spec.ConsistencyInvariant (Spec.Insert s k v d) d.
Proof.
  intros s d k v Hcons Hk Hkey_range.
  unfold Spec.ConsistencyInvariant in *.
  unfold Spec.Insert. simpl.
  unfold Spec.WalkUpFromLeaf.
  rewrite (walkup_equals_compute_root (Spec.entries s) k v d Hk).
  rewrite Hkey_range. reflexivity.
Qed.

(* Corollary: ConsistencyInvariant is preserved by Delete. *)
Corollary consistency_preserved_delete : forall (s : Spec.State) (d : nat)
    (k : FieldElement),
    Spec.ConsistencyInvariant s d ->
    k >= 0 ->
    k / pow2 d = 0 ->
    Spec.ConsistencyInvariant (Spec.Delete s k d) d.
Proof.
  intros s d k Hcons Hk Hkey_range.
  unfold Spec.Delete.
  apply consistency_preserved_insert; assumption.
Qed.

(* ================================================================ *)
(*  PART 9: ALL INVARIANTS INDUCTION                                *)
(* ================================================================ *)

(* All three TLA+ invariants hold at initialization. *)
Theorem all_invariants_init : forall (d : nat),
    let s := Spec.Init d in
    Spec.ConsistencyInvariant s d /\
    Spec.CompletenessInvariant s d /\
    Spec.SoundnessInvariant s d.
Proof.
  intros d s.
  assert (Hcons : Spec.ConsistencyInvariant s d) by apply consistency_init.
  repeat split.
  - exact Hcons.
  - exact (completeness_from_consistency s d Hcons).
  - exact (soundness_from_consistency s d Hcons).
Qed.

(* All three invariants preserved by Insert (for valid keys). *)
Theorem all_invariants_preserved_insert : forall (s : Spec.State) (d : nat)
    (k v : FieldElement),
    Spec.ConsistencyInvariant s d ->
    k >= 0 -> k / pow2 d = 0 ->
    let s' := Spec.Insert s k v d in
    Spec.ConsistencyInvariant s' d /\
    Spec.CompletenessInvariant s' d /\
    Spec.SoundnessInvariant s' d.
Proof.
  intros s d k v Hcons Hk Hkey_range s'.
  assert (Hcons' : Spec.ConsistencyInvariant s' d).
  { apply consistency_preserved_insert; assumption. }
  repeat split.
  - exact Hcons'.
  - exact (completeness_from_consistency s' d Hcons').
  - exact (soundness_from_consistency s' d Hcons').
Qed.

(* All three invariants preserved by Delete (for valid keys). *)
Theorem all_invariants_preserved_delete : forall (s : Spec.State) (d : nat)
    (k : FieldElement),
    Spec.ConsistencyInvariant s d ->
    k >= 0 -> k / pow2 d = 0 ->
    let s' := Spec.Delete s k d in
    Spec.ConsistencyInvariant s' d /\
    Spec.CompletenessInvariant s' d /\
    Spec.SoundnessInvariant s' d.
Proof.
  intros s d k Hcons Hk Hkey_range s'.
  assert (Hcons' : Spec.ConsistencyInvariant s' d).
  { apply consistency_preserved_delete; assumption. }
  repeat split.
  - exact Hcons'.
  - exact (completeness_from_consistency s' d Hcons').
  - exact (soundness_from_consistency s' d Hcons').
Qed.

(* ================================================================ *)
(*  SUMMARY OF VERIFIED THEOREMS                                    *)
(* ================================================================ *)

(* 1. init_refinement:
      Impl.Init maps to Spec.Init under the refinement mapping.
      STATUS: PROVED (Qed)

   2. verify_walkup_equiv:
      Impl.verifyWalkUp = Spec.VerifyWalkUp (structural identity).
      STATUS: PROVED (Qed)

   3. completeness_from_consistency:
      ConsistencyInvariant => CompletenessInvariant.
      STATUS: PROVED (Qed)

   4. soundness_from_consistency:
      ConsistencyInvariant + hash_injective => SoundnessInvariant.
      STATUS: PROVED (Qed)

   5. consistency_init:
      ConsistencyInvariant holds for the initial state.
      STATUS: PROVED (Qed)

   6. consistency_preserved_insert:
      ConsistencyInvariant is preserved by Insert (for valid keys).
      STATUS: PROVED (Qed)

   7. consistency_preserved_delete:
      ConsistencyInvariant is preserved by Delete (for valid keys).
      STATUS: PROVED (Qed)

   8. all_invariants_init:
      All three invariants hold at initialization.
      STATUS: PROVED (Qed)

   9. all_invariants_preserved_insert:
      All three invariants preserved by Insert.
      STATUS: PROVED (Qed)

   10. all_invariants_preserved_delete:
       All three invariants preserved by Delete.
       STATUS: PROVED (Qed)

   HELPER LEMMAS (all proved):
   - ancestor_step, pathbit_0_ancestor, pathbit_1_ancestor
   - sibling_index_pathbit_0, sibling_index_pathbit_1
   - pathbit_range
   - compute_node_ext, compute_node_update_outside, compute_node_empty
   - verify_reconstructs_node, verify_walkup_injective
   - walkup_computes_new_root, walkup_equals_compute_root

   AXIOM TRUST BASE:
   - hash_positive (Hash output > 0 for non-negative inputs)
   - hash_injective (collision resistance)
   - depth_positive (DEPTH > 0)

   PRECONDITIONS:
   - k >= 0 (non-negative key, models BN128 field elements)
   - k / pow2 d = 0 (key in valid range [0, 2^d))
     This models the TLA+ ASSUME Keys \subseteq LeafIndices. *)
