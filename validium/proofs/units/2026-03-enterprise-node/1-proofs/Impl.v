(* ================================================================ *)
(*  Impl.v -- Abstract Model of orchestrator.ts                      *)
(* ================================================================ *)
(*                                                                  *)
(*  Models the TypeScript EnterpriseNodeOrchestrator class as Coq   *)
(*  state transitions. Each definition references the source code.  *)
(*                                                                  *)
(*  Source: 0-input-impl/orchestrator.ts                            *)
(*  Source: 0-input-impl/types.ts                                   *)
(*                                                                  *)
(*  Modeling approach for TypeScript:                                *)
(*  - async/Promise -> composed state transitions                   *)
(*  - Class instance -> Spec.State record (fields correspond 1:1)   *)
(*  - setInterval batch loop -> discrete check + batch cycle        *)
(*  - try/catch -> error transition + recovery                      *)
(*                                                                  *)
(*  Key difference from Spec: the implementation bundles multiple   *)
(*  spec actions into a single processBatchCycle() call:            *)
(*    FormBatch -> GenerateWitness -> GenerateProof ->              *)
(*    SubmitBatch -> ConfirmBatch                                   *)
(* ================================================================ *)

From EN Require Import Common.
From EN Require Import Spec.

Module Impl.

(* ======================================== *)
(*     STATE                                *)
(* ======================================== *)

(* [Impl: orchestrator.ts, class EnterpriseNodeOrchestrator, lines 75-104]
   The implementation state is isomorphic to the specification state.
   TypeScript class fields map directly to TLA+ variables:

     this.state          -> nodeState
     this.smt            -> smtState (tree state as set abstraction)
     this.queue           -> txQueue + wal (WAL-backed TransactionQueue)
     this.smtCheckpoint   -> l1State (serialized SMT at last checkpoint)
     this.aggregator      -> batchTxs (via BatchAggregator)
     this.crashCount      -> crashCount
     this.dac             -> dataExposed (via DACProtocol)

   Since the mapping is an isomorphism, we reuse Spec.State directly. *)
Definition State := Spec.State.

(* ======================================== *)
(*     STATE MAPPING                        *)
(* ======================================== *)

(* The refinement mapping is the identity function.
   Each TypeScript class field corresponds to a Spec state variable
   with the same semantics. *)
Definition map_state (si : State) : Spec.State := si.

(* ======================================== *)
(*     OPERATIONS                           *)
(* ======================================== *)

(* [Impl: orchestrator.ts, submitTransaction(), lines 140-164]
   Atomic operation: directly matches Spec.ReceiveTx.
   WAL-first write, then enqueue, then state transition. *)
Definition submit_tx (s : State) (tx : Tx) : State :=
  Spec.receive_tx s tx.

(* [Impl: orchestrator.ts, processBatchCycle(), lines 339-469]
   Bundled operation: composes five spec actions sequentially.
   The try block executes: FormBatch -> GenWitness -> GenProof ->
   SubmitBatch -> ConfirmBatch.
   Models the await chain in the implementation. *)
Definition batch_cycle (s : State) : State :=
  Spec.confirm_batch
    (Spec.submit_batch
      (Spec.gen_proof
        (Spec.gen_witness
          (Spec.form_batch s)))).

(* [Impl: orchestrator.ts, handleBatchError(), lines 476-499]
   Error handling: combines Crash + automatic Retry.
   The catch block transitions to Error then immediately calls recover(). *)
Definition handle_error (s : State) : State :=
  Spec.retry (Spec.crash s).

(* [Impl: orchestrator.ts, handleBatchError() with L1 rejection]
   L1 rejection variant: L1Reject + automatic Retry. *)
Definition handle_l1_reject (s : State) : State :=
  Spec.retry (Spec.l1_reject s).

(* [Impl: orchestrator.ts, recover(), lines 210-250]
   Startup recovery. Directly matches Spec.Retry. *)
Definition recover (s : State) : State :=
  Spec.retry s.

(* [Impl: orchestrator.ts, batchLoopTick(), lines 299-307]
   Queue check: if Idle with pending txs, transition to Receiving.
   Directly matches Spec.CheckQueue. *)
Definition batch_loop_tick (s : State) : State :=
  Spec.check_queue s.

(* ======================================== *)
(*     STEP RELATION                        *)
(* ======================================== *)

(* The implementation step relation reflects the coarser
   granularity of TypeScript method calls. Each impl step
   corresponds to one or more spec steps. *)
Inductive step : State -> State -> Prop :=
  | step_submit_tx : forall s tx,
      Spec.receive_tx_pre s tx ->
      step s (submit_tx s tx)
  | step_batch_cycle : forall s,
      Spec.form_batch_pre s ->
      step s (batch_cycle s)
  | step_error : forall s,
      Spec.crash_pre s ->
      step s (handle_error s)
  | step_l1_reject : forall s,
      Spec.l1_reject_pre s ->
      step s (handle_l1_reject s)
  | step_recover : forall s,
      Spec.retry_pre s ->
      step s (recover s)
  | step_loop_tick : forall s,
      Spec.check_queue_pre s ->
      step s (batch_loop_tick s)
  | step_timer : forall s,
      Spec.timer_tick_pre s ->
      step s (Spec.timer_tick s).

End Impl.
