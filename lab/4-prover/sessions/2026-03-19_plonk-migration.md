# Session Log: PLONK Migration Verification

- **Date**: 2026-03-19
- **Target**: zkl2
- **Unit**: 2026-03-plonk-migration
- **Proof Status**: COMPLETE

## Summary

Constructed Coq proofs verifying that the Groth16-to-PLONK migration implementation
(Rust halo2 prover + Solidity BasisVerifier) is isomorphic to its TLA+ specification
(PlonkMigration.tla, TLC-verified over 9.1M states).

## Artifacts Produced

All artifacts in `zkl2/proofs/units/2026-03-plonk-migration/`:

| Path | Description |
|------|-------------|
| `0-input-spec/PlonkMigration.tla` | Frozen TLA+ specification (READ-ONLY) |
| `0-input-spec/MC_PlonkMigration.log` | TLC model-checking evidence (READ-ONLY) |
| `0-input-impl/*.rs` | Frozen Rust implementation snapshot (READ-ONLY) |
| `0-input-impl/BasisVerifier.sol` | Frozen Solidity contract snapshot (READ-ONLY) |
| `1-proofs/Common.v` | Standard library: Phase, ProofSystemId, ps_accepted, tactics |
| `1-proofs/Spec.v` | Faithful TLA+ translation: State, Init, 8 actions, 8 safety properties |
| `1-proofs/Impl.v` | Rust/Solidity model: rust_accepts, sol_is_active, phase transition guards |
| `1-proofs/Refinement.v` | Safety invariant proofs: Init, Next preservation, main theorem |
| `2-reports/verification.log` | Coq compilation output (all PASS) |
| `2-reports/SUMMARY.md` | Verification summary with theorem inventory |

## Theorems Proved

### Implementation Isomorphism (Impl.v)
- `rust_accepts_correct`: Rust MigrationPhase::accepts = TLA+ VerifiersForPhase
- `sol_is_active_correct`: Solidity _isProofSystemActive = TLA+ VerifiersForPhase
- `rust_sol_equivalence`: Rust and Solidity agree on all inputs
- 4 phase transition guard soundness lemmas

### Safety Invariants (Refinement.v)
- S1 MigrationSafety: No batch lost during migration
- S2 BackwardCompatibility: Groth16 accepted when active
- S3 Soundness: No false positives (proof system change safe)
- S4 Completeness: No false negatives (valid proofs never rejected)
- S5 NoGroth16AfterCutover: Groth16 rejected after PLONK-only cutover
- S6 PhaseConsistency: Holds by construction (no separate activeVerifiers variable)
- S7 RollbackOnlyOnFailure: Rollback requires failure detection
- S8 NoBatchLossDuringRollback: Follows from S1

### Main Result
```
Theorem reachable_all_safety : forall s, Reachable s -> AllSafety s.
```
Every reachable state satisfies all 8 safety properties.

## Decisions Made

1. **S6 by construction**: Omitted activeVerifiers from State record. Computed from
   phase via ps_accepted. This matches both Rust and Solidity implementations where
   active_verifiers() / _isProofSystemActive() are pure functions of the phase.

2. **Lists for queues and registry**: Used Coq lists with `In` predicate instead of
   axiomatized finite sets. This is sufficient because the safety properties only
   require membership reasoning, not cardinality.

3. **Boolean ps_accepted**: Used bool (not Prop) for the acceptance function. This
   enables computation-based proofs (reflexivity after destruct) for S2/S4/S5.

4. **Point-wise update for per-enterprise state**: Actions that modify a specific
   enterprise's queue/counter use point-wise equations (value at e, forall e' <> e)
   rather than function update. This avoids needing functional extensionality.

## Admitted Count

Zero. No Admitted, no admit, no give_up. All proofs are complete.

## Next Steps

None required for this unit. The PLONK migration has been mathematically certified:
- The implementation faithfully implements the TLA+ specification
- All 8 safety properties are inductive invariants
- The proof system change introduces no false positives (Soundness)
- No batch is lost during migration (MigrationSafety)
- Groth16 backward compatibility holds during the dual period
- Groth16 is correctly disabled after cutover to PLONK-only
