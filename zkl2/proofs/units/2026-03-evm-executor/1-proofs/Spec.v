(* ========================================== *)
(*     Spec.v -- TLA+ Specification Model      *)
(*     Faithful Translation of EvmExecutor.tla *)
(*     zkl2/proofs/units/2026-03-evm-executor  *)
(* ========================================== *)

(* This file translates the TLA+ specification of the EVM Executor
   into Coq definitions. The TLA+ spec models the EVM as a deterministic
   state machine that executes transactions containing sequences of opcodes,
   producing execution traces for ZK witness generation.

   The translation preserves the essential structure:
   - Opcodes as an inductive type (OpcodeSet in TLA+)
   - Trace entries as an inductive type (TraceEntrySet in TLA+)
   - Single-step execution as a total function (ExecX actions in TLA+)
   - Full program execution as iteration (Executing guard + CurrentOp)

   Key simplification: Account balances and nonces are not modeled because
   the target properties (Determinism, TraceCompleteness) depend only on
   the opcode-to-trace correspondence, not on balance arithmetic.

   Source: EvmExecutor.tla (frozen in 0-input-spec/) *)

From EvmExecutor Require Import Common.
From Stdlib Require Import List.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
Import ListNotations.

(* ========================================== *)
(*     ABSTRACT TYPES                          *)
(* ========================================== *)

(* Account address -- modeled as nat for decidable equality.
   [Source: EvmExecutor.tla, line 27 -- Accounts constant] *)
Definition Account := nat.

(* Storage slot identifier -- modeled as nat.
   [Source: EvmExecutor.tla, line 28 -- StorageSlots constant] *)
Definition Slot := nat.

(* Bounded integer value. Using nat; the TLA+ spec uses 0..MaxValue.
   Modular arithmetic for ADD is abstracted since it does not
   affect Determinism or TraceCompleteness properties.
   [Source: EvmExecutor.tla, line 29 -- MaxValue constant] *)
Definition Value := nat.

(* ========================================== *)
(*     OPCODE TYPE                             *)
(* ========================================== *)

(* The five opcodes modeled in the TLA+ specification, covering all
   five ZK difficulty tiers.
   [Source: EvmExecutor.tla, lines 38-49 -- OpcodeSet definition] *)
Inductive Opcode : Type :=
  | OpPush   (v : Value)       (* ZKTrivial,        ~1 constraint  *)
  | OpAdd                      (* ZKCheap,          ~30 constraints *)
  | OpSload  (slot : Slot)     (* ZKExpensive,      ~255 Poseidon   *)
  | OpSstore (slot : Slot)     (* ZKExpensive,      ~255 Poseidon   *)
  | OpCall   (target : Account). (* ZKVeryExpensive, ~20K R1CS      *)

(* A program is a sequence of opcodes.
   [Source: EvmExecutor.tla, line 31 -- Programs constant] *)
Definition Program := list Opcode.

(* ========================================== *)
(*     TRACE ENTRY TYPE                        *)
(* ========================================== *)

(* Trace entries record state-modifying operations for ZK witness generation.
   Each constructor corresponds to a case in the TLA+ TraceEntrySet.
   [Source: EvmExecutor.tla, lines 55-59 -- TraceEntrySet definition] *)
Inductive TraceEntry : Type :=
  | TrSload  (acct : Account) (slot : Slot) (val : Value)
      (* SLOAD trace: account, slot, value read.
         [Source: EvmExecutor.tla, line 56] *)
  | TrSstore (acct : Account) (slot : Slot) (oldv newv : Value)
      (* SSTORE trace: account, slot, old value, new value.
         [Source: EvmExecutor.tla, lines 57-58] *)
  | TrCall   (from to : Account) (val : Value).
      (* CALL trace: caller, callee, value transferred.
         [Source: EvmExecutor.tla, line 59] *)

(* ========================================== *)
(*     TRACE OPERATION DISCRIMINATOR           *)
(* ========================================== *)

(* Discriminator for trace entry types. Used for counting in
   the TraceCompleteness property.
   [Source: EvmExecutor.tla, lines 383-388 -- CountInProgram/CountInTrace helpers] *)
Inductive TraceOp : Type :=
  | TOSload
  | TOSstore
  | TOCall.

(* Decidable boolean equality for TraceOp. *)
Definition TraceOp_eqb (a b : TraceOp) : bool :=
  match a, b with
  | TOSload, TOSload   => true
  | TOSstore, TOSstore => true
  | TOCall, TOCall     => true
  | _, _               => false
  end.

Lemma TraceOp_eqb_refl : forall t, TraceOp_eqb t t = true.
Proof. destruct t; reflexivity. Qed.

(* Extract the operation type from a trace entry.
   [Source: EvmExecutor.tla, lines 55-59 -- op field of TraceEntrySet] *)
Definition trace_entry_op (e : TraceEntry) : TraceOp :=
  match e with
  | TrSload _ _ _    => TOSload
  | TrSstore _ _ _ _ => TOSstore
  | TrCall _ _ _     => TOCall
  end.

(* Map an opcode to its trace operation type, if state-modifying.
   Returns None for non-state-modifying opcodes (PUSH, ADD).
   [Source: EvmExecutor.tla -- ExecPush/ExecAdd have UNCHANGED trace;
    ExecSload/ExecSstore/ExecCall append to trace] *)
Definition opcode_trace_op (op : Opcode) : option TraceOp :=
  match op with
  | OpPush _   => None
  | OpAdd      => None
  | OpSload _  => Some TOSload
  | OpSstore _ => Some TOSstore
  | OpCall _   => Some TOCall
  end.

(* ========================================== *)
(*     STORAGE MODEL                           *)
(* ========================================== *)

(* Storage is a total function from slot to value.
   [Source: EvmExecutor.tla, line 86 -- storage: [StorageSlots -> 0..MaxValue]] *)
Definition Storage := Slot -> Value.

(* Update a single slot in storage.
   [Source: EvmExecutor.tla, line 263 -- EXCEPT ![target].storage[slot] = newValue] *)
Definition storage_update (st : Storage) (slot : Slot) (val : Value) : Storage :=
  fun s => if Nat.eqb s slot then val else st s.

(* ========================================== *)
(*     EXECUTION CONTEXT                       *)
(* ========================================== *)

(* Simplified execution context: the executing contract and its storage.
   The full TLA+ state includes accountState with balances and nonces,
   but these fields are not needed for Determinism or TraceCompleteness.

   [Source: EvmExecutor.tla, lines 64-76 -- VARIABLES (simplified)] *)
Record ExecCtx := mkExecCtx {
  ctx_to      : Account;   (* Executing contract address -- currentTx.to *)
  ctx_storage : Storage;   (* Current contract storage *)
}.

(* ========================================== *)
(*     SINGLE-STEP EXECUTION FUNCTION          *)
(* ========================================== *)

(* Execute a single opcode, returning the new stack, optional trace entry,
   and updated storage. Returns None on stack underflow/overflow.

   This is a total FUNCTION, not a relation. Determinism follows
   immediately: the same inputs always produce the same output.

   Each case corresponds to a TLA+ action:
   - OpPush  -> ExecPush   (EvmExecutor.tla, lines 190-197)
   - OpAdd   -> ExecAdd    (EvmExecutor.tla, lines 203-215)
   - OpSload -> ExecSload  (EvmExecutor.tla, lines 224-240)
   - OpSstore-> ExecSstore (EvmExecutor.tla, lines 247-266)
   - OpCall  -> ExecCall   (EvmExecutor.tla, lines 277-306) *)
Definition exec_opcode (ctx : ExecCtx) (op : Opcode) (stack : list Value)
  : option (list Value * option TraceEntry * Storage) :=
  match op with
  (* PUSH: Push constant onto stack. No trace entry.
     [Source: EvmExecutor.tla, lines 190-197 -- UNCHANGED trace] *)
  | OpPush v =>
    Some (v :: stack, None, ctx_storage ctx)

  (* ADD: Pop two values, push their sum. No trace entry.
     [Source: EvmExecutor.tla, lines 203-215 -- UNCHANGED trace]
     Note: TLA+ uses modular arithmetic (a+b) mod (MaxValue+1).
     We use nat addition; this does not affect trace properties. *)
  | OpAdd =>
    match stack with
    | a :: b :: rest =>
      Some ((a + b) :: rest, None, ctx_storage ctx)
    | _ => None
    end

  (* SLOAD: Load storage value onto stack. Generates SLOAD trace entry.
     [Source: EvmExecutor.tla, lines 224-240 -- Append(trace, traceEntry)] *)
  | OpSload slot =>
    let val := ctx_storage ctx slot in
    let entry := TrSload (ctx_to ctx) slot val in
    Some (val :: stack, Some entry, ctx_storage ctx)

  (* SSTORE: Pop value and write to storage. Generates SSTORE trace entry.
     [Source: EvmExecutor.tla, lines 247-266 -- Append(trace, traceEntry)] *)
  | OpSstore slot =>
    match stack with
    | v :: rest =>
      let old_val := ctx_storage ctx slot in
      let new_st := storage_update (ctx_storage ctx) slot v in
      let entry := TrSstore (ctx_to ctx) slot old_val v in
      Some (rest, Some entry, new_st)
    | _ => None
    end

  (* CALL: Transfer value to target. Always generates CALL trace entry.
     Simplified: always succeeds (pushes 1). The TLA+ spec checks balance
     sufficiency, but the trace entry is generated regardless of outcome
     (EvmExecutor.tla line 304), so this simplification is safe for
     TraceCompleteness.
     [Source: EvmExecutor.tla, lines 277-306 -- Append(trace, callTrace)] *)
  | OpCall target =>
    match stack with
    | v :: rest =>
      let entry := TrCall (ctx_to ctx) target v in
      Some (1 :: rest, Some entry, ctx_storage ctx)
    | _ => None
    end
  end.

(* ========================================== *)
(*     FULL PROGRAM EXECUTION                  *)
(* ========================================== *)

(* Execute a complete program (list of opcodes) starting from the given
   context, stack, and accumulated trace. Returns the final stack, trace,
   and context, or None if any opcode guard fails.

   This models the execution loop in EvmExecutor.tla:
   - pc starts at 1, advances each step
   - Executing guard (phase = "executing", pc in range)
   - FinishTx fires when pc > Len(program)

   [Source: EvmExecutor.tla, lines 136-143, 317-332] *)
Fixpoint run_program (ctx : ExecCtx) (prog : Program) (stack : list Value)
  (acc_trace : list TraceEntry)
  : option (list Value * list TraceEntry * ExecCtx) :=
  match prog with
  | [] => Some (stack, acc_trace, ctx)
  | op :: rest =>
    match exec_opcode ctx op stack with
    | None => None
    | Some (new_stack, maybe_entry, new_storage) =>
      let new_trace := match maybe_entry with
                       | None => acc_trace
                       | Some e => acc_trace ++ [e]
                       end in
      let new_ctx := mkExecCtx (ctx_to ctx) new_storage in
      run_program new_ctx rest new_stack new_trace
    end
  end.

(* ========================================== *)
(*     COUNTING FUNCTIONS                      *)
(* ========================================== *)

(* Count trace entries of a given operation type.
   Coq counterpart of TLA+ CountInTrace helper.
   [Source: EvmExecutor.tla, lines 387-388] *)
Definition count_trace_type (tr : list TraceEntry) (top : TraceOp) : nat :=
  count_pred (fun e => TraceOp_eqb (trace_entry_op e) top) tr.

(* Count opcodes that would produce a given trace operation type.
   Coq counterpart of TLA+ CountInProgram helper.
   [Source: EvmExecutor.tla, lines 383-384] *)
Definition count_opcode_type (prog : Program) (top : TraceOp) : nat :=
  count_pred (fun op => match opcode_trace_op op with
                        | None => false
                        | Some t => TraceOp_eqb t top
                        end) prog.

(* count_opcode_type unfolds one step for a cons list. *)
Lemma count_opcode_type_cons : forall op rest top,
  count_opcode_type (op :: rest) top =
  (if match opcode_trace_op op with None => false | Some t => TraceOp_eqb t top end
   then 1 else 0) + count_opcode_type rest top.
Proof.
  intros. reflexivity.
Qed.

(* count_trace_type distributes over app. *)
Lemma count_trace_type_app : forall tr1 tr2 top,
  count_trace_type (tr1 ++ tr2) top = count_trace_type tr1 top + count_trace_type tr2 top.
Proof.
  intros. unfold count_trace_type. apply count_pred_app.
Qed.

(* count_trace_type of a singleton. *)
Lemma count_trace_type_singleton : forall e top,
  count_trace_type [e] top = if TraceOp_eqb (trace_entry_op e) top then 1 else 0.
Proof.
  intros. unfold count_trace_type. simpl. lia.
Qed.

(* ========================================== *)
(*     PROPERTY STATEMENTS                     *)
(* ========================================== *)

(* Property 1: Determinism (single step).
   exec_opcode is a Coq function, so determinism holds by construction:
   the same inputs always produce the same output.
   [Source: EvmExecutor.tla, lines 369-372 -- Determinism invariant] *)
Definition Determinism_step :=
  forall ctx op stack r1 r2,
    exec_opcode ctx op stack = Some r1 ->
    exec_opcode ctx op stack = Some r2 ->
    r1 = r2.

(* Property 1b: Determinism (full program). *)
Definition Determinism_program :=
  forall ctx prog stack trace r1 r2,
    run_program ctx prog stack trace = Some r1 ->
    run_program ctx prog stack trace = Some r2 ->
    r1 = r2.

(* Property 2: Trace Completeness.
   After executing a complete program, the number of trace entries of each
   type equals the number of corresponding opcodes in the program.
   [Source: EvmExecutor.tla, lines 390-397 -- TraceCompleteness invariant] *)
Definition TraceCompleteness :=
  forall ctx prog stack stack' trace' ctx',
    run_program ctx prog stack [] = Some (stack', trace', ctx') ->
    forall top,
      count_trace_type trace' top = count_opcode_type prog top.

(* Property 3: Trace entry type matches opcode type.
   When exec_opcode generates a trace entry, its discriminator matches
   the opcode's trace operation type. *)
Definition TraceTypeCorrectness :=
  forall ctx op stack stack' entry storage',
    exec_opcode ctx op stack = Some (stack', Some entry, storage') ->
    opcode_trace_op op = Some (trace_entry_op entry).

(* Property 4: Non-state-modifying opcodes produce no trace entry. *)
Definition NonModifyingNoTrace :=
  forall ctx op stack stack' storage',
    exec_opcode ctx op stack = Some (stack', None, storage') ->
    opcode_trace_op op = None.
