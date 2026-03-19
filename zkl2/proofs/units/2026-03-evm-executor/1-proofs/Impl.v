(* ========================================== *)
(*     Impl.v -- Go Implementation Model       *)
(*     Abstract Model of executor.go + tracer  *)
(*     zkl2/proofs/units/2026-03-evm-executor  *)
(* ========================================== *)

(* This file models the Go implementation of the EVM executor as
   Coq definitions. The key architectural difference from the spec:

   TLA+ (Spec.v):
     Each ExecX action directly constructs its trace entry inline.

   Go (this file):
     Executor delegates to go-ethereum's EVM interpreter.
     ZKTracer hooks capture state-modifying operations:
       - onOpcode:        fires BEFORE opcode, captures SLOAD and CALL
       - onStorageChange: fires AFTER SSTORE, captures old/new values
       - onBalanceChange: captures balance changes (spec extension)
       - onNonceChange:   captures nonce changes (spec extension)

   The verification proves that the hook-based mechanism produces
   the same trace entries as the spec's inline construction.

   Source: executor.go, tracer.go, types.go (frozen in 0-input-impl/) *)

From EvmExecutor Require Import Common.
From EvmExecutor Require Import Spec.
From Stdlib Require Import List.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
Import ListNotations.

(* ========================================== *)
(*     IMPLEMENTATION TRACE OPERATIONS         *)
(* ========================================== *)

(* The Go implementation extends the spec with additional trace types.
   [Source: types.go, lines 25-51 -- TraceOp constants]
   For this verification, we focus on the three spec-modeled types.
   BALANCE_CHANGE, NONCE_CHANGE, and LOG are implementation extensions
   that do not participate in the TraceCompleteness property. *)
Inductive ImplTraceOp : Type :=
  | ImplSLOAD
  | ImplSSTORE
  | ImplCALL
  | ImplBALANCE_CHANGE
  | ImplNONCE_CHANGE
  | ImplLOG.

(* Map implementation trace op to spec trace op.
   Only SLOAD, SSTORE, CALL have spec counterparts. *)
Definition impl_to_spec_op (op : ImplTraceOp) : option TraceOp :=
  match op with
  | ImplSLOAD  => Some TOSload
  | ImplSSTORE => Some TOSstore
  | ImplCALL   => Some TOCall
  | _ => None
  end.

(* ========================================== *)
(*     TRACER HOOK FUNCTIONS                   *)
(* ========================================== *)

(* Each function models a ZKTracer hook from tracer.go.
   The hooks construct TraceEntry values that are appended to the trace. *)

(* onOpcode hook for SLOAD: fires BEFORE opcode executes.
   Reads slot from stack, looks up current value via stateDB.GetState.
   [Source: tracer.go, lines 87-98 -- SLOAD branch in onOpcode] *)
Definition tracer_on_sload (acct : Account) (slot : Slot) (val : Value) : TraceEntry :=
  TrSload acct slot val.

(* onStorageChange hook for SSTORE: fires AFTER SSTORE executes.
   Receives account, slot, previous value, and new value.
   [Source: tracer.go, lines 155-163 -- onStorageChange] *)
Definition tracer_on_sstore (acct : Account) (slot : Slot) (oldv newv : Value) : TraceEntry :=
  TrSstore acct slot oldv newv.

(* onOpcode hook for CALL: fires BEFORE CALL executes.
   Reads target address and value from the EVM stack.
   [Source: tracer.go, lines 100-114 -- CALL branch in onOpcode] *)
Definition tracer_on_call (from to : Account) (val : Value) : TraceEntry :=
  TrCall from to val.

(* ========================================== *)
(*     IMPLEMENTATION STEP FUNCTION            *)
(* ========================================== *)

(* The implementation step function mirrors exec_opcode from Spec.v
   but constructs trace entries via tracer hook functions instead
   of inline construction.

   The go-ethereum EVM interpreter:
   1. Fetches the opcode at the current PC
   2. Fires onOpcode hook (captures SLOAD, CALL)
   3. Executes the opcode (modifies stack, storage)
   4. Fires state-change hooks (onStorageChange for SSTORE)

   [Source: executor.go, lines 75-209 -- ExecuteTransaction]
   [Source: tracer.go -- hook implementations] *)
Definition impl_exec_opcode (ctx : ExecCtx) (op : Opcode) (stack : list Value)
  : option (list Value * option TraceEntry * Storage) :=
  match op with
  (* go-ethereum executes PUSH. No hook fires for trace capture.
     [Source: opcodes.go -- PUSH classified as ZKTrivial, not state-modifying] *)
  | OpPush v =>
    Some (v :: stack, None, ctx_storage ctx)

  (* go-ethereum executes ADD. No hook fires for trace capture.
     [Source: opcodes.go -- ADD classified as ZKCheap, not state-modifying] *)
  | OpAdd =>
    match stack with
    | a :: b :: rest =>
      Some ((a + b) :: rest, None, ctx_storage ctx)
    | _ => None
    end

  (* 1. onOpcode hook fires BEFORE SLOAD executes
     2. Hook reads slot from stack[n-1], calls stateDB.GetState
     3. Hook calls tracer_on_sload to construct trace entry
     4. go-ethereum pushes the loaded value onto the stack
     [Source: tracer.go, lines 87-98] *)
  | OpSload slot =>
    let val := ctx_storage ctx slot in
    let entry := tracer_on_sload (ctx_to ctx) slot val in
    Some (val :: stack, Some entry, ctx_storage ctx)

  (* 1. go-ethereum executes SSTORE (writes to stateDB)
     2. onStorageChange hook fires AFTER SSTORE with old and new values
     3. Hook calls tracer_on_sstore to construct trace entry
     [Source: tracer.go, lines 155-163] *)
  | OpSstore slot =>
    match stack with
    | v :: rest =>
      let old_val := ctx_storage ctx slot in
      let new_st := storage_update (ctx_storage ctx) slot v in
      let entry := tracer_on_sstore (ctx_to ctx) slot old_val v in
      Some (rest, Some entry, new_st)
    | _ => None
    end

  (* 1. onOpcode hook fires BEFORE CALL executes
     2. Hook reads target (stack[n-2]) and value (stack[n-3])
     3. Hook calls tracer_on_call to construct trace entry
     4. go-ethereum executes the call and pushes result
     [Source: tracer.go, lines 100-114] *)
  | OpCall target =>
    match stack with
    | v :: rest =>
      let entry := tracer_on_call (ctx_to ctx) target v in
      Some (1 :: rest, Some entry, ctx_storage ctx)
    | _ => None
    end
  end.

(* Full program execution using implementation step function.
   Models the EVM interpreter loop delegated by executor.go.
   [Source: executor.go, lines 137-175 -- evm.Call execution] *)
Fixpoint impl_run_program (ctx : ExecCtx) (prog : Program) (stack : list Value)
  (acc_trace : list TraceEntry)
  : option (list Value * list TraceEntry * ExecCtx) :=
  match prog with
  | [] => Some (stack, acc_trace, ctx)
  | op :: rest =>
    match impl_exec_opcode ctx op stack with
    | None => None
    | Some (new_stack, maybe_entry, new_storage) =>
      let new_trace := match maybe_entry with
                       | None => acc_trace
                       | Some e => acc_trace ++ [e]
                       end in
      let new_ctx := mkExecCtx (ctx_to ctx) new_storage in
      impl_run_program new_ctx rest new_stack new_trace
    end
  end.

(* ========================================== *)
(*     STEP EQUIVALENCE                        *)
(* ========================================== *)

(* Core observation: the tracer hook functions produce the same
   TraceEntry constructors as the spec's inline construction.
   This follows from the definitions:
     tracer_on_sload  = TrSload   (by definition)
     tracer_on_sstore = TrSstore  (by definition)
     tracer_on_call   = TrCall    (by definition)

   Therefore impl_exec_opcode is definitionally equal to exec_opcode. *)

(* The implementation step function produces identical results to the spec.
   This is the fundamental refinement at the single-step level. *)
Lemma impl_exec_eq_spec : forall ctx op stack,
  impl_exec_opcode ctx op stack = exec_opcode ctx op stack.
Proof.
  intros ctx op stack.
  destruct op; simpl; reflexivity.
Qed.

(* Full program execution is identical between implementation and spec.
   Follows by induction from single-step equivalence. *)
Lemma impl_run_eq_spec : forall prog ctx stack trace,
  impl_run_program ctx prog stack trace = run_program ctx prog stack trace.
Proof.
  induction prog as [| op rest IH]; intros ctx stack trace; simpl.
  - reflexivity.
  - rewrite impl_exec_eq_spec.
    destruct (exec_opcode ctx op stack) as [[[new_stack maybe_entry] new_storage]|].
    + apply IH.
    + reflexivity.
Qed.
