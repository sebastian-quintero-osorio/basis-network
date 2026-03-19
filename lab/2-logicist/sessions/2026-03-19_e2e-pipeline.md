# Session Log: E2E Pipeline Formalization

- **Date**: 2026-03-19
- **Target**: zkl2
- **Unit**: e2e-pipeline
- **Phase**: Phase 1 (Formalize Research)
- **Result**: PASS

## What Was Accomplished

Formalized the E2E L2-to-L1 proving pipeline as a TLA+ specification and verified
it through exhaustive model checking. The pipeline state machine models 5 stages
(Execute, Witness, Prove, Submit, Finalize) with per-stage retry and failure handling.

## Artifacts Produced

| Artifact | Path |
|----------|------|
| TLA+ Specification | zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/specs/E2EPipeline/E2EPipeline.tla |
| Model Instance | zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/experiments/E2EPipeline/MC_E2EPipeline.tla |
| TLC Config (combined) | zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/experiments/E2EPipeline/MC_E2EPipeline.cfg |
| TLC Config (safety) | zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/experiments/E2EPipeline/MC_E2EPipeline_safety.cfg |
| TLC Config (liveness) | zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/experiments/E2EPipeline/MC_E2EPipeline_liveness.cfg |
| Certificate of Truth | zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/experiments/E2EPipeline/MC_E2EPipeline.log |
| Phase 1 Report | zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/PHASE-1-FORMALIZATION_NOTES.md |

## Specification Summary

- **Variables**: 6 (batchStage, retryCount, hasTrace, hasWitness, hasProof, proofOnL1)
- **Actions**: 13 (4 success + 4 fail + 4 exhaust + 1 finalize) + Done (stuttering)
- **Safety Invariants**: 5 (TypeOK, PipelineIntegrity, AtomicFailure, ArtifactDependencyChain, MonotonicProgress)
- **Liveness Properties**: 1 (EventualTermination)

## Verification Results

| Check | States | Distinct | Depth | Time | Result |
|-------|--------|----------|-------|------|--------|
| Safety (symmetry) | 9,144 | 2,024 | 22 | <1s | PASS |
| Liveness (no symmetry) | 48,042 | 10,648 | 22 | 2s | PASS |

## Decisions Made

1. **Separated safety and liveness configs**: TLC warns that symmetry is dangerous
   during liveness checking. Safety uses symmetry (3! = 6x reduction); liveness runs
   without symmetry for correctness.

2. **Added Done stuttering action**: Initial run hit false deadlock when all batches
   reached terminal states. Added explicit `Done` action with `UNCHANGED vars` to
   model quiescent pipeline termination.

3. **Per-batch weak fairness**: Used `WF_vars(BatchAction(b))` for each batch to ensure
   no batch is starved. This models the orchestrator's guarantee that all active batches
   are eventually processed.

4. **L1 submission as atomic**: Modeled commitBatch + proveBatch + executeBatch as a
   single SubmitSuccess action. Justified by the code's retry-the-whole-submission
   pattern.

## Next Steps

- Phase 2 (/2-audit): Verify formalization faithfully represents the source materials.
  Check for hallucinated mechanisms and missed transitions.
