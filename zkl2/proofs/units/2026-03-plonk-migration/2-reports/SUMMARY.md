# Verification Summary: PLONK Migration (2026-03-plonk-migration)

## Status: PASS

All 8 safety properties proved as inductive invariants. Zero Admitted.

## Verification Environment

- **Coq version**: The Rocq Prover 9.0.1 (OCaml 4.14.2)
- **Target**: zkl2
- **Date**: 2026-03-19
- **TLC Evidence**: 9,117,756 states, 3,985,171 distinct, depth 22 -- PASS

## Files

| File | Lines | Purpose | Status |
|------|-------|---------|--------|
| Common.v | 100 | Types, ps_accepted, tactics | PASS |
| Spec.v | 207 | TLA+ translation (Init, 8 actions, Next, 8 safety properties) | PASS |
| Impl.v | 109 | Rust/Solidity model, isomorphism proofs | PASS |
| Refinement.v | 575 | Safety invariant proofs, main theorem | PASS |

## Theorems Proved

### Refinement: Implementation matches Specification

| Theorem | Statement |
|---------|-----------|
| `rust_accepts_correct` | Rust `MigrationPhase::accepts()` = TLA+ `VerifiersForPhase` |
| `sol_is_active_correct` | Solidity `_isProofSystemActive()` = TLA+ `VerifiersForPhase` |
| `rust_sol_equivalence` | Rust and Solidity acceptance logic are equivalent |
| `sol_start_dual_sound` | Solidity startDualVerification guard implies TLA+ precondition |
| `sol_cutover_sound` | Solidity cutoverToPlonkOnly guard implies TLA+ precondition |
| `sol_rollback_sound` | Solidity rollbackMigration guard implies TLA+ precondition |
| `sol_complete_rollback_sound` | Solidity completeRollback guard implies TLA+ precondition |

### Safety Properties (Inductive Invariants)

| Property | Init | Next | Statement |
|----------|------|------|-----------|
| S1 MigrationSafety | `init_migration_safety` | `migration_safety_preserved` | No batch lost during migration |
| S2 BackwardCompatibility | `init_backward_compat` | `backward_compat_preserved` | Groth16 accepted when active |
| S3 Soundness | `init_soundness` | `soundness_preserved` | No false positives |
| S4 Completeness | `init_completeness` | `completeness_preserved` | No false negatives |
| S5 NoGroth16AfterCutover | `init_no_groth16_after` | `no_groth16_preserved` | Groth16 rejected after cutover |
| S6 PhaseConsistency | By construction | By construction | activeVerifiers = VerifiersForPhase(phase) |
| S7 RollbackOnlyOnFailure | `init_rollback_failure` | `rollback_failure_preserved` | Rollback requires failure detection |
| S8 NoBatchLossDuringRollback | `init_no_batch_loss_rollback` | Follows from S1 | Batches preserved during rollback |

### Main Theorem

```
Theorem reachable_all_safety : forall s,
  Reachable s -> AllSafety s.
```

Every state reachable from Init via any sequence of Next transitions satisfies
all 8 safety properties simultaneously.

### Extracted Corollaries (User-Requested)

| Corollary | Statement |
|-----------|-----------|
| `reachable_soundness` | Proof system migration introduces no false positives |
| `reachable_migration_safety` | No batch goes unverified during migration |
| `reachable_backward_compat` | Groth16 proofs accepted during dual period |
| `reachable_no_groth16_after_cutover` | Groth16 correctly rejected after PLONK-only cutover |

## Proof Architecture

The proof follows the standard inductive invariant methodology:

1. **Init establishes AllSafety**: Each property holds in the initial state
   (batchCounter=0, empty queues, empty registry, Groth16Only phase).

2. **Each action preserves AllSafety**: For each of the 8 actions in the Next
   relation, each safety property is shown to be preserved. Most cases are
   trivial (state variables unchanged). Non-trivial cases:
   - **SubmitBatch x S1**: New batch appended to queue with seqNo = S(counter).
     Existing batches preserved via `in_or_app`.
   - **VerifyBatch x S1**: Head batch moves from queue to registry. Tail
     batches remain. Batch identity (enterprise, seqNo) preserved in ProofRecord.
   - **VerifyBatch x S3**: Batch added to verifiedBatches only when isValid=true.
     The corresponding ProofRecord has proof_valid=true by construction.
   - **VerifyBatch x S2/S4/S5**: New ProofRecord has proof_valid = ps_accepted(...).
     Properties follow from the definition of ps_accepted.
   - **RollbackMigration x S7**: Phase becomes Rollback, failureDetected preserved
     as true (from precondition).

3. **By induction on Reachable**: The combined AllSafety holds for all reachable states.

## Design Decisions

1. **S6 by construction**: activeVerifiers is not stored as a separate state variable
   but computed from migrationPhase via `ps_accepted`. This makes PhaseConsistency
   trivially true (= True) and eliminates an entire class of bugs where the verifier
   set could diverge from the phase. Both the Rust and Solidity implementations use
   this approach.

2. **S8 as corollary of S1**: NoBatchLossDuringRollback is a specialization of
   MigrationSafety to the Rollback phase. Since MigrationSafety holds for ALL
   states (including Rollback), S8 follows immediately.

3. **Phase stamp in ProofRecord**: The proof_phase field stamps each verification
   outcome with the phase at verification time. This resolves temporal ambiguity
   for S2 (BackwardCompatibility) and S4 (Completeness), ensuring these properties
   evaluate validity relative to the verifiers that were active AT VERIFICATION TIME.

## Axiom Audit

The proof development uses only standard Coq axioms (no custom Axiom declarations).
The only Parameters are:
- `MaxBatches : nat` (protocol constant)
- `MaxMigrationSteps : nat` (protocol constant)
- `max_batches_pos : MaxBatches >= 1` (well-formedness constraint)

No `Admitted`, no `admit`, no `give_up`.
