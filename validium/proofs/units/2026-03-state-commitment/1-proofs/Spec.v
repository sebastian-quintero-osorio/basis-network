(* ================================================================ *)
(*  Spec.v -- Faithful Translation of StateCommitment.tla to Coq    *)
(* ================================================================ *)
(*                                                                  *)
(*  Every definition corresponds to a construct in the TLA+ spec.   *)
(*  Source references: [TLA: <name>, line <N>]                      *)
(*                                                                  *)
(*  Source: 0-input-spec/StateCommitment.tla                        *)
(*  TLC Result: PASS (all 5 safety properties verified)             *)
(* ================================================================ *)

From SC Require Import Common.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.

Open Scope nat_scope.

Module Spec.

(* ======================================== *)
(*     STATE                               *)
(* ======================================== *)

(* [TLA: VARIABLES -- lines 34-39]
   Five state variables combined into a single record.
   Each enterprise has independent state; cross-enterprise
   isolation is enforced by EXCEPT ![e] update semantics. *)
Record State := mkState {
  currentRoot    : Enterprise -> Root;           (* [TLA: line 35] *)
  batchCount     : Enterprise -> nat;            (* [TLA: line 36] *)
  initialized    : Enterprise -> bool;           (* [TLA: line 37] *)
  batchHistory   : Enterprise -> nat -> Root;    (* [TLA: line 38] *)
  totalCommitted : nat                           (* [TLA: line 39] *)
}.

(* ======================================== *)
(*     INITIAL STATE                       *)
(* ======================================== *)

(* [TLA: Init -- lines 62-67]
   All enterprises start uninitialized with no roots and no history. *)
Definition Init : State := mkState
  (fun _ => NONE)       (* currentRoot = [e \in Enterprises |-> None] *)
  (fun _ => 0)          (* batchCount = [e \in Enterprises |-> 0] *)
  (fun _ => false)      (* initialized = [e \in Enterprises |-> FALSE] *)
  (fun _ _ => NONE)     (* batchHistory = [e |-> [i |-> None]] *)
  0.                    (* totalCommitted = 0 *)

(* ======================================== *)
(*     ACTIONS                             *)
(* ======================================== *)

(* [TLA: InitializeEnterprise(e, genesisRoot) -- lines 78-84]
   Admin initializes an enterprise with a genesis root.
   Guard: ~initialized[e], genesisRoot \in Roots
   Effect: initialized'[e] = TRUE, currentRoot'[e] = genesisRoot
   UNCHANGED: batchCount, batchHistory, totalCommitted *)
Definition InitializeEnterprise (s : State) (e : Enterprise)
  (genesisRoot : Root) : State :=
  mkState
    (fupdate (currentRoot s) e genesisRoot)
    (batchCount s)
    (fupdate (initialized s) e true)
    (batchHistory s)
    (totalCommitted s).

(* [TLA: SubmitBatch(e, prevRoot, newRoot, proofIsValid) -- lines 100-113]
   Enterprise submits a batch after ZK proof verification.
   Guards: initialized[e], prevRoot = currentRoot[e],
           proofIsValid = TRUE, newRoot \in Roots
   Effect: currentRoot'[e] = newRoot, batchCount'[e] = bid + 1,
           batchHistory'[e][bid] = newRoot, totalCommitted' + 1
   UNCHANGED: initialized *)
Definition SubmitBatch (s : State) (e : Enterprise)
  (newRoot : Root) : State :=
  let bid := batchCount s e in
  mkState
    (fupdate (currentRoot s) e newRoot)
    (fupdate (batchCount s) e (bid + 1))
    (initialized s)
    (fupdate2 (batchHistory s) e bid newRoot)
    (totalCommitted s + 1).

(* ======================================== *)
(*     STEP RELATION                       *)
(* ======================================== *)

(* [TLA: Next -- lines 134-138]
   Non-deterministic choice of action with guards as preconditions.
   proofIsValid = TRUE is modeled structurally: only the valid-proof
   constructor exists. Invalid proofs produce no step (reverted).

   prevRoot in step_submit_batch models the caller-supplied previous
   root. The guard prevRoot = currentRoot[e] enforces ChainContinuity
   (INV-S1). Since prevRoot is existentially quantified in Next, the
   guard is always satisfiable. *)
Inductive step : State -> State -> Prop :=
  | step_init_enterprise : forall s e genesisRoot,
      initialized s e = false ->               (* ~initialized[e] *)
      genesisRoot > 0 ->                       (* genesisRoot \in Roots *)
      step s (InitializeEnterprise s e genesisRoot)

  | step_submit_batch : forall s e prevRoot newRoot,
      initialized s e = true ->                (* Guard 1: initialized[e] *)
      prevRoot = currentRoot s e ->            (* Guard 2: ChainContinuity *)
      newRoot > 0 ->                           (* Guard: newRoot \in Roots *)
      (* Guard 3: proofIsValid = TRUE -- enforced by constructor *)
      step s (SubmitBatch s e newRoot).

(* ======================================== *)
(*     SAFETY INVARIANTS                   *)
(* ======================================== *)

(* [TLA: ChainContinuity -- lines 156-159]
   Current root reflects the latest committed batch.
   If an enterprise is initialized and has committed at least one
   batch, its currentRoot must equal the root in its last batch. *)
Definition ChainContinuity (s : State) : Prop :=
  forall e,
    initialized s e = true ->
    batchCount s e > 0 ->
    currentRoot s e = batchHistory s e (batchCount s e - 1).

(* [TLA: NoGap -- lines 166-171]
   Batch IDs form a dense sequence with no gaps.
   All slots below batchCount are filled (non-NONE);
   all slots at or above batchCount are empty (NONE). *)
Definition NoGap (s : State) : Prop :=
  forall e,
    (forall i, i < batchCount s e -> batchHistory s e i <> NONE) /\
    (forall i, i >= batchCount s e -> batchHistory s e i = NONE).

(* [TLA: NoReversal -- lines 179-181]
   An initialized enterprise always has a valid (non-NONE) root.
   Without explicit rollback, the chain head can never revert to
   the uninitialized sentinel. *)
Definition NoReversal (s : State) : Prop :=
  forall e,
    initialized s e = true ->
    currentRoot s e <> NONE.

(* [TLA: InitBeforeBatch -- lines 187-189]
   Only initialized enterprises can have committed batches.
   Contrapositive: uninitialized enterprises have batchCount = 0. *)
Definition InitBeforeBatch (s : State) : Prop :=
  forall e,
    batchCount s e > 0 ->
    initialized s e = true.

(* Combined invariant for joint inductive proofs. *)
Definition AllInvariants (s : State) : Prop :=
  ChainContinuity s /\
  NoGap s /\
  NoReversal s /\
  InitBeforeBatch s.

End Spec.
