(* ========================================== *)
(*     Spec.v -- TLA+ Specification Model      *)
(*     Faithful Translation of                 *)
(*     WitnessGeneration.tla                   *)
(*     zkl2/proofs/units/2026-03-witness-generation *)
(* ========================================== *)

(* This file faithfully translates the TLA+ specification of the
   witness generation pipeline into Coq definitions. The specification
   models sequential, deterministic dispatch of EVM trace entries to
   three witness tables: arithmetic, storage, and call context.

   Every definition is tagged with its source in WitnessGeneration.tla.

   Key design choices for Coq modeling:
   - Operation types are a finite Inductive (6 constructors)
   - Classification predicates are decidable boolean functions
   - Witness rows carry metadata (gc, width, srcIdx) not field elements
   - Trace is a parameter (list of trace entries)

   [Source: zkl2/specs/units/2026-03-witness-generation/1-formalization/
    v0-analysis/specs/WitnessGeneration/WitnessGeneration.tla] *)

From WG Require Import Common.
From Stdlib Require Import List.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
Import ListNotations.

(* ========================================== *)
(*     OPERATION TYPES                         *)
(* ========================================== *)

(* Models TLA+ OpTypes constant. The operation types are partitioned
   into five disjoint classes determining dispatch behavior.
   [Source: WitnessGeneration.tla lines 22-28] *)
Inductive op_type : Type :=
  | OpBalanceChange   (* ArithOps *)
  | OpNonceChange     (* ArithOps *)
  | OpSLOAD           (* StorageReadOps *)
  | OpSSTORE          (* StorageWriteOps *)
  | OpCALL            (* CallOps *)
  | OpLOG.            (* Not in WitnessOps -- skipped *)

(* Classification predicates.
   Each returns true iff the operation belongs to the named set.
   [Source: WitnessGeneration.tla lines 25-28] *)

(* ArithOps == {BALANCE_CHANGE, NONCE_CHANGE} *)
Definition is_arith_op (op : op_type) : bool :=
  match op with OpBalanceChange | OpNonceChange => true | _ => false end.

(* StorageReadOps == {SLOAD} *)
Definition is_storage_read_op (op : op_type) : bool :=
  match op with OpSLOAD => true | _ => false end.

(* StorageWriteOps == {SSTORE} *)
Definition is_storage_write_op (op : op_type) : bool :=
  match op with OpSSTORE => true | _ => false end.

(* CallOps == {CALL} *)
Definition is_call_op (op : op_type) : bool :=
  match op with OpCALL => true | _ => false end.

(* WitnessOps == ArithOps U StorageReadOps U StorageWriteOps U CallOps
   [Source: WitnessGeneration.tla line 68] *)
Definition is_witness_op (op : op_type) : bool :=
  is_arith_op op || is_storage_read_op op ||
  is_storage_write_op op || is_call_op op.

(* ========================================== *)
(*     PARTITION LEMMAS                        *)
(* ========================================== *)

(* Mutual exclusion of operation type sets, corresponding to the
   TLA+ ASSUME block (lines 39-51). Proved by exhaustive case analysis. *)

Lemma arith_not_sread : forall op,
  is_arith_op op = true -> is_storage_read_op op = false.
Proof. destruct op; simpl; discriminate || reflexivity. Qed.

Lemma arith_not_swrite : forall op,
  is_arith_op op = true -> is_storage_write_op op = false.
Proof. destruct op; simpl; discriminate || reflexivity. Qed.

Lemma arith_not_call : forall op,
  is_arith_op op = true -> is_call_op op = false.
Proof. destruct op; simpl; discriminate || reflexivity. Qed.

Lemma sread_not_arith : forall op,
  is_storage_read_op op = true -> is_arith_op op = false.
Proof. destruct op; simpl; discriminate || reflexivity. Qed.

Lemma sread_not_swrite : forall op,
  is_storage_read_op op = true -> is_storage_write_op op = false.
Proof. destruct op; simpl; discriminate || reflexivity. Qed.

Lemma sread_not_call : forall op,
  is_storage_read_op op = true -> is_call_op op = false.
Proof. destruct op; simpl; discriminate || reflexivity. Qed.

Lemma swrite_not_arith : forall op,
  is_storage_write_op op = true -> is_arith_op op = false.
Proof. destruct op; simpl; discriminate || reflexivity. Qed.

Lemma swrite_not_sread : forall op,
  is_storage_write_op op = true -> is_storage_read_op op = false.
Proof. destruct op; simpl; discriminate || reflexivity. Qed.

Lemma swrite_not_call : forall op,
  is_storage_write_op op = true -> is_call_op op = false.
Proof. destruct op; simpl; discriminate || reflexivity. Qed.

Lemma call_not_arith : forall op,
  is_call_op op = true -> is_arith_op op = false.
Proof. destruct op; simpl; discriminate || reflexivity. Qed.

Lemma call_not_sread : forall op,
  is_call_op op = true -> is_storage_read_op op = false.
Proof. destruct op; simpl; discriminate || reflexivity. Qed.

Lemma call_not_swrite : forall op,
  is_call_op op = true -> is_storage_write_op op = false.
Proof. destruct op; simpl; discriminate || reflexivity. Qed.

(* Exhaustive classification: every op belongs to exactly one class.
   Corresponds to TLA+ DeterminismGuard (S5, lines 297-305). *)
Lemma op_classification : forall op,
  (is_arith_op op = true /\ is_storage_read_op op = false /\
   is_storage_write_op op = false /\ is_call_op op = false) \/
  (is_arith_op op = false /\ is_storage_read_op op = true /\
   is_storage_write_op op = false /\ is_call_op op = false) \/
  (is_arith_op op = false /\ is_storage_read_op op = false /\
   is_storage_write_op op = true /\ is_call_op op = false) \/
  (is_arith_op op = false /\ is_storage_read_op op = false /\
   is_storage_write_op op = false /\ is_call_op op = true) \/
  (is_arith_op op = false /\ is_storage_read_op op = false /\
   is_storage_write_op op = false /\ is_call_op op = false).
Proof.
  destruct op; simpl.
  - left; auto.
  - left; auto.
  - right; left; auto.
  - right; right; left; auto.
  - right; right; right; left; auto.
  - right; right; right; right; auto.
Qed.

Lemma not_witness_from_parts : forall op,
  is_arith_op op = false ->
  is_storage_read_op op = false ->
  is_storage_write_op op = false ->
  is_call_op op = false ->
  is_witness_op op = false.
Proof.
  intros op Ha Hsr Hsw Hc.
  unfold is_witness_op. rewrite Ha, Hsr, Hsw, Hc. reflexivity.
Qed.

Lemma not_witness_implies : forall op,
  is_witness_op op = false ->
  is_arith_op op = false /\ is_storage_read_op op = false /\
  is_storage_write_op op = false /\ is_call_op op = false.
Proof. destruct op; simpl; intro H; try discriminate; auto. Qed.

(* ========================================== *)
(*     TRACE AND ROW TYPES                     *)
(* ========================================== *)

(* Simplified trace entry: only the operation type matters for
   structural verification. Field element values are abstracted away.
   [Source: WitnessGeneration.tla line 23 -- Trace[i].op] *)
Record trace_entry := mkEntry {
  entry_op : op_type;
}.

(* Abstract witness row with metadata for verification.
   Models TLA+ MakeRow(gc, width, sourceIdx).
   [Source: WitnessGeneration.tla line 131] *)
Record witness_row := mkRow {
  row_gc : nat;
  row_width : nat;
  row_src_idx : nat;
}.

(* ========================================== *)
(*     CONSTANTS (Parameters)                  *)
(* ========================================== *)

(* The trace to process. Models TLA+ CONSTANT Trace.
   [Source: WitnessGeneration.tla line 23] *)
Parameter Trace : list trace_entry.

(* Column counts for each table. Models TLA+ CONSTANTS.
   [Source: WitnessGeneration.tla lines 29-31] *)
Parameter ArithColCount : nat.
Parameter StorageColCount : nat.
Parameter CallColCount : nat.

Axiom ArithColCount_pos : ArithColCount > 0.
Axiom StorageColCount_pos : StorageColCount > 0.
Axiom CallColCount_pos : CallColCount > 0.

(* Derived constant.
   [Source: WitnessGeneration.tla line 64] *)
Definition trace_len : nat := length Trace.

(* ========================================== *)
(*     SPECIFICATION STATE                     *)
(* ========================================== *)

(* Models TLA+ variables:
     << idx, arithRows, storageRows, callRows, globalCounter >>
   Uses 0-based indexing (TLA+ uses 1-based; adjusted here).
   [Source: WitnessGeneration.tla lines 77-83] *)
Record spec_state := mkSpecState {
  sp_idx : nat;
  sp_arith_rows : list witness_row;
  sp_storage_rows : list witness_row;
  sp_call_rows : list witness_row;
  sp_global_counter : nat;
}.

(* ========================================== *)
(*     INITIAL STATE                           *)
(* ========================================== *)

(* [Source: WitnessGeneration.tla lines 110-115] *)
Definition spec_init : spec_state :=
  mkSpecState 0 [] [] [] 0.

(* ========================================== *)
(*     STEP RELATION                           *)
(* ========================================== *)

(* The next-state relation. Each constructor corresponds to one TLA+ action.
   The guards are mutually exclusive (proved in DeterminismGuard S5).
   [Source: WitnessGeneration.tla lines 218-224, Next] *)
Inductive spec_step : spec_state -> spec_state -> Prop :=

  (* ProcessArithEntry: BALANCE_CHANGE or NONCE_CHANGE -> 1 arith row.
     [Source: WitnessGeneration.tla lines 142-149] *)
  | SpProcessArith : forall s e,
      sp_idx s < trace_len ->
      nth_error Trace (sp_idx s) = Some e ->
      is_arith_op (entry_op e) = true ->
      spec_step s (mkSpecState
        (sp_idx s + 1)
        (sp_arith_rows s ++ [mkRow (sp_global_counter s) ArithColCount (sp_idx s)])
        (sp_storage_rows s)
        (sp_call_rows s)
        (sp_global_counter s + 1))

  (* ProcessStorageRead: SLOAD -> 1 storage row.
     [Source: WitnessGeneration.tla lines 155-162] *)
  | SpProcessStorageRead : forall s e,
      sp_idx s < trace_len ->
      nth_error Trace (sp_idx s) = Some e ->
      is_storage_read_op (entry_op e) = true ->
      spec_step s (mkSpecState
        (sp_idx s + 1)
        (sp_arith_rows s)
        (sp_storage_rows s ++ [mkRow (sp_global_counter s) StorageColCount (sp_idx s)])
        (sp_call_rows s)
        (sp_global_counter s + 1))

  (* ProcessStorageWrite: SSTORE -> 2 storage rows (old + new Merkle path).
     Both rows share the same global counter (same source entry).
     [Source: WitnessGeneration.tla lines 170-179] *)
  | SpProcessStorageWrite : forall s e,
      sp_idx s < trace_len ->
      nth_error Trace (sp_idx s) = Some e ->
      is_storage_write_op (entry_op e) = true ->
      spec_step s (mkSpecState
        (sp_idx s + 1)
        (sp_arith_rows s)
        (sp_storage_rows s ++
          [mkRow (sp_global_counter s) StorageColCount (sp_idx s);
           mkRow (sp_global_counter s) StorageColCount (sp_idx s)])
        (sp_call_rows s)
        (sp_global_counter s + 1))

  (* ProcessCallEntry: CALL -> 1 call context row.
     [Source: WitnessGeneration.tla lines 185-192] *)
  | SpProcessCall : forall s e,
      sp_idx s < trace_len ->
      nth_error Trace (sp_idx s) = Some e ->
      is_call_op (entry_op e) = true ->
      spec_step s (mkSpecState
        (sp_idx s + 1)
        (sp_arith_rows s)
        (sp_storage_rows s)
        (sp_call_rows s ++ [mkRow (sp_global_counter s) CallColCount (sp_idx s)])
        (sp_global_counter s + 1))

  (* ProcessSkipEntry: LOG or other non-witness op -> no rows.
     Global counter still increments (one per entry).
     [Source: WitnessGeneration.tla lines 197-204] *)
  | SpProcessSkip : forall s e,
      sp_idx s < trace_len ->
      nth_error Trace (sp_idx s) = Some e ->
      is_witness_op (entry_op e) = false ->
      spec_step s (mkSpecState
        (sp_idx s + 1)
        (sp_arith_rows s)
        (sp_storage_rows s)
        (sp_call_rows s)
        (sp_global_counter s + 1)).

(* ========================================== *)
(*     MULTI-STEP REACHABILITY                 *)
(* ========================================== *)

Inductive reachable : spec_state -> Prop :=
  | reach_init : reachable spec_init
  | reach_step : forall s s',
      reachable s -> spec_step s s' -> reachable s'.

(* ========================================== *)
(*     COUNT ABBREVIATION                      *)
(* ========================================== *)

(* Count ops of a given type in the first n entries of Trace.
   Used throughout the invariant and safety properties. *)
Definition count_in_prefix (p : op_type -> bool) (n : nat) : nat :=
  count_pred p (map entry_op (take n Trace)).

(* ========================================== *)
(*     SAFETY PROPERTY DEFINITIONS             *)
(* ========================================== *)

(* --- S1: Completeness ---
   Every trace entry that belongs to a witness-producing operation
   generates the correct number of rows in the corresponding table.
   [Source: WitnessGeneration.tla lines 242-253] *)
Definition completeness (s : spec_state) : Prop :=
  sp_idx s = trace_len ->
  length (sp_arith_rows s) =
    count_in_prefix is_arith_op (sp_idx s) /\
  length (sp_storage_rows s) =
    count_in_prefix is_storage_read_op (sp_idx s) +
    2 * count_in_prefix is_storage_write_op (sp_idx s) /\
  length (sp_call_rows s) =
    count_in_prefix is_call_op (sp_idx s).

(* --- S2: Soundness (Source Traceability) ---
   Every witness row traces back to a valid source entry whose
   operation type matches the table.
   [Source: WitnessGeneration.tla lines 260-269] *)
Definition soundness (s : spec_state) : Prop :=
  (forall r, In r (sp_arith_rows s) ->
    row_src_idx r < trace_len /\
    exists e, nth_error Trace (row_src_idx r) = Some e /\
              is_arith_op (entry_op e) = true) /\
  (forall r, In r (sp_storage_rows s) ->
    row_src_idx r < trace_len /\
    exists e, nth_error Trace (row_src_idx r) = Some e /\
              (is_storage_read_op (entry_op e) = true \/
               is_storage_write_op (entry_op e) = true)) /\
  (forall r, In r (sp_call_rows s) ->
    row_src_idx r < trace_len /\
    exists e, nth_error Trace (row_src_idx r) = Some e /\
              is_call_op (entry_op e) = true).

(* --- S3: Row Width Consistency ---
   Every row in a table has the correct column count.
   [Source: WitnessGeneration.tla lines 275-278] *)
Definition row_width_consistency (s : spec_state) : Prop :=
  (forall r, In r (sp_arith_rows s) -> row_width r = ArithColCount) /\
  (forall r, In r (sp_storage_rows s) -> row_width r = StorageColCount) /\
  (forall r, In r (sp_call_rows s) -> row_width r = CallColCount).

(* --- S4: Global Counter Monotonicity ---
   The global counter equals the number of entries processed.
   [Source: WitnessGeneration.tla lines 286-287] *)
Definition global_counter_monotonic (s : spec_state) : Prop :=
  sp_global_counter s = sp_idx s.

(* --- S5: Determinism Guard ---
   For each entry, exactly one dispatch branch is enabled.
   [Source: WitnessGeneration.tla lines 297-305] *)
Definition determinism_guard : Prop :=
  forall op : op_type,
    let enabled :=
      (if is_arith_op op then 1 else 0) +
      (if is_storage_read_op op then 1 else 0) +
      (if is_storage_write_op op then 1 else 0) +
      (if is_call_op op then 1 else 0) +
      (if negb (is_witness_op op) then 1 else 0)
    in enabled = 1.

(* --- S6: Sequential Processing Order ---
   Source indices are ordered within each table.
   [Source: WitnessGeneration.tla lines 312-317] *)
Definition sequential_order (s : spec_state) : Prop :=
  strictly_increasing (map row_src_idx (sp_arith_rows s)) /\
  non_decreasing (map row_src_idx (sp_storage_rows s)) /\
  strictly_increasing (map row_src_idx (sp_call_rows s)).
