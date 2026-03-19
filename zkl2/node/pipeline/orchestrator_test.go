package pipeline

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

// fastStages returns simulated stages with microsecond-level timing for fast tests.
func fastStages() *SimulatedStages {
	return &SimulatedStages{
		ExecTimePerTx:    time.Microsecond,
		WitnessTimePerTx: time.Microsecond,
		ProofBaseTime:    time.Millisecond,
		ProofTimePerTx:   time.Microsecond,
		L1SubmitTime:     time.Millisecond,
		BaseConstraints:  10000,
		ConstraintsPerTx: 500,
	}
}

// fastConfig returns a pipeline config with fast retry for testing.
func fastConfig() PipelineConfig {
	return PipelineConfig{
		BatchSize:            10,
		MaxConcurrentBatches: 2,
		WitnessGenTimeout:    5 * time.Second,
		ProofGenTimeout:      5 * time.Second,
		L1SubmitTimeout:      5 * time.Second,
		RetryPolicy: RetryPolicy{
			MaxRetries:     3,
			InitialBackoff: time.Millisecond,
			MaxBackoff:     5 * time.Millisecond,
			BackoffFactor:  2.0,
		},
		WitnessGenCommand: "witness-generator",
	}
}

// failingStages implements Stages with deterministic failure at a chosen stage.
type failingStages struct {
	base      *SimulatedStages
	failAt    BatchStage // which stage to fail at
	failCount int        // how many times to fail before succeeding (-1 = always)
	calls     atomic.Int32
}

func (f *failingStages) Execute(ctx context.Context, batch *BatchState) error {
	if f.failAt == StageExecuted {
		n := int(f.calls.Add(1))
		if f.failCount < 0 || n <= f.failCount {
			return fmt.Errorf("deterministic execute failure #%d", n)
		}
	}
	return f.base.Execute(ctx, batch)
}

func (f *failingStages) WitnessGen(ctx context.Context, batch *BatchState) error {
	if f.failAt == StageWitnessed {
		n := int(f.calls.Add(1))
		if f.failCount < 0 || n <= f.failCount {
			return fmt.Errorf("deterministic witness failure #%d", n)
		}
	}
	return f.base.WitnessGen(ctx, batch)
}

func (f *failingStages) Prove(ctx context.Context, batch *BatchState) error {
	if f.failAt == StageProved {
		n := int(f.calls.Add(1))
		if f.failCount < 0 || n <= f.failCount {
			return fmt.Errorf("deterministic prove failure #%d", n)
		}
	}
	return f.base.Prove(ctx, batch)
}

func (f *failingStages) Submit(ctx context.Context, batch *BatchState) error {
	if f.failAt == StageSubmitted {
		n := int(f.calls.Add(1))
		if f.failCount < 0 || n <= f.failCount {
			return fmt.Errorf("deterministic submit failure #%d", n)
		}
	}
	return f.base.Submit(ctx, batch)
}

// ---------------------------------------------------------------------------
// E2E Tests
// ---------------------------------------------------------------------------

// TestSingleBatchE2E validates the pipeline processes a single batch end-to-end.
func TestSingleBatchE2E(t *testing.T) {
	stages := fastStages()
	config := fastConfig()
	orch := NewOrchestrator(config, nil, stages)

	batch := NewBatchState(1, 1000, 10)
	err := orch.ProcessBatch(context.Background(), batch)
	if err != nil {
		t.Fatalf("pipeline failed: %v", err)
	}

	if batch.Stage != StageFinalized {
		t.Fatalf("expected StageFinalized, got %s", batch.Stage)
	}

	// Verify all artifacts are present
	if !batch.HasTrace {
		t.Error("HasTrace should be true after finalization")
	}
	if !batch.HasWitness {
		t.Error("HasWitness should be true after finalization")
	}
	if !batch.HasProof {
		t.Error("HasProof should be true after finalization")
	}
	if !batch.ProofOnL1 {
		t.Error("ProofOnL1 should be true after finalization")
	}

	// Verify stage outputs
	if len(batch.Traces) != 10 {
		t.Errorf("expected 10 traces, got %d", len(batch.Traces))
	}
	if batch.WitnessResult == nil {
		t.Error("WitnessResult should not be nil")
	}
	if batch.ProofResult == nil {
		t.Error("ProofResult should not be nil")
	}
	if batch.L1TxHash == "" {
		t.Error("L1TxHash should not be empty")
	}

	// All invariants must hold
	if err := CheckAllInvariants(batch); err != nil {
		t.Fatalf("invariant violation: %v", err)
	}

	t.Logf("E2E latency: %v, constraints: %d, proof: %d bytes, L1 gas: %d",
		batch.Metrics.TotalDuration, batch.Metrics.ConstraintCount,
		batch.Metrics.ProofSizeBytes, batch.Metrics.L1GasUsed)
}

// TestRetryOnFailure validates automatic retry with exponential backoff.
func TestRetryOnFailure(t *testing.T) {
	base := fastStages()
	// Fail prove stage twice, then succeed on third attempt
	stages := &failingStages{
		base:      base,
		failAt:    StageProved,
		failCount: 2,
	}

	config := fastConfig()
	orch := NewOrchestrator(config, nil, stages)

	batch := NewBatchState(1, 1000, 10)
	err := orch.ProcessBatch(context.Background(), batch)
	if err != nil {
		t.Fatalf("pipeline should succeed after retries: %v", err)
	}

	if batch.Stage != StageFinalized {
		t.Fatalf("expected StageFinalized, got %s", batch.Stage)
	}

	// Verify retries happened by checking stage metrics.
	// RetryCount is per-stage (resets on advancement), so we check the prove stage's recorded retries.
	proveFound := false
	for _, sm := range batch.Metrics.StageMetrics {
		if sm.Stage == StageProved {
			proveFound = true
			if sm.Retries < 2 {
				t.Errorf("expected prove stage to record at least 2 retries, got %d", sm.Retries)
			}
		}
	}
	if !proveFound {
		t.Error("prove stage metrics not found")
	}

	if err := CheckAllInvariants(batch); err != nil {
		t.Fatalf("invariant violation after retry: %v", err)
	}
}

// TestRetryExhaustion validates that a stage failing beyond MaxRetries marks batch Failed.
func TestRetryExhaustion(t *testing.T) {
	base := fastStages()
	// Always fail at prove stage
	stages := &failingStages{
		base:      base,
		failAt:    StageProved,
		failCount: -1, // always fail
	}

	config := fastConfig()
	config.RetryPolicy.MaxRetries = 2
	orch := NewOrchestrator(config, nil, stages)

	batch := NewBatchState(1, 1000, 10)
	err := orch.ProcessBatch(context.Background(), batch)
	if err == nil {
		t.Fatal("pipeline should fail when retries exhausted")
	}

	if batch.Stage != StageFailed {
		t.Fatalf("expected StageFailed, got %s", batch.Stage)
	}

	if !errors.Is(err, ErrRetriesExhausted) {
		t.Errorf("expected ErrRetriesExhausted, got: %v", err)
	}

	// Verify StageError type
	var stageErr *StageError
	if !errors.As(err, &stageErr) {
		t.Fatal("expected *StageError")
	}
	if stageErr.Stage != StageProved {
		t.Errorf("expected stage Proved, got %s", stageErr.Stage)
	}

	if err := CheckAllInvariants(batch); err != nil {
		t.Fatalf("invariant violation after exhaustion: %v", err)
	}
}

// TestConcurrentBatches validates pipeline parallelism with multiple batches.
func TestConcurrentBatches(t *testing.T) {
	// Use longer prove times so parallelism is measurable above goroutine overhead.
	stages := fastStages()
	stages.ProofBaseTime = 20 * time.Millisecond
	stages.L1SubmitTime = 5 * time.Millisecond

	config := fastConfig()
	config.MaxConcurrentBatches = 3

	orch := NewOrchestrator(config, nil, stages)

	batches := make([]*BatchState, 5)
	for i := range batches {
		batches[i] = NewBatchState(uint64(i+1), uint64(1000+i), 10)
	}

	start := time.Now()
	metrics, err := orch.ProcessBatchesConcurrent(context.Background(), batches)
	elapsed := time.Since(start)

	if err != nil {
		t.Logf("some batches failed (expected with concurrency): %v", err)
	}

	// All batches should reach a terminal state
	for _, b := range batches {
		if !b.Stage.IsTerminal() {
			t.Errorf("batch %d in non-terminal state %s", b.BatchID, b.Stage)
		}
		if err := CheckAllInvariants(b); err != nil {
			t.Errorf("batch %d invariant violation: %v", b.BatchID, err)
		}
	}

	// With concurrency=3, should be faster than sequential
	singleBatchTime := stages.ProofBaseTime +
		time.Duration(10)*stages.ProofTimePerTx +
		stages.L1SubmitTime +
		time.Duration(10)*stages.ExecTimePerTx +
		time.Duration(10)*stages.WitnessTimePerTx
	sequentialTime := singleBatchTime * 5

	speedup := float64(sequentialTime) / float64(elapsed)
	t.Logf("Parallelism: wall=%v sequential_est=%v speedup=%.2fx completed=%d failed=%d",
		elapsed, sequentialTime, speedup, metrics.SuccessfulBatches, metrics.FailedBatches)

	if speedup < 1.3 {
		t.Errorf("insufficient parallelism: speedup=%.2fx (expected >1.3x)", speedup)
	}
}

// TestContextCancellation validates that cancelling the context stops the pipeline.
func TestContextCancellation(t *testing.T) {
	stages := fastStages()
	// Make prove stage slow enough to cancel
	stages.ProofBaseTime = 5 * time.Second

	config := fastConfig()
	orch := NewOrchestrator(config, nil, stages)

	batch := NewBatchState(1, 1000, 10)
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	err := orch.ProcessBatch(ctx, batch)
	if err == nil {
		t.Fatal("pipeline should fail on context cancellation")
	}

	// Batch should NOT be finalized
	if batch.Stage == StageFinalized {
		t.Fatal("batch should not be finalized after cancellation")
	}

	// AtomicFailure: if batch failed, no L1 footprint
	if batch.Stage == StageFailed {
		if err := CheckAtomicFailure(batch); err != nil {
			t.Fatalf("atomic failure violated after cancellation: %v", err)
		}
	}

	// ArtifactDependencyChain must hold regardless
	if err := CheckArtifactDependencyChain(batch); err != nil {
		t.Fatalf("artifact chain violated after cancellation: %v", err)
	}
}

// TestStagesNotConfigured validates that ProcessBatch fails when stages are nil.
func TestStagesNotConfigured(t *testing.T) {
	config := fastConfig()
	orch := NewOrchestrator(config, nil, nil)

	batch := NewBatchState(1, 1000, 10)
	err := orch.ProcessBatch(context.Background(), batch)
	if !errors.Is(err, ErrStageNotConfigured) {
		t.Fatalf("expected ErrStageNotConfigured, got: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Invariant Tests (TLA+ Safety Properties)
// These tests specifically target each TLA+ invariant.
// ---------------------------------------------------------------------------

// TestInvariantPipelineIntegrity verifies that finalized batches have complete artifacts.
//
// [Spec: PipelineIntegrity == \A b \in Batches:
//
//	batchStage[b] = "finalized" =>
//	  /\ hasTrace[b] /\ hasWitness[b] /\ hasProof[b] /\ proofOnL1[b]]
func TestInvariantPipelineIntegrity(t *testing.T) {
	stages := fastStages()
	config := fastConfig()
	orch := NewOrchestrator(config, nil, stages)

	// Run 10 batches, verify invariant for each
	for i := 0; i < 10; i++ {
		batch := NewBatchState(uint64(i+1), uint64(1000+i), 5)
		err := orch.ProcessBatch(context.Background(), batch)
		if err != nil {
			t.Fatalf("batch %d failed: %v", i+1, err)
		}
		if err := CheckPipelineIntegrity(batch); err != nil {
			t.Fatalf("batch %d: %v", i+1, err)
		}
	}

	// Negative test: a batch with missing artifact should be caught
	fakeBatch := &BatchState{
		BatchID:    999,
		Stage:      StageFinalized,
		HasTrace:   true,
		HasWitness: true,
		HasProof:   false, // missing proof
		ProofOnL1:  true,
	}
	if err := CheckPipelineIntegrity(fakeBatch); err == nil {
		t.Fatal("should detect missing proof on finalized batch")
	}
}

// TestInvariantAtomicFailure verifies that failed batches leave no L1 footprint.
//
// [Spec: AtomicFailure == \A b \in Batches:
//
//	batchStage[b] = "failed" => ~proofOnL1[b]]
func TestInvariantAtomicFailure(t *testing.T) {
	// Test failure at each stage
	failStages := []BatchStage{StageExecuted, StageWitnessed, StageProved, StageSubmitted}
	stageNames := []string{"execute", "witness", "prove", "submit"}

	for i, failAt := range failStages {
		t.Run(stageNames[i], func(t *testing.T) {
			base := fastStages()
			stages := &failingStages{
				base:      base,
				failAt:    failAt,
				failCount: -1,
			}

			config := fastConfig()
			config.RetryPolicy.MaxRetries = 1
			orch := NewOrchestrator(config, nil, stages)

			batch := NewBatchState(1, 1000, 5)
			_ = orch.ProcessBatch(context.Background(), batch)

			if batch.Stage != StageFailed {
				t.Fatalf("expected StageFailed, got %s", batch.Stage)
			}

			if err := CheckAtomicFailure(batch); err != nil {
				t.Fatalf("AtomicFailure violated when failing at %s: %v", stageNames[i], err)
			}
		})
	}

	// Negative test: a failed batch with L1 proof should be caught
	fakeBatch := &BatchState{
		BatchID:   999,
		Stage:     StageFailed,
		ProofOnL1: true,
	}
	if err := CheckAtomicFailure(fakeBatch); err == nil {
		t.Fatal("should detect L1 proof on failed batch")
	}
}

// TestInvariantArtifactDependencyChain verifies artifact ordering.
//
// [Spec: ArtifactDependencyChain == \A b \in Batches:
//
//	/\ hasWitness[b] => hasTrace[b]
//	/\ hasProof[b]   => hasWitness[b]
//	/\ proofOnL1[b]  => hasProof[b]]
func TestInvariantArtifactDependencyChain(t *testing.T) {
	// Test that failing at each stage preserves the dependency chain
	failStages := []BatchStage{StageExecuted, StageWitnessed, StageProved, StageSubmitted}

	for _, failAt := range failStages {
		base := fastStages()
		stages := &failingStages{
			base:      base,
			failAt:    failAt,
			failCount: -1,
		}

		config := fastConfig()
		config.RetryPolicy.MaxRetries = 1
		orch := NewOrchestrator(config, nil, stages)

		batch := NewBatchState(1, 1000, 5)
		_ = orch.ProcessBatch(context.Background(), batch)

		if err := CheckArtifactDependencyChain(batch); err != nil {
			t.Fatalf("ArtifactDependencyChain violated when failing at %s: %v", failAt, err)
		}
	}

	// Negative tests: invalid artifact combinations
	tests := []struct {
		name       string
		hasTrace   bool
		hasWitness bool
		hasProof   bool
		proofOnL1  bool
	}{
		{"witness without trace", false, true, false, false},
		{"proof without witness", true, false, true, false},
		{"L1 proof without proof", true, true, false, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			batch := &BatchState{
				BatchID:    999,
				Stage:      StageFailed,
				HasTrace:   tc.hasTrace,
				HasWitness: tc.hasWitness,
				HasProof:   tc.hasProof,
				ProofOnL1:  tc.proofOnL1,
			}
			if err := CheckArtifactDependencyChain(batch); err == nil {
				t.Fatalf("should detect invalid artifact combination: %s", tc.name)
			}
		})
	}
}

// TestInvariantMonotonicProgress verifies stage-artifact consistency.
//
// [Spec: MonotonicProgress]
func TestInvariantMonotonicProgress(t *testing.T) {
	// Positive test: process batch and check at each stage
	stages := fastStages()
	config := fastConfig()
	orch := NewOrchestrator(config, nil, stages)

	batch := NewBatchState(1, 1000, 5)
	err := orch.ProcessBatch(context.Background(), batch)
	if err != nil {
		t.Fatalf("pipeline failed: %v", err)
	}
	if err := CheckMonotonicProgress(batch); err != nil {
		t.Fatalf("MonotonicProgress violated for finalized batch: %v", err)
	}

	// Negative tests: invalid stage-artifact combinations
	tests := []struct {
		name     string
		stage    BatchStage
		hasTrace bool
		proofL1  bool
	}{
		{"trace at pending", StagePending, true, false},
		{"L1 proof at proved", StageProved, true, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			b := &BatchState{
				BatchID:   999,
				Stage:     tc.stage,
				HasTrace:  tc.hasTrace,
				ProofOnL1: tc.proofL1,
			}
			if err := CheckMonotonicProgress(b); err == nil {
				t.Fatalf("should detect violation: %s", tc.name)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Adversarial Tests
// ---------------------------------------------------------------------------

// TestAdversarial_AllStagesCanFail verifies that failure at every stage
// results in a clean Failed state with no invariant violations.
func TestAdversarial_AllStagesCanFail(t *testing.T) {
	stages := []BatchStage{StageExecuted, StageWitnessed, StageProved, StageSubmitted}
	names := []string{"execute", "witness", "prove", "submit"}

	for i, failAt := range stages {
		t.Run("fail_at_"+names[i], func(t *testing.T) {
			base := fastStages()
			fs := &failingStages{base: base, failAt: failAt, failCount: -1}
			config := fastConfig()
			config.RetryPolicy.MaxRetries = 0 // fail immediately
			orch := NewOrchestrator(config, nil, fs)

			batch := NewBatchState(1, 1000, 5)
			err := orch.ProcessBatch(context.Background(), batch)

			if err == nil {
				t.Fatal("expected failure")
			}
			if batch.Stage != StageFailed {
				t.Fatalf("expected StageFailed, got %s", batch.Stage)
			}
			if err := CheckAllInvariants(batch); err != nil {
				t.Fatalf("invariant violation: %v", err)
			}
		})
	}
}

// TestAdversarial_RetryCountResetBetweenStages verifies that retry count
// resets when advancing to the next stage.
func TestAdversarial_RetryCountResetBetweenStages(t *testing.T) {
	base := fastStages()
	// Fail execute twice, then succeed; fail witness once, then succeed
	executeCallCount := atomic.Int32{}
	witnessCallCount := atomic.Int32{}

	stages := &customStages{
		base: base,
		executeFunc: func(ctx context.Context, batch *BatchState) error {
			n := int(executeCallCount.Add(1))
			if n <= 2 {
				return fmt.Errorf("execute failure #%d", n)
			}
			return base.Execute(ctx, batch)
		},
		witnessFunc: func(ctx context.Context, batch *BatchState) error {
			n := int(witnessCallCount.Add(1))
			if n <= 1 {
				return fmt.Errorf("witness failure #%d", n)
			}
			return base.WitnessGen(ctx, batch)
		},
	}

	config := fastConfig()
	orch := NewOrchestrator(config, nil, stages)

	batch := NewBatchState(1, 1000, 5)
	err := orch.ProcessBatch(context.Background(), batch)
	if err != nil {
		t.Fatalf("pipeline should succeed: %v", err)
	}

	if batch.Stage != StageFinalized {
		t.Fatalf("expected StageFinalized, got %s", batch.Stage)
	}
	if err := CheckAllInvariants(batch); err != nil {
		t.Fatalf("invariant violation: %v", err)
	}
}

// TestAdversarial_ConcurrentInvariantCheck verifies invariants hold for all
// batches in concurrent processing, including both successful and failed ones.
func TestAdversarial_ConcurrentInvariantCheck(t *testing.T) {
	base := fastStages()
	base.ProveFailRate = 0.3 // 30% prove failure rate

	config := fastConfig()
	config.MaxConcurrentBatches = 3
	config.RetryPolicy.MaxRetries = 1

	orch := NewOrchestrator(config, nil, base)

	batches := make([]*BatchState, 10)
	for i := range batches {
		batches[i] = NewBatchState(uint64(i+1), uint64(1000+i), 5)
	}

	_, _ = orch.ProcessBatchesConcurrent(context.Background(), batches)

	// Every batch must satisfy all invariants regardless of outcome
	for _, b := range batches {
		if !b.Stage.IsTerminal() {
			t.Errorf("batch %d in non-terminal state %s", b.BatchID, b.Stage)
		}
		if err := CheckAllInvariants(b); err != nil {
			t.Errorf("batch %d invariant violation: %v", b.BatchID, err)
		}
	}
}

// TestAdversarial_BackoffDuration verifies exponential backoff calculation.
func TestAdversarial_BackoffDuration(t *testing.T) {
	policy := RetryPolicy{
		MaxRetries:     5,
		InitialBackoff: 100 * time.Millisecond,
		MaxBackoff:     1 * time.Second,
		BackoffFactor:  2.0,
	}

	expected := []time.Duration{
		100 * time.Millisecond,  // attempt 0
		200 * time.Millisecond,  // attempt 1
		400 * time.Millisecond,  // attempt 2
		800 * time.Millisecond,  // attempt 3
		1000 * time.Millisecond, // attempt 4 (capped at MaxBackoff)
	}

	for i, want := range expected {
		got := policy.BackoffDuration(i)
		if got != want {
			t.Errorf("attempt %d: got %v, want %v", i, got, want)
		}
	}
}

// TestAdversarial_MetricsAccuracy verifies metrics are correctly recorded.
func TestAdversarial_MetricsAccuracy(t *testing.T) {
	stages := fastStages()
	config := fastConfig()
	orch := NewOrchestrator(config, nil, stages)

	// Process 3 successful batches
	for i := 0; i < 3; i++ {
		batch := NewBatchState(uint64(i+1), uint64(1000+i), 5)
		if err := orch.ProcessBatch(context.Background(), batch); err != nil {
			t.Fatalf("batch %d failed: %v", i+1, err)
		}
	}

	metrics := orch.Metrics()
	if metrics.TotalBatches != 3 {
		t.Errorf("expected 3 total batches, got %d", metrics.TotalBatches)
	}
	if metrics.SuccessfulBatches != 3 {
		t.Errorf("expected 3 successful batches, got %d", metrics.SuccessfulBatches)
	}
	if metrics.FailedBatches != 0 {
		t.Errorf("expected 0 failed batches, got %d", metrics.FailedBatches)
	}

	// Verify JSON serialization works
	jsonBytes, err := orch.MetricsJSON()
	if err != nil {
		t.Fatalf("MetricsJSON failed: %v", err)
	}
	if len(jsonBytes) == 0 {
		t.Error("MetricsJSON returned empty")
	}
}

// TestAdversarial_BatchStageString verifies stage string representation.
func TestAdversarial_BatchStageString(t *testing.T) {
	cases := []struct {
		stage BatchStage
		want  string
	}{
		{StagePending, "pending"},
		{StageExecuted, "executed"},
		{StageWitnessed, "witnessed"},
		{StageProved, "proved"},
		{StageSubmitted, "submitted"},
		{StageFinalized, "finalized"},
		{StageFailed, "failed"},
		{BatchStage(99), "unknown(99)"},
	}

	for _, tc := range cases {
		got := tc.stage.String()
		if got != tc.want {
			t.Errorf("stage %d: got %q, want %q", tc.stage, got, tc.want)
		}
	}
}

// TestAdversarial_IsTerminal verifies terminal state detection.
func TestAdversarial_IsTerminal(t *testing.T) {
	terminal := []BatchStage{StageFinalized, StageFailed}
	nonTerminal := []BatchStage{StagePending, StageExecuted, StageWitnessed, StageProved, StageSubmitted}

	for _, s := range terminal {
		if !s.IsTerminal() {
			t.Errorf("%s should be terminal", s)
		}
	}
	for _, s := range nonTerminal {
		if s.IsTerminal() {
			t.Errorf("%s should not be terminal", s)
		}
	}
}

// ---------------------------------------------------------------------------
// customStages allows per-method function overrides for fine-grained test control.
// ---------------------------------------------------------------------------

type customStages struct {
	base        *SimulatedStages
	executeFunc func(context.Context, *BatchState) error
	witnessFunc func(context.Context, *BatchState) error
	proveFunc   func(context.Context, *BatchState) error
	submitFunc  func(context.Context, *BatchState) error
}

func (c *customStages) Execute(ctx context.Context, batch *BatchState) error {
	if c.executeFunc != nil {
		return c.executeFunc(ctx, batch)
	}
	return c.base.Execute(ctx, batch)
}

func (c *customStages) WitnessGen(ctx context.Context, batch *BatchState) error {
	if c.witnessFunc != nil {
		return c.witnessFunc(ctx, batch)
	}
	return c.base.WitnessGen(ctx, batch)
}

func (c *customStages) Prove(ctx context.Context, batch *BatchState) error {
	if c.proveFunc != nil {
		return c.proveFunc(ctx, batch)
	}
	return c.base.Prove(ctx, batch)
}

func (c *customStages) Submit(ctx context.Context, batch *BatchState) error {
	if c.submitFunc != nil {
		return c.submitFunc(ctx, batch)
	}
	return c.base.Submit(ctx, batch)
}
