(* ========================================== *)
(*     Impl.v -- Go Implementation Model       *)
(* ========================================== *)
(* Abstract model of the Go StateDB            *)
(* implementation in zkl2/node/statedb/.        *)
(*                                             *)
(* Models Go state transitions as pure          *)
(* functions with error returns.                *)
(*                                             *)
(* [Source: zkl2/node/statedb/state_db.go]      *)
(* [Source: zkl2/node/statedb/smt.go]           *)
(* [Source: zkl2/node/statedb/account.go]       *)
(* [Source: zkl2/node/statedb/types.go]         *)
(* ========================================== *)

Require Import StateDB.Common.
Require Import StateDB.Spec.
From Stdlib Require Import ZArith.
From Stdlib Require Import Arith.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import List.
From Stdlib Require Import Lia.

Open Scope Z_scope.

Section WithHash.

Variable hash : Z -> Z -> Z.

(* ========================================== *)
(*     ERROR TYPE                              *)
(* ========================================== *)

(* Models Go error constants from types.go.
   [Source: types.go, lines 116-123] *)
Inductive ImplError : Type :=
  | ErrAccountNotAlive
  | ErrAccountAlreadyAlive
  | ErrInsufficientBalance
  | ErrSelfTransfer
  | ErrZeroAmount
  | ErrSelfDestructToSelf.

(* ========================================== *)
(*     IMPLEMENTATION STATE                    *)
(* ========================================== *)

(* The Go StateDB struct fields, abstracted.
   [Source: state_db.go, lines 25-31]

   The implementation state IS the spec state.
   The Go code operates on the same logical variables
   as the TLA+ specification:

   Go StateDB field         -> Coq State field
   accountTrie.Root()       -> account_root
   storageTries[addr].Root()-> storage_roots(addr)
   accounts[addr].Balance   -> balances(addr)
   accounts[addr].Alive     -> st_alive(addr)
   storageTries[c].Get(s)   -> storage_data(c)(s)

   This simplifies refinement: map_state = identity. *)
Definition ImplState := State.

(* ========================================== *)
(*     IMPLEMENTATION ACTIONS                  *)
(* ========================================== *)

(* Each Go method returns (new_state, error).
   Success: Ok(new_state). Failure: Err(error_code). *)

(* [Source: state_db.go, CreateAccount, lines 85-100]
   Go: func (db *StateDB) CreateAccount(addr TreeKey) error *)
Definition impl_create_account (s : ImplState) (is_contract : nat -> bool)
           (sdepth adepth : nat) (addr : nat)
  : Result ImplState ImplError :=
  if st_alive s addr
  then Err ErrAccountAlreadyAlive
  else Ok (create_account hash s is_contract sdepth adepth addr).

(* [Source: state_db.go, Transfer, lines 112-145]
   Go: func (db *StateDB) Transfer(from, to TreeKey, amount *big.Int) error *)
Definition impl_transfer (s : ImplState) (is_contract : nat -> bool)
           (sdepth adepth : nat) (from to : nat) (amount : Z)
  : Result ImplState ImplError :=
  if Nat.eqb from to then Err ErrSelfTransfer
  else if Z.leb amount 0 then Err ErrZeroAmount
  else if negb (st_alive s from) then Err ErrAccountNotAlive
  else if negb (st_alive s to) then Err ErrAccountNotAlive
  else if Z.ltb (balances s from) amount then Err ErrInsufficientBalance
  else Ok (transfer hash s is_contract sdepth adepth from to amount).

(* [Source: state_db.go, SetStorage, lines 156-177]
   Go: func (db *StateDB) SetStorage(contract, slot TreeKey, value fr.Element) error *)
Definition impl_set_storage (s : ImplState) (is_contract : nat -> bool)
           (sdepth adepth : nat) (contract slot : nat) (value : Z)
  : Result ImplState ImplError :=
  if negb (st_alive s contract) then Err ErrAccountNotAlive
  else Ok (set_storage hash s is_contract sdepth adepth contract slot value).

(* [Source: state_db.go, SelfDestruct, lines 192-235]
   Go: func (db *StateDB) SelfDestruct(contract, beneficiary TreeKey) error *)
Definition impl_self_destruct (s : ImplState) (is_contract : nat -> bool)
           (sdepth adepth : nat) (contract beneficiary : nat)
  : Result ImplState ImplError :=
  if Nat.eqb contract beneficiary then Err ErrSelfDestructToSelf
  else if negb (st_alive s contract) then Err ErrAccountNotAlive
  else if negb (st_alive s beneficiary) then Err ErrAccountNotAlive
  else Ok (self_destruct hash s is_contract sdepth adepth contract beneficiary).

(* ========================================== *)
(*     IMPLEMENTATION STEP RELATION            *)
(* ========================================== *)

(* The implementation steps are exactly the spec steps
   with additional error checking. When the error checks
   pass, the state transition is identical. *)
Inductive impl_step (is_contract : nat -> bool) (sdepth adepth : nat) :
  ImplState -> ImplState -> Prop :=
  | ImplStepCreate : forall s addr s',
      impl_create_account s is_contract sdepth adepth addr = Ok s' ->
      impl_step is_contract sdepth adepth s s'
  | ImplStepTransfer : forall s from to amount s',
      impl_transfer s is_contract sdepth adepth from to amount = Ok s' ->
      impl_step is_contract sdepth adepth s s'
  | ImplStepSetStorage : forall s contract slot value s',
      impl_set_storage s is_contract sdepth adepth contract slot value = Ok s' ->
      impl_step is_contract sdepth adepth s s'
  | ImplStepSelfDestruct : forall s contract beneficiary s',
      impl_self_destruct s is_contract sdepth adepth contract beneficiary = Ok s' ->
      impl_step is_contract sdepth adepth s s'.

End WithHash.
