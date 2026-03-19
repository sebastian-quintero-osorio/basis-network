(* ========================================== *)
(*     Impl.v -- Rust Implementation Model     *)
(*     Abstract Model of witness generator     *)
(*     Rust code (generator.rs + modules)      *)
(*     zkl2/proofs/units/2026-03-witness-generation *)
(* ========================================== *)

(* This file models the Rust implementation of the witness generator.

   The key architectural difference from the TLA+ spec:

   TLA+ (Spec.v):
     ProcessArithEntry | ProcessStorageRead | ProcessStorageWrite |
     ProcessCallEntry | ProcessSkipEntry -- mutually exclusive guards.

   Rust (this file):
     For each entry, dispatch to ALL three table generators.
     Each generator returns empty for non-matching ops.
     The combined effect is identical to the spec's exclusive dispatch.

   Rust Result<T,E> modeling:
     We model the successful execution path. Errors (InvalidHex,
     RowWidthMismatch, etc.) are precondition violations that do not
     affect structural properties. Result<T,E> is modeled as the
     unwrapped T on the happy path.

   Source: generator.rs, arithmetic.rs, storage.rs, call_context.rs
           (frozen in 0-input-impl/) *)

From WG Require Import Common.
From WG Require Import Spec.
From Stdlib Require Import List.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
Import ListNotations.

(* ========================================== *)
(*     DISPATCH FUNCTIONS                      *)
(* ========================================== *)

(* Models arithmetic::process_entry() return value.
   Returns 1 row for BALANCE_CHANGE/NONCE_CHANGE, 0 rows otherwise.
   Rust: match entry.op { BalanceChange => Ok(vec![row]), ... _ => Ok(vec![]) }
   [Source: arithmetic.rs lines 41-77] *)
Definition arith_dispatch (op : op_type) (gc width idx : nat)
  : list witness_row :=
  if is_arith_op op then [mkRow gc width idx] else [].

(* Models storage::process_entry() return value.
   Returns 1 row for SLOAD, 2 rows for SSTORE, 0 otherwise.
   Rust: match entry.op { SLOAD => Ok(vec![row]), SSTORE => Ok(vec![row1,row2]), _ => Ok(vec![]) }
   [Source: storage.rs lines 68-143] *)
Definition storage_dispatch (op : op_type) (gc width idx : nat)
  : list witness_row :=
  if is_storage_read_op op then [mkRow gc width idx]
  else if is_storage_write_op op then [mkRow gc width idx; mkRow gc width idx]
  else [].

(* Models call_context::process_entry() return value.
   Returns 1 row for CALL, 0 rows otherwise.
   Rust: match entry.op { CALL => Ok(vec![row]), _ => Ok(vec![]) }
   [Source: call_context.rs lines 37-61] *)
Definition call_dispatch (op : op_type) (gc width idx : nat)
  : list witness_row :=
  if is_call_op op then [mkRow gc width idx] else [].

(* ========================================== *)
(*     IMPLEMENTATION STEP                     *)
(* ========================================== *)

(* The implementation processes each entry by dispatching to all three
   table generators simultaneously. This models the sequential for-loop
   in generator::generate() (lines 95-121).

   The state type is reused from Spec (both maintain identical fields).
   The dispatch mechanism differs: spec uses exclusive guards, impl
   dispatches to all generators and concatenates results. *)

Inductive impl_step : spec_state -> spec_state -> Prop :=
  | ImProcess : forall s e,
      sp_idx s < trace_len ->
      nth_error Trace (sp_idx s) = Some e ->
      impl_step s (mkSpecState
        (sp_idx s + 1)
        (sp_arith_rows s ++
          arith_dispatch (entry_op e)
            (sp_global_counter s) ArithColCount (sp_idx s))
        (sp_storage_rows s ++
          storage_dispatch (entry_op e)
            (sp_global_counter s) StorageColCount (sp_idx s))
        (sp_call_rows s ++
          call_dispatch (entry_op e)
            (sp_global_counter s) CallColCount (sp_idx s))
        (sp_global_counter s + 1)).

(* ========================================== *)
(*     INITIAL STATE EQUIVALENCE               *)
(* ========================================== *)

(* Implementation and specification share the same initial state.
   Both start with empty tables and counter = 0.
   [Source: generator.rs lines 85-91 -- Init] *)
Lemma init_equiv : spec_init = spec_init.
Proof. reflexivity. Qed.

(* ========================================== *)
(*     REFINEMENT                              *)
(* ========================================== *)

(* Every implementation step corresponds to a valid specification step.
   The proof is by case analysis on the operation type, showing that
   the dispatch-all-three pattern produces the same result as the
   spec's exclusive dispatch.

   This is the core refinement theorem: Impl refines Spec. *)
Theorem refinement_step : forall s s',
  impl_step s s' ->
  spec_step s s'.
Proof.
  intros s s' Hstep.
  inversion Hstep; subst.
  unfold arith_dispatch, storage_dispatch, call_dispatch.
  (* Find the trace entry introduced by inversion and case-split its op *)
  match goal with
  | [ H2 : nth_error Trace (sp_idx ?s0) = Some ?e |- _ ] =>
    destruct (entry_op e) eqn:Eop;
    simpl; rewrite ?app_nil_r;
    [ apply (SpProcessArith s0 e)
    | apply (SpProcessArith s0 e)
    | apply (SpProcessStorageRead s0 e)
    | apply (SpProcessStorageWrite s0 e)
    | apply (SpProcessCall s0 e)
    | apply (SpProcessSkip s0 e) ];
    auto; try (rewrite Eop; reflexivity);
    try (unfold is_witness_op; rewrite Eop; reflexivity)
  end.
Qed.
