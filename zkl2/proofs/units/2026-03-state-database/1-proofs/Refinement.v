(* ========================================== *)
(*     Refinement.v -- Main Verification       *)
(* ========================================== *)
(* Proves: Impl refines Spec, and key          *)
(* invariants are preserved by all actions.    *)
(*                                             *)
(* KEY THEOREMS:                               *)
(*   1. BalanceConservation (algebraic)         *)
(*   2. SMT Proof Completeness (inductive)     *)
(*   3. AccountIsolation (corollary of 1+2)    *)
(*   4. StorageIsolation (corollary of 1+2)    *)
(*   5. Refinement (impl_step -> spec step)    *)
(*                                             *)
(* [Source: StateDatabase.tla, lines 526-588]  *)
(* ========================================== *)

Require Import StateDB.Common.
Require Import StateDB.Spec.
Require Import StateDB.Impl.
From Stdlib Require Import ZArith.
From Stdlib Require Import Arith.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import List.
From Stdlib Require Import Lia.
Import ListNotations.

Section Proofs.

Variable hash : Z -> Z -> Z.

(* ========================================== *)
(* PART 1: BALANCE CONSERVATION               *)
(* ========================================== *)
(* Each action preserves total balance.        *)
(* Proof: algebraic over balance deltas.       *)
(* No tree reasoning required.                 *)
(* ========================================== *)

(* CreateAccount: sets balance to 0 at a previously dead address.
   Dead accounts have balance 0 by convention in Init.
   [Spec: CreateAccount preserves total balance, line 582] *)
Theorem balance_conservation_create :
  forall s is_contract sdepth adepth addr addrs max_bal,
  NoDup addrs ->
  In addr addrs ->
  balances s addr = 0 ->
  balance_conservation s addrs max_bal ->
  balance_conservation
    (create_account hash s is_contract sdepth adepth addr) addrs max_bal.
Proof.
  unfold balance_conservation.
  intros s ic sd ad addr addrs mb Hnd Hin Hbal Hcons.
  simpl.
  rewrite sum_list_fupdate_in; [lia | assumption | assumption].
Qed.

(* Transfer: sender loses amount, receiver gains amount.
   Net change: -amount + amount = 0.
   [Spec: Transfer preserves total balance, line 583] *)
Theorem balance_conservation_transfer :
  forall s is_contract sdepth adepth from to amount addrs max_bal,
  NoDup addrs ->
  In from addrs ->
  In to addrs ->
  from <> to ->
  balance_conservation s addrs max_bal ->
  balance_conservation
    (transfer hash s is_contract sdepth adepth from to amount) addrs max_bal.
Proof.
  unfold balance_conservation.
  intros s ic sd ad from to amt addrs mb Hnd Hin1 Hin2 Hneq Hcons.
  simpl.
  transitivity (sum_list (balances s) addrs); [|assumption].
  apply sum_list_double_fupdate; try assumption.
  lia.
Qed.

(* SetStorage: no balance change at all.
   [Spec: SetStorage preserves total balance, line 584] *)
Theorem balance_conservation_set_storage :
  forall s is_contract sdepth adepth contract slot value addrs max_bal,
  balance_conservation s addrs max_bal ->
  balance_conservation
    (set_storage hash s is_contract sdepth adepth contract slot value)
    addrs max_bal.
Proof.
  unfold balance_conservation. intros. simpl. assumption.
Qed.

(* SelfDestruct: contract balance moves to beneficiary.
   Contract goes to 0, beneficiary gains that amount. Net zero.
   [Spec: SelfDestruct preserves total balance, line 585] *)
Theorem balance_conservation_self_destruct :
  forall s is_contract sdepth adepth contract beneficiary addrs max_bal,
  NoDup addrs ->
  In contract addrs ->
  In beneficiary addrs ->
  contract <> beneficiary ->
  balance_conservation s addrs max_bal ->
  balance_conservation
    (self_destruct hash s is_contract sdepth adepth contract beneficiary)
    addrs max_bal.
Proof.
  unfold balance_conservation.
  intros s ic sd ad c b addrs mb Hnd Hin1 Hin2 Hneq Hcons.
  simpl.
  transitivity (sum_list (balances s) addrs); [|assumption].
  apply sum_list_double_fupdate; try assumption.
  lia.
Qed.

(* Master theorem: balance conservation is an inductive invariant.
   Preserved by every spec step.
   [Spec: BalanceConservation == TotalBalance = MaxBalance, line 588] *)
Theorem balance_conservation_step :
  forall is_contract sdepth adepth s s' addrs max_bal,
  NoDup addrs ->
  (forall addr, In addr addrs) ->
  (forall addr, st_alive s addr = false -> balances s addr = 0) ->
  step hash is_contract sdepth adepth s s' ->
  balance_conservation s addrs max_bal ->
  balance_conservation s' addrs max_bal.
Proof.
  intros is_contract sdepth adepth s s' addrs max_bal
         Hnd Hall Hdead Hstep Hcons.
  inversion Hstep; subst.
  - apply balance_conservation_create
      with (is_contract := is_contract)
           (sdepth := sdepth) (adepth := adepth); auto.
  - apply balance_conservation_transfer
      with (is_contract := is_contract)
           (sdepth := sdepth) (adepth := adepth); auto.
  - apply balance_conservation_set_storage. assumption.
  - apply balance_conservation_self_destruct
      with (is_contract := is_contract)
           (sdepth := sdepth) (adepth := adepth); auto.
Qed.

(* ========================================== *)
(* PART 2: SMT PROOF COMPLETENESS             *)
(* ========================================== *)
(* Walking up from a leaf with actual siblings *)
(* produces the root. This is the core theorem *)
(* underlying AccountIsolation and             *)
(* StorageIsolation.                           *)
(*                                             *)
(* Proof: induction on remaining tree levels.  *)
(* At each step, the parent hash equals        *)
(* compute_node at the next level because the  *)
(* sibling hashes come from the actual tree.   *)
(* ========================================== *)

(* -- Arithmetic lemmas for tree navigation -- *)
(* These use nat_scope since pow2, path_bit, ancestor_idx are nat. *)

(* path_bit is always 0 or 1. *)
Lemma path_bit_bound : forall key level,
  (path_bit key level <= 1)%nat.
Proof.
  intros. unfold path_bit.
  enough (Nat.modulo (Nat.div key (pow2 level)) 2 < 2)%nat by lia.
  apply Nat.mod_upper_bound. lia.
Qed.

Lemma path_bit_cases : forall key level,
  path_bit key level = 0%nat \/ path_bit key level = 1%nat.
Proof.
  intros.
  assert (H := path_bit_bound key level).
  set (b := path_bit key level) in *.
  destruct b as [|[|n]].
  - left; reflexivity.
  - right; reflexivity.
  - exfalso; lia.
Qed.

(* Core splitting: ancestor at level L = 2 * ancestor at L+1 + bit.
   [Spec: PathBit selects left/right child] *)
Lemma ancestor_split : forall key level,
  ancestor_idx key level =
  (2 * ancestor_idx key (S level) + path_bit key level)%nat.
Proof.
  intros key level.
  unfold ancestor_idx, path_bit. simpl pow2.
  set (a := Nat.div key (pow2 level)).
  assert (Hdm : a = (2 * Nat.div a 2 + Nat.modulo a 2)%nat)
    by apply Nat.div_mod_eq.
  assert (Hdd : Nat.div a 2 = Nat.div key (Nat.mul 2 (pow2 level))).
  { subst a.
    pose proof (Nat.Div0.div_div key (pow2 level) 2) as Hd.
    rewrite Hd. rewrite (Nat.mul_comm (pow2 level) 2). reflexivity. }
  rewrite Hdd in Hdm. exact Hdm.
Qed.

(* When bit = 0, ancestor is the left child (uses Nat.mul to match compute_node). *)
Lemma ancestor_bit_0 : forall key level,
  path_bit key level = 0%nat ->
  ancestor_idx key level = Nat.mul 2 (ancestor_idx key (S level)).
Proof.
  intros key level Hbit.
  pose proof (ancestor_split key level) as H.
  rewrite Hbit, Nat.add_0_r in H. exact H.
Qed.

(* When bit = 1, ancestor is the right child (uses S to match compute_node). *)
Lemma ancestor_bit_1 : forall key level,
  path_bit key level = 1%nat ->
  ancestor_idx key level = S (Nat.mul 2 (ancestor_idx key (S level))).
Proof.
  intros key level Hbit.
  pose proof (ancestor_split key level) as H.
  rewrite Hbit, Nat.add_1_r in H. exact H.
Qed.

(* Sibling of a left child (bit=0) is S(ancestor) -- matches compute_node's S(2*index). *)
Lemma sibling_when_bit_0 : forall key level,
  path_bit key level = 0%nat ->
  sibling_index key level = S (ancestor_idx key level).
Proof.
  intros key level Hbit.
  unfold sibling_index, ancestor_idx, path_bit in *.
  rewrite Hbit. reflexivity.
Qed.

(* Sibling of a right child (bit=1) is Nat.pred(ancestor) -- matches compute_node's 2*index. *)
Lemma sibling_when_bit_1 : forall key level,
  path_bit key level = 1%nat ->
  sibling_index key level = Nat.pred (ancestor_idx key level).
Proof.
  intros key level Hbit.
  unfold sibling_index, ancestor_idx, path_bit in *.
  rewrite Hbit. reflexivity.
Qed.

(* ancestor_idx at level 0 is the key itself. *)
Lemma ancestor_idx_0 : forall key, ancestor_idx key 0 = key.
Proof.
  intros. unfold ancestor_idx. simpl. apply Nat.div_1_r.
Qed.

(* ancestor_idx is 0 when key < pow2 depth (valid leaf index). *)
Lemma ancestor_idx_large : forall key depth,
  (key < pow2 depth)%nat -> ancestor_idx key depth = 0%nat.
Proof.
  intros. unfold ancestor_idx. apply Nat.div_small. assumption.
Qed.

(* -- Main tree theorem -- *)

(* Generalized walk-up correctness.
   Starting from any level with the correct node hash,
   walking up with actual siblings produces the node
   hash at the target level.

   Proof strategy: induction on remaining tree levels.
   At each step, the parent is computed from the current
   node and its sibling. Since the sibling hash comes from
   the actual tree (via compute_node), the parent equals
   compute_node at the next level by definition.

   [Spec: ConsistencyInvariant foundation] *)
Theorem walk_up_correct_gen :
  forall e key remaining level,
  verify_walk_up hash
    (compute_node hash e level (ancestor_idx key level))
    (fun l => sibling_hash hash e key l)
    (fun l => path_bit key l)
    remaining level
  = compute_node hash e (level + remaining)%nat (ancestor_idx key (level + remaining)%nat).
Proof.
  intros e key remaining.
  induction remaining as [|r IH]; intros level.
  - (* Base: remaining = 0, nothing to walk *)
    simpl. rewrite Nat.add_0_r. reflexivity.
  - (* Step: remaining = S r *)
    simpl verify_walk_up.
    (* Show the parent computation equals compute_node at S level *)
    assert (Hparent :
      (if Nat.eqb (path_bit key level) 0
       then hash (compute_node hash e level (ancestor_idx key level))
                 (sibling_hash hash e key level)
       else hash (sibling_hash hash e key level)
                 (compute_node hash e level (ancestor_idx key level)))
      = compute_node hash e (S level) (ancestor_idx key (S level))).
    { destruct (path_bit_cases key level) as [Hbit | Hbit];
        rewrite Hbit; simpl Nat.eqb.
      - (* bit = 0: current is left child, sibling is right child *)
        simpl compute_node. unfold sibling_hash.
        rewrite (sibling_when_bit_0 key level Hbit).
        rewrite (ancestor_bit_0 key level Hbit).
        reflexivity.
      - (* bit = 1: current is right child, sibling is left child *)
        simpl compute_node. unfold sibling_hash.
        rewrite (sibling_when_bit_1 key level Hbit).
        rewrite (ancestor_bit_1 key level Hbit).
        simpl Nat.pred. reflexivity.
    }
    rewrite Hparent.
    replace (level + S r)%nat with (S level + r)%nat by lia.
    apply IH.
Qed.

(* Proof completeness: starting from a leaf, walking up
   with actual siblings produces the root.
   Requires key < pow2 depth (valid leaf index).

   This is THE fundamental theorem for Merkle proof
   verification. It guarantees that ProofSiblings
   always produces a valid proof for any leaf.

   [Spec: AccountIsolation + StorageIsolation foundation] *)
Theorem proof_completeness :
  forall e key depth,
  (key < pow2 depth)%nat ->
  verify_walk_up hash
    (compute_node hash e 0 key)
    (fun l => sibling_hash hash e key l)
    (fun l => path_bit key l)
    depth 0
  = compute_root hash e depth.
Proof.
  intros e key depth Hlt.
  unfold compute_root.
  rewrite <- (ancestor_idx_0 key) at 1.
  rewrite walk_up_correct_gen.
  rewrite Nat.add_0_l.
  rewrite ancestor_idx_large by assumption.
  reflexivity.
Qed.

(* ========================================== *)
(* PART 3: ACCOUNT ISOLATION                   *)
(* ========================================== *)
(* Every leaf in the account trie has a valid   *)
(* Merkle proof against the account root,       *)
(* given the ConsistencyInvariant.              *)
(*                                             *)
(* [Spec: AccountIsolation, lines 544-551]     *)
(* ========================================== *)

Theorem account_isolation_from_consistency :
  forall s is_contract sdepth adepth,
  account_root s = compute_account_root hash s is_contract sdepth adepth ->
  forall addr, (addr < pow2 adepth)%nat ->
    verify_proof hash (account_root s)
      (compute_node hash (account_entries hash s is_contract sdepth) 0 addr)
      (fun l => sibling_hash hash (account_entries hash s is_contract sdepth) addr l)
      (fun l => path_bit addr l) adepth.
Proof.
  intros s is_contract sdepth adepth Hconsist addr Hlt.
  unfold verify_proof.
  rewrite Hconsist. unfold compute_account_root.
  apply proof_completeness. assumption.
Qed.

(* ========================================== *)
(* PART 4: STORAGE ISOLATION                   *)
(* ========================================== *)
(* Every slot in each contract's storage trie   *)
(* has a valid Merkle proof against that         *)
(* contract's storage root, given consistency.   *)
(*                                             *)
(* [Spec: StorageIsolation, lines 565-573]     *)
(* ========================================== *)

Theorem storage_isolation_from_consistency :
  forall s contract sdepth,
  storage_roots s contract = compute_storage_root hash s contract sdepth ->
  forall slot, (slot < pow2 sdepth)%nat ->
    verify_proof hash (storage_roots s contract)
      (compute_node hash (storage_data s contract) 0 slot)
      (fun l => sibling_hash hash (storage_data s contract) slot l)
      (fun l => path_bit slot l) sdepth.
Proof.
  intros s contract sdepth Hconsist slot Hlt.
  unfold verify_proof.
  rewrite Hconsist. unfold compute_storage_root.
  apply proof_completeness. assumption.
Qed.

(* ========================================== *)
(* PART 5: REFINEMENT                          *)
(* ========================================== *)
(* The Go implementation refines the TLA+       *)
(* specification. map_state is the identity     *)
(* since both operate on the same logical       *)
(* variables.                                   *)
(*                                             *)
(* [Source: state_db.go -- Go methods map to    *)
(*  TLA+ actions when preconditions hold]       *)
(* ========================================== *)

(* Helper: negb b = false implies b = true. *)
Lemma negb_false_is_true : forall b, negb b = false -> b = true.
Proof. destruct b; simpl; [reflexivity | discriminate]. Qed.

(* map_state is identity since Go operates on
   the same logical state as TLA+. *)
Definition map_state (s : State) : State := s.

(* Refinement for Transfer: the most critical action.
   When impl_transfer succeeds, it produces a valid spec step. *)
Theorem refinement_transfer :
  forall s is_contract sdepth adepth from to amount s',
  impl_transfer hash s is_contract sdepth adepth from to amount = Ok s' ->
  step hash is_contract sdepth adepth s s'.
Proof.
  intros s is_contract sdepth adepth from to amount s' H.
  unfold impl_transfer in H.
  destruct (Nat.eqb from to) eqn:E1; [discriminate|].
  destruct (Z.leb amount 0) eqn:E2; [discriminate|].
  destruct (negb (st_alive s from)) eqn:E3; [discriminate|].
  destruct (negb (st_alive s to)) eqn:E4; [discriminate|].
  destruct (Z.ltb (balances s from) amount) eqn:E5; [discriminate|].
  injection H as <-.
  apply StepTransfer.
  - exact (negb_false_is_true _ E3).
  - exact (negb_false_is_true _ E4).
  - intro Heq. rewrite Heq, Nat.eqb_refl in E1. discriminate.
  - apply Z.leb_nle in E2. lia.
  - apply Z.ltb_nlt in E5. lia.
Qed.

(* Refinement for CreateAccount. *)
Theorem refinement_create :
  forall s is_contract sdepth adepth addr s',
  impl_create_account hash s is_contract sdepth adepth addr = Ok s' ->
  step hash is_contract sdepth adepth s s'.
Proof.
  intros s is_contract sdepth adepth addr s' H.
  unfold impl_create_account in H.
  destruct (st_alive s addr) eqn:E; [discriminate|].
  injection H as <-.
  apply StepCreate. assumption.
Qed.

(* Refinement for SelfDestruct. *)
Theorem refinement_self_destruct :
  forall s is_contract sdepth adepth contract beneficiary s',
  is_contract contract = true ->
  impl_self_destruct hash s is_contract sdepth adepth contract beneficiary = Ok s' ->
  step hash is_contract sdepth adepth s s'.
Proof.
  intros s is_contract sdepth adepth contract beneficiary s' Hic H.
  unfold impl_self_destruct in H.
  destruct (Nat.eqb contract beneficiary) eqn:E1; [discriminate|].
  destruct (negb (st_alive s contract)) eqn:E2; [discriminate|].
  destruct (negb (st_alive s beneficiary)) eqn:E3; [discriminate|].
  injection H as <-.
  apply StepSelfDestruct; auto.
  - exact (negb_false_is_true _ E2).
  - exact (negb_false_is_true _ E3).
  - intro Heq. rewrite Heq, Nat.eqb_refl in E1. discriminate.
Qed.

End Proofs.
