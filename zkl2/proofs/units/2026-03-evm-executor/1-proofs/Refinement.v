(* ========================================== *)
(*     Refinement.v -- Verification Proofs     *)
(*     Implementation Refines Specification    *)
(*     zkl2/proofs/units/2026-03-evm-executor  *)
(* ========================================== *)

(* This file proves the core properties of the EVM Executor:

   1. determinism_step        : Single-step execution is deterministic
   2. determinism_program     : Full program execution is deterministic
   3. trace_type_correctness  : Trace entry types match opcode types
   4. non_modifying_no_trace  : Non-modifying opcodes produce no trace
   5. trace_completeness_gen  : Generalized trace completeness (inductive)
   6. trace_completeness      : Trace entry counts match opcode counts
   7. refinement_step         : Impl step = Spec step
   8. refinement_program      : Impl program = Spec program
   9. impl_determinism        : Implementation is deterministic
  10. impl_trace_completeness : Implementation satisfies TraceCompleteness

   All theorems are proved without Admitted.

   Source: EvmExecutor.tla (spec), executor.go + tracer.go (impl) *)

From EvmExecutor Require Import Common.
From EvmExecutor Require Import Spec.
From EvmExecutor Require Import Impl.
From Stdlib Require Import List.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
Import ListNotations.

(* ========================================== *)
(*     THEOREM 1: DETERMINISM (SINGLE STEP)    *)
(* ========================================== *)

(* exec_opcode is a Coq function, so determinism holds by construction.
   Given the same inputs, it always returns the same output.

   This corresponds to the Determinism invariant in EvmExecutor.tla
   (lines 369-372): "same tx + same pre-state => same post-state + same trace"

   In the TLA+ spec, determinism follows from the fact that each ExecX
   action is a pure function of the current state. Here, it follows
   from Coq's functional evaluation semantics. *)
Theorem determinism_step : Determinism_step.
Proof.
  unfold Determinism_step.
  intros ctx op stack r1 r2 H1 H2.
  rewrite H1 in H2.
  injection H2 as H2.
  exact H2.
Qed.

(* ========================================== *)
(*     THEOREM 2: DETERMINISM (FULL PROGRAM)   *)
(* ========================================== *)

(* Full program execution is deterministic: same program on same initial
   state produces the same final state and trace. *)
Theorem determinism_program : Determinism_program.
Proof.
  unfold Determinism_program.
  intros ctx prog stack trace r1 r2 H1 H2.
  rewrite H1 in H2.
  injection H2 as H2.
  exact H2.
Qed.

(* ========================================== *)
(*     THEOREM 3: TRACE TYPE CORRECTNESS       *)
(* ========================================== *)

(* When exec_opcode generates a trace entry, its type matches the opcode's
   trace type. SLOAD opcodes produce TrSload entries, SSTORE produces
   TrSstore, and CALL produces TrCall.

   This ensures the trace is semantically correct: no opcode can produce
   a trace entry of the wrong type. *)
Theorem trace_type_correctness : TraceTypeCorrectness.
Proof.
  unfold TraceTypeCorrectness.
  intros ctx op stack stack' entry storage' H.
  destruct op as [v | | sl | sl | tgt]; simpl in H.
  - (* OpPush: returns None for trace, contradiction *)
    congruence.
  - (* OpAdd: returns None for trace or fails *)
    destruct stack as [| a [| b rest]]; congruence.
  - (* OpSload: entry = TrSload, opcode_trace_op = Some TOSload *)
    assert (entry = TrSload (ctx_to ctx) sl (ctx_storage ctx sl)) by congruence.
    subst. simpl. reflexivity.
  - (* OpSstore: entry = TrSstore or stack underflow *)
    destruct stack as [| w rest]; [congruence|].
    assert (entry = TrSstore (ctx_to ctx) sl (ctx_storage ctx sl) w) by congruence.
    subst. simpl. reflexivity.
  - (* OpCall: entry = TrCall or stack underflow *)
    destruct stack as [| w rest]; [congruence|].
    assert (entry = TrCall (ctx_to ctx) tgt w) by congruence.
    subst. simpl. reflexivity.
Qed.

(* ========================================== *)
(*     THEOREM 4: NON-MODIFYING NO TRACE       *)
(* ========================================== *)

(* Opcodes that do not modify state (PUSH, ADD) produce no trace entry.
   This is the converse of trace_type_correctness. *)
Theorem non_modifying_no_trace : NonModifyingNoTrace.
Proof.
  unfold NonModifyingNoTrace.
  intros ctx op stack stack' storage' H.
  destruct op as [v | | sl | sl | tgt]; simpl in H; simpl.
  - (* OpPush *) reflexivity.
  - (* OpAdd *)
    destruct stack as [| a [| b rest]]; congruence.
  - (* OpSload: always produces Some entry, contradiction *)
    congruence.
  - (* OpSstore: produces Some entry or fails *)
    destruct stack as [| w rest]; congruence.
  - (* OpCall: produces Some entry or fails *)
    destruct stack as [| w rest]; congruence.
Qed.

(* ========================================== *)
(*     HELPER: TRACE TYPE MATCH                *)
(* ========================================== *)

(* When exec_opcode produces a trace entry, the boolean equality
   of the entry's type with any target type equals the boolean
   equality of the opcode's trace type with the same target.

   This lemma bridges the single-step trace generation with the
   counting functions used in TraceCompleteness. *)
Lemma exec_opcode_trace_type_match :
  forall ctx op stack stack' entry storage' top,
  exec_opcode ctx op stack = Some (stack', Some entry, storage') ->
  TraceOp_eqb (trace_entry_op entry) top =
  match opcode_trace_op op with
  | None => false
  | Some t => TraceOp_eqb t top
  end.
Proof.
  intros ctx op stack stack' entry storage' top H.
  destruct op as [v | | sl | sl | tgt]; simpl in H.
  - (* OpPush *) congruence.
  - (* OpAdd *) destruct stack as [| a [| b rest]]; congruence.
  - (* OpSload *)
    assert (entry = TrSload (ctx_to ctx) sl (ctx_storage ctx sl)) by congruence.
    subst. simpl. reflexivity.
  - (* OpSstore *)
    destruct stack as [| w rest]; [congruence|].
    assert (entry = TrSstore (ctx_to ctx) sl (ctx_storage ctx sl) w) by congruence.
    subst. simpl. reflexivity.
  - (* OpCall *)
    destruct stack as [| w rest]; [congruence|].
    assert (entry = TrCall (ctx_to ctx) tgt w) by congruence.
    subst. simpl. reflexivity.
Qed.

(* When exec_opcode produces no trace entry, the opcode is non-modifying. *)
Lemma exec_opcode_no_trace_type :
  forall ctx op stack stack' storage',
  exec_opcode ctx op stack = Some (stack', None, storage') ->
  match opcode_trace_op op with
  | None => true
  | Some _ => false
  end = true.
Proof.
  intros ctx op stack stack' storage' H.
  destruct op as [v | | sl | sl | tgt]; simpl in H; simpl.
  - (* OpPush *) reflexivity.
  - (* OpAdd *)
    destruct stack as [| a [| b rest]]; congruence.
  - (* OpSload *) congruence.
  - (* OpSstore *) destruct stack as [| w rest]; congruence.
  - (* OpCall *) destruct stack as [| w rest]; congruence.
Qed.

(* ========================================== *)
(*     THEOREM 5: TRACE COMPLETENESS (GEN)     *)
(* ========================================== *)

(* Generalized trace completeness: the final trace count equals
   the initial trace count plus the opcode count in the program.

   Proof strategy: Induction on the program list.
   - Base case: empty program, trace unchanged, opcode count is 0.
   - Inductive step: execute one opcode, show the trace count change
     matches the opcode count contribution, then apply IH.

   For state-modifying opcodes (SLOAD, SSTORE, CALL):
     One trace entry is appended. Its type matches the opcode type
     (by exec_opcode_trace_type_match). Both counts increase by 1.

   For non-modifying opcodes (PUSH, ADD):
     No trace entry is appended. The opcode contributes 0 to the count
     (by exec_opcode_no_trace_type). Both counts unchanged. *)
Lemma trace_completeness_gen :
  forall prog ctx stack trace stack' trace' ctx',
  run_program ctx prog stack trace = Some (stack', trace', ctx') ->
  forall top,
    count_trace_type trace' top =
    count_trace_type trace top + count_opcode_type prog top.
Proof.
  induction prog as [| op rest IH];
    intros ctx stack trace stack' trace' ctx' Hrun top.
  - (* Base case: empty program *)
    simpl in Hrun.
    assert (Ht : trace' = trace) by congruence.
    rewrite Ht.
    assert (Ho : count_opcode_type [] top = 0) by reflexivity.
    rewrite Ho, Nat.add_0_r. reflexivity.
  - (* Inductive case: op :: rest *)
    simpl in Hrun.
    destruct (exec_opcode ctx op stack) as [[[new_stack [entry|]] new_storage]|] eqn:Hstep;
      try discriminate.
    + (* State-modifying opcode: entry generated *)
      specialize (IH _ _ _ _ _ _ Hrun top).
      rewrite IH.
      rewrite count_trace_type_app, count_trace_type_singleton.
      rewrite count_opcode_type_cons.
      pose proof (exec_opcode_trace_type_match _ _ _ _ _ _ top Hstep) as Hmatch.
      rewrite Hmatch.
      lia.
    + (* Non-state-modifying opcode: no entry *)
      specialize (IH _ _ _ _ _ _ Hrun top).
      rewrite IH.
      rewrite count_opcode_type_cons.
      pose proof (exec_opcode_no_trace_type _ _ _ _ _ Hstep) as Hno.
      destruct (opcode_trace_op op) as [t|]; [discriminate|].
      simpl. lia.
Qed.

(* ========================================== *)
(*     THEOREM 6: TRACE COMPLETENESS (MAIN)    *)
(* ========================================== *)

(* Main TraceCompleteness theorem: starting from an empty trace,
   executing a program produces a trace where the count of each
   operation type equals the count of corresponding opcodes.

   Coq equivalent of the TLA+ TraceCompleteness invariant:
     CountInTrace(r.executionTrace, "SLOAD")  = CountInProgram(r.tx.program, "SLOAD")
     CountInTrace(r.executionTrace, "SSTORE") = CountInProgram(r.tx.program, "SSTORE")
     CountInTrace(r.executionTrace, "CALL")   = CountInProgram(r.tx.program, "CALL")

   [Source: EvmExecutor.tla, lines 390-397] *)
Theorem trace_completeness : TraceCompleteness.
Proof.
  unfold TraceCompleteness.
  intros ctx prog stack stack' trace' ctx' Hrun top.
  exact (trace_completeness_gen prog ctx stack [] stack' trace' ctx' Hrun top).
Qed.

(* ========================================== *)
(*     THEOREM 7: IMPLEMENTATION REFINEMENT    *)
(* ========================================== *)

(* The implementation step function refines the specification step.
   For every implementation step, the spec step produces identical results.

   The refinement is exact equality: the hook-based trace generation
   in the Go implementation produces the same trace entries as the
   spec's inline construction. This follows from the tracer hook
   definitions being identical to the spec constructors:
     tracer_on_sload  acct slot val    = TrSload  acct slot val
     tracer_on_sstore acct slot old new = TrSstore acct slot old new
     tracer_on_call   from to val       = TrCall   from to val *)
Theorem refinement_step : forall ctx op stack,
  impl_exec_opcode ctx op stack = exec_opcode ctx op stack.
Proof.
  exact impl_exec_eq_spec.
Qed.

(* Full program execution refinement. *)
Theorem refinement_program : forall prog ctx stack trace,
  impl_run_program ctx prog stack trace = run_program ctx prog stack trace.
Proof.
  exact impl_run_eq_spec.
Qed.

(* ========================================== *)
(*     THEOREM 8: IMPL DETERMINISM             *)
(* ========================================== *)

(* The implementation is deterministic.
   Follows from refinement + spec determinism. *)
Theorem impl_determinism :
  forall ctx prog stack trace r1 r2,
  impl_run_program ctx prog stack trace = Some r1 ->
  impl_run_program ctx prog stack trace = Some r2 ->
  r1 = r2.
Proof.
  intros ctx prog stack trace r1 r2 H1 H2.
  rewrite impl_run_eq_spec in H1.
  rewrite impl_run_eq_spec in H2.
  rewrite H1 in H2.
  injection H2 as H2.
  exact H2.
Qed.

(* ========================================== *)
(*     THEOREM 9: IMPL TRACE COMPLETENESS      *)
(* ========================================== *)

(* The implementation satisfies TraceCompleteness.
   Follows from refinement + spec TraceCompleteness. *)
Theorem impl_trace_completeness :
  forall ctx prog stack stack' trace' ctx',
  impl_run_program ctx prog stack [] = Some (stack', trace', ctx') ->
  forall top,
    count_trace_type trace' top = count_opcode_type prog top.
Proof.
  intros ctx prog stack stack' trace' ctx' Hrun top.
  rewrite impl_run_eq_spec in Hrun.
  exact (trace_completeness ctx prog stack stack' trace' ctx' Hrun top).
Qed.

(* ========================================== *)
(*     VERIFICATION SUMMARY                    *)
(* ========================================== *)

(* All 10 theorems proved without Admitted:

   DETERMINISM
     1. determinism_step        -- Single opcode execution is deterministic
     2. determinism_program     -- Full program execution is deterministic

   TRACE INTEGRITY
     3. trace_type_correctness  -- Trace entry type matches opcode type
     4. non_modifying_no_trace  -- PUSH/ADD produce no trace entries

   TRACE COMPLETENESS
     5. trace_completeness_gen  -- Generalized (with initial trace accumulator)
     6. trace_completeness      -- Main theorem (empty initial trace)

   REFINEMENT (Impl refines Spec)
     7. refinement_step         -- Single-step equivalence
     8. refinement_program      -- Full program equivalence

   IMPL PROPERTIES (derived from refinement)
     9. impl_determinism        -- Implementation is deterministic
    10. impl_trace_completeness -- Implementation satisfies TraceCompleteness

   Proof Architecture:
     - Determinism is trivial from the functional definition (Coq functions
       are deterministic by construction).
     - TraceCompleteness is proved by induction on the program, using
       exec_opcode_trace_type_match to show trace entry types correspond
       to opcode types at each step.
     - Refinement is proved by showing the implementation's hook-based
       trace generation is definitionally equal to the spec's inline
       construction (the tracer hook functions are identity wrappers
       around the spec constructors).
     - Implementation properties follow directly from refinement +
       spec properties. *)
