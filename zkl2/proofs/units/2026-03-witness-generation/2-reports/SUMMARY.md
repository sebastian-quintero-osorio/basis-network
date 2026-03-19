# Verification Summary: Witness Generation

**Unit:** `zkl2/proofs/units/2026-03-witness-generation/`
**Date:** 2026-03-19
**Target:** zkl2 (Enterprise zkEVM L2)
**Verdict:** PASS -- All theorems proved without Admitted.

## Inputs

| Artifact | Source | Frozen Snapshot |
|----------|--------|-----------------|
| TLA+ Specification | `zkl2/specs/units/2026-03-witness-generation/1-formalization/v0-analysis/specs/WitnessGeneration/WitnessGeneration.tla` | `0-input-spec/WitnessGeneration.tla` |
| Rust Implementation | `zkl2/prover/witness/src/{generator,arithmetic,storage,call_context,types,error}.rs` | `0-input-impl/*.rs` |

## Proof Files

| File | Lines | Purpose |
|------|-------|---------|
| `Common.v` | Standard library: take, count_pred, strictly_increasing, non_decreasing, append lemmas, tactics |
| `Spec.v` | Faithful translation of WitnessGeneration.tla: op_type, trace_entry, witness_row, spec_state, spec_step, safety property definitions |
| `Impl.v` | Rust implementation model: dispatch functions (arith_dispatch, storage_dispatch, call_dispatch), impl_step, refinement theorem |
| `Refinement.v` | Safety proofs: 14-field strengthened invariant, inductive preservation, final safety theorems |

## Theorems Proved

### Structural Invariant (14 fields, preserved inductively across 5 step types)

| ID | Field | Property |
|----|-------|----------|
| I1 | `inv_gc` | Global counter equals index |
| I2 | `inv_bound` | Index within trace length |
| I3 | `inv_ac` | Arithmetic row count = count of arith ops in processed prefix |
| I4 | `inv_sc` | Storage row count = reads + 2 * writes in processed prefix |
| I5 | `inv_cc` | Call row count = count of call ops in processed prefix |
| I6 | `inv_aw` | All arithmetic rows have ArithColCount columns |
| I7 | `inv_sw` | All storage rows have StorageColCount columns |
| I8 | `inv_cw` | All call rows have CallColCount columns |
| I9 | `inv_as` | Every arith row traces to a valid BALANCE_CHANGE/NONCE_CHANGE entry |
| I10 | `inv_ss` | Every storage row traces to a valid SLOAD/SSTORE entry |
| I11 | `inv_cs` | Every call row traces to a valid CALL entry |
| I12 | `inv_ao` | Arithmetic source indices strictly increasing |
| I13 | `inv_so` | Storage source indices non-decreasing (SSTORE produces 2 rows) |
| I14 | `inv_co` | Call source indices strictly increasing |

### Safety Theorems (for all reachable states)

| TLA+ Property | Theorem | Statement |
|---------------|---------|-----------|
| S1: Completeness | `thm_completeness` | At termination, row counts match expected per operation type |
| S2: Soundness | `thm_soundness` | Every witness row traces to a valid source entry with matching op type |
| S3: Row Width | `thm_row_width` | Column counts consistent within each table |
| S4: Global Counter | `thm_global_counter` | Counter = number of entries processed |
| S5: Determinism | `thm_determinism_guard` | Exactly one dispatch branch enabled per entry (by case analysis) |
| S6: Sequential Order | `thm_sequential_order` | Source indices ordered within each table |

### Refinement

| Theorem | Statement |
|---------|-----------|
| `refinement_step` (Impl.v) | Every Rust dispatch-all-three step is a valid TLA+ exclusive-guard step |
| `impl_refines_spec` (Refinement.v) | Restated for completeness |

## Proof Architecture

- **Technique:** Single strengthened invariant (Record with 14 fields) proved as inductive invariant over the spec_step relation.
- **Cases:** 5 spec_step constructors (Arith, StorageRead, StorageWrite, Call, Skip) x 14 invariant fields = 70 subgoals.
- **Key lemmas:**
  - `count_take_succ`: Bridges `take(n)` to `take(n+1)` for counting predicates.
  - `count_unchanged` / `count_incremented`: Handle row count updates using mutual exclusion of op types.
  - `si_app_single` / `nd_app_single` / `nd_app_pair`: Ordering preservation under append.
  - `op_classification`: Exhaustive 5-way case split on operation types.
  - `not_witness_implies`: Derives individual negations from `is_witness_op = false`.
- **Determinism:** Proved independently by case analysis on `op_type` (no invariant needed).
- **Refinement:** Proved by case analysis on `entry_op e`, showing dispatch-all-three reduces to the matching exclusive-guard action.

## Rust Modeling Decisions

| Rust Concept | Coq Model | Justification |
|-------------|-----------|---------------|
| `Result<T, WitnessError>` | Successful path only | Errors are precondition violations; structural properties hold on the happy path |
| `BTreeMap<String, WitnessTable>` | Implicit in state fields | Deterministic iteration order modeled by fixed table names |
| `Vec<Fr>` (field element rows) | `witness_row` record with metadata | Abstracted to (gc, width, src_idx) since field element values are irrelevant to structural properties |
| `match entry.op { ... }` | `arith_dispatch` / `storage_dispatch` / `call_dispatch` functions | Each returns empty for non-matching ops, modeling the Rust match dispatch |
| Sequential for-loop | `spec_step` / `impl_step` one-entry-at-a-time | Isomorphic to loop iteration |

## Compilation

```
Rocq Prover 9.0.1 (OCaml 4.14.2)
Namespace: WG
Command: coqc -Q . WG <file>.v

Common.v:     PASS
Spec.v:       PASS
Impl.v:       PASS
Refinement.v: PASS

Admitted count: 0
Axiom count: 3 (ArithColCount_pos, StorageColCount_pos, CallColCount_pos -- parameter constraints matching TLA+ ASSUME)
```
