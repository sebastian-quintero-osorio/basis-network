(* ================================================================ *)
(*  Impl.v -- Abstract Model of StateCommitment.sol                  *)
(* ================================================================ *)
(*                                                                  *)
(*  Models the Solidity StateCommitment contract as Coq records     *)
(*  and functions. Each definition references the source code.      *)
(*                                                                  *)
(*  Modeling approach for Solidity:                                  *)
(*    - Storage mappings -> total functions nat -> X                 *)
(*    - require/revert -> preconditions in step relation             *)
(*    - msg.sender -> enterprise parameter (abstracted)              *)
(*    - Groth16 verification -> boolean abstraction (valid/invalid)  *)
(*    - Events -> omitted (do not affect state)                     *)
(*    - block.timestamp -> nat parameter (deterministic)             *)
(*                                                                  *)
(*  Source: 0-input-impl/StateCommitment.sol                        *)
(* ================================================================ *)

From SC Require Import Common.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.

Open Scope nat_scope.

Module Impl.

(* ======================================== *)
(*     STATE                               *)
(* ======================================== *)

(* [Solidity: lines 36-43, 47-71]
   Models all storage variables. Fields not present in TLA+ are
   marked; they are dropped by map_state in Refinement.v.

   Per-enterprise state (mapping(address => EnterpriseState)):
     currentRoot, batchCount, lastTimestamp, initialized
   Global state:
     batchRoots (mapping(address => mapping(uint256 => bytes32)))
     totalBatchesCommitted (uint256)
     verifyingKeySet (bool) *)
Record State := mkState {
  currentRoot           : Enterprise -> Root;            (* line 39 *)
  batchCount            : Enterprise -> nat;             (* line 40 *)
  lastTimestamp         : Enterprise -> nat;             (* line 41, NOT IN TLA+ *)
  initialized           : Enterprise -> bool;            (* line 42 *)
  batchRoots            : Enterprise -> nat -> Root;     (* line 67 *)
  totalBatchesCommitted : nat;                           (* line 71 *)
  verifyingKeySet       : bool                           (* line 59, NOT IN TLA+ *)
}.

(* ======================================== *)
(*     INITIAL STATE                       *)
(* ======================================== *)

(* [Solidity: constructor, lines 123-126]
   After deployment, all storage is zero-initialized.
   verifyingKeySet defaults to false. *)
Definition Init : State := mkState
  (fun _ => NONE)         (* bytes32(0) default *)
  (fun _ => 0)            (* uint64(0) default *)
  (fun _ => 0)            (* timestamp not set *)
  (fun _ => false)        (* bool false default *)
  (fun _ _ => NONE)       (* bytes32(0) default *)
  0                       (* uint256(0) default *)
  false.                  (* bool false default *)

(* ======================================== *)
(*     ADMIN FUNCTIONS                     *)
(* ======================================== *)

(* [Solidity: setVerifyingKey, lines 139-155]
   Admin configures the Groth16 verifying key.
   Only the flag is modeled; key contents do not affect state logic.
   This has no TLA+ counterpart -- maps to a stutter step. *)
Definition SetVerifyingKey (s : State) : State :=
  mkState
    (currentRoot s) (batchCount s) (lastTimestamp s)
    (initialized s) (batchRoots s) (totalBatchesCommitted s)
    true.

(* [Solidity: initializeEnterprise, lines 168-182]
   require(!enterprises[enterprise].initialized)
   Effect: EnterpriseState{ currentRoot: genesisRoot, batchCount: 0,
                            lastTimestamp: timestamp, initialized: true }

   NOTE: The Solidity struct literal writes batchCount = 0 explicitly.
   This is semantically UNCHANGED because InitBeforeBatch guarantees
   batchCount = 0 for uninitialized enterprises. We model the semantic
   effect (UNCHANGED) to enable clean refinement without funcext. *)
Definition initializeEnterprise (s : State) (e : Enterprise)
  (genesisRoot : Root) (timestamp : nat) : State :=
  mkState
    (fupdate (currentRoot s) e genesisRoot)
    (batchCount s)                                    (* UNCHANGED, see note *)
    (fupdate (lastTimestamp s) e timestamp)
    (fupdate (initialized s) e true)
    (batchRoots s)
    (totalBatchesCommitted s)
    (verifyingKeySet s).

(* ======================================== *)
(*     CORE FUNCTION                       *)
(* ======================================== *)

(* [Solidity: submitBatch, lines 208-257]
   Preconditions enforced by require():
     1. verifyingKeySet                        (line 217)
     2. enterpriseRegistry.isAuthorized(caller) (line 220, abstracted)
     3. es.initialized                         (line 225)
     4. es.currentRoot == prevStateRoot         (line 228, INV-S1)
     5. _verifyProof(a, b, c, publicSignals)   (line 233, INV-S2)

   Effect:
     es.currentRoot = newStateRoot              (line 240)
     es.batchCount = batchId + 1                (line 241)
     es.lastTimestamp = block.timestamp          (line 242)
     batchRoots[caller][batchId] = newStateRoot  (line 245)
     totalBatchesCommitted++                     (line 248) *)
Definition submitBatch (s : State) (e : Enterprise)
  (newRoot : Root) (timestamp : nat) : State :=
  let bid := batchCount s e in
  mkState
    (fupdate (currentRoot s) e newRoot)
    (fupdate (batchCount s) e (bid + 1))
    (fupdate (lastTimestamp s) e timestamp)
    (initialized s)                                   (* UNCHANGED *)
    (fupdate2 (batchRoots s) e bid newRoot)
    (totalBatchesCommitted s + 1)
    (verifyingKeySet s).

(* ======================================== *)
(*     STEP RELATION                       *)
(* ======================================== *)

(* Models all valid Solidity function calls as state transitions.
   Each constructor captures the require() checks as preconditions.

   SetVerifyingKey has no TLA+ counterpart -- maps to stutter step.
   Authorization (isAuthorized) is abstracted -- the step relation
   assumes the caller is authorized.
   Proof validity is modeled structurally: only step_submit_batch
   exists for valid proofs. Invalid proofs revert (no step). *)
Inductive step : State -> State -> Prop :=
  | step_set_vk : forall s,
      step s (SetVerifyingKey s)

  | step_init_enterprise : forall s e genesisRoot timestamp,
      initialized s e = false ->                       (* require(!initialized) *)
      genesisRoot > 0 ->                               (* non-zero genesis root *)
      step s (initializeEnterprise s e genesisRoot timestamp)

  | step_submit_batch : forall s e prevRoot newRoot timestamp,
      verifyingKeySet s = true ->                      (* require(verifyingKeySet) *)
      initialized s e = true ->                        (* require(es.initialized) *)
      prevRoot = currentRoot s e ->                    (* require(currentRoot == prevRoot) *)
      newRoot > 0 ->                                   (* non-zero new root *)
      (* _verifyProof == true -- modeled by constructor existence *)
      step s (submitBatch s e newRoot timestamp).

End Impl.
