# Session Log: PLONK Migration Formalization

> **Date**: 2026-03-19
> **Target**: zkl2
> **Unit**: plonk-migration (RU-L9 Logicist)
> **Phase**: Phase 1 -- Formalize Research
> **Result**: PASS

---

## Summary

Formalized the Groth16-to-halo2-KZG migration protocol as a TLA+ specification.
The specification models the dual verification transition period, cutover to PLONK-only,
failure detection, and rollback. All 9 safety invariants pass exhaustive model checking
across 9.1M states (3 enterprises, 2 batches each).

## Artifacts Produced

| Artifact | Path |
|----------|------|
| Unit README | `zkl2/specs/units/2026-03-plonk-migration/0-input/README.md` |
| TLA+ Specification | `zkl2/specs/units/2026-03-plonk-migration/1-formalization/v0-analysis/specs/PlonkMigration/PlonkMigration.tla` |
| Model Instance | `zkl2/specs/units/2026-03-plonk-migration/1-formalization/v0-analysis/experiments/PlonkMigration/MC_PlonkMigration.tla` |
| Model Config | `zkl2/specs/units/2026-03-plonk-migration/1-formalization/v0-analysis/experiments/PlonkMigration/MC_PlonkMigration.cfg` |
| Certificate of Truth | `zkl2/specs/units/2026-03-plonk-migration/1-formalization/v0-analysis/experiments/PlonkMigration/MC_PlonkMigration.log` |
| Phase 1 Report | `zkl2/specs/units/2026-03-plonk-migration/1-formalization/v0-analysis/PHASE-1-FORMALIZATION_NOTES.md` |

## Key Decisions

1. **Phase-stamped ProofRecords**: Added `phase` field to proof records to resolve temporal
   ambiguity in Completeness and BackwardCompatibility invariants. Without this, phase
   transitions retroactively invalidate historical records.

2. **Open submission model**: Enterprises can submit any proof type regardless of active
   verifiers. Verification rejects invalid types. This models stale provers realistically.

3. **Empty-queue cutover guard**: Cutover to PLONK-only requires all enterprise queues
   empty, preventing stranded Groth16 batches.

4. **Model size calibration**: 3 enterprises x 4 batches was intractable (183M+ states,
   growing). Reduced to 3 enterprises x 2 batches (9.1M states, 37 seconds) with full
   scenario coverage.

## Verification Results

- 9,117,756 states generated, 3,985,171 distinct
- Depth 22, 4 workers, 37 seconds
- All 9 invariants PASS: TypeOK, MigrationSafety, BackwardCompatibility, Soundness,
  Completeness, NoGroth16AfterCutover, PhaseConsistency, RollbackOnlyOnFailure,
  NoBatchLossDuringRollback

## Next Steps

- Phase 2: Audit (`/2-audit`) -- Verify formalization faithfulness against source materials
