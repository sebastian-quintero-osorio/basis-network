package pipeline

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

// Orchestrator manages the E2E proving pipeline, advancing batches through
// stages with automatic retry and pipeline parallelism.
//
// Architecture (informed by push0, arxiv 2602.16338):
//   - Event-driven: each stage completion triggers the next stage
//   - Stateless dispatchers: stages are pure functions on batch state
//   - Fault-tolerant: exponential backoff retry with dead-letter on max retries
//   - Observable: per-stage timing metrics with W3C-style trace propagation
//
// Pipeline parallelism model:
//   While batch N is in the proving stage (the bottleneck), batch N+1 can be
//   executing and generating witnesses. This overlaps the two most expensive
//   stages, targeting near-100% prover utilization.
type Orchestrator struct {
	config  PipelineConfig
	logger  *slog.Logger
	metrics *PipelineMetrics

	// Stage executors (pluggable for testing)
	executeStage PipelineStageFunc
	witnessStage PipelineStageFunc
	proveStage   PipelineStageFunc
	submitStage  PipelineStageFunc

	// Pipeline state
	mu             sync.Mutex
	nextBatchID    uint64
	activeBatches  map[uint64]*BatchState
	completedCount int
	failedCount    int
}

// NewOrchestrator creates a new pipeline orchestrator with the given configuration.
func NewOrchestrator(config PipelineConfig, logger *slog.Logger) *Orchestrator {
	if logger == nil {
		logger = slog.Default()
	}
	return &Orchestrator{
		config:        config,
		logger:        logger,
		metrics:       NewPipelineMetrics(),
		activeBatches: make(map[uint64]*BatchState),
		nextBatchID:   1,
	}
}

// SetStages configures the pipeline stage executors.
// This allows injection of real or simulated components.
func (o *Orchestrator) SetStages(
	execute, witness, prove, submit PipelineStageFunc,
) {
	o.executeStage = execute
	o.witnessStage = witness
	o.proveStage = prove
	o.submitStage = submit
}

// ProcessBatch runs a single batch through the entire pipeline E2E.
// Returns the final batch state and metrics. This is the core pipeline loop.
//
// Stage progression:
//   1. Execute: Run transactions through EVM, collect traces
//   2. Witness: Generate witness tables from traces (Go -> Rust via JSON)
//   3. Prove:   Generate ZK proof from witness (Groth16/PLONK)
//   4. Submit:  Submit proof to L1 (commitBatch + proveBatch + executeBatch)
//
// Each stage is retried according to RetryPolicy on failure.
// If a stage exhausts retries, the batch is marked Failed.
func (o *Orchestrator) ProcessBatch(ctx context.Context, batch *BatchState) error {
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

	stages := []struct {
		name    string
		stage   BatchStage
		fn      PipelineStageFunc
		timeout time.Duration
	}{
		{"execute", StageExecuted, o.executeStage, 2 * time.Minute},
		{"witness", StageWitnessed, o.witnessStage, o.config.WitnessGenTimeout},
		{"prove", StageProved, o.proveStage, o.config.ProofGenTimeout},
		{"submit", StageSubmitted, o.submitStage, o.config.L1SubmitTimeout},
	}

	for _, s := range stages {
		if s.fn == nil {
			return fmt.Errorf("pipeline: stage %q not configured", s.name)
		}

		err := o.executeWithRetry(ctx, batch, s.name, s.stage, s.fn, s.timeout)
		if err != nil {
			batch.Advance(StageFailed, time.Since(batch.CreatedAt), err)
			o.logger.Error("pipeline: batch failed",
				"batch_id", batch.BatchID,
				"stage", s.name,
				"error", err.Error(),
				"retries", batch.RetryCount,
			)
			return fmt.Errorf("pipeline: batch %d failed at stage %s: %w",
				batch.BatchID, s.name, err)
		}
	}

	// Mark finalized
	batch.Advance(StageFinalized, time.Since(batch.CreatedAt), nil)
	o.logger.Info("pipeline: batch finalized",
		"batch_id", batch.BatchID,
		"total_duration", batch.Metrics.TotalDuration,
		"tx_count", batch.TxCount,
	)

	return nil
}

// executeWithRetry runs a pipeline stage with automatic retry and exponential backoff.
func (o *Orchestrator) executeWithRetry(
	ctx context.Context,
	batch *BatchState,
	stageName string,
	stage BatchStage,
	fn PipelineStageFunc,
	timeout time.Duration,
) error {
	policy := o.config.RetryPolicy
	var lastErr error

	for attempt := 0; attempt <= policy.MaxRetries; attempt++ {
		if attempt > 0 {
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

	batch.RetryCount = policy.MaxRetries
	return fmt.Errorf("exhausted %d retries for stage %s: %w",
		policy.MaxRetries, stageName, lastErr)
}

// ProcessBatchesConcurrent processes multiple batches with pipeline parallelism.
// Up to MaxConcurrentBatches can be in-flight simultaneously.
//
// Pipeline parallelism diagram:
//   Time ->
//   Batch 1: [Execute][Witness][===Prove===][Submit]
//   Batch 2:          [Execute][Witness]    [===Prove===][Submit]
//   Batch 3:                   [Execute]    [Witness]    [===Prove===][Submit]
//
// The proving stage (longest) overlaps with execution of subsequent batches.
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
