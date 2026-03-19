(* ========================================== *)
(*     Spec.v -- TLA+ Specification in Coq     *)
(* ========================================== *)
(* Faithful translation of StateDatabase.tla.  *)
(* Two-level Sparse Merkle Tree for EVM state. *)
(*                                             *)
(* [Source: zkl2/specs/units/2026-03-state-    *)
(*   database/1-formalization/v0-analysis/     *)
(*   specs/StateDatabase/StateDatabase.tla]    *)
(* ========================================== *)

Require Import StateDB.Common.
From Stdlib Require Import ZArith.
From Stdlib Require Import Arith.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import List.
From Stdlib Require Import Lia.
Import ListNotations.

Open Scope Z_scope.

(* All definitions are parameterized by the hash function.
   Production: Poseidon2 over BN254 scalar field.
   Model checking: algebraic hash over F_65537. *)
Section WithHash.

Variable hash : Z -> Z -> Z.

(* ========================================== *)
(*     LEAF AND DEFAULT HASHES                 *)
(* ========================================== *)

(* [Spec: LeafHash(key, value), line 123] *)
Definition leaf_hash (key : Z) (value : Z) : Z :=
  if Z.eqb value EMPTY then EMPTY else hash key value.

(* [Spec: DefaultHash(level), lines 133-137] *)
Fixpoint default_hash (level : nat) : Z :=
  match level with
  | O => EMPTY
  | S l => let prev := default_hash l in hash prev prev
  end.

(* ========================================== *)
(*     POWER OF 2 AND PATH OPERATIONS          *)
(* ========================================== *)

(* [Spec: Pow2(n), line 72] *)
Fixpoint pow2 (n : nat) : nat :=
  match n with
  | O => 1
  | S m => 2 * pow2 m
  end.

Lemma pow2_pos : forall n, (pow2 n > 0)%nat.
Proof. induction n; simpl; lia. Qed.

(* [Spec: PathBit(key, level), line 178] *)
Definition path_bit (key : nat) (level : nat) : nat :=
  Nat.modulo (Nat.div key (pow2 level)) 2.

(* Ancestor index: key's ancestor at a given tree level. *)
Definition ancestor_idx (key : nat) (level : nat) : nat :=
  Nat.div key (pow2 level).

(* [Spec: SiblingIndex(key, level), lines 181-185] *)
Definition sibling_index (key : nat) (level : nat) : nat :=
  let a := ancestor_idx key level in
  if Nat.eqb (Nat.modulo a 2) 0 then S a else Nat.pred a.

(* ========================================== *)
(*     TREE COMPUTATION                        *)
(* ========================================== *)

(* Entries: mapping from leaf index to value.
   [Spec: EntryValue(e, idx), line 152] *)
Definition Entries := nat -> Z.

(* [Spec: ComputeNode(e, level, index), lines 158-163] *)
Fixpoint compute_node (e : Entries) (level : nat) (index : nat) : Z :=
  match level with
  | O => leaf_hash (Z.of_nat index) (e index)
  | S l =>
    let lc := compute_node e l (Nat.mul 2 index) in
    let rc := compute_node e l (S (Nat.mul 2 index)) in
    hash lc rc
  end.

(* [Spec: ComputeRoot(e, depth), line 166] *)
Definition compute_root (e : Entries) (depth : nat) : Z :=
  compute_node e depth 0.

(* [Spec: SiblingHash(e, key, level), lines 188-189] *)
Definition sibling_hash (e : Entries) (key : nat) (level : nat) : Z :=
  compute_node e level (sibling_index key level).

(* ========================================== *)
(*     INCREMENTAL PATH RECOMPUTATION          *)
(* ========================================== *)

(* [Spec: WalkUp(old, current, key, level, depth), lines 204-213]
   Restructured with decreasing remaining = depth - level
   for Coq's structural recursion checker. *)
Fixpoint walk_up (old : Entries) (current : Z) (key : nat)
         (remaining : nat) (level : nat) : Z :=
  match remaining with
  | O => current
  | S r =>
    let bit := path_bit key level in
    let sib := sibling_hash old key level in
    let parent := if Nat.eqb bit 0
                  then hash current sib
                  else hash sib current in
    walk_up old parent key r (S level)
  end.

(* WalkUp from level 0 to depth.
   [Spec: WalkUp(old, leaf, key, 0, depth)] *)
Definition walk_up_full (old : Entries) (leaf_h : Z)
           (key : nat) (depth : nat) : Z :=
  walk_up old leaf_h key depth 0.

(* ========================================== *)
(*     PROOF VERIFICATION                      *)
(* ========================================== *)

(* [Spec: VerifyWalkUp, lines 234-241] *)
Fixpoint verify_walk_up (current : Z) (siblings : nat -> Z)
         (pbits : nat -> nat) (remaining : nat) (level : nat) : Z :=
  match remaining with
  | O => current
  | S r =>
    let parent := if Nat.eqb (pbits level) 0
                  then hash current (siblings level)
                  else hash (siblings level) current in
    verify_walk_up parent siblings pbits r (S level)
  end.

(* [Spec: VerifyProof, lines 244-245] *)
Definition verify_proof (expected_root leaf_h : Z)
           (siblings : nat -> Z) (pbits : nat -> nat)
           (depth : nat) : Prop :=
  verify_walk_up leaf_h siblings pbits depth 0 = expected_root.

(* ========================================== *)
(*     STATE TYPE                              *)
(* ========================================== *)

(* [Spec: VARIABLES, lines 275-281] *)
Record State := mkState {
  balances      : nat -> Z;        (* [Addresses -> 0..MaxBalance] *)
  storage_data  : nat -> nat -> Z; (* [Contracts -> [Slots -> Value]] *)
  st_alive      : nat -> bool;     (* [Addresses -> BOOLEAN] *)
  account_root  : Z;              (* Root hash of account trie *)
  storage_roots : nat -> Z        (* [Contracts -> root hash] *)
}.

(* ========================================== *)
(*     ACCOUNT VALUE COMPUTATION               *)
(* ========================================== *)

(* [Spec: AccountValue(addr), lines 295-300] *)
Definition account_value (s : State) (is_contract : nat -> bool)
           (sdepth : nat) (addr : nat) : Z :=
  if negb (st_alive s addr) then EMPTY
  else let sr := if is_contract addr
                 then storage_roots s addr
                 else default_hash sdepth in
       hash (balances s addr) sr.

(* [Spec: AccountEntries, line 304] *)
Definition account_entries (s : State) (is_contract : nat -> bool)
           (sdepth : nat) : Entries :=
  fun addr => account_value s is_contract sdepth addr.

(* [Spec: ComputeAccountRoot, line 307] *)
Definition compute_account_root (s : State) (is_contract : nat -> bool)
           (sdepth adepth : nat) : Z :=
  compute_root (account_entries s is_contract sdepth) adepth.

(* [Spec: ComputeStorageRoot(contract), lines 311-312] *)
Definition compute_storage_root (s : State) (contract : nat)
           (sdepth : nat) : Z :=
  compute_root (storage_data s contract) sdepth.

(* ========================================== *)
(*     ACTIONS                                 *)
(* ========================================== *)

(* [Spec: CreateAccount(addr), lines 369-381] *)
Definition create_account (s : State) (is_contract : nat -> bool)
           (sdepth adepth : nat) (addr : nat) : State :=
  let sr := if is_contract addr
            then storage_roots s addr
            else default_hash sdepth in
  let new_val := hash 0 sr in
  let new_leaf := leaf_hash (Z.of_nat addr) new_val in
  let ae := account_entries s is_contract sdepth in
  let new_root := walk_up_full ae new_leaf addr adepth in
  mkState
    (fupdate (balances s) addr 0)
    (storage_data s)
    (bupdate (st_alive s) addr true)
    new_root
    (storage_roots s).

(* [Spec: Transfer(from, to, amount), lines 391-418] *)
Definition transfer (s : State) (is_contract : nat -> bool)
           (sdepth adepth : nat) (from to : nat) (amount : Z) : State :=
  let ae := account_entries s is_contract sdepth in
  let from_sr := if is_contract from
                 then storage_roots s from
                 else default_hash sdepth in
  let new_from_val := hash (balances s from - amount) from_sr in
  let new_from_leaf := leaf_hash (Z.of_nat from) new_from_val in
  let inter_entries := fupdate ae from new_from_val in
  let to_sr := if is_contract to
               then storage_roots s to
               else default_hash sdepth in
  let new_to_val := hash (balances s to + amount) to_sr in
  let new_to_leaf := leaf_hash (Z.of_nat to) new_to_val in
  let final_root := walk_up_full inter_entries new_to_leaf to adepth in
  mkState
    (fupdate (fupdate (balances s) from (balances s from - amount))
             to (balances s to + amount))
    (storage_data s)
    (st_alive s)
    final_root
    (storage_roots s).

(* [Spec: SetStorage(contract, slot, value), lines 430-449] *)
Definition set_storage (s : State) (is_contract : nat -> bool)
           (sdepth adepth : nat) (contract slot : nat)
           (value : Z) : State :=
  let old_se := storage_data s contract in
  let new_sleaf := leaf_hash (Z.of_nat slot) value in
  let new_sr := walk_up_full old_se new_sleaf slot sdepth in
  let new_acc_val := hash (balances s contract) new_sr in
  let new_acc_leaf := leaf_hash (Z.of_nat contract) new_acc_val in
  let ae := account_entries s is_contract sdepth in
  let new_ar := walk_up_full ae new_acc_leaf contract adepth in
  mkState
    (balances s)
    (fun c => if Nat.eqb c contract
              then fupdate (storage_data s contract) slot value
              else storage_data s c)
    (st_alive s)
    new_ar
    (fupdate (storage_roots s) contract new_sr).

(* [Spec: SelfDestruct(contract, beneficiary), lines 459-488] *)
Definition self_destruct (s : State) (is_contract : nat -> bool)
           (sdepth adepth : nat) (contract beneficiary : nat) : State :=
  let ae := account_entries s is_contract sdepth in
  let dead_leaf := leaf_hash (Z.of_nat contract) EMPTY in
  let inter_entries := fupdate ae contract EMPTY in
  let ben_sr := if is_contract beneficiary
                then storage_roots s beneficiary
                else default_hash sdepth in
  let new_ben_val := hash (balances s beneficiary + balances s contract) ben_sr in
  let new_ben_leaf := leaf_hash (Z.of_nat beneficiary) new_ben_val in
  let final_root := walk_up_full inter_entries new_ben_leaf beneficiary adepth in
  mkState
    (fupdate (fupdate (balances s) contract 0) beneficiary
             (balances s beneficiary + balances s contract))
    (fun c => if Nat.eqb c contract
              then fun _ => EMPTY
              else storage_data s c)
    (bupdate (st_alive s) contract false)
    final_root
    (fupdate (storage_roots s) contract (default_hash sdepth)).

(* ========================================== *)
(*     NEXT-STATE RELATION                     *)
(* ========================================== *)

(* [Spec: Next, lines 494-501] *)
Inductive step (is_contract : nat -> bool) (sdepth adepth : nat) :
  State -> State -> Prop :=
  | StepCreate : forall s addr,
      st_alive s addr = false ->
      step is_contract sdepth adepth s
           (create_account s is_contract sdepth adepth addr)
  | StepTransfer : forall s from to amount,
      st_alive s from = true ->
      st_alive s to = true ->
      from <> to ->
      (amount > 0)%Z ->
      (balances s from >= amount)%Z ->
      step is_contract sdepth adepth s
           (transfer s is_contract sdepth adepth from to amount)
  | StepSetStorage : forall s contract slot value,
      is_contract contract = true ->
      st_alive s contract = true ->
      value <> storage_data s contract slot ->
      step is_contract sdepth adepth s
           (set_storage s is_contract sdepth adepth contract slot value)
  | StepSelfDestruct : forall s contract beneficiary,
      is_contract contract = true ->
      st_alive s contract = true ->
      st_alive s beneficiary = true ->
      contract <> beneficiary ->
      step is_contract sdepth adepth s
           (self_destruct s is_contract sdepth adepth contract beneficiary).

(* ========================================== *)
(*     INVARIANTS                              *)
(* ========================================== *)

(* [Spec: ConsistencyInvariant, lines 526-528] *)
Definition consistency_invariant (s : State) (is_contract : nat -> bool)
           (sdepth adepth : nat) (contracts : list nat) : Prop :=
  account_root s = compute_account_root s is_contract sdepth adepth
  /\ Forall (fun c => storage_roots s c =
             compute_storage_root s c sdepth) contracts.

(* [Spec: AccountIsolation, lines 544-551] *)
Definition account_isolation (s : State) (is_contract : nat -> bool)
           (sdepth adepth : nat) : Prop :=
  let ae := account_entries s is_contract sdepth in
  forall addr : nat,
    let lh := leaf_hash (Z.of_nat addr) (ae addr) in
    let siblings := fun l => sibling_hash ae addr l in
    let pbits := fun l => path_bit addr l in
    verify_proof (account_root s) lh siblings pbits adepth.

(* [Spec: StorageIsolation, lines 565-573] *)
Definition storage_isolation (s : State) (sdepth : nat)
           (contracts : list nat) : Prop :=
  Forall (fun c =>
    st_alive s c = true ->
    forall slot : nat,
      let se := storage_data s c in
      let lh := leaf_hash (Z.of_nat slot) (se slot) in
      let siblings := fun l => sibling_hash se slot l in
      let pbits := fun l => path_bit slot l in
      verify_proof (storage_roots s c) lh siblings pbits sdepth
  ) contracts.

(* [Spec: BalanceConservation, line 588] *)
Definition balance_conservation (s : State) (addrs : list nat)
           (max_balance : Z) : Prop :=
  sum_list (balances s) addrs = max_balance.

End WithHash.
