(* ================================================================ *)
(*  Refinement.v -- Proof that Circuit Refines Specification        *)
(* ================================================================ *)
(*                                                                  *)
(*  This file proves that state_transition.circom (modeled in       *)
(*  Impl.v) correctly implements StateTransitionCircuit.tla         *)
(*  (modeled in Spec.v).                                            *)
(*                                                                  *)
(*  Structure:                                                      *)
(*    Part 1: Arithmetic Helper Lemmas (from RU-V1)                 *)
(*    Part 2: ComputeNode Independence Lemmas (from RU-V1)          *)
(*    Part 3: MerklePathVerifier Equivalences                       *)
(*    Part 4: WalkUp Correctness for Updates (from RU-V1)           *)
(*    Part 5: Verifier Injectivity (from RU-V1)                     *)
(*    Part 6: StateRootChain Preservation (Init + Single + Batch)   *)
(*    Part 7: BatchIntegrity and ProofSoundness                     *)
(*    Part 8: Circuit Refinement (honest witness -> spec)           *)
(*    Part 9: Circuit Soundness (wrong value -> reject)             *)
(*                                                                  *)
(*  Axiom Trust Base (from Common.v):                               *)
(*    - hash_positive: Hash(a,b) > 0                                *)
(*    - hash_injective: Hash is collision-resistant                 *)
(*    - depth_positive: DEPTH > 0                                   *)
(*                                                                  *)
(*  Source Spec: 0-input-spec/StateTransitionCircuit.tla            *)
(*  Source Impl: 0-input-impl/state_transition.circom               *)
(* ================================================================ *)

From STC Require Import Common.
From STC Require Import Spec.
From STC Require Import Impl.
From Stdlib Require Import ZArith.ZArith.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Lia.

Open Scope Z_scope.
Import ListNotations.

(* ================================================================ *)
(*  PART 1: ARITHMETIC HELPER LEMMAS                                *)
(* ================================================================ *)

(* These lemmas relate ancestor indices across tree levels.
   Re-proved from RU-V1 because they are in a separate compilation unit. *)

Lemma ancestor_step : forall key level,
    key / pow2 (S level) = (key / pow2 level) / 2.
Proof.
  intros key level. unfold pow2.
  rewrite Nat2Z.inj_succ. rewrite Z.pow_succ_r by lia.
  rewrite Z.mul_comm. rewrite Z.div_div by lia. reflexivity.
Qed.

Lemma pathbit_0_ancestor : forall key level,
    PathBit key level = 0 ->
    key / pow2 level = 2 * (key / pow2 (S level)).
Proof.
  intros key level Hbit. unfold PathBit in Hbit. rewrite ancestor_step.
  assert (Hpow : pow2 level > 0) by apply pow2_pos.
  pose proof (Z.div_mod (key / pow2 level) 2) as Hdm. lia.
Qed.

Lemma pathbit_1_ancestor : forall key level,
    PathBit key level = 1 ->
    key / pow2 level = 2 * (key / pow2 (S level)) + 1.
Proof.
  intros key level Hbit. unfold PathBit in Hbit. rewrite ancestor_step.
  assert (Hpow : pow2 level > 0) by apply pow2_pos.
  pose proof (Z.div_mod (key / pow2 level) 2) as Hdm. lia.
Qed.

Lemma sibling_index_pathbit_0 : forall key level,
    PathBit key level = 0 ->
    SiblingIndex key level = key / pow2 level + 1.
Proof.
  intros key level Hbit. unfold SiblingIndex, PathBit in *.
  destruct (Z.eq_dec ((key / pow2 level) mod 2) 0); [reflexivity | lia].
Qed.

Lemma sibling_index_pathbit_1 : forall key level,
    PathBit key level = 1 ->
    SiblingIndex key level = key / pow2 level - 1.
Proof.
  intros key level Hbit. unfold SiblingIndex, PathBit in *.
  destruct (Z.eq_dec ((key / pow2 level) mod 2) 0); [lia | reflexivity].
Qed.

Lemma pathbit_range : forall key level,
    key >= 0 ->
    PathBit key level = 0 \/ PathBit key level = 1.
Proof.
  intros key level Hkey. unfold PathBit.
  assert (Hpow : pow2 level > 0) by apply pow2_pos.
  assert (Hdiv_nonneg : key / pow2 level >= 0) by (apply Z_div_ge0; lia).
  assert (Hmod := Z.mod_bound_pos (key / pow2 level) 2). lia.
Qed.

(* ================================================================ *)
(*  PART 2: COMPUTENODE INDEPENDENCE LEMMAS                         *)
(* ================================================================ *)

(* ComputeNode depends only on entries within its subtree. *)
Lemma compute_node_ext : forall (e1 e2 : Entries) (level : nat) (index : Z),
    (forall idx, index * pow2 level <= idx < (index + 1) * pow2 level ->
                 e1 idx = e2 idx) ->
    Spec.ComputeNode e1 level index = Spec.ComputeNode e2 level index.
Proof.
  intros e1 e2 level.
  induction level as [| l IH].
  - intros index Hagree. simpl. unfold Spec.EntryValue.
    rewrite pow2_0 in Hagree. rewrite (Hagree index) by lia. reflexivity.
  - intros index Hagree. cbn [Spec.ComputeNode].
    assert (Hpow : pow2 l > 0) by apply pow2_pos. f_equal.
    + apply IH. intros idx Hrange. apply Hagree. rewrite pow2_double. nia.
    + apply IH. intros idx Hrange. apply Hagree. rewrite pow2_double. nia.
Qed.

(* Updating entry k does not change subtrees not containing k. *)
Lemma compute_node_update_outside : forall (e : Entries) (k v : FieldElement)
    (level : nat) (index : Z),
    (k < index * pow2 level \/ k >= (index + 1) * pow2 level) ->
    Spec.ComputeNode (update_entry e k v) level index =
    Spec.ComputeNode e level index.
Proof.
  intros e k v level index Houtside. apply compute_node_ext.
  intros idx Hrange. unfold update_entry.
  destruct (Z.eq_dec k idx); [subst; lia | reflexivity].
Qed.

(* ComputeNode on empty entries returns DefaultHash. *)
Lemma compute_node_empty : forall (level : nat) (index : Z),
    Spec.ComputeNode empty_entries level index = Spec.DefaultHash level.
Proof.
  induction level as [| l IH].
  - intros. simpl. unfold Spec.EntryValue, empty_entries.
    rewrite leaf_hash_empty. reflexivity.
  - intros. simpl. rewrite IH, IH. reflexivity.
Qed.

(* ================================================================ *)
(*  PART 3: MERKLE PATH VERIFIER EQUIVALENCES                      *)
(* ================================================================ *)

(* Spec.WalkUp is a MerklePathVerifier with SiblingHash as siblings. *)
Lemma spec_walkup_as_verifier : forall (e : Entries) (key : Z)
    (ch : FieldElement) (level : nat) (remaining : nat),
    Spec.WalkUp e ch key level remaining =
    Impl.MerklePathVerifier ch
      (fun l => Spec.SiblingHash e key l) (fun l => PathBit key l)
      level remaining.
Proof.
  intros e key ch level remaining. revert ch level.
  induction remaining as [| r IH]; intros ch level; simpl.
  - reflexivity.
  - apply IH.
Qed.

(* MerklePathVerifier depends only on siblings in the active range. *)
Lemma merkle_path_verifier_ext : forall (s1 s2 : nat -> FieldElement)
    (pathBits : nat -> Z) (ch : FieldElement) (level remaining : nat),
    (forall l, (l >= level)%nat -> (l < level + remaining)%nat ->
     s1 l = s2 l) ->
    Impl.MerklePathVerifier ch s1 pathBits level remaining =
    Impl.MerklePathVerifier ch s2 pathBits level remaining.
Proof.
  intros s1 s2 pathBits ch level remaining. revert ch level.
  induction remaining as [| r IH]; intros ch level Hagree.
  - reflexivity.
  - simpl. rewrite (Hagree level) by lia.
    apply IH. intros l Hl1 Hl2. apply Hagree; lia.
Qed.

(* When PathBit = 0, hashing current with sibling gives parent. *)
Lemma parent_from_left : forall (e : Entries) (key : Z) (level : nat),
    PathBit key level = 0 ->
    Hash (Spec.ComputeNode e level (key / pow2 level))
         (Spec.SiblingHash e key level) =
    Spec.ComputeNode e (S level) (key / pow2 (S level)).
Proof.
  intros e key level Hbit. cbn [Spec.ComputeNode]. unfold Spec.SiblingHash.
  rewrite (sibling_index_pathbit_0 key level Hbit).
  rewrite (pathbit_0_ancestor key level Hbit).
  f_equal; f_equal; lia.
Qed.

(* When PathBit = 1, hashing sibling with current gives parent. *)
Lemma parent_from_right : forall (e : Entries) (key : Z) (level : nat),
    key >= 0 ->
    PathBit key level = 1 ->
    Hash (Spec.SiblingHash e key level)
         (Spec.ComputeNode e level (key / pow2 level)) =
    Spec.ComputeNode e (S level) (key / pow2 (S level)).
Proof.
  intros e key level Hk Hbit. cbn [Spec.ComputeNode]. unfold Spec.SiblingHash.
  rewrite (sibling_index_pathbit_1 key level Hbit).
  rewrite (pathbit_1_ancestor key level Hbit).
  f_equal; f_equal; lia.
Qed.

(* Core lemma: Walking up from a node with correct siblings
   reconstructs the ancestor node at the top. *)
Lemma verify_reconstructs_node : forall (e : Entries) (key : Z),
    key >= 0 ->
    forall (level : nat) (remaining : nat),
    Impl.MerklePathVerifier
      (Spec.ComputeNode e level (key / pow2 level))
      (fun l => Spec.SiblingHash e key l)
      (fun l => PathBit key l)
      level remaining =
    Spec.ComputeNode e (level + remaining) (key / pow2 (level + remaining)).
Proof.
  intros e key Hkey level remaining. revert level.
  induction remaining as [| r IH].
  - intros level. simpl. replace (level + 0)%nat with level by lia. reflexivity.
  - intros level. simpl.
    destruct (pathbit_range key level Hkey) as [Hbit0 | Hbit1].
    + rewrite Hbit0. destruct (Z.eq_dec 0 0) as [_ | Habs]; [| contradiction].
      rewrite (parent_from_left e key level Hbit0). rewrite IH.
      replace (S level + r)%nat with (level + S r)%nat by lia. reflexivity.
    + rewrite Hbit1. destruct (Z.eq_dec 1 0) as [Habs | _]; [lia |].
      rewrite (parent_from_right e key level Hkey Hbit1). rewrite IH.
      replace (S level + r)%nat with (level + S r)%nat by lia. reflexivity.
Qed.

(* Verifying with correct leaf hash and honest siblings produces the root. *)
Lemma honest_verify_produces_root : forall (e : Entries) (key : Z) (d : nat),
    key >= 0 -> key / pow2 d = 0 ->
    Impl.MerklePathVerifier
      (LeafHash key (e key))
      (fun l => Spec.SiblingHash e key l)
      (fun l => PathBit key l)
      0 d =
    Spec.ComputeNode e d 0.
Proof.
  intros e key d Hkey Hrange.
  pose proof (verify_reconstructs_node e key Hkey 0 d) as H.
  simpl in H. rewrite Z.div_1_r in H. unfold Spec.EntryValue in H.
  rewrite H. rewrite Hrange. reflexivity.
Qed.

(* ================================================================ *)
(*  PART 4: WALKUP CORRECTNESS FOR UPDATES                         *)
(* ================================================================ *)

(* The sibling subtree at a given level does not contain the key. *)
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
  - left. nia.
  - right. nia.
Qed.

(* After updating entry k, the sibling subtree is unchanged. *)
Lemma sibling_hash_update_invariant : forall (e : Entries) (k v : FieldElement)
    (level : nat),
    k >= 0 ->
    Spec.SiblingHash e k level =
    Spec.SiblingHash (update_entry e k v) k level.
Proof.
  intros e k v level Hk. unfold Spec.SiblingHash. symmetry.
  apply compute_node_update_outside.
  exact (sibling_outside_key k level Hk).
Qed.

(* Helper: PathBit = 0 parent step with updated entries. *)
Lemma parent_step_left : forall (e : Entries) (k v : FieldElement) (level : nat),
    k >= 0 ->
    PathBit k level = 0 ->
    Hash (Spec.ComputeNode (update_entry e k v) level (k / pow2 level))
         (Spec.SiblingHash e k level) =
    Spec.ComputeNode (update_entry e k v) (S level) (k / pow2 (S level)).
Proof.
  intros e k v level Hk Hbit.
  rewrite (sibling_hash_update_invariant e k v level Hk).
  apply parent_from_left. exact Hbit.
Qed.

(* Helper: PathBit = 1 parent step with updated entries. *)
Lemma parent_step_right : forall (e : Entries) (k v : FieldElement) (level : nat),
    k >= 0 ->
    PathBit k level = 1 ->
    Hash (Spec.SiblingHash e k level)
         (Spec.ComputeNode (update_entry e k v) level (k / pow2 level)) =
    Spec.ComputeNode (update_entry e k v) (S level) (k / pow2 (S level)).
Proof.
  intros e k v level Hk Hbit.
  rewrite (sibling_hash_update_invariant e k v level Hk).
  apply parent_from_right; assumption.
Qed.

(* MerklePathVerifier from updated entry's ComputeNode with old siblings
   produces ComputeNode of updated entries at the ancestor position. *)
Lemma walkup_computes_new_root : forall (e : Entries) (k v : FieldElement)
    (level : nat) (remaining : nat),
    k >= 0 ->
    Impl.MerklePathVerifier
      (Spec.ComputeNode (update_entry e k v) level (k / pow2 level))
      (fun l => Spec.SiblingHash e k l)
      (fun l => PathBit k l)
      level remaining =
    Spec.ComputeNode (update_entry e k v)
      (level + remaining) (k / pow2 (level + remaining)).
Proof.
  intros e k v level remaining Hk.
  revert level.
  induction remaining as [| r IH].
  - intros level. simpl. replace (level + 0)%nat with level by lia. reflexivity.
  - intros level. simpl.
    destruct (pathbit_range k level Hk) as [Hbit0 | Hbit1].
    + rewrite Hbit0. destruct (Z.eq_dec 0 0) as [_ | Habs]; [| contradiction].
      rewrite (parent_step_left e k v level Hk Hbit0). rewrite IH.
      replace (S level + r)%nat with (level + S r)%nat by lia. reflexivity.
    + rewrite Hbit1. destruct (Z.eq_dec 1 0) as [Habs | _]; [lia |].
      rewrite (parent_step_right e k v level Hk Hbit1). rewrite IH.
      replace (S level + r)%nat with (level + S r)%nat by lia. reflexivity.
Qed.

(* WalkUp from new leaf hash = ComputeRoot of new entries. *)
Theorem walkup_equals_compute_root : forall (e : Entries) (k v : FieldElement)
    (d : nat),
    k >= 0 -> k / pow2 d = 0 ->
    Impl.MerklePathVerifier (LeafHash k v)
      (fun l => Spec.SiblingHash e k l) (fun l => PathBit k l) 0 d =
    Spec.ComputeNode (update_entry e k v) d 0.
Proof.
  intros e k v d Hk Hrange.
  pose proof (walkup_computes_new_root e k v 0 d Hk) as H.
  simpl in H. rewrite Z.div_1_r in H.
  unfold Spec.EntryValue in H. rewrite update_entry_same in H.
  rewrite H. rewrite Hrange. reflexivity.
Qed.

(* Spec.WalkUpFromLeaf equals ComputeNode of new entries. *)
Theorem spec_walkup_equals_compute_root : forall (e : Entries)
    (k v : FieldElement) (d : nat),
    k >= 0 -> k / pow2 d = 0 ->
    Spec.WalkUpFromLeaf e (LeafHash k v) k d =
    Spec.ComputeNode (update_entry e k v) d 0.
Proof.
  intros e k v d Hk Hrange. unfold Spec.WalkUpFromLeaf.
  rewrite spec_walkup_as_verifier.
  apply walkup_equals_compute_root; assumption.
Qed.

(* ================================================================ *)
(*  PART 5: VERIFIER INJECTIVITY                                    *)
(* ================================================================ *)

(* MerklePathVerifier is injective in the starting hash.
   If h1 <> h2, then walking up from h1 and h2 with the same
   siblings and path bits produces different results. *)
Lemma verify_walkup_injective : forall siblings pathBits level remaining
    (h1 h2 : FieldElement),
    h1 <> h2 ->
    Impl.MerklePathVerifier h1 siblings pathBits level remaining <>
    Impl.MerklePathVerifier h2 siblings pathBits level remaining.
Proof.
  intros siblings pathBits level remaining. revert level.
  induction remaining as [| r IH].
  - intros level h1 h2 Hneq. simpl. exact Hneq.
  - intros level h1 h2 Hneq. simpl. apply IH.
    destruct (Z.eq_dec (pathBits level) 0).
    + intro Heq. apply hash_injective in Heq.
      destruct Heq as [Heq _]. contradiction.
    + intro Heq. apply hash_injective in Heq.
      destruct Heq as [_ Heq]. contradiction.
Qed.

(* ================================================================ *)
(*  PART 6: STATE ROOT CHAIN PRESERVATION                           *)
(* ================================================================ *)

(* StateRootChain holds for the initial state. *)
Theorem init_state_root_chain : forall (d : nat),
    Spec.StateRootChain (Spec.Init d) d.
Proof.
  intros d. unfold Spec.StateRootChain, Spec.Init. simpl.
  rewrite compute_node_empty. reflexivity.
Qed.

(* StateRootChain is preserved by a single valid ApplyTx. *)
Lemma single_tx_preserves_state_root_chain : forall (e : Entries)
    (r : FieldElement) (tx : Spec.Transaction) (d : nat),
    r = Spec.ComputeNode e d 0 ->
    Spec.tx_key tx >= 0 ->
    Spec.tx_key tx / pow2 d = 0 ->
    Spec.tx_valid (Spec.ApplyTx e r tx d) = true ->
    Spec.tx_root (Spec.ApplyTx e r tx d) =
    Spec.ComputeNode (Spec.tx_entries (Spec.ApplyTx e r tx d)) d 0.
Proof.
  intros e r tx d Hstate Hk Hrange Hvalid.
  unfold Spec.ApplyTx in *.
  destruct (Z.eq_dec (e (Spec.tx_key tx)) (Spec.tx_oldValue tx)) as [Heq | Hneq].
  - simpl. apply spec_walkup_equals_compute_root; assumption.
  - simpl in Hvalid. discriminate.
Qed.

(* MAIN THEOREM: StateRootChain is preserved by batch application.
   This is the novel result of RU-V2: extending single-operation
   WalkUp correctness to chained multi-operation batches.

   [TLA: StateRootChain invariant, line 401]

   Proof strategy: Induction on the transaction list. At each step,
   the single-tx preservation gives consistency of the intermediate
   state, which serves as the inductive hypothesis for the remainder. *)
Theorem batch_preserves_state_root_chain : forall (txs : list Spec.Transaction)
    (e : Entries) (r : FieldElement) (d : nat),
    r = Spec.ComputeNode e d 0 ->
    Forall (fun tx => Spec.tx_key tx >= 0 /\ Spec.tx_key tx / pow2 d = 0) txs ->
    Spec.tx_valid (Spec.ApplyBatch e r txs d) = true ->
    Spec.tx_root (Spec.ApplyBatch e r txs d) =
    Spec.ComputeNode (Spec.tx_entries (Spec.ApplyBatch e r txs d)) d 0.
Proof.
  induction txs as [| tx rest IH]; intros e r d Hstate Hkeys Hvalid.
  - (* Base case: empty batch *)
    simpl in *. exact Hstate.
  - (* Inductive case: tx :: rest *)
    inversion_clear Hkeys as [| ? ? Hkv Hrest].
    destruct Hkv as [Hk Hrange].
    cbn [Spec.ApplyBatch] in Hvalid |- *.
    destruct (Spec.tx_valid (Spec.ApplyTx e r tx d)) eqn:Hv.
    + (* Transaction valid: apply IH *)
      apply IH.
      * apply (single_tx_preserves_state_root_chain e r tx d Hstate Hk Hrange Hv).
      * exact Hrest.
      * exact Hvalid.
    + (* Transaction invalid: contradicts batch validity *)
      simpl in Hvalid. discriminate.
Qed.

(* ================================================================ *)
(*  PART 7: BATCH INTEGRITY AND PROOF SOUNDNESS                     *)
(* ================================================================ *)

(* BatchIntegrity follows from StateRootChain.
   [TLA: BatchIntegrity invariant, lines 423-430]

   When the current state satisfies StateRootChain, any single
   valid transaction on a valid key produces correct root. *)
Theorem batch_integrity_from_chain : forall (s : Spec.State) (d : nat),
    Spec.StateRootChain s d ->
    Spec.BatchIntegrity s d.
Proof.
  intros s d Hchain.
  unfold Spec.BatchIntegrity. intros k v Hk Hrange.
  unfold Spec.ApplyTx. simpl.
  destruct (Z.eq_dec (Spec.entries s k) (Spec.entries s k)) as [_ | Habs].
  - simpl. intros _.
    apply spec_walkup_equals_compute_root; assumption.
  - contradiction.
Qed.

(* ProofSoundness at the specification level.
   [TLA: ProofSoundness invariant, lines 450-456]

   This is definitionally true: ApplyTx checks e[key] = oldValue,
   and if wrongVal <> e[key], the check fails. *)
Theorem proof_soundness_spec : forall (s : Spec.State) (d : nat),
    Spec.ProofSoundness s d.
Proof.
  intros s d. unfold Spec.ProofSoundness.
  intros k wrongVal Hwrong. simpl.
  unfold Spec.ApplyTx. simpl.
  destruct (Z.eq_dec (Spec.entries s k) wrongVal) as [Heq | _].
  - exfalso. apply Hwrong. symmetry. exact Heq.
  - reflexivity.
Qed.

(* ================================================================ *)
(*  PART 8: CIRCUIT REFINEMENT                                      *)
(* ================================================================ *)

(* When the witness is honest (siblings match tree, old value correct,
   key valid), the circuit produces the same result as the spec.

   [Impl: state_transition.circom, per-tx loop, lines 56-108]
   [Spec: ApplyTx, lines 278-284]

   Proof strategy:
   1. Show old root check passes (MerklePathVerifier = root)
   2. Show new root = WalkUpFromLeaf (by honest siblings) *)
Theorem circuit_tx_correct : forall (e : Entries) (r : FieldElement)
    (w : Impl.TxWitness) (d : nat),
    r = Spec.ComputeNode e d 0 ->
    (forall l, (l < d)%nat ->
     Impl.w_siblings w l = Spec.SiblingHash e (Impl.w_key w) l) ->
    Impl.w_key w >= 0 ->
    Impl.w_key w / pow2 d = 0 ->
    e (Impl.w_key w) = Impl.w_oldValue w ->
    Impl.PerTxCircuit r w d =
    Some (Spec.WalkUpFromLeaf e
            (LeafHash (Impl.w_key w) (Impl.w_newValue w))
            (Impl.w_key w) d).
Proof.
  intros e r w d Hstate Hhonest Hk Hrange Hval.
  unfold Impl.PerTxCircuit.
  (* Step 1: Show old root = r *)
  assert (Holdr : Impl.MerklePathVerifier
    (LeafHash (Impl.w_key w) (Impl.w_oldValue w))
    (Impl.w_siblings w) (fun l => PathBit (Impl.w_key w) l) 0 d = r).
  {
    rewrite <- Hval.
    rewrite (merkle_path_verifier_ext
      (Impl.w_siblings w) (fun l => Spec.SiblingHash e (Impl.w_key w) l)
      (fun l => PathBit (Impl.w_key w) l)
      (LeafHash (Impl.w_key w) (e (Impl.w_key w))) 0 d).
    - rewrite honest_verify_produces_root by assumption.
      symmetry. exact Hstate.
    - intros l _ Hl. apply Hhonest. lia.
  }
  rewrite Holdr.
  destruct (Z.eq_dec r r) as [_ | Habs]; [| contradiction].
  (* Step 2: Show new root matches *)
  f_equal.
  rewrite (merkle_path_verifier_ext
    (Impl.w_siblings w) (fun l => Spec.SiblingHash e (Impl.w_key w) l)
    (fun l => PathBit (Impl.w_key w) l)
    (LeafHash (Impl.w_key w) (Impl.w_newValue w)) 0 d).
  - unfold Spec.WalkUpFromLeaf. symmetry.
    apply spec_walkup_as_verifier.
  - intros l _ Hl. apply Hhonest. lia.
Qed.

(* ================================================================ *)
(*  PART 9: CIRCUIT SOUNDNESS                                       *)
(* ================================================================ *)

(* When the witness has a wrong old value (even with honest siblings),
   the circuit rejects. This is the ZK proof soundness property.

   [Impl: state_transition.circom, lines 89-92]
   oldRootChecks[i].out === 1 enforces old path = chained root.
   Wrong oldValue -> wrong leaf hash -> wrong path root -> reject.

   [Spec: ProofSoundness, lines 450-456]

   Proof strategy:
   1. Show leaf hashes differ (wrongVal <> e[key] -> different hash)
   2. By MerklePathVerifier injectivity, computed root differs
   3. Therefore old root check fails, circuit returns None *)
Theorem circuit_tx_soundness : forall (e : Entries) (r : FieldElement)
    (w : Impl.TxWitness) (d : nat),
    r = Spec.ComputeNode e d 0 ->
    (forall l, (l < d)%nat ->
     Impl.w_siblings w l = Spec.SiblingHash e (Impl.w_key w) l) ->
    Impl.w_key w >= 0 ->
    Impl.w_key w / pow2 d = 0 ->
    Impl.w_oldValue w <> e (Impl.w_key w) ->
    Impl.PerTxCircuit r w d = None.
Proof.
  intros e r w d Hstate Hhonest Hk Hrange Hwrong.
  unfold Impl.PerTxCircuit.
  (* The old root check must fail *)
  destruct (Z.eq_dec
    (Impl.MerklePathVerifier
      (LeafHash (Impl.w_key w) (Impl.w_oldValue w))
      (Impl.w_siblings w) (fun l => PathBit (Impl.w_key w) l) 0 d)
    r) as [Heq | _].
  - (* Contradiction: old root cannot equal r with wrong old value *)
    exfalso.
    (* Leaf hashes are different *)
    assert (Hleaf_neq : LeafHash (Impl.w_key w) (Impl.w_oldValue w) <>
                         LeafHash (Impl.w_key w) (e (Impl.w_key w))).
    {
      intro Hleafeq. apply Hwrong. unfold LeafHash in Hleafeq.
      destruct (Z.eq_dec (Impl.w_oldValue w) EMPTY) as [Hw0 | Hw_ne];
      destruct (Z.eq_dec (e (Impl.w_key w)) EMPTY) as [He0 | He_ne].
      - congruence.
      - exfalso. pose proof (hash_positive (Impl.w_key w) (e (Impl.w_key w))).
        unfold EMPTY in Hleafeq. lia.
      - exfalso. pose proof (hash_positive (Impl.w_key w) (Impl.w_oldValue w)).
        unfold EMPTY in Hleafeq. lia.
      - apply hash_injective in Hleafeq. destruct Hleafeq as [_ Hval].
        exact Hval.
    }
    (* Both verify to the same root -- contradiction with injectivity *)
    assert (Hsame : Impl.MerklePathVerifier
      (LeafHash (Impl.w_key w) (Impl.w_oldValue w))
      (fun l => Spec.SiblingHash e (Impl.w_key w) l)
      (fun l => PathBit (Impl.w_key w) l) 0 d =
      Impl.MerklePathVerifier
        (LeafHash (Impl.w_key w) (e (Impl.w_key w)))
        (fun l => Spec.SiblingHash e (Impl.w_key w) l)
        (fun l => PathBit (Impl.w_key w) l) 0 d).
    {
      transitivity (Spec.ComputeNode e d 0).
      - rewrite <- Hstate. rewrite <- Heq.
        symmetry. apply merkle_path_verifier_ext.
        intros l _ Hl. apply Hhonest. lia.
      - symmetry. apply honest_verify_produces_root; assumption.
    }
    exact (verify_walkup_injective _ _ _ _ _ _ Hleaf_neq Hsame).
  - reflexivity.
Qed.

(* ================================================================ *)
(*  SUMMARY OF VERIFIED THEOREMS                                    *)
(* ================================================================ *)

(* Specification-Level Theorems:

   1. init_state_root_chain:
      StateRootChain holds for the initial state (all-empty tree).
      STATUS: PROVED (Qed)

   2. single_tx_preserves_state_root_chain:
      A single valid ApplyTx preserves StateRootChain.
      STATUS: PROVED (Qed)

   3. batch_preserves_state_root_chain:
      ApplyBatch preserves StateRootChain (for valid-key batches).
      This is the CORE NOVEL RESULT of RU-V2: chained multi-operation
      WalkUp correctness extending RU-V1's single-operation result.
      STATUS: PROVED (Qed)

   4. batch_integrity_from_chain:
      StateRootChain implies BatchIntegrity.
      STATUS: PROVED (Qed)

   5. proof_soundness_spec:
      ProofSoundness holds at the specification level (definitional).
      STATUS: PROVED (Qed)

   Circuit-Level Theorems:

   6. circuit_tx_correct:
      With honest siblings and correct old value, PerTxCircuit
      produces the same root as the spec's WalkUpFromLeaf.
      STATUS: PROVED (Qed)

   7. circuit_tx_soundness:
      With honest siblings but wrong old value, PerTxCircuit
      rejects (returns None). ZK proof cannot be generated.
      STATUS: PROVED (Qed)

   Key Helper Lemmas (all proved):
   - spec_walkup_as_verifier (WalkUp = MerklePathVerifier)
   - merkle_path_verifier_ext (siblings extensionality)
   - verify_reconstructs_node (walk-up reconstructs ancestor)
   - honest_verify_produces_root (honest verification = root)
   - walkup_computes_new_root (update walk-up = ComputeNode)
   - walkup_equals_compute_root (update = ComputeRoot)
   - spec_walkup_equals_compute_root (spec WalkUp = ComputeRoot)
   - verify_walkup_injective (verification is leaf-injective)
   - compute_node_ext, compute_node_update_outside, compute_node_empty
   - sibling_outside_key, sibling_hash_update_invariant

   AXIOM TRUST BASE:
   - hash_positive (Hash output > 0)
   - hash_injective (collision resistance)
   - depth_positive (DEPTH > 0)

   PRECONDITIONS:
   - k >= 0 (non-negative key, models BN128 field elements)
   - k / pow2 d = 0 (key in valid range [0, 2^d))
   - Honest siblings: w_siblings = SiblingHash(entries, key, _)
   - These model: TLA+ ASSUME Keys \subseteq LeafIndices and
     the prover constructing witness from the actual SMT state. *)
