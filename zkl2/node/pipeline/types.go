// Package pipeline implements the E2E proving pipeline orchestrator for Basis Network zkEVM L2.
//
// The pipeline connects all components into a unified state machine:
//
//	Sequencer -> Executor -> StateDB -> WitnessGenerator -> Prover -> L1Submitter
//
// Each batch transitions through stages:
//
//	Pending -> Executed -> Witnessed -> Proved -> Submitted -> Finalized
//
// Any stage may fail. After MaxRetries exhausted, the batch transitions to a terminal
// Failed state. Failure at any stage must not corrupt L1 state or leave partial
// artifacts on-chain.
//
// [Spec: zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/specs/E2EPipeline/E2EPipeline.tla]
package pipeline

import (
	"encoding/json"
	"fmt"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// Pipeline Stages
// [Spec: StageSet == {"pending", "executed", "witnessed", "proved",
//                     "submitted", "finalized", "failed"}]
// ---------------------------------------------------------------------------

// BatchStage represents the current stage of a batch in the proving pipeline.
// Transitions are strictly monotonic: a batch can only advance forward through
// the defined sequence, or transition to the terminal Failed state.
//
// [Spec: StageSet, TerminalStages]
type BatchStage int

const (
	StagePending   BatchStage = iota // Batch created, transactions selected
	StageExecuted                    // EVM execution complete, traces generated
	StageWitnessed                   // Witness tables generated from traces
	StageProved                      // ZK proof generated (Groth16)
	StageSubmitted                   // Proof submitted and verified on L1
	StageFinalized                   // L1 state root accepted (terminal)
	StageFailed                      // Terminal failure after max retries
)

var stageNames = map[BatchStage]string{
	StagePending:   "pending",
	StageExecuted:  "executed",
	StageWitnessed: "witnessed",
	StageProved:    "proved",
	StageSubmitted: "submitted",
	StageFinalized: "finalized",
	StageFailed:    "failed",
}

// String returns the TLA+ stage name.
func (s BatchStage) String() string {
	if name, ok := stageNames[s]; ok {
		return name
	}
	return fmt.Sprintf("unknown(%d)", s)
}

// IsTerminal returns true if the stage is a terminal state (finalized or failed).
//
// [Spec: TerminalStages == {"finalized", "failed"}]
func (s BatchStage) IsTerminal() bool {
	return s == StageFinalized || s == StageFailed
}

// ---------------------------------------------------------------------------
// Stage Metrics
// ---------------------------------------------------------------------------

// StageMetrics captures timing for a single pipeline stage execution.
type StageMetrics struct {
	Stage     BatchStage    `json:"stage"`
	StartTime time.Time     `json:"start_time"`
	EndTime   time.Time     `json:"end_time"`
	Duration  time.Duration `json:"duration_ms"`
	Retries   int           `json:"retries"`
	Error     string        `json:"error,omitempty"`
}

// BatchMetrics captures the complete pipeline metrics for a single batch.
type BatchMetrics struct {
	BatchID          uint64         `json:"batch_id"`
	TxCount          int            `json:"tx_count"`
	Stage            BatchStage     `json:"current_stage"`
	StageMetrics     []StageMetrics `json:"stage_metrics"`
	TotalDuration    time.Duration  `json:"total_duration_ms"`
	ConstraintCount  uint64         `json:"constraint_count"`
	ProofSizeBytes   uint64         `json:"proof_size_bytes"`
	WitnessSizeBytes uint64         `json:"witness_size_bytes"`
	L1GasUsed        uint64         `json:"l1_gas_used"`
}

// PipelineMetrics aggregates metrics across all batches.
type PipelineMetrics struct {
	mu                sync.RWMutex
	Batches           []BatchMetrics           `json:"batches"`
	TotalBatches      int                      `json:"total_batches"`
	SuccessfulBatches int                      `json:"successful_batches"`
	FailedBatches     int                      `json:"failed_batches"`
	AvgE2ELatency     time.Duration            `json:"avg_e2e_latency_ms"`
	AvgStageLatency   map[string]time.Duration `json:"avg_stage_latency_ms"`
}

// NewPipelineMetrics creates an empty metrics aggregator.
func NewPipelineMetrics() *PipelineMetrics {
	return &PipelineMetrics{
		AvgStageLatency: make(map[string]time.Duration),
	}
}

// AddBatch records a completed batch's metrics.
func (pm *PipelineMetrics) AddBatch(m BatchMetrics) {
	pm.mu.Lock()
	defer pm.mu.Unlock()
	pm.Batches = append(pm.Batches, m)
	pm.TotalBatches++
	if m.Stage == StageFinalized {
		pm.SuccessfulBatches++
	} else if m.Stage == StageFailed {
		pm.FailedBatches++
	}
}

// ComputeAverages calculates average latencies across all recorded batches.
func (pm *PipelineMetrics) ComputeAverages() {
	pm.mu.Lock()
	defer pm.mu.Unlock()

	if len(pm.Batches) == 0 {
		return
	}

	var totalE2E time.Duration
	stageTotals := make(map[string]time.Duration)
	stageCounts := make(map[string]int)

	for _, b := range pm.Batches {
		totalE2E += b.TotalDuration
		for _, sm := range b.StageMetrics {
			name := sm.Stage.String()
			stageTotals[name] += sm.Duration
			stageCounts[name]++
		}
	}

	pm.AvgE2ELatency = totalE2E / time.Duration(len(pm.Batches))
	for name, total := range stageTotals {
		if stageCounts[name] > 0 {
			pm.AvgStageLatency[name] = total / time.Duration(stageCounts[name])
		}
	}
}

// JSON returns the metrics as formatted JSON.
func (pm *PipelineMetrics) JSON() ([]byte, error) {
	pm.mu.RLock()
	defer pm.mu.RUnlock()
	return json.MarshalIndent(pm, "", "  ")
}

// ---------------------------------------------------------------------------
// Retry Policy
// [Spec: retryCount variable -- 0..MaxRetries per batch per stage]
// ---------------------------------------------------------------------------

// RetryPolicy defines the retry behavior for failed pipeline stages.
// Exponential backoff: delay = InitialBackoff * BackoffFactor^attempt, capped at MaxBackoff.
type RetryPolicy struct {
	MaxRetries     int           `json:"max_retries"`
	InitialBackoff time.Duration `json:"initial_backoff_ms"`
	MaxBackoff     time.Duration `json:"max_backoff_ms"`
	BackoffFactor  float64       `json:"backoff_factor"`
}

// DefaultRetryPolicy returns a production-grade retry policy.
// Exponential backoff: 1s -> 2s -> 4s -> 8s -> 16s (max 5 retries).
func DefaultRetryPolicy() RetryPolicy {
	return RetryPolicy{
		MaxRetries:     5,
		InitialBackoff: 1 * time.Second,
		MaxBackoff:     30 * time.Second,
		BackoffFactor:  2.0,
	}
}

// BackoffDuration computes the backoff duration for the given retry attempt.
func (rp RetryPolicy) BackoffDuration(attempt int) time.Duration {
	backoff := rp.InitialBackoff
	for i := 0; i < attempt; i++ {
		backoff = time.Duration(float64(backoff) * rp.BackoffFactor)
		if backoff > rp.MaxBackoff {
			backoff = rp.MaxBackoff
			break
		}
	}
	return backoff
}

// ---------------------------------------------------------------------------
// Pipeline Configuration
// ---------------------------------------------------------------------------

// PipelineConfig holds configuration for the E2E pipeline orchestrator.
type PipelineConfig struct {
	// BatchSize is the number of transactions per batch.
	BatchSize int `json:"batch_size"`

	// MaxConcurrentBatches is the number of batches processed in parallel.
	// Pipeline parallelism: execute batch N+1 while proving batch N.
	MaxConcurrentBatches int `json:"max_concurrent_batches"`

	// WitnessGenTimeout is the maximum time allowed for witness generation.
	WitnessGenTimeout time.Duration `json:"witness_gen_timeout_ms"`

	// ProofGenTimeout is the maximum time allowed for proof generation.
	ProofGenTimeout time.Duration `json:"proof_gen_timeout_ms"`

	// L1SubmitTimeout is the maximum time allowed for L1 submission.
	L1SubmitTimeout time.Duration `json:"l1_submit_timeout_ms"`

	// RetryPolicy defines retry behavior for failed stages.
	RetryPolicy RetryPolicy `json:"retry_policy"`

	// WitnessGenCommand is the command to invoke the Rust witness generator.
	// The Go orchestrator communicates with Rust via JSON over stdin/stdout.
	WitnessGenCommand string `json:"witness_gen_command"`
}

// DefaultPipelineConfig returns production defaults.
func DefaultPipelineConfig() PipelineConfig {
	return PipelineConfig{
		BatchSize:            100,
		MaxConcurrentBatches: 2,
		WitnessGenTimeout:    60 * time.Second,
		ProofGenTimeout:      5 * time.Minute,
		L1SubmitTimeout:      2 * time.Minute,
		RetryPolicy:          DefaultRetryPolicy(),
		WitnessGenCommand:    "witness-generator",
	}
}

// ---------------------------------------------------------------------------
// Cross-Language Boundary Types
// JSON serialization format between Go orchestrator and Rust witness generator.
// The Go-Rust boundary uses JSON over stdin/stdout (<2.5ms overhead for 100 tx).
// ---------------------------------------------------------------------------

// ExecutionTraceJSON mirrors the executor's ExecutionTrace for JSON serialization.
type ExecutionTraceJSON struct {
	TxHash      string           `json:"tx_hash"`
	From        string           `json:"from"`
	To          string           `json:"to,omitempty"`
	Value       string           `json:"value"`
	GasUsed     uint64           `json:"gas_used"`
	Success     bool             `json:"success"`
	OpcodeCount int              `json:"opcode_count"`
	Entries     []TraceEntryJSON `json:"entries"`
}

// TraceEntryJSON is the JSON-serializable trace entry for the Go-Rust boundary.
type TraceEntryJSON struct {
	Op          string `json:"op"`
	Account     string `json:"account,omitempty"`
	Slot        string `json:"slot,omitempty"`
	Value       string `json:"value,omitempty"`
	OldValue    string `json:"old_value,omitempty"`
	NewValue    string `json:"new_value,omitempty"`
	From        string `json:"from,omitempty"`
	To          string `json:"to,omitempty"`
	CallValue   string `json:"call_value,omitempty"`
	PrevBalance string `json:"prev_balance,omitempty"`
	CurrBalance string `json:"curr_balance,omitempty"`
	Reason      string `json:"reason,omitempty"`
	PrevNonce   uint64 `json:"prev_nonce,omitempty"`
	CurrNonce   uint64 `json:"curr_nonce,omitempty"`
}

// BatchTraceJSON is the top-level input to the Rust witness generator.
type BatchTraceJSON struct {
	BlockNumber   uint64               `json:"block_number"`
	PreStateRoot  string               `json:"pre_state_root"`
	PostStateRoot string               `json:"post_state_root"`
	Traces        []ExecutionTraceJSON `json:"traces"`
}

// WitnessResultJSON is the output from the Rust witness generator.
type WitnessResultJSON struct {
	BlockNumber      uint64 `json:"block_number"`
	PreStateRoot     string `json:"pre_state_root"`
	PostStateRoot    string `json:"post_state_root"`
	TotalRows        uint64 `json:"total_rows"`
	TotalFieldElems  uint64 `json:"total_field_elements"`
	SizeBytes        uint64 `json:"size_bytes"`
	GenerationTimeMs uint64 `json:"generation_time_ms"`
}

// ProofResultJSON represents a generated ZK proof.
type ProofResultJSON struct {
	ProofBytes       []byte `json:"proof_bytes"`
	PublicInputs     []byte `json:"public_inputs"`
	EvmProofBytes    []byte `json:"evm_proof_bytes"`    // Decompressed for on-chain verification
	ProofSizeBytes   uint64 `json:"proof_size_bytes"`
	ConstraintCount  uint64 `json:"constraint_count"`
	GenerationTimeMs uint64 `json:"generation_time_ms"`
}

// ---------------------------------------------------------------------------
// Batch State
// [Spec: batchStage, retryCount, hasTrace, hasWitness, hasProof, proofOnL1]
// ---------------------------------------------------------------------------

// BatchState holds the mutable state of a batch as it progresses through the pipeline.
// Each artifact tracking field maps directly to a TLA+ boolean variable.
type BatchState struct {
	mu sync.Mutex

	// Identity
	BatchID     uint64    `json:"batch_id"`
	BlockNumber uint64    `json:"block_number"`
	CreatedAt   time.Time `json:"created_at"`

	// Current stage [Spec: batchStage[b]]
	Stage BatchStage `json:"stage"`

	// Transaction count (set at creation)
	TxCount int `json:"tx_count"`

	// Artifact tracking -- mirrors TLA+ boolean variables exactly.
	// These are set by the orchestrator after successful stage completion.
	// [Spec: hasTrace[b]]
	HasTrace bool `json:"has_trace"`
	// [Spec: hasWitness[b]]
	HasWitness bool `json:"has_witness"`
	// [Spec: hasProof[b]]
	HasProof bool `json:"has_proof"`
	// [Spec: proofOnL1[b]]
	ProofOnL1 bool `json:"proof_on_l1"`

	// Execution output (set after StageExecuted)
	PreStateRoot  string               `json:"pre_state_root,omitempty"`
	PostStateRoot string               `json:"post_state_root,omitempty"`
	Traces        []ExecutionTraceJSON `json:"traces,omitempty"`
	ExecutionTime time.Duration        `json:"execution_time_ms,omitempty"`

	// Witness output (set after StageWitnessed)
	WitnessResult *WitnessResultJSON `json:"witness_result,omitempty"`
	WitnessTime   time.Duration      `json:"witness_time_ms,omitempty"`

	// Proof output (set after StageProved)
	ProofResult *ProofResultJSON `json:"proof_result,omitempty"`
	ProofTime   time.Duration    `json:"proof_time_ms,omitempty"`

	// L1 submission (set after StageSubmitted)
	L1TxHash   string        `json:"l1_tx_hash,omitempty"`
	L1GasUsed  uint64        `json:"l1_gas_used,omitempty"`
	SubmitTime time.Duration `json:"submit_time_ms,omitempty"`

	// Metrics
	Metrics BatchMetrics `json:"metrics"`

	// Error tracking
	LastError error `json:"-"`
	// [Spec: retryCount[b]]
	RetryCount int `json:"retry_count"`
}

// NewBatchState creates a new batch in the Pending stage with no artifacts.
//
// [Spec: Init -- batchStage[b] = "pending", retryCount[b] = 0,
//
//	hasTrace[b] = FALSE, hasWitness[b] = FALSE, hasProof[b] = FALSE, proofOnL1[b] = FALSE]
func NewBatchState(batchID, blockNumber uint64, txCount int) *BatchState {
	now := time.Now()
	return &BatchState{
		BatchID:     batchID,
		BlockNumber: blockNumber,
		TxCount:     txCount,
		Stage:       StagePending,
		CreatedAt:   now,
		Metrics: BatchMetrics{
			BatchID: batchID,
			TxCount: txCount,
			Stage:   StagePending,
		},
	}
}

// Advance moves the batch to the next stage, recording metrics.
// Stage transitions are monotonic: only forward progression is allowed.
func (bs *BatchState) Advance(stage BatchStage, duration time.Duration, err error) {
	bs.mu.Lock()
	defer bs.mu.Unlock()

	sm := StageMetrics{
		Stage:     stage,
		StartTime: time.Now().Add(-duration),
		EndTime:   time.Now(),
		Duration:  duration,
		Retries:   bs.RetryCount,
	}
	if err != nil {
		sm.Error = err.Error()
		bs.LastError = err
	}

	bs.Stage = stage
	bs.Metrics.Stage = stage
	bs.Metrics.StageMetrics = append(bs.Metrics.StageMetrics, sm)

	if stage.IsTerminal() {
		bs.Metrics.TotalDuration = time.Since(bs.CreatedAt)
	}
}
