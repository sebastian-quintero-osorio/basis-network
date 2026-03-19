(* ================================================================ *)
(*  Spec.v -- Faithful Translation of EnterpriseNode.tla to Coq     *)
(* ================================================================ *)
(*                                                                  *)
(*  Every definition corresponds to a definition in the TLA+ spec.  *)
(*  Source references: [TLA: <operator>, line <number>]             *)
(*                                                                  *)
(*  Source: 0-input-spec/EnterpriseNode.tla                         *)
(*  TLC Result: PASS (all safety + liveness properties)             *)
(* ================================================================ *)

From EN Require Import Common.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Bool.Bool.
From Stdlib Require Import Lia.

Import ListNotations.

Module Spec.

(* ======================================== *)
(*     STATE                                *)
(* ======================================== *)

(* [TLA: VARIABLES, lines 59-73]
   All 12 state variables from the TLA+ specification. *)
Record State := mkState {
  nodeState     : NodeState;    (* Current node state *)
  txQueue       : list Tx;      (* In-memory transaction queue (volatile) *)
  wal           : list Tx;      (* Write-Ahead Log (durable) *)
  walCheckpoint : nat;          (* Last checkpointed WAL position (durable) *)
  smtState      : TxSet;        (* Sparse Merkle Tree state (set abstraction) *)
  batchTxs      : list Tx;      (* Current batch transactions (volatile) *)
  batchPrevSmt  : TxSet;        (* SMT state before batch applied (volatile) *)
  l1State       : TxSet;        (* Last confirmed state on L1 (durable) *)
  dataExposed   : DKSet;        (* Data categories sent outside boundary *)
  pending       : TxSet;        (* Transactions not yet received *)
  crashCount    : nat;          (* Number of crashes occurred *)
  timerExpired  : bool;         (* Time threshold flag *)
}.

(* ======================================== *)
(*     INITIAL STATE                        *)
(* ======================================== *)

(* [TLA: Init, lines 121-133] *)
Definition init_state : State :=
  mkState
    Idle                (* nodeState = "Idle" *)
    []                  (* txQueue = << >> *)
    []                  (* wal = << >> *)
    0                   (* walCheckpoint = 0 *)
    empty_txset         (* smtState = {} *)
    []                  (* batchTxs = << >> *)
    empty_txset         (* batchPrevSmt = {} *)
    empty_txset         (* l1State = {} *)
    dk_empty            (* dataExposed = {} *)
    full_txset          (* pending = AllTxs *)
    0                   (* crashCount = 0 *)
    false.              (* timerExpired = FALSE *)

(* ======================================== *)
(*     ACTION PRECONDITIONS                 *)
(* ======================================== *)

(* [TLA: ReceiveTx(tx) precondition, lines 145-147] *)
Definition receive_tx_pre (s : State) (tx : Tx) : Prop :=
  pending s tx /\
  (nodeState s = Idle \/ nodeState s = Receiving \/
   nodeState s = Proving \/ nodeState s = Submitting).

(* [TLA: CheckQueue precondition, lines 161-162] *)
Definition check_queue_pre (s : State) : Prop :=
  nodeState s = Idle /\ length (txQueue s) > 0.

(* [TLA: FormBatch precondition, lines 179-181] *)
Definition form_batch_pre (s : State) : Prop :=
  nodeState s = Receiving /\
  (length (txQueue s) >= BatchThreshold \/
   (timerExpired s = true /\ length (txQueue s) > 0)).

(* [TLA: GenerateWitness precondition, lines 202-203] *)
Definition gen_witness_pre (s : State) : Prop :=
  nodeState s = Batching /\ length (batchTxs s) > 0.

(* [TLA: GenerateProof precondition, line 217] *)
Definition gen_proof_pre (s : State) : Prop :=
  nodeState s = Proving.

(* [TLA: SubmitBatch precondition, line 231] *)
Definition submit_batch_pre (s : State) : Prop :=
  nodeState s = Submitting.

(* [TLA: ConfirmBatch precondition, line 249] *)
Definition confirm_batch_pre (s : State) : Prop :=
  nodeState s = Submitting.

(* [TLA: Crash precondition, lines 264-265] *)
Definition crash_pre (s : State) : Prop :=
  (nodeState s = Receiving \/ nodeState s = Batching \/
   nodeState s = Proving \/ nodeState s = Submitting) /\
  crashCount s < MaxCrashes.

(* [TLA: L1Reject precondition, line 280] *)
Definition l1_reject_pre (s : State) : Prop :=
  nodeState s = Submitting.

(* [TLA: Retry precondition, line 297] *)
Definition retry_pre (s : State) : Prop :=
  nodeState s = Error.

(* [TLA: TimerTick precondition, lines 310-312] *)
Definition timer_tick_pre (s : State) : Prop :=
  nodeState s = Receiving /\
  timerExpired s = false /\
  length (txQueue s) > 0.

(* [TLA: Done precondition, lines 322-325] *)
Definition done_pre (s : State) : Prop :=
  pending s = empty_txset /\
  length (txQueue s) = 0 /\
  length (batchTxs s) = 0 /\
  nodeState s = Idle.

(* ======================================== *)
(*     ACTIONS                              *)
(* ======================================== *)

(* [TLA: ReceiveTx(tx), lines 145-153]
   WAL-first: persist to WAL, then add to queue.
   Pipelined: Idle -> Receiving; other states unchanged. *)
Definition receive_tx (s : State) (tx : Tx) : State :=
  mkState
    (if NodeState_eq_dec (nodeState s) Idle then Receiving
     else nodeState s)
    (txQueue s ++ [tx])
    (wal s ++ [tx])
    (walCheckpoint s)
    (smtState s)
    (batchTxs s)
    (batchPrevSmt s)
    (l1State s)
    (dataExposed s)
    (set_remove (pending s) tx)
    (crashCount s)
    (timerExpired s).

(* [TLA: CheckQueue, lines 160-166]
   Idle with non-empty queue -> Receiving. *)
Definition check_queue (s : State) : State :=
  mkState
    Receiving
    (txQueue s)
    (wal s)
    (walCheckpoint s)
    (smtState s)
    (batchTxs s)
    (batchPrevSmt s)
    (l1State s)
    (dataExposed s)
    (pending s)
    (crashCount s)
    (timerExpired s).

(* [TLA: FormBatch, lines 178-192]
   HYBRID batch formation. Records batchPrevSmt = smtState. *)
Definition form_batch (s : State) : State :=
  let batchSize := Nat.min (length (txQueue s)) BatchThreshold in
  mkState
    Batching
    (skipn batchSize (txQueue s))
    (wal s)
    (walCheckpoint s)
    (smtState s)
    (firstn batchSize (txQueue s))
    (smtState s)                     (* batchPrevSmt := smtState *)
    (l1State s)
    (dataExposed s)
    (pending s)
    (crashCount s)
    false.

(* [TLA: GenerateWitness, lines 201-207]
   Apply batch to SMT: smtState' = smtState \cup BatchTxSet. *)
Definition gen_witness (s : State) : State :=
  mkState
    Proving
    (txQueue s)
    (wal s)
    (walCheckpoint s)
    (set_union (smtState s) (list_to_set (batchTxs s)))
    (batchTxs s)
    (batchPrevSmt s)
    (l1State s)
    (dataExposed s)
    (pending s)
    (crashCount s)
    (timerExpired s).

(* [TLA: GenerateProof, lines 216-221]
   ZK proof generation completes. State: Proving -> Submitting. *)
Definition gen_proof (s : State) : State :=
  mkState
    Submitting
    (txQueue s)
    (wal s)
    (walCheckpoint s)
    (smtState s)
    (batchTxs s)
    (batchPrevSmt s)
    (l1State s)
    (dataExposed s)
    (pending s)
    (crashCount s)
    (timerExpired s).

(* [TLA: SubmitBatch, lines 230-235]
   Send proof + signals to L1, shares to DAC.
   Only dataExposed changes. nodeState stays Submitting. *)
Definition submit_batch (s : State) : State :=
  mkState
    (nodeState s)
    (txQueue s)
    (wal s)
    (walCheckpoint s)
    (smtState s)
    (batchTxs s)
    (batchPrevSmt s)
    (l1State s)
    (dk_add_ps_dac (dataExposed s))
    (pending s)
    (crashCount s)
    (timerExpired s).

(* [TLA: ConfirmBatch, lines 248-256]
   L1 confirmation: l1State advances to smtState,
   walCheckpoint advances, batch cleared, -> Idle. *)
Definition confirm_batch (s : State) : State :=
  mkState
    Idle
    (txQueue s)
    (wal s)
    (walCheckpoint s + length (batchTxs s))
    (smtState s)
    []
    empty_txset
    (smtState s)                     (* l1State := smtState *)
    (dataExposed s)
    (pending s)
    (crashCount s)
    (timerExpired s).

(* [TLA: Crash, lines 263-273]
   All volatile state lost. SMT resets to l1State. *)
Definition crash (s : State) : State :=
  mkState
    Error
    []
    (wal s)
    (walCheckpoint s)
    (l1State s)                      (* smtState := l1State *)
    []
    empty_txset
    (l1State s)
    (dataExposed s)
    (pending s)
    (crashCount s + 1)
    false.

(* [TLA: L1Reject, lines 279-288]
   L1 rejects submission. Batch lost, SMT rolls back. *)
Definition l1_reject (s : State) : State :=
  mkState
    Error
    []
    (wal s)
    (walCheckpoint s)
    (l1State s)
    []
    empty_txset
    (l1State s)
    (dataExposed s)
    (pending s)
    (crashCount s)
    false.

(* [TLA: Retry, lines 296-302]
   Recovery: restore SMT, replay WAL after checkpoint. *)
Definition retry (s : State) : State :=
  mkState
    Idle
    (skipn (walCheckpoint s) (wal s))
    (wal s)
    (walCheckpoint s)
    (l1State s)                      (* smtState := l1State *)
    (batchTxs s)
    (batchPrevSmt s)
    (l1State s)
    (dataExposed s)
    (pending s)
    (crashCount s)
    (timerExpired s).

(* [TLA: TimerTick, lines 309-316]
   Nondeterministic timer expiration. *)
Definition timer_tick (s : State) : State :=
  mkState
    (nodeState s)
    (txQueue s)
    (wal s)
    (walCheckpoint s)
    (smtState s)
    (batchTxs s)
    (batchPrevSmt s)
    (l1State s)
    (dataExposed s)
    (pending s)
    (crashCount s)
    true.

(* [TLA: Done, lines 321-326]
   Terminal state: UNCHANGED vars (stuttering). *)
Definition done (s : State) : State := s.

(* ======================================== *)
(*     STEP RELATION                        *)
(* ======================================== *)

(* [TLA: Next, lines 332-344]
   Disjunction of all actions. *)
Inductive step : State -> State -> Prop :=
  | step_receive_tx    : forall s tx,
      receive_tx_pre s tx -> step s (receive_tx s tx)
  | step_check_queue   : forall s,
      check_queue_pre s -> step s (check_queue s)
  | step_form_batch    : forall s,
      form_batch_pre s -> step s (form_batch s)
  | step_gen_witness   : forall s,
      gen_witness_pre s -> step s (gen_witness s)
  | step_gen_proof     : forall s,
      gen_proof_pre s -> step s (gen_proof s)
  | step_submit_batch  : forall s,
      submit_batch_pre s -> step s (submit_batch s)
  | step_confirm_batch : forall s,
      confirm_batch_pre s -> step s (confirm_batch s)
  | step_crash         : forall s,
      crash_pre s -> step s (crash s)
  | step_l1_reject     : forall s,
      l1_reject_pre s -> step s (l1_reject s)
  | step_retry         : forall s,
      retry_pre s -> step s (retry s)
  | step_timer_tick    : forall s,
      timer_tick_pre s -> step s (timer_tick s)
  | step_done          : forall s,
      done_pre s -> step s (done s).

(* ======================================== *)
(*     SAFETY INVARIANTS                    *)
(* ======================================== *)

(* INV-NO5: State Root Continuity.
   [TLA: StateRootContinuity, lines 429-433]
   In idle-like states: smtState = l1State (no batch applied).
   In active states: smtState = l1State + batch (batch applied). *)
Definition SRC (s : State) : Prop :=
  match nodeState s with
  | Idle | Receiving | Batching | Error =>
      smtState s = l1State s
  | Proving | Submitting =>
      smtState s = set_union (l1State s) (list_to_set (batchTxs s))
  end.

(* INV-NO2 (strengthened): Proof-State Root Integrity.
   [TLA: ProofStateIntegrity, lines 390-391]
   Strengthened: batchPrevSmt = l1State whenever a batch is active
   (Batching through Submitting). The original invariant
   "Submitting -> batchPrevSmt = l1State" follows as a corollary. *)
Definition PSI (s : State) : Prop :=
  match nodeState s with
  | Batching | Proving | Submitting => batchPrevSmt s = l1State s
  | _ => True
  end.

(* INV-NO3: No Data Leakage (Privacy Boundary).
   [TLA: NoDataLeakage, lines 400-401]
   Only proof signals and DAC shares leave the node boundary.
   Raw enterprise data NEVER exits the node. *)
Definition NDL (s : State) : Prop :=
  dk_subset (dataExposed s) allowed_external.

(* Combined safety invariant: the conjunction that is
   inductively preserved by all actions. *)
Definition SafetyInv (s : State) : Prop :=
  SRC s /\ PSI s /\ NDL s.

(* INV-NO2 (original formulation from TLA+).
   Follows directly from the strengthened PSI. *)
Definition ProofStateIntegrity (s : State) : Prop :=
  nodeState s = Submitting -> batchPrevSmt s = l1State s.

End Spec.
