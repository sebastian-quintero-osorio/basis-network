# Phase 1: Formalization Notes -- E2E Pipeline

## Unit Identity

- **Unit**: e2e-pipeline
- **Target**: zkl2
- **Date**: 2026-03-19
- **Input**: zkl2/specs/units/2026-03-e2e-pipeline/0-input/

## Research-to-Spec Mapping

### State Variables

| Research Source | TLA+ Variable | Type | Description |
|----------------|---------------|------|-------------|
| types.go:BatchStage enum (L26-42) | batchStage | [Batches -> StageSet] | Current pipeline stage per batch |
| orchestrator.go:executeWithRetry (L145-203) | retryCount | [Batches -> 0..MaxRetries] | Retry attempts at current stage |
| stages_sim.go:Execute output (L128-138) | hasTrace | [Batches -> BOOLEAN] | Valid execution trace produced |
| stages_sim.go:Witness output (L156-169) | hasWitness | [Batches -> BOOLEAN] | Valid witness tables produced |
| stages_sim.go:Prove output (L188-198) | hasProof | [Batches -> BOOLEAN] | Valid ZK proof produced |
| stages_sim.go:Submit output (L213-215) | proofOnL1 | [Batches -> BOOLEAN] | Proof verified on L1 |

### Actions

| Research Source | TLA+ Action | Guard | Effect |
|----------------|-------------|-------|--------|
| stages_sim.go:Execute() | ExecuteSuccess(b) | stage = "pending" | stage -> "executed", hasTrace = TRUE |
| orchestrator.go:executeWithRetry L156-170 | ExecuteFail(b) | stage = "pending", retries < max | retryCount += 1 |
| orchestrator.go:L200-202 | ExecuteExhaust(b) | stage = "pending", retries >= max | stage -> "failed" |
| stages_sim.go:Witness() | WitnessSuccess(b) | stage = "executed", hasTrace | stage -> "witnessed", hasWitness = TRUE |
| (retry pattern) | WitnessFail(b) | stage = "executed", hasTrace, retries < max | retryCount += 1 |
| (retry pattern) | WitnessExhaust(b) | stage = "executed", retries >= max | stage -> "failed" |
| stages_sim.go:Prove() | ProveSuccess(b) | stage = "witnessed", hasWitness | stage -> "proved", hasProof = TRUE |
| (retry pattern) | ProveFail(b) | stage = "witnessed", hasWitness, retries < max | retryCount += 1 |
| (retry pattern) | ProveExhaust(b) | stage = "witnessed", retries >= max | stage -> "failed" |
| stages_sim.go:Submit() | SubmitSuccess(b) | stage = "proved", hasProof | stage -> "submitted", proofOnL1 = TRUE |
| (retry pattern) | SubmitFail(b) | stage = "proved", hasProof, retries < max | retryCount += 1 |
| (retry pattern) | SubmitExhaust(b) | stage = "proved", retries >= max | stage -> "failed" |
| orchestrator.go:L134 | Finalize(b) | stage = "submitted", proofOnL1 | stage -> "finalized" |

### Invariants

| Invariant | Property Type | Source Justification |
|-----------|--------------|---------------------|
| TypeOK | Type safety | All variables well-typed |
| PipelineIntegrity | Safety | REPORT.md: "pipeline processes 100 L2 transactions" -- finalized must have full artifact chain + L1 proof |
| AtomicFailure | Safety | REPORT.md: "Retry Policy" -- failed batches must not leave L1 footprint |
| ArtifactDependencyChain | Safety | types.go: stage ordering enforces trace -> witness -> proof -> L1 dependency chain |
| MonotonicProgress | Safety | types.go:L29: "strictly monotonic: a batch can only advance forward" |
| EventualTermination | Liveness | REPORT.md: "100% success at 30% failure rate" -- batches must eventually terminate |

## Assumptions Made During Formalization

1. **Batches are independent**: No ordering constraint between batches. The model allows
   arbitrary interleaving of batch actions. This matches the orchestrator's
   `ProcessBatchesConcurrent` which runs batches in parallel via goroutines.

2. **L1 submission is atomic**: The three L1 transactions (commitBatch, proveBatch,
   executeBatch) are modeled as a single atomic action. In the real system, these are
   separate transactions but the code treats them as a logical unit -- if any fails,
   the entire submission is retried.

3. **Failure is non-deterministic**: At each stage, the model allows both success and
   failure paths. This over-approximates the real system (where failure probability is
   bounded) to ensure verification covers all possible behaviors.

4. **Retry count is per-stage**: When a batch advances to a new stage, its retry counter
   resets to 0. This matches the code's `executeWithRetry` loop which runs independently
   for each stage.

5. **Finalization is deterministic**: After successful L1 submission, finalization cannot
   fail. This is justified by Avalanche's sub-second Snowman consensus finality.

6. **No concurrent batch limits in model**: The model does not enforce
   `MaxConcurrentBatches`. All batches can progress simultaneously. This is a sound
   over-approximation: any property that holds without limits also holds with them.

## Verification Results

### Safety Check (with symmetry reduction)

```
TLC2 Version 2.16 of 31 December 2020
Model checking completed. No error has been found.
9,144 states generated, 2,024 distinct states found, 0 states left on queue.
Depth of complete state graph: 22.
Finished in 01s.
```

All 5 safety invariants verified:
- TypeOK: PASS
- PipelineIntegrity: PASS
- AtomicFailure: PASS
- ArtifactDependencyChain: PASS
- MonotonicProgress: PASS

### Liveness Check (without symmetry -- per TLC recommendation)

```
TLC2 Version 2.16 of 31 December 2020
Implied-temporal checking--satisfiability problem has 3 branches.
Checking 3 branches of temporal properties for the complete state space
with 31,944 total distinct states.
Model checking completed. No error has been found.
48,042 states generated, 10,648 distinct states found, 0 states left on queue.
Depth of complete state graph: 22.
Finished in 02s.
```

Temporal property verified:
- EventualTermination: PASS (every batch eventually reaches "finalized" or "failed")

### Reproduction Instructions

```bash
# Setup
BASE=<repository-root>
BUILD=$BASE/zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/experiments/E2EPipeline/_build
TLA2TOOLS=$BASE/lab/2-logicist/tools/tla2tools.jar

mkdir -p $BUILD
cp $BASE/zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/specs/E2EPipeline/E2EPipeline.tla $BUILD/
cp $BASE/zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/experiments/E2EPipeline/MC_E2EPipeline.tla $BUILD/

# Safety check (with symmetry)
cp $BASE/zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/experiments/E2EPipeline/MC_E2EPipeline_safety.cfg $BUILD/
cd $BUILD && java -cp $TLA2TOOLS tlc2.TLC MC_E2EPipeline -config MC_E2EPipeline_safety.cfg -workers 4

# Liveness check (without symmetry -- required for correctness)
cp $BASE/zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/experiments/E2EPipeline/MC_E2EPipeline_liveness.cfg $BUILD/
cd $BUILD && java -cp $TLA2TOOLS tlc2.TLC MC_E2EPipeline -config MC_E2EPipeline_liveness.cfg -workers 4
```

## Model Parameters

| Parameter | Value | Justification |
|-----------|-------|---------------|
| Batches | {b1, b2, b3} | 3 batches: sufficient to expose interleaving bugs |
| MaxRetries | 3 | 4 total attempts per stage; matches production policy |
| Symmetry | Permutations(Batches) | Batches are interchangeable; reduces state space 6x |

## Open Issues

1. **Concurrent batch limits**: The model does not enforce `MaxConcurrentBatches = 2`
   from the production config. Adding a semaphore variable would model this constraint
   but increases state space. Current over-approximation is sound.

2. **Batch ordering on L1**: The model does not enforce that batches are finalized in
   order on L1. In production, L1 state roots form a chain where batch N+1's
   preStateRoot must equal batch N's postStateRoot. This ordering invariant requires
   modeling state root values (finite hash domain) and is deferred to a future unit.

3. **Timeout modeling**: The real system has per-stage timeouts (WitnessGenTimeout,
   ProofGenTimeout, L1SubmitTimeout). These are not modeled because TLA+ models
   abstract away real time. The retry mechanism subsumes timeout behavior.

4. **Pipeline parallelism**: The model allows full concurrency (all batches active).
   Modeling the overlap pattern (execute N+1 while proving N) would require adding
   a resource constraint on the prover. Current model is a sound over-approximation.

## Verdict

**PASS**. The E2E pipeline state machine is formally verified. All safety invariants
hold across the exhaustive state space. The liveness property (EventualTermination)
holds under weak fairness. The specification is ready for Phase 2 audit.
