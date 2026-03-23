package pipeline

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os/exec"
	"time"
)

// ProductionStages implements the Stages interface with real component integration.
//
// Execute: runs L2 transactions through the Go EVM executor.
// WitnessGen: invokes the Rust witness generator via stdin/stdout IPC.
// Prove: invokes the Rust ZK prover via stdin/stdout IPC.
// Submit: calls BasisRollup.sol on L1 via ethers/Go-Ethereum client.
//
// [Spec: zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/specs/E2EPipeline/E2EPipeline.tla]
type ProductionStages struct {
	// WitnessCommand is the path to the Rust witness generator binary.
	WitnessCommand string

	// ProverCommand is the path to the Rust prover binary.
	ProverCommand string

	// WitnessTimeout is the maximum time for witness generation.
	WitnessTimeout time.Duration

	// ProverTimeout is the maximum time for proof generation.
	ProverTimeout time.Duration

	// L1RPCURL is the JSON-RPC endpoint for the Basis Network L1.
	L1RPCURL string

	// L1PrivateKey is the hex-encoded private key for L1 transactions.
	L1PrivateKey string

	// RollupAddress is the deployed BasisRollup.sol address.
	RollupAddress string

	// L1Submitter handles real L1 submission (nil = skip submission).
	L1Submitter *L1Submitter

	// Logger for structured logging.
	Logger *slog.Logger
}

// Compile-time interface compliance check.
var _ Stages = (*ProductionStages)(nil)

// DefaultProductionStages returns production stages with default paths.
func DefaultProductionStages(logger *slog.Logger) *ProductionStages {
	if logger == nil {
		logger = slog.Default()
	}
	return &ProductionStages{
		WitnessCommand: "basis-prover",
		ProverCommand:  "basis-prover",
		WitnessTimeout: 30 * time.Second,
		ProverTimeout:  5 * time.Minute,
		Logger:         logger,
	}
}

// Execute runs L2 transactions through the EVM executor and collects traces.
//
// In the current implementation, this generates synthetic traces (same as
// SimulatedStages) because the full EVM execution integration requires
// the sequencer to feed real transactions. The EVM executor library
// (zkl2/node/executor/) is fully tested; this stage will be wired to
// real execution once the JSON-RPC server accepts transactions.
//
// [Spec: ExecuteSuccess(b) -- batchStage' = "executed", hasTrace' = TRUE]
func (s *ProductionStages) Execute(ctx context.Context, batch *BatchState) error {
	start := time.Now()

	// If the batch already has traces pre-populated by the block production loop
	// (from real EVM execution), validate and use them directly.
	if len(batch.Traces) > 0 && batch.PreStateRoot != "" && batch.PostStateRoot != "" {
		s.Logger.Info("execute stage: using pre-populated EVM traces",
			"batch_id", batch.BatchID,
			"tx_count", batch.TxCount,
			"trace_count", len(batch.Traces),
		)
		batch.ExecutionTime = time.Since(start)
		return nil
	}

	// Fallback: generate synthetic traces for development/testing.
	// This path is used when the batch was submitted without real EVM execution
	// (e.g., from simulated tests or before the RPC server is fully integrated).
	s.Logger.Warn("execute stage: generating synthetic traces (no real EVM execution)",
		"batch_id", batch.BatchID,
		"tx_count", batch.TxCount,
	)
	traces := make([]ExecutionTraceJSON, batch.TxCount)
	for i := range traces {
		traces[i] = ExecutionTraceJSON{
			TxHash:      fmt.Sprintf("0x%064x", i),
			From:        fmt.Sprintf("0x%040x", i+1),
			To:          fmt.Sprintf("0x%040x", i+100),
			Value:       "0x0",
			GasUsed:     21000,
			Success:     true,
			OpcodeCount: 50,
			Entries: []TraceEntryJSON{
				{Op: "BALANCE_CHANGE", Account: fmt.Sprintf("0x%040x", i+1)},
				{Op: "SSTORE", Account: fmt.Sprintf("0x%040x", i+100), Slot: "0x00"},
			},
		}
	}

	batch.PreStateRoot = fmt.Sprintf("0x%064x", batch.BatchID)
	batch.PostStateRoot = fmt.Sprintf("0x%064x", batch.BatchID+1)
	batch.Traces = traces
	batch.ExecutionTime = time.Since(start)

	s.Logger.Info("execute stage complete (synthetic)",
		"batch_id", batch.BatchID,
		"tx_count", batch.TxCount,
		"duration_ms", batch.ExecutionTime.Milliseconds(),
	)

	return nil
}

// WitnessGen invokes the Rust witness generator via stdin/stdout IPC.
//
// Protocol: JSON over stdin/stdout.
//   - Input: BatchTraceJSON (serialized execution traces)
//   - Output: WitnessResultJSON (field element tables)
//
// [Spec: WitnessSuccess(b) -- batchStage' = "witnessed", hasWitness' = TRUE]
func (s *ProductionStages) WitnessGen(ctx context.Context, batch *BatchState) error {
	start := time.Now()

	// Serialize input for the Rust witness generator.
	input := BatchTraceJSON{
		BlockNumber:   batch.BlockNumber,
		PreStateRoot:  batch.PreStateRoot,
		PostStateRoot: batch.PostStateRoot,
		Traces:        batch.Traces,
	}
	inputBytes, err := json.Marshal(input)
	if err != nil {
		return fmt.Errorf("witness gen: marshal input: %w", err)
	}

	// Invoke Rust binary.
	witnessCtx, witnessCancel := context.WithTimeout(ctx, s.WitnessTimeout)
	defer witnessCancel()

	outputBytes, err := s.invokeRustBinary(witnessCtx, s.WitnessCommand, "witness", inputBytes)
	if err != nil {
		return fmt.Errorf("witness gen: invoke: %w", err)
	}

	// Parse output.
	var result WitnessResultJSON
	if err := json.Unmarshal(outputBytes, &result); err != nil {
		return fmt.Errorf("witness gen: unmarshal output: %w", err)
	}

	batch.WitnessResult = &result
	batch.WitnessTime = time.Since(start)
	batch.Metrics.WitnessSizeBytes = result.SizeBytes

	s.Logger.Info("witness gen stage complete",
		"batch_id", batch.BatchID,
		"rows", result.TotalRows,
		"size_bytes", result.SizeBytes,
		"duration_ms", batch.WitnessTime.Milliseconds(),
	)

	return nil
}

// Prove invokes the Rust ZK prover to generate a validity proof.
//
// Protocol: JSON over stdin/stdout.
//   - Input: WitnessResultJSON
//   - Output: ProofResultJSON (Groth16/PLONK proof bytes)
//
// [Spec: ProveSuccess(b) -- batchStage' = "proved", hasProof' = TRUE]
func (s *ProductionStages) Prove(ctx context.Context, batch *BatchState) error {
	start := time.Now()

	if batch.WitnessResult == nil {
		return fmt.Errorf("prove: witness result is nil")
	}

	inputBytes, err := json.Marshal(batch.WitnessResult)
	if err != nil {
		return fmt.Errorf("prove: marshal input: %w", err)
	}

	proveCtx, proveCancel := context.WithTimeout(ctx, s.ProverTimeout)
	defer proveCancel()

	outputBytes, err := s.invokeRustBinary(proveCtx, s.ProverCommand, "prove", inputBytes)
	if err != nil {
		return fmt.Errorf("prove: invoke: %w", err)
	}

	var result ProofResultJSON
	if err := json.Unmarshal(outputBytes, &result); err != nil {
		return fmt.Errorf("prove: unmarshal output: %w", err)
	}

	batch.ProofResult = &result
	batch.ProofTime = time.Since(start)
	batch.Metrics.ConstraintCount = result.ConstraintCount
	batch.Metrics.ProofSizeBytes = result.ProofSizeBytes

	s.Logger.Info("prove stage complete",
		"batch_id", batch.BatchID,
		"constraints", result.ConstraintCount,
		"proof_size", result.ProofSizeBytes,
		"duration_ms", batch.ProofTime.Milliseconds(),
	)

	return nil
}

// Submit submits the ZK proof to BasisRollup.sol on the Basis Network L1.
//
// Three L1 transactions as a logical unit:
//   1. commitBatch(batchID, preStateRoot, postStateRoot, txCount)
//   2. proveBatch(batchID, proofBytes, publicInputs)
//   3. executeBatch(batchID) -- finalizes the batch
//
// [Spec: SubmitSuccess(b) -- batchStage' = "submitted", proofOnL1' = TRUE]
func (s *ProductionStages) Submit(ctx context.Context, batch *BatchState) error {
	start := time.Now()

	if s.L1Submitter == nil {
		// No L1 submitter configured -- development mode.
		s.Logger.Warn("L1 submission skipped: no submitter configured",
			"batch_id", batch.BatchID,
		)
		batch.L1TxHash = "0x0000000000000000000000000000000000000000000000000000000000000000"
		batch.L1GasUsed = 0
		batch.SubmitTime = time.Since(start)
		return nil
	}

	// Real L1 submission: commitBatch + proveBatch + executeBatch.
	gasUsed, txHash, err := s.L1Submitter.SubmitBatch(ctx, batch)
	if err != nil {
		return fmt.Errorf("L1 submit: %w", err)
	}

	batch.L1TxHash = txHash
	batch.L1GasUsed = gasUsed
	batch.SubmitTime = time.Since(start)
	batch.Metrics.L1GasUsed = gasUsed

	s.Logger.Info("L1 batch submission complete",
		"batch_id", batch.BatchID,
		"gas_used", gasUsed,
		"tx_hash", txHash[:10],
		"duration_ms", batch.SubmitTime.Milliseconds(),
	)

	return nil
}

// invokeRustBinary executes a Rust binary with a subcommand, piping JSON
// through stdin and reading the result from stdout.
//
// This is the Go-Rust IPC bridge documented in POST_ROADMAP_TODO Section 2.3.
// Protocol: command stdin:JSON -> stdout:JSON, stderr for logs.
func (s *ProductionStages) invokeRustBinary(
	ctx context.Context,
	binary string,
	subcommand string,
	input []byte,
) ([]byte, error) {
	cmd := exec.CommandContext(ctx, binary, subcommand)
	cmd.Stdin = bytes.NewReader(input)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%s %s failed: %w (stderr: %s)",
			binary, subcommand, err, stderr.String())
	}

	return stdout.Bytes(), nil
}
