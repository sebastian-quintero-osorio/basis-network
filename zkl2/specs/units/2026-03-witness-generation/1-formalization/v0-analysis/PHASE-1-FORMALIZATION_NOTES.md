# Phase 1: Formalization Notes -- Witness Generation

**Unit**: witness-generation
**Target**: zkl2
**Date**: 2026-03-19
**Result**: PASS (all invariants verified, liveness satisfied)

---

## 1. Research-to-Spec Mapping

| Source (0-input/) | TLA+ Element | Type | Notes |
|---|---|---|---|
| `generator.rs:61` -- `generate()` | `Next` (full relation) | Next-state | Sequential processing of trace entries |
| `generator.rs:64-71` -- table initialization | `Init` | Initial state | Empty tables, counter = 0, idx = 1 |
| `generator.rs:69-96` -- `global_counter += 1` | `globalCounter` variable | Variable | Incremented per entry, not per row |
| `generator.rs:73-98` -- sequential for loops | `idx` variable + sequential actions | Variable | Entries processed in trace order |
| `arithmetic.rs:33-70` -- `process_entry()` | `ProcessArithEntry` | Action | BALANCE_CHANGE, NONCE_CHANGE -> 1 row each |
| `storage.rs:54-77` -- SLOAD branch | `ProcessStorageRead` | Action | 1 row with Merkle proof path |
| `storage.rs:79-119` -- SSTORE branch | `ProcessStorageWrite` | Action | 2 rows (old + new Merkle paths) |
| `call_context.rs:26-46` -- `process_entry()` | `ProcessCallEntry` | Action | CALL -> 1 row |
| `generator.rs:80-96` -- empty dispatch | `ProcessSkipEntry` | Action | LOG and other non-witness ops |
| `types.rs:16-23` -- `TraceOp` enum | `OpTypes` constant | Constant | 6 operation types |
| `arithmetic.rs:16-25` -- COLUMNS (8) | `ArithColCount = 8` | Constant | Fixed column count |
| `storage.rs:24-41` -- column_names (10+d) | `StorageColCount = 42` | Constant | 10 + depth 32 |
| `call_context.rs:13-22` -- COLUMNS (8) | `CallColCount = 8` | Constant | Fixed column count |
| `types.rs:114-123` -- debug_assert on row.len() | `RowWidthConsistency` | Invariant | Every row matches table column count |
| `generator.rs:9` -- Invariant I-08 | `DeterminismGuard` | Invariant | Mutual exclusion of dispatch guards |
| REPORT.md, Section 6, L17 | `GlobalCounterMonotonic` | Invariant | Counter provides total order |
| REPORT.md, Recommendations item [14] | `Completeness` | Invariant | Row counts match expected per trace |
| REPORT.md, Section 1 | `Soundness` | Invariant | Every row traces to valid source |

## 2. Abstraction Decisions

### What is modeled

- **Dispatch logic**: Which operation type maps to which table, and how many rows each produces.
- **Sequential processing**: Entries are consumed in order; no reordering or parallelism.
- **Row metadata**: Each witness row carries its global counter, column width, and source entry index.
- **Table structure**: Three separate tables (arithmetic, storage, call_context) with fixed column counts.

### What is abstracted away

- **Field element values**: Actual BN254 field arithmetic (hex_to_fr, hex_to_limbs, Poseidon siblings) is abstracted. The spec verifies structural properties (dispatch, completeness, ordering) rather than arithmetic correctness.
- **Limb decomposition**: The 256-bit to 2x128-bit split is not modeled. It does not affect dispatch or row counts.
- **Merkle sibling generation**: The deterministic PRNG for storage siblings is abstracted as a constant column count. Production correctness of siblings is a separate concern (state DB verification, RU-L4).
- **Transaction boundaries**: The spec flattens all entries into a single sequence. Transaction-level grouping does not affect the witness generation algorithm.

### Justification for abstraction level

The three target invariants (Completeness, Soundness, Determinism) are properties of the dispatch and ordering logic, not of field element computation. Modeling BN254 arithmetic in TLA+ would not strengthen verification of these properties and would make the model intractable. Arithmetic correctness is better verified at the circuit constraint level (ZK prover verification).

## 3. Invariants Verified

| ID | Name | Property Type | Description | Result |
|---|---|---|---|---|
| S1 | `Completeness` | Safety | Row counts match expected per operation type | PASS |
| S2 | `Soundness` | Safety | Every row traces to a valid source entry | PASS |
| S3 | `RowWidthConsistency` | Safety | All rows in a table have identical column count | PASS |
| S4 | `GlobalCounterMonotonic` | Safety | Counter equals entries processed (idx - 1) | PASS |
| S5 | `DeterminismGuard` | Safety | Exactly one action enabled per non-terminal state | PASS |
| S6 | `SequentialOrder` | Safety | Source indices are monotonically ordered per table | PASS |
| L1 | `Termination` | Liveness | Processing eventually completes | PASS |
| -- | `TypeOK` | Type invariant | All variables within declared domains | PASS |

## 4. Model Checking Results

```
TLC2 Version 2.16 of 31 December 2020
Model checking completed. No error has been found.
8 states generated, 7 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 7.
```

### Execution trace (state-by-state)

| State | idx | Action | arithRows | storageRows | callRows | gc |
|---|---|---|---|---|---|---|
| 0 (Init) | 1 | -- | 0 | 0 | 0 | 0 |
| 1 | 2 | ProcessArithEntry (BALANCE_CHANGE) | 1 | 0 | 0 | 1 |
| 2 | 3 | ProcessStorageWrite (SSTORE) | 1 | 2 | 0 | 2 |
| 3 | 4 | ProcessCallEntry (CALL) | 1 | 2 | 1 | 3 |
| 4 | 5 | ProcessArithEntry (NONCE_CHANGE) | 2 | 2 | 1 | 4 |
| 5 | 6 | ProcessStorageRead (SLOAD) | 2 | 3 | 1 | 5 |
| 6 | 7 | ProcessSkipEntry (LOG) | 2 | 3 | 1 | 6 |

Terminal state: Done = TRUE. Completeness check passes: arith=2, storage=3, call=1.

### Reproduction

```bash
cd zkl2/specs/units/2026-03-witness-generation/1-formalization/v0-analysis/experiments/WitnessGeneration/_build
java -cp lab/2-logicist/tools/tla2tools.jar tlc2.TLC MC_WitnessGeneration -workers 4
```

## 5. Open Issues

1. **Field element arithmetic correctness**: Not modeled. The specification verifies dispatch, completeness, and ordering, but does not verify that `hex_to_limbs` or `generate_deterministic_siblings` produce correct field elements. This should be verified at the circuit constraint level.

2. **Multi-transaction isolation**: The spec flattens all entries into a single trace. If future requirements demand transaction-level witness isolation (e.g., per-transaction proofs), the model would need transaction boundary tracking.

3. **Missing tables**: The prototype implements 3 of ~10+ tables needed for a production zkEVM (see REPORT.md T-17). Adding bytecode, memory, stack, Keccak, copy, and padding tables will require extending the dispatch logic and adding new action types. The specification structure (partitioned operation sets, per-table row sequences) supports this extension naturally.

4. **Real Merkle siblings**: The prototype uses simulated siblings (T-18). In production, the witness generator queries the state DB for actual Merkle proof paths, introducing I/O latency. The TLA+ model's abstraction of siblings as a column count remains valid regardless of the sibling source.

## 6. Verdict

**PASS**. The specification faithfully models the witness generation dispatch logic from the reference implementation. All 7 safety invariants and 1 liveness property hold across the exhaustive state space (7 distinct states). The model is ready for Phase 2 audit.
