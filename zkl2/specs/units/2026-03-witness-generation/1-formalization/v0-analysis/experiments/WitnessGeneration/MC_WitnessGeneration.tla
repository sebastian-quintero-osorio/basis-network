---- MODULE MC_WitnessGeneration ----
(*
 * Model checking instance for WitnessGeneration.
 *
 * Configuration: 2 transactions, 6 trace entries covering all 3 witness-producing
 * operation categories (arithmetic, storage, call) plus a silent operation (LOG).
 *
 * TX1: BALANCE_CHANGE -> SSTORE -> CALL
 *   - Exercises arithmetic dispatch, storage write (2 Merkle paths), call context
 * TX2: NONCE_CHANGE -> SLOAD -> LOG
 *   - Exercises arithmetic dispatch, storage read (1 Merkle path), skip (no rows)
 *
 * Expected witness at termination:
 *   arithRows:   2 rows (entries 1, 4)
 *   storageRows: 3 rows (entry 2 produces 2, entry 5 produces 1)
 *   callRows:    1 row  (entry 3)
 *   Total:       6 rows from 6 entries (5 witness-producing + 1 skipped)
 *)
EXTENDS WitnessGeneration

(* ========================================
              FINITE CONSTANT DEFINITIONS
   ======================================== *)

\* All operation types in the system
\* [Source: 0-input/code/src/types.rs, lines 16-23 -- TraceOp enum]
MC_OpTypes == {"BALANCE_CHANGE", "NONCE_CHANGE", "SLOAD", "SSTORE", "CALL", "LOG"}

\* Operations dispatched to the arithmetic table
\* [Source: 0-input/code/src/arithmetic.rs, lines 28-29 -- OP_BALANCE_CHANGE, OP_NONCE_CHANGE]
MC_ArithOps == {"BALANCE_CHANGE", "NONCE_CHANGE"}

\* Operations dispatched to the storage table (read path: 1 row)
\* [Source: 0-input/code/src/storage.rs, lines 55-77 -- SLOAD branch]
MC_StorageReadOps == {"SLOAD"}

\* Operations dispatched to the storage table (write path: 2 rows)
\* [Source: 0-input/code/src/storage.rs, lines 79-119 -- SSTORE branch]
MC_StorageWriteOps == {"SSTORE"}

\* Operations dispatched to the call context table
\* [Source: 0-input/code/src/call_context.rs, lines 27-28 -- CALL branch]
MC_CallOps == {"CALL"}

\* Column counts matching the reference implementation
\* [Source: 0-input/code/src/arithmetic.rs, lines 16-25 -- 8 columns]
MC_ArithColCount == 8

\* Storage: 10 fixed columns + 32 siblings (SmtDepth = 32, the default)
\* [Source: 0-input/code/src/storage.rs, lines 16-24 -- column_names(depth)]
MC_StorageColCount == 42

\* [Source: 0-input/code/src/call_context.rs, lines 13-22 -- 8 columns]
MC_CallColCount == 8

\* Input trace: 2 transactions x 3 entries each = 6 total entries
\* Covers every dispatch branch including the skip (LOG) path.
MC_Trace == <<
    [op |-> "BALANCE_CHANGE"],  \* TX1 entry 1: arithmetic table
    [op |-> "SSTORE"],          \* TX1 entry 2: storage table (2 rows)
    [op |-> "CALL"],            \* TX1 entry 3: call context table
    [op |-> "NONCE_CHANGE"],    \* TX2 entry 4: arithmetic table
    [op |-> "SLOAD"],           \* TX2 entry 5: storage table (1 row)
    [op |-> "LOG"]              \* TX2 entry 6: skipped (no witness rows)
>>

====
