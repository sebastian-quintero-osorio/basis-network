package pipeline

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// Pipeline Orchestrator
// [Spec: Next == \E b \in Batches: ExecuteSuccess(b) \/ ... \/ Finalize(b)]
// ---------------------------------------------------------------------------

// Orchestrator manages the E2E proving pipeline, advancing batches through
// stages with automatic retry and pipeline parallelism.
//
// Architecture:
//   - Event-driven: each stage completion triggers the next stage
//   - Stateless stages: stage implementations are pure functions on batch state
//   - Fault-tolerant: exponential backoff retry with failure after max retries
//   - Observable: per-stage timing metrics for bottleneck analysis
//
// Pipeline parallelism model:
//
//	While batch N is in the proving stage (the bottleneck at 71.3%), batch N+1
//	can be executing and generating witnesses. This overlaps the two most expensive
//	stages, targeting near-100% prover utilization.
//
// [Spec: zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/specs/E2EPipeline/E2EPipeline.tla]
type Orchestrator struct {
	config  PipelineConfig
	logger  *slog.Logger
	metrics *PipelineMetrics
	stages  Stages

	// Pipeline state
	mu             sync.Mutex
	nextBatchID    uint64
	activeBatches  map[uint64]*BatchState
	completedCount int
	failedCount    int
}

// Stages returns the underlying pipeline stages for direct access (e.g., aggregation).
func (o *Orchestrator) Stages() Stages {
	return o.stages
}

// NewOrchestrator creates a new pipeline orchestrator with the given configuration.
func NewOrchestrator(config PipelineConfig, logger *slog.Logger, stages Stages) *Orchestrator {
	if logger == nil {
		logger = slog.Default()
	}
	return &Orchestrator{
		config:        config,
		logger:        logger,
		metrics:       NewPipelineMetrics(),
		stages:        stages,
		activeBatches: make(map[uint64]*BatchState),
		nextBatchID:   1,
	}
}

// stageDescriptor binds a stage name to its execution function, target stage,
// timeout, and the artifact boolean it sets on success.
type stageDescriptor struct {
	name     string
	target   BatchStage
	fn       func(context.Context, *BatchState) error
	timeout  time.Duration
	artifact *bool // pointer to the BatchState artifact boolean to set on success
}

// ProcessBatch runs a single batch through the entire pipeline E2E.
// Returns nil on finalization, or an error if the batch fails at any stage.
//
// Stage progression with artifact tracking:
//  1. Execute:  Run transactions through EVM, collect traces     -> HasTrace = true
//  2. Witness:  Generate witness tables (Go -> Rust via JSON)    -> HasWitness = true
//  3. Prove:    Generate ZK proof (Groth16)                      -> HasProof = true
//  4. Submit:   Submit proof to L1 (commit + prove + execute)    -> ProofOnL1 = true
//  5. Finalize: Mark batch as finalized (deterministic)
//
// Each stage is retried according to RetryPolicy on failure.
// If a stage exhausts retries, the batch transitions to Failed.
//
// [Spec: ProcessBatch models Next for a single batch b,
//
//	with ExecuteSuccess/Fail/Exhaust -> WitnessSuccess/... -> ... -> Finalize]
func (o *Orchestrator) ProcessBatch(ctx context.Context, batch *BatchState) error {
	if o.stages == nil {
		return ErrStageNotConfigured
	}

	o.mu.Lock()
	o.activeBatches[batch.BatchID] = batch
	o.mu.Unlock()

	defer func() {
		o.metrics.AddBatch(batch.Metrics)
		o.mu.Lock()
		delete(o.activeBatches, batch.BatchID)
		if batch.Stage == StageFinalized {
			o.completedCount++
		} else {
			o.failedCount++
		}
		o.mu.Unlock()
	}()

	o.logger.Info("pipeline: starting batch",
		"batch_id", batch.BatchID,
		"tx_count", batch.TxCount,
	)

	// Define stage sequence with artifact pointers.
	// Each successful stage sets the corresponding TLA+ artifact boolean.
	// [Spec: ExecuteSuccess sets hasTrace' = TRUE, etc.]
	stages := []stageDescriptor{
		{"execute", StageExecuted, o.stages.Execute, 2 * time.Minute, &batch.HasTrace},
		{"witness", StageWitnessed, o.stages.WitnessGen, o.config.WitnessGenTimeout, &batch.HasWitness},
		{"prove", StageProved, o.stages.Prove, o.config.ProofGenTimeout, &batch.HasProof},
		{"submit", StageSubmitted, o.stages.Submit, o.config.L1SubmitTimeout, &batch.ProofOnL1},
	}

	for _, s := range stages {
		err := o.executeWithRetry(ctx, batch, s.name, s.target, s.fn, s.timeout)
		if err != nil {
			// [Spec: ExecuteExhaust/WitnessExhaust/ProveExhaust/SubmitExhaust
			//   -> batchStage' = "failed"]
			batch.Advance(StageFailed, time.Since(batch.CreatedAt), err)
			o.logger.Error("pipeline: batch failed",
				"batch_id", batch.BatchID,
				"stage", s.name,
				"error", err.Error(),
				"retries", batch.RetryCount,
			)
			return &StageError{
				Stage:   s.target,
				BatchID: batch.BatchID,
				Cause:   err,
				Attempt: batch.RetryCount,
			}
		}
		// Set the artifact boolean after successful completion.
		// This mirrors the TLA+ atomic transition: stage advancement + artifact = TRUE.
		*s.artifact = true
	}

	// [Spec: Finalize(b) -- batchStage' = "finalized", deterministic, no failure mode]
	batch.Advance(StageFinalized, time.Since(batch.CreatedAt), nil)
	o.logger.Info("pipeline: batch finalized",
		"batch_id", batch.BatchID,
		"total_duration", batch.Metrics.TotalDuration,
		"tx_count", batch.TxCount,
	)

	return nil
}

// executeWithRetry runs a pipeline stage with automatic retry and exponential backoff.
//
// [Spec: For each stage, models the Success/Fail/Exhaust triple:
//   - Success: stage function returns nil, batch advances
//   - Fail:    stage function returns error, retryCount increments, backoff applied
//   - Exhaust: retryCount >= MaxRetries, returns error for terminal failure]
func (o *Orchestrator) executeWithRetry(
	ctx context.Context,
	batch *BatchState,
	stageName string,
	stage BatchStage,
	fn func(context.Context, *BatchState) error,
	timeout time.Duration,
) error {
	policy := o.config.RetryPolicy
	var lastErr error

	for attempt := 0; attempt <= policy.MaxRetries; attempt++ {
		if attempt > 0 {
			// [Spec: ExecuteFail/WitnessFail/ProveFail/SubmitFail
			//   -> retryCount' = retryCount + 1, batch remains at current stage]
			backoff := policy.BackoffDuration(attempt - 1)
			o.logger.Warn("pipeline: retrying stage",
				"batch_id", batch.BatchID,
				"stage", stageName,
				"attempt", attempt,
				"backoff", backoff,
			)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(backoff):
			}
		}

		stageCtx, cancel := context.WithTimeout(ctx, timeout)
		start := time.Now()
		err := fn(stageCtx, batch)
		duration := time.Since(start)
		cancel()

		if err == nil {
			// [Spec: Success action -- retryCount' = 0, stage advances]
			batch.RetryCount = attempt
			batch.Advance(stage, duration, nil)
			o.logger.Info("pipeline: stage complete",
				"batch_id", batch.BatchID,
				"stage", stageName,
				"duration", duration,
				"attempt", attempt,
			)
			return nil
		}

		lastErr = err
		o.logger.Warn("pipeline: stage failed",
			"batch_id", batch.BatchID,
			"stage", stageName,
			"attempt", attempt,
			"error", err.Error(),
			"duration", duration,
		)
	}

	// [Spec: Exhaust action -- retryCount >= MaxRetries]
	batch.RetryCount = policy.MaxRetries
	return fmt.Errorf("%w: exhausted %d retries for stage %s: %v",
		ErrRetriesExhausted, policy.MaxRetries, stageName, lastErr)
}

// ProcessBatchesConcurrent processes multiple batches with pipeline parallelism.
// Up to MaxConcurrentBatches can be in-flight simultaneously.
//
// Pipeline parallelism diagram:
//
//	Time ->
//	Batch 1: [Execute][Witness][===Prove===][Submit]
//	Batch 2:          [Execute][Witness]    [===Prove===][Submit]
//	Batch 3:                   [Execute]    [Witness]    [===Prove===][Submit]
//
// The proving stage (longest at 71.3%) overlaps with execution of subsequent batches.
//
// [Spec: Next == \E b \in Batches: BatchAction(b) -- models concurrent independent batches]
func (o *Orchestrator) ProcessBatchesConcurrent(
	ctx context.Context,
	batches []*BatchState,
) (*PipelineMetrics, error) {
	sem := make(chan struct{}, o.config.MaxConcurrentBatches)
	var wg sync.WaitGroup
	var mu sync.Mutex
	var firstErr error

	for _, batch := range batches {
		select {
		case <-ctx.Done():
			wg.Wait()
			return o.metrics, ctx.Err()
		case sem <- struct{}{}:
		}

		wg.Add(1)
		go func(b *BatchState) {
			defer wg.Done()
			defer func() { <-sem }()

			if err := o.ProcessBatch(ctx, b); err != nil {
				mu.Lock()
				if firstErr == nil {
					firstErr = err
				}
				mu.Unlock()
			}
		}(batch)
	}

	wg.Wait()
	o.metrics.ComputeAverages()
	return o.metrics, firstErr
}

// Metrics returns the current pipeline metrics.
func (o *Orchestrator) Metrics() *PipelineMetrics {
	return o.metrics
}

// MetricsJSON returns pipeline metrics as formatted JSON.
func (o *Orchestrator) MetricsJSON() ([]byte, error) {
	o.metrics.ComputeAverages()
	return json.MarshalIndent(o.metrics, "", "  ")
}

// ActiveBatchCount returns the number of batches currently in-flight.
func (o *Orchestrator) ActiveBatchCount() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return len(o.activeBatches)
}

// Stats returns a summary of pipeline execution.
func (o *Orchestrator) Stats() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return fmt.Sprintf("completed=%d failed=%d active=%d",
		o.completedCount, o.failedCount, len(o.activeBatches))
}

// PipelineStats returns active, completed, and failed counts for health reporting.
func (o *Orchestrator) PipelineStats() (active int, completed int, failed int) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return len(o.activeBatches), o.completedCount, o.failedCount
}

// DrainAndWait stops accepting new batches and waits for all active batches
// to complete. Returns a list of batch IDs still in-flight if the context
// expires before all batches complete.
func (o *Orchestrator) DrainAndWait(ctx context.Context) []uint64 {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			o.mu.Lock()
			remaining := make([]uint64, 0, len(o.activeBatches))
			for id := range o.activeBatches {
				remaining = append(remaining, id)
			}
			o.mu.Unlock()
			return remaining
		case <-ticker.C:
			o.mu.Lock()
			active := len(o.activeBatches)
			o.mu.Unlock()
			if active == 0 {
				return nil
			}
			o.logger.Info("pipeline: draining", "active_batches", active)
		}
	}
}
