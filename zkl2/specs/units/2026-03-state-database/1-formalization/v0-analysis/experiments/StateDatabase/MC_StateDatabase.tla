---- MODULE MC_StateDatabase ----
(* =================================================================== *)
(* Model Checking Instance for StateDatabase                           *)
(* =================================================================== *)
(*                                                                     *)
(* Finite parameter set for exhaustive state-space exploration.        *)
(*                                                                     *)
(* Configuration:                                                      *)
(*   Addresses      = {0, 1, 2}  (1 EOA + 2 contracts)               *)
(*   Contracts      = {1, 2}     (two smart contracts)                *)
(*   Slots          = {0, 1}     (two storage slots per contract)     *)
(*   MaxBalance     = 3          (total supply = max individual bal)   *)
(*   StorageValues  = {1, 2}     (two non-zero storage values)        *)
(*   ACCOUNT_DEPTH  = 2          (4 leaf positions, 3 used)           *)
(*   STORAGE_DEPTH  = 2          (4 leaf positions, 2 used)           *)
(*                                                                     *)
(* Account trie: 4 leaf positions (0,1,2,3), 3 active addresses.      *)
(*   Address 0 (EOA):      path [0,0] -- left-left                    *)
(*   Address 1 (Contract): path [1,0] -- right-left                   *)
(*   Address 2 (Contract): path [0,1] -- left-right                   *)
(*   Position 3 (empty):   path [1,1] -- right-right                  *)
(*                                                                     *)
(* Storage trie (per contract): 4 leaf positions, 2 active slots.     *)
(*   Slot 0: path [0,0]                                               *)
(*   Slot 1: path [1,0]                                               *)
(*   Positions 2,3: permanently empty                                  *)
(*                                                                     *)
(* State space estimate:                                               *)
(*   - alive: {T} x {T,F} x {T,F} = 4 configurations                 *)
(*   - balances: constrained by conservation (total=3)                 *)
(*   - storage: 3^4 = 81 (2 contracts x 2 slots x 3 values each)     *)
(*   - Effective: ~1000-3000 distinct reachable states                 *)
(*                                                                     *)
(* Invariant checks per state:                                         *)
(*   TypeOK                -- type correctness                         *)
(*   ConsistencyInvariant  -- WalkUp agrees with ComputeRoot (2 lvls) *)
(*   AccountIsolation      -- all 4 account positions have valid proof *)
(*   StorageIsolation      -- all 4 storage positions per contract     *)
(*   BalanceConservation   -- sum of balances = 3                      *)
(* =================================================================== *)

EXTENDS StateDatabase

\* 1 EOA (address 0) + 2 contracts (addresses 1, 2)
MC_Addresses == {0, 1, 2}

\* Smart contract addresses
MC_Contracts == {1, 2}

\* Storage slot indices
MC_Slots == {0, 1}

\* Total supply and max individual balance
MC_MaxBalance == 3

\* Non-zero storage values
MC_StorageValues == {1, 2}

\* Tree depths (4 leaf positions each)
MC_ACCOUNT_DEPTH == 2

MC_STORAGE_DEPTH == 2

====
