(* ========================================== *)
(*     Spec.v -- TLA+ Specification Model      *)
(*     Faithful Translation of BasisRollup.tla  *)
(*     zkl2/proofs/units/2026-03-basis-rollup  *)
(* ========================================== *)

(* This file translates the TLA+ specification of the BasisRollup
   contract into Coq definitions. The model captures the per-enterprise
   commit-prove-execute-revert lifecycle as a state machine.

   Simplification: The model focuses on a SINGLE enterprise's lifecycle.
   This is sound because:
   - TLA+ uses EXCEPT ![e] to isolate per-enterprise state updates
   - Solidity uses mapping(address => EnterpriseState) for isolation
   - No action modifies another enterprise's state
   - All safety invariants are per-enterprise (universally quantified)

   Global counters (globalCommitted/Proven/Executed) are excluded
   because they are derived quantities (sums of per-enterprise counters)
   with an independent, trivial proof of correctness.

   Source: BasisRollup.tla (frozen in 0-input-spec/) *)

From BasisRollup Require Import Common.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.

(* ========================================== *)
(*     STATE DEFINITION                        *)
(* ========================================== *)

(* Per-enterprise state. Each field corresponds to a TLA+ variable
   restricted to a single enterprise.

   [Source: BasisRollup.tla, lines 58-68 -- VARIABLES]
   currentRoot             -> st_root (option Root, None = uninitialized)
   initialized[e]          -> st_init (bool)
   totalBatchesCommitted[e]-> st_committed (nat)
   totalBatchesProven[e]   -> st_proven (nat)
   totalBatchesExecuted[e] -> st_executed (nat)
   batchStatus[e]          -> st_batch_status (BatchId -> BatchStatus)
   batchRoot[e]            -> st_batch_root (BatchId -> option Root) *)
Record State := mkState {
  st_root         : option Root;
  st_init         : bool;
  st_committed    : nat;
  st_proven       : nat;
  st_executed     : nat;
  st_batch_status : BatchId -> BatchStatus;
  st_batch_root   : BatchId -> option Root;
}.

(* ========================================== *)
(*     INITIAL STATE                           *)
(* ========================================== *)

(* [Source: BasisRollup.tla, lines 98-108 -- Init]
   All fields zeroed/None. Enterprise starts uninitialized. *)
Definition init_state : State :=
  mkState None false 0 0 0 (fun _ => BSNone) (fun _ => None).

(* ========================================== *)
(*     ACTION PRECONDITIONS                    *)
(* ========================================== *)

(* InitializeEnterprise guard.
   [Source: BasisRollup.tla, lines 121-124] *)
Definition can_initialize (s : State) : Prop :=
  st_init s = false.

(* CommitBatch guard.
   [Source: BasisRollup.tla, lines 150-154]
   Note: MaxBatches bound is dropped (unbounded model). *)
Definition can_commit (s : State) : Prop :=
  st_init s = true.

(* ProveBatch guard.
   [Source: BasisRollup.tla, lines 183-190]
   proofIsValid = TRUE is absorbed into the guard (invalid proofs
   are rejected, so only valid paths are reachable). *)
Definition can_prove (s : State) : Prop :=
  st_init s = true /\
  st_proven s < st_committed s /\
  st_batch_status s (st_proven s) = BSCommitted.

(* ExecuteBatch guard.
   [Source: BasisRollup.tla, lines 216-222] *)
Definition can_execute (s : State) : Prop :=
  st_init s = true /\
  st_executed s < st_proven s /\
  st_batch_status s (st_executed s) = BSProven.

(* RevertBatch guard.
   [Source: BasisRollup.tla, lines 249-255] *)
Definition can_revert (s : State) : Prop :=
  st_init s = true /\
  st_committed s > st_executed s /\
  st_batch_status s (st_committed s - 1) <> BSExecuted.

(* ========================================== *)
(*     ACTION DEFINITIONS                      *)
(* ========================================== *)

(* InitializeEnterprise(e, genesisRoot).
   Sets genesis root and marks initialized.
   [Source: BasisRollup.tla, lines 121-128] *)
Definition do_initialize (s : State) (genesis : Root) : State :=
  mkState (Some genesis) true
    (st_committed s) (st_proven s) (st_executed s)
    (st_batch_status s) (st_batch_root s).

(* CommitBatch(e, newRoot).
   Assigns next batch slot with Committed status and target root.
   [Source: BasisRollup.tla, lines 150-162] *)
Definition do_commit (s : State) (r : Root) : State :=
  let bid := st_committed s in
  mkState (st_root s) (st_init s)
    (bid + 1) (st_proven s) (st_executed s)
    (update_map (st_batch_status s) bid BSCommitted)
    (update_map (st_batch_root s) bid (Some r)).

(* ProveBatch(e, proofIsValid).
   Transitions batch from Committed to Proven.
   [Source: BasisRollup.tla, lines 183-195] *)
Definition do_prove (s : State) : State :=
  let bid := st_proven s in
  mkState (st_root s) (st_init s)
    (st_committed s) (bid + 1) (st_executed s)
    (update_map (st_batch_status s) bid BSProven)
    (st_batch_root s).

(* ExecuteBatch(e).
   Advances currentRoot and transitions batch to Executed.
   [Source: BasisRollup.tla, lines 216-228] *)
Definition do_execute (s : State) : State :=
  let bid := st_executed s in
  mkState (st_batch_root s bid) (st_init s)
    (st_committed s) (st_proven s) (bid + 1)
    (update_map (st_batch_status s) bid BSExecuted)
    (st_batch_root s).

(* RevertBatch(e).
   Clears last committed batch. If it was Proven, also reverts proven counter.
   [Source: BasisRollup.tla, lines 249-268] *)
Definition do_revert (s : State) : State :=
  let bid := st_committed s - 1 in
  let new_proven := if BatchStatus_eqb (st_batch_status s bid) BSProven
                    then bid
                    else st_proven s in
  mkState (st_root s) (st_init s)
    bid new_proven (st_executed s)
    (update_map (st_batch_status s) bid BSNone)
    (update_map (st_batch_root s) bid None).

(* ========================================== *)
(*     STEP RELATION                           *)
(* ========================================== *)

(* Non-deterministic state transition. Models TLA+ Next.
   [Source: BasisRollup.tla, lines 287-297 -- Next] *)
Inductive step : State -> State -> Prop :=
  | step_initialize : forall s r,
      can_initialize s ->
      step s (do_initialize s r)
  | step_commit : forall s r,
      can_commit s ->
      step s (do_commit s r)
  | step_prove : forall s,
      can_prove s ->
      step s (do_prove s)
  | step_execute : forall s,
      can_execute s ->
      step s (do_execute s)
  | step_revert : forall s,
      can_revert s ->
      step s (do_revert s).

(* ========================================== *)
(*     SAFETY PROPERTIES                       *)
(* ========================================== *)

(* BatchChainContinuity (extends INV-S1 from validium StateCommitment).
   After execution, the enterprise's current root equals the state root
   of the most recently executed batch.

   [Source: BasisRollup.tla, lines 318-321]
   [Source: BasisRollup.sol, line 383 -- es.currentRoot = batch.stateRoot] *)
Definition BatchChainContinuity (s : State) : Prop :=
  st_init s = true ->
  st_executed s > 0 ->
  st_root s = st_batch_root s (st_executed s - 1).

(* ProveBeforeExecute (INV-R2).
   Every executed batch has passed through the proven phase.

   [Source: BasisRollup.tla, lines 331-337]
   [Source: BasisRollup.sol, line 379 -- batch.status != BatchStatus.Proven] *)
Definition ProveBeforeExecute (s : State) : Prop :=
  forall i, st_batch_status s i = BSExecuted -> i < st_proven s.

(* CounterMonotonicity (INV-R3/R1/R6/R7).
   Pipeline ordering: executed <= proven <= committed.

   [Source: BasisRollup.tla, lines 391-395]
   [Source: BasisRollup.sol, lines 322, 356] *)
Definition CounterMonotonicity (s : State) : Prop :=
  st_executed s <= st_proven s /\ st_proven s <= st_committed s.

(* ExecuteInOrder (INV-R1).
   All batches below the executed watermark have Executed status.

   [Source: BasisRollup.tla, lines 347-353] *)
Definition ExecuteInOrder (s : State) : Prop :=
  forall i, i < st_executed s -> st_batch_status s i = BSExecuted.

(* StatusConsistency (INV-10).
   Batch statuses align with the three counter watermarks.

   [Source: BasisRollup.tla, lines 427-435] *)
Definition StatusConsistency (s : State) : Prop :=
  (forall i, i < st_executed s -> st_batch_status s i = BSExecuted) /\
  (forall i, st_executed s <= i -> i < st_proven s ->
     st_batch_status s i = BSProven) /\
  (forall i, st_proven s <= i -> i < st_committed s ->
     st_batch_status s i = BSCommitted) /\
  (forall i, st_committed s <= i -> st_batch_status s i = BSNone).

(* BatchRootIntegrity (INV-12).
   Committed batches have roots; uncommitted do not.

   [Source: BasisRollup.tla, lines 463-469] *)
Definition BatchRootIntegrity (s : State) : Prop :=
  (forall i, i < st_committed s -> exists r, st_batch_root s i = Some r) /\
  (forall i, st_committed s <= i -> st_batch_root s i = None).

(* NoReversal (INV-08).
   Initialized enterprise always has a valid root.

   [Source: BasisRollup.tla, lines 404-406] *)
Definition NoReversal (s : State) : Prop :=
  st_init s = true -> exists r, st_root s = Some r.

(* InitBeforeBatch (INV-09).
   Uninitialized enterprise has no batches.

   [Source: BasisRollup.tla, lines 414-416] *)
Definition InitBeforeBatch (s : State) : Prop :=
  st_init s = false -> st_committed s = 0.

(* ========================================== *)
(*     COMPOSITE INVARIANT                     *)
(* ========================================== *)

(* All safety properties combined into a single inductive invariant.
   Used as the strengthened invariant for the inductive proof of
   preservation across all lifecycle actions.

   Each field is tagged with the corresponding TLA+ invariant name
   and Solidity line reference for cross-verification. *)
Record Inv (s : State) : Prop := mk_inv {
  inv_counter_mono     : st_executed s <= st_proven s /\
                         st_proven s <= st_committed s;
  inv_status_exec      : forall i, i < st_executed s ->
                           st_batch_status s i = BSExecuted;
  inv_status_proven    : forall i, st_executed s <= i -> i < st_proven s ->
                           st_batch_status s i = BSProven;
  inv_status_committed : forall i, st_proven s <= i -> i < st_committed s ->
                           st_batch_status s i = BSCommitted;
  inv_status_none      : forall i, st_committed s <= i ->
                           st_batch_status s i = BSNone;
  inv_root_some        : forall i, i < st_committed s ->
                           exists r, st_batch_root s i = Some r;
  inv_root_none        : forall i, st_committed s <= i ->
                           st_batch_root s i = None;
  inv_no_reversal      : st_init s = true ->
                           exists r, st_root s = Some r;
  inv_init_before      : st_init s = false -> st_committed s = 0;
  inv_chain_cont       : st_init s = true -> st_executed s > 0 ->
                           st_root s = st_batch_root s (st_executed s - 1);
}.
