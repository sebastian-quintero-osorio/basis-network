package pipeline

import (
	"context"
	"errors"
	"fmt"
)

// ---------------------------------------------------------------------------
// Stage Interface
// [Spec: ExecuteSuccess, WitnessSuccess, ProveSuccess, SubmitSuccess actions]
// ---------------------------------------------------------------------------

// Stages defines the pipeline stage implementations.
// Each method executes a single stage of the proving pipeline, modifying
// the batch state with stage-specific outputs on success.
//
// Implementations must be safe for concurrent use across different batches.
// A single batch is never processed by multiple goroutines simultaneously.
type Stages interface {
	// Execute runs L2 transactions through the EVM executor and collects
	// execution traces. On success: batch.Traces, batch.PreStateRoot, and
	// batch.PostStateRoot are populated.
	//
	// [Spec: ExecuteSuccess(b) -- batchStage' = "executed", hasTrace' = TRUE]
	Execute(ctx context.Context, batch *BatchState) error

	// WitnessGen generates witness tables from execution traces.
	// Cross-language boundary: Go sends BatchTraceJSON to Rust via stdin/stdout.
	// On success: batch.WitnessResult is populated.
	//
	// [Spec: WitnessSuccess(b) -- batchStage' = "witnessed", hasWitness' = TRUE]
	WitnessGen(ctx context.Context, batch *BatchState) error

	// Prove generates a Groth16 ZK proof from witness tables.
	// This is the pipeline bottleneck (~71.3% of E2E latency for 100 tx).
	// On success: batch.ProofResult is populated.
	//
	// [Spec: ProveSuccess(b) -- batchStage' = "proved", hasProof' = TRUE]
	Prove(ctx context.Context, batch *BatchState) error

	// Submit submits the ZK proof to the Basis Network L1 on Avalanche.
	// Three L1 transactions as a logical unit: commitBatch + proveBatch + executeBatch.
	// On success: batch.L1TxHash and batch.L1GasUsed are populated.
	//
	// [Spec: SubmitSuccess(b) -- batchStage' = "submitted", proofOnL1' = TRUE]
	Submit(ctx context.Context, batch *BatchState) error

	// Aggregate folds multiple proved batches into a single aggregated proof
	// using ProtoGalaxy folding. Called after N batches are finalized.
	Aggregate(ctx context.Context, batches []*BatchState) (*AggregateResult, error)
}

// AggregateResult is the output from proof aggregation (ProtoGalaxy folding).
type AggregateResult struct {
	InstanceCount    int    `json:"instance_count"`
	IsSatisfiable    bool   `json:"is_satisfiable"`
	ProofBytes       []byte `json:"proof_bytes"`
	EstimatedGas     uint64 `json:"estimated_gas"`
	GenerationTimeMs uint64 `json:"generation_time_ms"`
}

// ---------------------------------------------------------------------------
// Error Types
// ---------------------------------------------------------------------------

// StageError is a structured error type for pipeline stage failures.
// It preserves the stage identity, batch ID, and root cause for diagnostics.
type StageError struct {
	Stage   BatchStage
	BatchID uint64
	Cause   error
	Attempt int
}

// Error returns a human-readable error message.
func (e *StageError) Error() string {
	return fmt.Sprintf("stage %s failed for batch %d (attempt %d): %v",
		e.Stage, e.BatchID, e.Attempt, e.Cause)
}

// Unwrap returns the underlying cause for errors.Is/As.
func (e *StageError) Unwrap() error {
	return e.Cause
}

// Sentinel errors for pipeline operations.
var (
	ErrStageNotConfigured = errors.New("pipeline: stages not configured")
	ErrRetriesExhausted   = errors.New("pipeline: retries exhausted")
	ErrBatchFailed        = errors.New("pipeline: batch failed")
)

// ---------------------------------------------------------------------------
// Invariant Checking Functions
// These functions verify the TLA+ safety invariants at runtime.
// Used in tests for verification; can be called in production for defensive checks.
//
// [Spec: PipelineIntegrity, AtomicFailure, ArtifactDependencyChain, MonotonicProgress]
// ---------------------------------------------------------------------------

// CheckPipelineIntegrity verifies that every finalized batch has a complete
// artifact chain and L1 proof verification.
//
// [Spec: PipelineIntegrity == \A b \in Batches:
//
//	batchStage[b] = "finalized" =>
//	  /\ hasTrace[b] /\ hasWitness[b] /\ hasProof[b] /\ proofOnL1[b]]
func CheckPipelineIntegrity(bs *BatchState) error {
	if bs.Stage != StageFinalized {
		return nil
	}
	if !bs.HasTrace {
		return fmt.Errorf("PipelineIntegrity violated: finalized batch %d missing execution trace", bs.BatchID)
	}
	if !bs.HasWitness {
		return fmt.Errorf("PipelineIntegrity violated: finalized batch %d missing witness", bs.BatchID)
	}
	if !bs.HasProof {
		return fmt.Errorf("PipelineIntegrity violated: finalized batch %d missing proof", bs.BatchID)
	}
	if !bs.ProofOnL1 {
		return fmt.Errorf("PipelineIntegrity violated: finalized batch %d missing L1 proof verification", bs.BatchID)
	}
	return nil
}

// CheckAtomicFailure verifies that failed batches leave zero L1 footprint.
//
// [Spec: AtomicFailure == \A b \in Batches:
//
//	batchStage[b] = "failed" => ~proofOnL1[b]]
func CheckAtomicFailure(bs *BatchState) error {
	if bs.Stage != StageFailed {
		return nil
	}
	if bs.ProofOnL1 {
		return fmt.Errorf("AtomicFailure violated: failed batch %d has L1 proof (should have none)", bs.BatchID)
	}
	return nil
}

// CheckArtifactDependencyChain verifies the strict dependency chain between artifacts.
// No artifact can exist without its predecessor.
//
// [Spec: ArtifactDependencyChain == \A b \in Batches:
//
//	/\ hasWitness[b] => hasTrace[b]
//	/\ hasProof[b]   => hasWitness[b]
//	/\ proofOnL1[b]  => hasProof[b]]
func CheckArtifactDependencyChain(bs *BatchState) error {
	if bs.HasWitness && !bs.HasTrace {
		return fmt.Errorf("ArtifactDependencyChain violated: batch %d has witness without trace", bs.BatchID)
	}
	if bs.HasProof && !bs.HasWitness {
		return fmt.Errorf("ArtifactDependencyChain violated: batch %d has proof without witness", bs.BatchID)
	}
	if bs.ProofOnL1 && !bs.HasProof {
		return fmt.Errorf("ArtifactDependencyChain violated: batch %d has L1 proof without proof", bs.BatchID)
	}
	return nil
}

// CheckMonotonicProgress verifies that artifact presence is consistent with the
// current stage. Once an artifact is produced, the batch must be at or beyond
// the stage that produced it.
//
// [Spec: MonotonicProgress == \A b \in Batches:
//
//	/\ hasTrace[b]   => batchStage[b] \in {"executed", ..., "failed"}
//	/\ hasWitness[b] => batchStage[b] \in {"witnessed", ..., "failed"}
//	/\ hasProof[b]   => batchStage[b] \in {"proved", ..., "failed"}
//	/\ proofOnL1[b]  => batchStage[b] \in {"submitted", "finalized"}]
func CheckMonotonicProgress(bs *BatchState) error {
	if bs.HasTrace && bs.Stage == StagePending {
		return fmt.Errorf("MonotonicProgress violated: batch %d has trace but stage is pending", bs.BatchID)
	}
	if bs.HasWitness && (bs.Stage == StagePending || bs.Stage == StageExecuted) {
		return fmt.Errorf("MonotonicProgress violated: batch %d has witness but stage is %s", bs.BatchID, bs.Stage)
	}
	if bs.HasProof && (bs.Stage == StagePending || bs.Stage == StageExecuted || bs.Stage == StageWitnessed) {
		return fmt.Errorf("MonotonicProgress violated: batch %d has proof but stage is %s", bs.BatchID, bs.Stage)
	}
	if bs.ProofOnL1 && bs.Stage != StageSubmitted && bs.Stage != StageFinalized {
		return fmt.Errorf("MonotonicProgress violated: batch %d has L1 proof but stage is %s", bs.BatchID, bs.Stage)
	}
	return nil
}

// CheckAllInvariants verifies all TLA+ safety invariants for a batch.
// Returns the first violation found, or nil if all invariants hold.
func CheckAllInvariants(bs *BatchState) error {
	checks := []func(*BatchState) error{
		CheckPipelineIntegrity,
		CheckAtomicFailure,
		CheckArtifactDependencyChain,
		CheckMonotonicProgress,
	}
	for _, check := range checks {
		if err := check(bs); err != nil {
			return err
		}
	}
	return nil
}
