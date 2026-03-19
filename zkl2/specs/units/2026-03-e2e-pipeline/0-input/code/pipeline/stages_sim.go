package pipeline

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"math/big"
	"time"
)

// SimulatedStages provides realistic simulated pipeline stages for benchmarking.
// Timing parameters are calibrated from published benchmarks:
//
// Execution: Based on existing executor benchmarks (4K-12K tx/s)
//   -> 100 tx batch: ~10-25ms execution time
//
// Witness Generation: Based on existing Rust witness generator (1000 tx in 13.37ms)
//   -> 100 tx batch: ~1.5ms witness generation
//
// Proof Generation: Calibrated from production systems:
//   - Polygon zkProver: 500 tx batch in <120s (224-thread GCP), 84s (FPGA)
//   - X Layer (Polygon CDK): 300 tx in 90s (192-core AMD EPYC)
//   - snarkjs Groth16: ~15-60s for RSA/complex circuits on consumer CPU
//   - gnark Groth16: >2M constraints/s on BN254
//   - Our target circuit (~50K constraints for 100 tx): ~5-30s with gnark
//
// L1 Submission: Based on Avalanche sub-second finality + gas estimation:
//   -> commitBatch + proveBatch + executeBatch: ~3-6s total
type SimulatedStages struct {
	// Timing parameters (configurable for sensitivity analysis)
	ExecTimePerTx      time.Duration // Per-transaction execution time
	WitnessTimePerTx   time.Duration // Per-transaction witness generation time
	ProofBaseTime      time.Duration // Base proof generation time (fixed overhead)
	ProofTimePerTx     time.Duration // Per-transaction proof time (scales with batch)
	L1SubmitTime       time.Duration // L1 submission time (3 txs: commit+prove+execute)

	// Failure injection (for retry testing)
	ExecuteFailRate    float64 // Probability of execute stage failure [0,1]
	WitnessFailRate    float64
	ProveFailRate      float64
	SubmitFailRate     float64

	// Constraint model
	BaseConstraints    uint64 // Fixed circuit constraints (setup, state root check)
	ConstraintsPerTx   uint64 // Constraints per transaction
}

// DefaultSimulatedStages returns stages calibrated to conservative production estimates.
func DefaultSimulatedStages() *SimulatedStages {
	return &SimulatedStages{
		ExecTimePerTx:    150 * time.Microsecond, // ~6.7K tx/s (mid-range of 4K-12K)
		WitnessTimePerTx: 15 * time.Microsecond,  // ~1.5ms for 100 tx (from Rust bench)
		ProofBaseTime:    5 * time.Second,         // Fixed Groth16 setup overhead
		ProofTimePerTx:   50 * time.Millisecond,   // Linear scaling per tx in circuit
		L1SubmitTime:     4 * time.Second,         // Avalanche: 3 txs * ~1.3s each

		ExecuteFailRate:  0.0,
		WitnessFailRate:  0.0,
		ProveFailRate:    0.0,
		SubmitFailRate:   0.0,

		BaseConstraints:  10000,  // State root verification, public inputs
		ConstraintsPerTx: 500,    // Per-tx constraints (SLOAD/SSTORE/arithmetic)
	}
}

// OptimisticStages returns stages calibrated to best-case estimates.
func OptimisticStages() *SimulatedStages {
	s := DefaultSimulatedStages()
	s.ExecTimePerTx = 100 * time.Microsecond    // ~10K tx/s
	s.WitnessTimePerTx = 10 * time.Microsecond  // Optimized Rust path
	s.ProofBaseTime = 3 * time.Second            // gnark with GPU acceleration
	s.ProofTimePerTx = 30 * time.Millisecond     // Optimized circuit
	s.L1SubmitTime = 2 * time.Second             // Avalanche sub-second finality
	return s
}

// PessimisticStages returns stages calibrated to worst-case estimates.
func PessimisticStages() *SimulatedStages {
	s := DefaultSimulatedStages()
	s.ExecTimePerTx = 250 * time.Microsecond    // ~4K tx/s (complex contracts)
	s.WitnessTimePerTx = 25 * time.Microsecond  // Complex witness with storage proofs
	s.ProofBaseTime = 15 * time.Second           // snarkjs on consumer CPU
	s.ProofTimePerTx = 100 * time.Millisecond    // Large circuit, no GPU
	s.L1SubmitTime = 8 * time.Second             // Network congestion
	return s
}

// WithFailureInjection returns a copy with failure injection enabled.
func (s *SimulatedStages) WithFailureInjection(rate float64) *SimulatedStages {
	copy := *s
	copy.ExecuteFailRate = rate * 0.1  // Execution is reliable
	copy.WitnessFailRate = rate * 0.1  // Witness gen is reliable
	copy.ProveFailRate = rate * 0.5    // Proof gen most likely to fail (OOM, timeout)
	copy.SubmitFailRate = rate * 0.3   // Network failures on L1 submit
	return &copy
}

// shouldFail returns true with probability rate.
func shouldFail(rate float64) bool {
	if rate <= 0 {
		return false
	}
	b := make([]byte, 8)
	rand.Read(b)
	val := new(big.Int).SetBytes(b)
	threshold := new(big.Int).SetUint64(uint64(rate * 1e18))
	max := new(big.Int).SetUint64(1e18)
	return val.Mod(val, max).Cmp(threshold) < 0
}

// Execute simulates the EVM execution + trace generation stage.
func (s *SimulatedStages) Execute(ctx context.Context, batch *BatchState) error {
	if shouldFail(s.ExecuteFailRate) {
		return fmt.Errorf("simulated execute failure: EVM out of gas")
	}

	execTime := time.Duration(batch.TxCount) * s.ExecTimePerTx

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(execTime):
	}

	// Generate synthetic traces
	traces := make([]ExecutionTraceJSON, batch.TxCount)
	for i := 0; i < batch.TxCount; i++ {
		traces[i] = generateSyntheticTrace(i)
	}

	batch.PreStateRoot = "0x" + randomHex(32)
	batch.PostStateRoot = "0x" + randomHex(32)
	batch.Traces = traces
	batch.ExecutionTime = execTime

	return nil
}

// Witness simulates the witness generation stage (Go -> Rust boundary).
func (s *SimulatedStages) Witness(ctx context.Context, batch *BatchState) error {
	if shouldFail(s.WitnessFailRate) {
		return fmt.Errorf("simulated witness failure: invalid trace entry")
	}

	witnessTime := time.Duration(batch.TxCount) * s.WitnessTimePerTx

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(witnessTime):
	}

	// Simulate witness output
	totalRows := uint64(batch.TxCount) * 5    // ~5 witness rows per tx
	totalFE := totalRows * 8                    // ~8 field elements per row
	batch.WitnessResult = &WitnessResultJSON{
		BlockNumber:      batch.BlockNumber,
		PreStateRoot:     batch.PreStateRoot,
		PostStateRoot:    batch.PostStateRoot,
		TotalRows:        totalRows,
		TotalFieldElems:  totalFE,
		SizeBytes:        totalFE * 32,          // 32 bytes per BN254 Fr element
		GenerationTimeMs: uint64(witnessTime.Milliseconds()),
	}
	batch.WitnessTime = witnessTime
	batch.Metrics.WitnessSizeBytes = totalFE * 32

	return nil
}

// Prove simulates the ZK proof generation stage.
func (s *SimulatedStages) Prove(ctx context.Context, batch *BatchState) error {
	if shouldFail(s.ProveFailRate) {
		return fmt.Errorf("simulated prove failure: prover OOM")
	}

	proofTime := s.ProofBaseTime + time.Duration(batch.TxCount)*s.ProofTimePerTx

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(proofTime):
	}

	constraints := s.BaseConstraints + uint64(batch.TxCount)*s.ConstraintsPerTx
	batch.ProofResult = &ProofResultJSON{
		ProofBytes:       make([]byte, 192), // Groth16: 2 G1 + 1 G2 = 192 bytes
		PublicInputs:     make([]byte, 64),  // pre + post state roots
		ProofSizeBytes:   192,
		ConstraintCount:  constraints,
		GenerationTimeMs: uint64(proofTime.Milliseconds()),
	}
	batch.ProofTime = proofTime
	batch.Metrics.ConstraintCount = constraints
	batch.Metrics.ProofSizeBytes = 192

	return nil
}

// Submit simulates the L1 proof submission stage.
func (s *SimulatedStages) Submit(ctx context.Context, batch *BatchState) error {
	if shouldFail(s.SubmitFailRate) {
		return fmt.Errorf("simulated submit failure: L1 tx reverted")
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(s.L1SubmitTime):
	}

	batch.L1TxHash = "0x" + randomHex(32)
	batch.L1GasUsed = 287000 // From BasisRollup.sol benchmarks
	batch.SubmitTime = s.L1SubmitTime
	batch.Metrics.L1GasUsed = 287000

	return nil
}

// generateSyntheticTrace creates a realistic synthetic execution trace.
func generateSyntheticTrace(txIndex int) ExecutionTraceJSON {
	from := "0x" + randomHex(20)
	to := "0x" + randomHex(20)

	// Typical enterprise tx: 1 NONCE_CHANGE + 2 BALANCE_CHANGE + 1-2 SSTORE + 1 SLOAD
	entries := []TraceEntryJSON{
		{Op: "NONCE_CHANGE", Account: from, PrevNonce: uint64(txIndex), CurrNonce: uint64(txIndex + 1)},
		{Op: "BALANCE_CHANGE", Account: from, PrevBalance: "0x1000000", CurrBalance: "0x0ff0000", Reason: "transfer"},
		{Op: "BALANCE_CHANGE", Account: to, PrevBalance: "0x0", CurrBalance: "0x10000", Reason: "transfer"},
		{Op: "SSTORE", Account: to, Slot: "0x01", OldValue: "0x0", NewValue: "0x01"},
		{Op: "SLOAD", Account: to, Slot: "0x02", Value: "0x42"},
	}

	return ExecutionTraceJSON{
		TxHash:      "0x" + randomHex(32),
		From:        from,
		To:          to,
		Value:       "0x10000",
		GasUsed:     42000,
		Success:     true,
		OpcodeCount: 150,
		Entries:     entries,
	}
}

func randomHex(nBytes int) string {
	b := make([]byte, nBytes)
	rand.Read(b)
	return hex.EncodeToString(b)
}
