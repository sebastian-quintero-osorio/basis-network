---- MODULE WitnessGeneration ----
(*
 * Formal specification of the witness generation pipeline for Basis Network zkEVM L2.
 *
 * Models WitnessExtract(trace) -> witness as a sequential, deterministic function
 * from EVM execution traces to multi-table witness data for ZK proof circuits.
 *
 * The witness generator dispatches each trace entry to the appropriate table
 * generator based on the operation type, producing rows of field elements.
 * Three tables: arithmetic (balance/nonce changes), storage (SLOAD/SSTORE with
 * Merkle proof paths), and call_context (CALL operations).
 *
 * [Source: 0-input/REPORT.md -- "Witness Generation from EVM Execution Traces"]
 * [Source: 0-input/code/src/generator.rs -- generate() function]
 * [Source: 0-input/hypothesis.json -- I-08 Trace-Witness Bijection]
 *)
EXTENDS Integers, Sequences, FiniteSets, TLC

(* ========================================
              CONSTANTS
   ======================================== *)
CONSTANTS
    Trace,              \* Sequence of trace entries: each entry is a record [op |-> OpType]
    OpTypes,            \* Set of all operation types (superset)
    ArithOps,           \* Subset: operations producing arithmetic rows (BALANCE_CHANGE, NONCE_CHANGE)
    StorageReadOps,     \* Subset: operations producing 1 storage row (SLOAD)
    StorageWriteOps,    \* Subset: operations producing 2 storage rows (SSTORE -- old + new Merkle path)
    CallOps,            \* Subset: operations producing call context rows (CALL)
    ArithColCount,      \* Number of columns in arithmetic table (8 in reference implementation)
    StorageColCount,    \* Number of columns in storage table (10 + SmtDepth in reference)
    CallColCount        \* Number of columns in call context table (8 in reference implementation)

(* ========================================
              ASSUMPTIONS
   ======================================== *)
\* [Why]: The operation type sets must form a partition of the witness-producing subset
\*        of OpTypes. Overlapping sets would cause duplicate row generation; gaps would
\*        cause silent entry drops. Both violate Completeness and Soundness.
ASSUME
    \* Operation type sets are subsets of the universal type set
    /\ ArithOps \subseteq OpTypes
    /\ StorageReadOps \subseteq OpTypes
    /\ StorageWriteOps \subseteq OpTypes
    /\ CallOps \subseteq OpTypes
    \* Mutual exclusion: no operation belongs to two tables
    /\ ArithOps \cap StorageReadOps = {}
    /\ ArithOps \cap StorageWriteOps = {}
    /\ ArithOps \cap CallOps = {}
    /\ StorageReadOps \cap StorageWriteOps = {}
    /\ StorageReadOps \cap CallOps = {}
    /\ StorageWriteOps \cap CallOps = {}
    \* Column counts are positive integers
    /\ ArithColCount > 0
    /\ StorageColCount > 0
    /\ CallColCount > 0
    \* All trace entries reference valid operation types
    /\ \A i \in 1..Len(Trace) : Trace[i].op \in OpTypes

(* ========================================
              DERIVED CONSTANTS
   ======================================== *)

\* Total number of trace entries to process
TraceLen == Len(Trace)

\* The set of operations that produce at least one witness row
\* [Source: 0-input/code/src/generator.rs, lines 79-94 -- dispatch logic]
WitnessOps == ArithOps \union StorageReadOps \union StorageWriteOps \union CallOps

\* The set of valid column counts (used in TypeOK)
AllColCounts == {ArithColCount, StorageColCount, CallColCount}

(* ========================================
              VARIABLES
   ======================================== *)
VARIABLES
    idx,            \* Current position in trace: 1..TraceLen+1 (TraceLen+1 = done)
    arithRows,      \* Sequence of arithmetic witness rows produced so far
    storageRows,    \* Sequence of storage witness rows produced so far
    callRows,       \* Sequence of call context witness rows produced so far
    globalCounter   \* Monotonically increasing counter for cross-table ordering

vars == << idx, arithRows, storageRows, callRows, globalCounter >>

(* ========================================
              TYPE INVARIANT
   ======================================== *)

\* [Why]: Establishes the domain of every variable. A type violation means the
\*        specification has a structural error in its state transitions.
TypeOK ==
    /\ idx \in 1..(TraceLen + 1)
    /\ globalCounter \in 0..TraceLen
    /\ Len(arithRows) \in 0..TraceLen
    /\ Len(storageRows) \in 0..(TraceLen * 2)
    /\ Len(callRows) \in 0..TraceLen
    /\ \A i \in 1..Len(arithRows) :
        arithRows[i] \in [gc: 0..(TraceLen - 1), width: AllColCounts, srcIdx: 1..TraceLen]
    /\ \A i \in 1..Len(storageRows) :
        storageRows[i] \in [gc: 0..(TraceLen - 1), width: AllColCounts, srcIdx: 1..TraceLen]
    /\ \A i \in 1..Len(callRows) :
        callRows[i] \in [gc: 0..(TraceLen - 1), width: AllColCounts, srcIdx: 1..TraceLen]

(* ========================================
              INITIAL STATE
   ======================================== *)

\* [Source: 0-input/code/src/generator.rs, lines 64-71 -- "Initialize tables"]
\* All tables begin empty. The global counter starts at 0. Processing begins at entry 1.
Init ==
    /\ idx = 1
    /\ arithRows = << >>
    /\ storageRows = << >>
    /\ callRows = << >>
    /\ globalCounter = 0

(* ========================================
              HELPER OPERATORS
   ======================================== *)

\* The trace entry currently being processed
CurrentEntry == Trace[idx]

\* Processing is complete when all entries have been consumed
Done == idx > TraceLen

\* Construct a witness row record with metadata for verification
\* gc:     global counter value at the time of creation
\* width:  number of columns (must match the table's column count)
\* srcIdx: index of the source trace entry (for traceability)
MakeRow(gc, width, sourceIdx) == [gc |-> gc, width |-> width, srcIdx |-> sourceIdx]

(* ========================================
              ACTIONS
   ======================================== *)

\* [Source: 0-input/code/src/arithmetic.rs, lines 33-70 -- process_entry()]
\* Process a trace entry whose op is in ArithOps (BALANCE_CHANGE or NONCE_CHANGE).
\* Produces exactly 1 row in the arithmetic table with 8 columns:
\* [global_counter, op_type, operand_a_hi, operand_a_lo, operand_b_hi, operand_b_lo,
\*  result_hi, result_lo]
ProcessArithEntry ==
    /\ ~Done
    /\ CurrentEntry.op \in ArithOps
    /\ arithRows' = Append(arithRows, MakeRow(globalCounter, ArithColCount, idx))
    /\ storageRows' = storageRows
    /\ callRows' = callRows
    /\ globalCounter' = globalCounter + 1
    /\ idx' = idx + 1

\* [Source: 0-input/code/src/storage.rs, lines 54-77 -- process_entry() SLOAD branch]
\* Process a storage read (SLOAD). Produces exactly 1 row with 10+depth columns:
\* [global_counter, op_type, account_hash, slot_hash, value_hi, value_lo,
\*  old_value_hi, old_value_lo, new_value_hi, new_value_lo, sibling_0..sibling_{d-1}]
ProcessStorageRead ==
    /\ ~Done
    /\ CurrentEntry.op \in StorageReadOps
    /\ storageRows' = Append(storageRows, MakeRow(globalCounter, StorageColCount, idx))
    /\ arithRows' = arithRows
    /\ callRows' = callRows
    /\ globalCounter' = globalCounter + 1
    /\ idx' = idx + 1

\* [Source: 0-input/code/src/storage.rs, lines 79-119 -- process_entry() SSTORE branch]
\* Process a storage write (SSTORE). Produces exactly 2 rows: old-state Merkle path
\* and new-state Merkle path. Both rows carry the same global counter value because
\* they originate from the same trace entry.
\* Row 1: op_type = SSTORE (old path siblings)
\* Row 2: op_type = SSTORE+100 marker (new path siblings)
ProcessStorageWrite ==
    /\ ~Done
    /\ CurrentEntry.op \in StorageWriteOps
    /\ LET row1 == MakeRow(globalCounter, StorageColCount, idx)
           row2 == MakeRow(globalCounter, StorageColCount, idx)
       IN storageRows' = storageRows \o << row1, row2 >>
    /\ arithRows' = arithRows
    /\ callRows' = callRows
    /\ globalCounter' = globalCounter + 1
    /\ idx' = idx + 1

\* [Source: 0-input/code/src/call_context.rs, lines 26-46 -- process_entry()]
\* Process a CALL entry. Produces exactly 1 row in the call context table with 8 columns:
\* [global_counter, caller_hash, callee_hash, value_hi, value_lo,
\*  is_success, call_depth, gas_available]
ProcessCallEntry ==
    /\ ~Done
    /\ CurrentEntry.op \in CallOps
    /\ callRows' = Append(callRows, MakeRow(globalCounter, CallColCount, idx))
    /\ arithRows' = arithRows
    /\ storageRows' = storageRows
    /\ globalCounter' = globalCounter + 1
    /\ idx' = idx + 1

\* [Source: 0-input/code/src/generator.rs, lines 80-96 -- dispatch returns empty for non-matching ops]
\* Process a trace entry with no corresponding witness table (e.g., LOG).
\* No rows are produced. The global counter still increments (one counter per entry).
ProcessSkipEntry ==
    /\ ~Done
    /\ CurrentEntry.op \notin WitnessOps
    /\ arithRows' = arithRows
    /\ storageRows' = storageRows
    /\ callRows' = callRows
    /\ globalCounter' = globalCounter + 1
    /\ idx' = idx + 1

\* Terminal: stuttering step after all entries are processed.
Terminated ==
    /\ Done
    /\ UNCHANGED vars

(* ========================================
              NEXT-STATE RELATION
   ======================================== *)

\* [Source: 0-input/code/src/generator.rs, lines 73-98 -- sequential processing loop]
\* The Next relation is fully deterministic: exactly one disjunct is enabled per state.
\* This models the sequential, deterministic processing in generator::generate().
Next ==
    \/ ProcessArithEntry
    \/ ProcessStorageRead
    \/ ProcessStorageWrite
    \/ ProcessCallEntry
    \/ ProcessSkipEntry
    \/ Terminated

(* ========================================
              SPECIFICATION
   ======================================== *)

\* Weak fairness ensures the system processes all entries and terminates.
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

(* ========================================
              SAFETY PROPERTIES
   ======================================== *)

\* --- S1: Completeness ---
\* [Why]: Every trace entry that belongs to a witness-producing operation must generate
\*        the correct number of rows in the corresponding table. No entry is silently dropped.
\*        This guarantees the witness contains all information needed for proof generation.
\* [Source: 0-input/REPORT.md, "Recommendations for Downstream Agents", item [14]]
Completeness ==
    Done =>
        LET
            ExpectedArith == Cardinality({i \in 1..TraceLen : Trace[i].op \in ArithOps})
            ExpectedStorageRead == Cardinality({i \in 1..TraceLen : Trace[i].op \in StorageReadOps})
            ExpectedStorageWrite == Cardinality({i \in 1..TraceLen : Trace[i].op \in StorageWriteOps})
            ExpectedStorage == ExpectedStorageRead + (ExpectedStorageWrite * 2)
            ExpectedCall == Cardinality({i \in 1..TraceLen : Trace[i].op \in CallOps})
        IN
            /\ Len(arithRows) = ExpectedArith
            /\ Len(storageRows) = ExpectedStorage
            /\ Len(callRows) = ExpectedCall

\* --- S2: Soundness (Source Traceability) ---
\* [Why]: Every witness row must trace back to a valid source entry whose operation type
\*        matches the table. No witness row is fabricated without a corresponding trace entry.
\*        A fabricated row would produce an invalid proof (false positive impossible).
\* [Source: 0-input/REPORT.md, Section 1 -- multi-table dispatch architecture]
Soundness ==
    /\ \A i \in 1..Len(arithRows) :
        /\ arithRows[i].srcIdx \in 1..TraceLen
        /\ Trace[arithRows[i].srcIdx].op \in ArithOps
    /\ \A i \in 1..Len(storageRows) :
        /\ storageRows[i].srcIdx \in 1..TraceLen
        /\ Trace[storageRows[i].srcIdx].op \in (StorageReadOps \union StorageWriteOps)
    /\ \A i \in 1..Len(callRows) :
        /\ callRows[i].srcIdx \in 1..TraceLen
        /\ Trace[callRows[i].srcIdx].op \in CallOps

\* --- S3: Row Width Consistency ---
\* [Why]: Every row in a table must have the same column count. A mismatched row would
\*        cause the prover circuit to fail (polynomial commitments have fixed degree).
\* [Source: 0-input/code/src/types.rs, lines 114-123 -- debug_assert_eq on row length]
RowWidthConsistency ==
    /\ \A i \in 1..Len(arithRows) : arithRows[i].width = ArithColCount
    /\ \A i \in 1..Len(storageRows) : storageRows[i].width = StorageColCount
    /\ \A i \in 1..Len(callRows) : callRows[i].width = CallColCount

\* --- S4: Global Counter Monotonicity ---
\* [Why]: The global counter provides total ordering across tables, analogous to
\*        Scroll's GlobalCounter. Non-monotonic counters break cross-table consistency
\*        checks in the circuit. The counter equals the number of entries processed.
\* [Source: 0-input/code/src/generator.rs, lines 69-96 -- global_counter += 1]
\* [Source: 0-input/REPORT.md, Section 6 -- L17 global counter ensures consistent ordering]
GlobalCounterMonotonic ==
    globalCounter = idx - 1

\* --- S5: Determinism (Structural) ---
\* [Why]: Same trace must always produce the same witness (Invariant I-08).
\*        The specification achieves this by construction: the Next relation is a function
\*        (not a relation), meaning exactly one action is enabled in each non-terminal state.
\*        This invariant verifies the mutual exclusion of action guards by counting the
\*        number of enabled dispatch branches for the current entry.
\* [Source: 0-input/REPORT.md, Section 6 -- "Deterministic Witness Generation (I-08)"]
\* [Source: 0-input/code/src/generator.rs, line 9 -- "Invariant I-08"]
DeterminismGuard ==
    ~Done =>
        LET enabledCount ==
              (IF CurrentEntry.op \in ArithOps THEN 1 ELSE 0)
            + (IF CurrentEntry.op \in StorageReadOps THEN 1 ELSE 0)
            + (IF CurrentEntry.op \in StorageWriteOps THEN 1 ELSE 0)
            + (IF CurrentEntry.op \in CallOps THEN 1 ELSE 0)
            + (IF CurrentEntry.op \notin WitnessOps THEN 1 ELSE 0)
        IN enabledCount = 1

\* --- S6: Sequential Processing Order ---
\* [Why]: Entries must be processed in the order they appear in the trace.
\*        Reordering would break EVM execution semantics (e.g., an SSTORE that depends
\*        on a prior SLOAD would reference stale state).
\* [Source: 0-input/code/src/generator.rs, lines 73-98 -- sequential for loops]
SequentialOrder ==
    \* Source indices in arithmetic and call tables are strictly increasing
    /\ \A i \in 1..(Len(arithRows) - 1) : arithRows[i].srcIdx < arithRows[i + 1].srcIdx
    /\ \A i \in 1..(Len(callRows) - 1) : callRows[i].srcIdx < callRows[i + 1].srcIdx
    \* Source indices in storage table are non-decreasing (SSTORE produces 2 rows with same srcIdx)
    /\ \A i \in 1..(Len(storageRows) - 1) : storageRows[i].srcIdx <= storageRows[i + 1].srcIdx

(* ========================================
              LIVENESS PROPERTIES
   ======================================== *)

\* --- L1: Termination ---
\* [Why]: The witness generator must eventually finish processing all trace entries.
\*        A non-terminating generator would block the entire proving pipeline.
Termination == <>Done

====
