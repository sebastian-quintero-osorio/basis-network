(* ================================================================ *)
(*  Spec.v -- Faithful Translation of StateTransitionCircuit.tla    *)
(* ================================================================ *)
(*                                                                  *)
(*  Every definition in this file corresponds to a definition in    *)
(*  the TLA+ specification. Source references are provided as:      *)
(*  [TLA: <operator name>, line <number>]                           *)
(*                                                                  *)
(*  We model a single enterprise since the multi-enterprise         *)
(*  property is enterprise isolation (each operates independently). *)
(*  The invariants are universally quantified over enterprises in   *)
(*  the TLA+ spec; here they apply to the single modeled entity.   *)
(*                                                                  *)
(*  Source: 0-input-spec/StateTransitionCircuit.tla                 *)
(*  TLC Result: 3,342,337 states, 4,096 distinct, PASS             *)
(* ================================================================ *)

From STC Require Import Common.
From Stdlib Require Import ZArith.ZArith.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Lia.

Open Scope Z_scope.
Import ListNotations.

Module Spec.

(* ======================================== *)
(*     STATE                                *)
(* ======================================== *)

(* [TLA: VARIABLES trees, roots -- lines 228-231]
   Per-enterprise state: key-value entries and Merkle root. *)
Record State := mkState {
  entries : Entries;
  root    : FieldElement;
}.

(* ======================================== *)
(*     DEFAULT HASHES                       *)
(* ======================================== *)

(* [TLA: DefaultHash(level), lines 132-136]
   Precomputed hashes for all-empty subtrees at each level. *)
Fixpoint DefaultHash (level : nat) : FieldElement :=
  match level with
  | O => EMPTY
  | S l => Hash (DefaultHash l) (DefaultHash l)
  end.

(* ======================================== *)
(*     ENTRY VALUE LOOKUP                   *)
(* ======================================== *)

(* [TLA: EntryValue(e, idx), line 150] *)
Definition EntryValue (e : Entries) (idx : Z) : FieldElement := e idx.

(* ======================================== *)
(*     TREE COMPUTATION (REFERENCE)         *)
(* ======================================== *)

(* [TLA: ComputeNode(e, level, index), lines 154-160]
   Full tree rebuild. Reference truth for invariant checking. *)
Fixpoint ComputeNode (e : Entries) (level : nat) (index : Z) : FieldElement :=
  match level with
  | O => LeafHash index (EntryValue e index)
  | S l => Hash (ComputeNode e l (2 * index))
                (ComputeNode e l (2 * index + 1))
  end.

(* [TLA: ComputeRoot(e), line 163] *)
Definition ComputeRoot (e : Entries) (d : nat) : FieldElement :=
  ComputeNode e d 0.

(* ======================================== *)
(*     SIBLING HASH                         *)
(* ======================================== *)

(* [TLA: SiblingHash(e, key, level), lines 188-189] *)
Definition SiblingHash (e : Entries) (key : Z) (level : nat) : FieldElement :=
  ComputeNode e level (SiblingIndex key level).

(* ======================================== *)
(*     WALKUP -- INCREMENTAL ROOT UPDATE    *)
(* ======================================== *)

(* [TLA: WalkUp(treeEntries, currentHash, key, level), lines 213-222]
   Incremental path recomputation using sibling hashes from
   the OLD tree. Recursion on remaining levels. *)
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

(* Convenience: WalkUp from level 0 to depth. *)
Definition WalkUpFromLeaf (oldEntries : Entries) (leafHash : FieldElement)
           (key : Z) (d : nat) : FieldElement :=
  WalkUp oldEntries leafHash key 0 d.

(* ======================================== *)
(*     INITIAL STATE                        *)
(* ======================================== *)

(* [TLA: Init, lines 253-255]
   All entries empty, root is default hash for all-empty tree. *)
Definition Init (d : nat) : State :=
  mkState empty_entries (DefaultHash d).

(* ======================================== *)
(*     TRANSACTION TYPES                    *)
(* ======================================== *)

(* [TLA: Tx == [key: Keys, oldValue: Values \cup {EMPTY},
               newValue: Values \cup {EMPTY}], line 357] *)
Record Transaction := mkTx {
  tx_key      : Z;
  tx_oldValue : FieldElement;
  tx_newValue : FieldElement;
}.

(* Result of applying a transaction or batch. *)
Record TxResult := mkTxResult {
  tx_valid   : bool;
  tx_entries : Entries;
  tx_root    : FieldElement;
}.

(* ======================================== *)
(*     TRANSACTION APPLICATION              *)
(* ======================================== *)

(* [TLA: ApplyTx(treeEntries, currentRoot, tx), lines 278-284]
   Check old value matches tree, then update entries and root.
   WalkUp uses OLD entries for sibling computation (correct because
   only the leaf at tx.key changes; all siblings are off-path). *)
Definition ApplyTx (e : Entries) (r : FieldElement)
           (tx : Transaction) (d : nat) : TxResult :=
  if Z.eq_dec (e (tx_key tx)) (tx_oldValue tx)
  then let newEntries := update_entry e (tx_key tx) (tx_newValue tx) in
       let newLeafHash := LeafHash (tx_key tx) (tx_newValue tx) in
       let newRoot := WalkUpFromLeaf e newLeafHash (tx_key tx) d in
       mkTxResult true newEntries newRoot
  else mkTxResult false e r.

(* [TLA: ApplyBatch(treeEntries, currentRoot, txs), lines 300-306]
   Sequential application of transactions. Each tx operates on
   the tree state produced by all previous transactions.
   Mirrors the circuit's chainedRoots mechanism. *)
Fixpoint ApplyBatch (e : Entries) (r : FieldElement)
         (txs : list Transaction) (d : nat) : TxResult :=
  match txs with
  | nil => mkTxResult true e r
  | tx :: rest =>
    let result := ApplyTx e r tx d in
    match tx_valid result with
    | true => ApplyBatch (tx_entries result) (tx_root result) rest d
    | false => mkTxResult false e r
    end
  end.

(* ======================================== *)
(*     SAFETY PROPERTIES (INVARIANTS)       *)
(* ======================================== *)

(* STATE ROOT CHAIN INVARIANT
   [TLA: StateRootChain, line 401]
   The Merkle root is a deterministic function of tree contents.
   Verifies that chained WalkUp produces the same result as
   full ComputeRoot after arbitrarily many batch applications. *)
Definition StateRootChain (s : State) (d : nat) : Prop :=
  root s = ComputeNode (entries s) d 0.

(* BATCH INTEGRITY INVARIANT
   [TLA: BatchIntegrity, lines 423-430]
   For any valid key and value, a single valid transaction from
   the current state produces a root matching ComputeRoot.
   Key validity (k >= 0, k / pow2 d = 0) models TLA+ \A k \in Keys. *)
Definition BatchIntegrity (s : State) (d : nat) : Prop :=
  forall k v,
    k >= 0 -> k / pow2 d = 0 ->
    let tx := mkTx k (entries s k) v in
    let result := ApplyTx (entries s) (root s) tx d in
    tx_valid result = true ->
    tx_root result = ComputeNode (tx_entries result) d 0.

(* PROOF SOUNDNESS INVARIANT
   [TLA: ProofSoundness, lines 450-456]
   A transaction claiming a wrong old value is always rejected. *)
Definition ProofSoundness (s : State) (d : nat) : Prop :=
  forall k wrongVal,
    wrongVal <> entries s k ->
    let tx := mkTx k wrongVal EMPTY in
    let result := ApplyTx (entries s) (root s) tx d in
    tx_valid result = false.

End Spec.
