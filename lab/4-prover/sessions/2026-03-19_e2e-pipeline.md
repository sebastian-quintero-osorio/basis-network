# Session Log: E2E Pipeline Verification

**Date**: 2026-03-19
**Target**: zkl2
**Unit**: 2026-03-e2e-pipeline
**Proof Status**: COMPLETE -- All theorems proved, zero Admitted

## What Was Accomplished

Constructed Coq proofs verifying that the Go E2E Pipeline implementation
(`zkl2/node/pipeline/`) correctly implements the TLA+ specification
(`E2EPipeline.tla`). Four safety properties proved for all reachable states,
plus refinement from Go implementation to TLA+ spec.

## Artifacts Produced

| Artifact | Path |
|----------|------|
| Common.v | `zkl2/proofs/units/2026-03-e2e-pipeline/1-proofs/Common.v` |
| Spec.v | `zkl2/proofs/units/2026-03-e2e-pipeline/1-proofs/Spec.v` |
| Impl.v | `zkl2/proofs/units/2026-03-e2e-pipeline/1-proofs/Impl.v` |
| Refinement.v | `zkl2/proofs/units/2026-03-e2e-pipeline/1-proofs/Refinement.v` |
| TLA+ snapshot | `zkl2/proofs/units/2026-03-e2e-pipeline/0-input-spec/E2EPipeline.tla` |
| Go snapshot | `zkl2/proofs/units/2026-03-e2e-pipeline/0-input-impl/{orchestrator,stages,types}.go` |
| Verification log | `zkl2/proofs/units/2026-03-e2e-pipeline/2-reports/verification.log` |
| Summary | `zkl2/proofs/units/2026-03-e2e-pipeline/2-reports/SUMMARY.md` |

## Theorems Proved

1. **thm_pipeline_integrity** -- Finalized batch has complete artifact chain
2. **thm_atomic_failure** -- Failed batch leaves zero L1 footprint
3. **thm_artifact_dependency_chain** -- Strict causal ordering of artifacts
4. **thm_monotonic_progress** -- Artifact presence implies minimum stage
5. **refinement_step** -- Go impl step -> valid TLA+ spec step

## Proof Strategy

Used a `valid_state` inductive invariant that exactly characterizes the
reachable artifact configurations for each pipeline stage. The invariant
maps stages to permitted artifact combinations:

- Non-failed stages: artifacts fully determined by stage position
- Failed stage: proofOnL1 = false, lower artifacts follow dependency chain

Preservation across all 13 spec_step constructors proved automatically
via `intuition congruence`. Safety properties derived by case analysis.

## Decisions Made

1. **Single-batch model**: Modeled one batch since TLA+ batches are independent.
   This avoids multi-batch complexity while preserving all per-batch safety guarantees.

2. **im_max_retries field**: Modeled Go's `PipelineConfig.RetryPolicy.MaxRetries`
   as an explicit field in impl_state, erased by map_state. This makes the refinement
   non-trivial: it requires the linking constraint `im_max_retries = MaxRetries`.

3. **valid_state over separate sub-invariants**: Unlike the sequencer proof (which
   used 4 separate sub-invariants), used a single match-based invariant. This is
   cleaner for the linear pipeline because artifacts are fully determined by stage.

4. **simpl after apply**: Record projections require explicit `simpl` after `apply`
   to make `lia` work. Discovered during compilation.

## Next Steps

- This completes the 6th and final zkL2 verification unit
- All 6 units now verified: basis-rollup, evm-executor, sequencer,
  state-database, witness-generation, e2e-pipeline
