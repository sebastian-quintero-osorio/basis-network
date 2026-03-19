# Session Log: BasisRollup Formalization

**Date**: 2026-03-19
**Target**: zkl2
**Unit**: basis-rollup
**Phase**: 1 (Formalize Research)
**Result**: PASS

---

## What Was Accomplished

Formalized BasisRollup.sol (the L1 rollup contract for the zkEVM L2) into a TLA+ specification, extending the validium StateCommitment (RU-V3) from a single-phase atomic model to a three-phase commit-prove-execute lifecycle. Verified all 12 invariants via exhaustive TLC model checking.

## Artifacts Produced

| Artifact | Path |
|----------|------|
| TLA+ specification | `zkl2/specs/units/2026-03-basis-rollup/1-formalization/v0-analysis/specs/BasisRollup/BasisRollup.tla` |
| Model instance | `zkl2/specs/units/2026-03-basis-rollup/1-formalization/v0-analysis/experiments/BasisRollup/MC_BasisRollup.tla` |
| Model configuration | `zkl2/specs/units/2026-03-basis-rollup/1-formalization/v0-analysis/experiments/BasisRollup/MC_BasisRollup.cfg` |
| TLC log (Certificate of Truth) | `zkl2/specs/units/2026-03-basis-rollup/1-formalization/v0-analysis/experiments/BasisRollup/MC_BasisRollup.log` |
| Phase 1 report | `zkl2/specs/units/2026-03-basis-rollup/1-formalization/v0-analysis/PHASE-1-FORMALIZATION_NOTES.md` |

## Key Decisions

1. **Abstracted block range tracking (INV-R4)**: L2 block numbers (l2BlockStart, l2BlockEnd) are data-level constraints that do not interact with the batch lifecycle state machine. Omitting them reduces state space without losing lifecycle coverage.

2. **Modeled proof as boolean oracle**: ZK proof verification is non-deterministic (TRUE/FALSE). TLC explores both paths, confirming no state mutation occurs without a valid proof.

3. **Added 6 new invariants beyond the 4 requested**: CounterMonotonicity, StatusConsistency, BatchRootIntegrity, CommitBeforeProve, NoReversal, InitBeforeBatch. These provide comprehensive coverage of the state machine.

4. **Used `-deadlock` flag**: Terminal states (all batches fully processed) are expected in the bounded model. This is not a protocol flaw.

## Verification Summary

- **States generated**: 2,187,547
- **Distinct states**: 383,161
- **Search depth**: 21
- **Time**: 18 seconds
- **Result**: No error found. All 12 invariants hold.

## Next Steps

- Phase 2: Audit (`/2-audit`) -- Verify formalization integrity against source materials
- Specifically check for hallucinated mechanisms and omitted state transitions
