// Package relayer -- benchmark simulation for BasisBridge latency and gas cost analysis.
//
// This file contains the benchmark simulation that models deposit/withdrawal latency
// and gas costs for the BasisBridge design under various scenarios.
package relayer

import (
	"fmt"
	"math"
	"math/big"
	"math/rand"
	"time"
)

// BenchmarkConfig configures the bridge benchmark simulation.
type BenchmarkConfig struct {
	// Avalanche L1 parameters
	L1BlockTime     time.Duration // Avalanche block time (~2s)
	L1Finality      time.Duration // Snowman finality (~2s)
	L1GasPrice      uint64        // 0 for Basis Network

	// L2 parameters
	L2BlockTime     time.Duration // L2 block time (~1s)
	BatchInterval   time.Duration // How often batches are created
	BatchSize       int           // Transactions per batch

	// Pipeline parameters (from E2E Pipeline experiment)
	ExecuteTime     time.Duration // EVM execution time per batch
	WitnessTime     time.Duration // Witness generation time per batch
	ProveTime       time.Duration // Proof generation time per batch
	SubmitTime      time.Duration // L1 submission time (3 txs)

	// Relayer parameters
	RelayerPollTime time.Duration // How often relayer checks for events
	RelayerLatency  time.Duration // Relayer processing overhead

	// Merkle proof parameters
	WithdrawTrieDepth int // Depth of the withdraw trie (for gas estimation)
}

// DefaultBenchmarkConfig returns the default (realistic) configuration.
func DefaultBenchmarkConfig() BenchmarkConfig {
	return BenchmarkConfig{
		L1BlockTime:       2 * time.Second,
		L1Finality:        2 * time.Second,
		L1GasPrice:        0,
		L2BlockTime:       1 * time.Second,
		BatchInterval:     10 * time.Second,
		BatchSize:         100,
		ExecuteTime:       15 * time.Millisecond,
		WitnessTime:       2 * time.Millisecond,
		ProveTime:         10 * time.Second,
		SubmitTime:        4 * time.Second,
		RelayerPollTime:   2 * time.Second,
		RelayerLatency:    100 * time.Millisecond,
		WithdrawTrieDepth: 32,
	}
}

// OptimisticBenchmarkConfig returns optimistic scenario configuration.
func OptimisticBenchmarkConfig() BenchmarkConfig {
	cfg := DefaultBenchmarkConfig()
	cfg.ProveTime = 3 * time.Second
	cfg.SubmitTime = 2 * time.Second
	cfg.RelayerPollTime = 1 * time.Second
	cfg.RelayerLatency = 50 * time.Millisecond
	return cfg
}

// PessimisticBenchmarkConfig returns pessimistic scenario configuration.
func PessimisticBenchmarkConfig() BenchmarkConfig {
	cfg := DefaultBenchmarkConfig()
	cfg.ProveTime = 25 * time.Second
	cfg.SubmitTime = 8 * time.Second
	cfg.RelayerPollTime = 5 * time.Second
	cfg.RelayerLatency = 500 * time.Millisecond
	cfg.BatchInterval = 30 * time.Second
	return cfg
}

// GasEstimate holds gas cost estimates for bridge operations.
type GasEstimate struct {
	Operation   string
	Gas         uint64
	Components  map[string]uint64
}

// LatencyResult holds latency simulation results.
type LatencyResult struct {
	Operation     string
	Scenario      string
	TotalLatency  time.Duration
	Breakdown     map[string]time.Duration
	MeetsTarget   bool
	TargetLatency time.Duration
}

// BenchmarkResult holds complete benchmark results.
type BenchmarkResult struct {
	GasEstimates   []GasEstimate
	LatencyResults []LatencyResult
	WithdrawTrie   WithdrawTrieBenchmark
	EscapeHatch    EscapeHatchBenchmark
}

// WithdrawTrieBenchmark holds withdraw trie performance results.
type WithdrawTrieBenchmark struct {
	Depth          int
	InsertTimeAvg  time.Duration
	RootTimeAvg    time.Duration
	ProofTimeAvg   time.Duration
	ProofSize      int // bytes
	Iterations     int
}

// EscapeHatchBenchmark holds escape hatch analysis results.
type EscapeHatchBenchmark struct {
	StateProofGas   uint64
	NullifierGas    uint64
	TransferGas     uint64
	TotalGas        uint64
	TimeoutSeconds  uint64
}

// RunBenchmarks executes the full benchmark suite.
func RunBenchmarks() BenchmarkResult {
	return BenchmarkResult{
		GasEstimates:   estimateGasCosts(),
		LatencyResults: simulateLatencies(),
		WithdrawTrie:   benchmarkWithdrawTrie(),
		EscapeHatch:    analyzeEscapeHatch(),
	}
}

// estimateGasCosts estimates gas for each bridge operation.
func estimateGasCosts() []GasEstimate {
	estimates := []GasEstimate{
		{
			Operation: "deposit",
			Gas:       61_500,
			Components: map[string]uint64{
				"calldata_overhead":     2_100,  // Function selector + params
				"enterprise_sload":      2_100,  // Read enterprises mapping (cold)
				"deposit_counter_sload": 2_100,  // Read depositCounter
				"deposit_counter_store": 5_000,  // Write depositCounter (warm)
				"total_deposited_sload": 2_100,  // Read totalDeposited
				"total_deposited_store": 5_000,  // Write totalDeposited (warm)
				"event_emission":        3_100,  // DepositInitiated (3 indexed + 3 data)
				"msg_value_transfer":    9_000,  // ETH value handling
				"computation":           31_000, // Overhead, memory, etc.
			},
		},
		{
			Operation: "claimWithdrawal",
			Gas:       82_000,
			Components: map[string]uint64{
				"calldata_overhead":      3_500,  // Function selector + params + proof
				"withdraw_root_sload":    2_100,  // Read withdrawRoots (cold)
				"leaf_hash":              100,    // keccak256 for leaf
				"withdrawal_hash":        100,    // keccak256 for nullifier
				"nullifier_sload":        2_100,  // Read nullifier (cold)
				"merkle_verify_32":       48_000, // 32 keccak256 hashes (32 * ~1500)
				"nullifier_sstore":       20_000, // Write nullifier (cold, 0->1)
				"total_withdrawn_update": 5_000,  // Update totalWithdrawn
				"eth_transfer":           2_300,  // ETH transfer to recipient
				"event_emission":         3_100,  // WithdrawalClaimed event
				"computation":            -4_300, // Negative adjustment (some SLOADs warm)
			},
		},
		{
			Operation: "escapeWithdraw",
			Gas:       118_500,
			Components: map[string]uint64{
				"calldata_overhead":      3_500,   // Function selector + params + proof
				"escape_mode_sload":      2_100,   // Read escapeMode
				"escape_nullifier_sload": 2_100,   // Read escapeNullifier (cold)
				"current_root_sload":     2_100,   // Read currentRoot from rollup (external call)
				"external_call_overhead": 2_600,   // STATICCALL to rollup contract
				"leaf_hash":              100,     // keccak256 for leaf
				"merkle_verify_32":       48_000,  // 32 keccak256 hashes
				"nullifier_sstore":       20_000,  // Write escape nullifier (cold)
				"total_withdrawn_update": 5_000,   // Update totalWithdrawn
				"balance_check":          100,     // Check address(this).balance
				"eth_transfer":           2_300,   // ETH transfer
				"event_emission":         3_100,   // EscapeWithdrawal event
				"computation":            27_000,  // Overhead, memory, etc.
			},
		},
		{
			Operation: "activateEscapeHatch",
			Gas:       32_000,
			Components: map[string]uint64{
				"calldata_overhead":          2_100,  // Function selector + params
				"escape_mode_sload":          2_100,  // Read escapeMode
				"last_batch_time_sload":      2_100,  // Read lastBatchExecutionTime
				"enterprise_sload":           2_100,  // Read enterprises mapping (external)
				"external_call_overhead":     2_600,  // STATICCALL to rollup
				"escape_mode_sstore":         20_000, // Write escapeMode (cold, 0->1)
				"event_emission":             2_100,  // EscapeHatchActivated event
				"timestamp_computation":      100,    // block.timestamp subtraction
				"negative_adjustment":        -1_200, // Some warm slots
			},
		},
		{
			Operation: "submitWithdrawRoot",
			Gas:       52_000,
			Components: map[string]uint64{
				"calldata_overhead":       2_100,  // Function selector + params
				"admin_sload":            2_100,  // Read admin
				"enterprise_sload":       2_100,  // Read enterprises (external call)
				"external_call_overhead": 2_600,  // STATICCALL to rollup
				"withdraw_root_sstore":   20_000, // Write withdrawRoots (cold)
				"last_batch_time_store":  5_000,  // Write lastBatchExecutionTime (warm)
				"event_emission":         3_100,  // WithdrawRootSubmitted event
				"computation":            15_000, // Overhead
			},
		},
	}

	return estimates
}

// simulateLatencies simulates deposit and withdrawal latencies.
func simulateLatencies() []LatencyResult {
	scenarios := map[string]BenchmarkConfig{
		"optimistic":  OptimisticBenchmarkConfig(),
		"default":     DefaultBenchmarkConfig(),
		"pessimistic": PessimisticBenchmarkConfig(),
	}

	results := make([]LatencyResult, 0)
	rng := rand.New(rand.NewSource(42))

	for name, cfg := range scenarios {
		// Deposit latency (L1 -> L2)
		depositResults := simulateDepositLatency(name, cfg, rng, 30)
		results = append(results, depositResults...)

		// Withdrawal latency (L2 -> L1)
		withdrawalResults := simulateWithdrawalLatency(name, cfg, rng, 30)
		results = append(results, withdrawalResults...)
	}

	return results
}

func simulateDepositLatency(scenario string, cfg BenchmarkConfig, rng *rand.Rand, reps int) []LatencyResult {
	targetLatency := 5 * time.Minute
	results := make([]LatencyResult, 0)

	var totalLatency time.Duration

	for i := 0; i < reps; i++ {
		// Phase 1: L1 tx confirmation (deposit call)
		l1Confirm := cfg.L1Finality + jitter(rng, cfg.L1BlockTime/4)

		// Phase 2: Relayer detects deposit event
		relayerDetect := cfg.RelayerPollTime/2 + jitter(rng, cfg.RelayerPollTime/4)

		// Phase 3: Relayer processing
		relayerProcess := cfg.RelayerLatency + jitter(rng, cfg.RelayerLatency/4)

		// Phase 4: L2 tx submission and inclusion
		l2Inclusion := cfg.L2BlockTime + jitter(rng, cfg.L2BlockTime/4)

		total := l1Confirm + relayerDetect + relayerProcess + l2Inclusion
		totalLatency += total
	}

	avgLatency := totalLatency / time.Duration(reps)

	results = append(results, LatencyResult{
		Operation:     "deposit",
		Scenario:      scenario,
		TotalLatency:  avgLatency,
		MeetsTarget:   avgLatency < targetLatency,
		TargetLatency: targetLatency,
		Breakdown: map[string]time.Duration{
			"l1_confirmation": cfg.L1Finality,
			"relayer_detect":  cfg.RelayerPollTime / 2,
			"relayer_process": cfg.RelayerLatency,
			"l2_inclusion":    cfg.L2BlockTime,
		},
	})

	return results
}

func simulateWithdrawalLatency(scenario string, cfg BenchmarkConfig, rng *rand.Rand, reps int) []LatencyResult {
	targetLatency := 30 * time.Minute
	results := make([]LatencyResult, 0)

	var totalLatency time.Duration

	for i := 0; i < reps; i++ {
		// Phase 1: L2 withdrawal tx inclusion
		l2Inclusion := cfg.L2BlockTime + jitter(rng, cfg.L2BlockTime/4)

		// Phase 2: Wait for batch aggregation
		// Worst case: just missed a batch, wait full interval
		// Average case: half the interval
		batchWait := cfg.BatchInterval/2 + jitter(rng, cfg.BatchInterval/4)

		// Phase 3: E2E pipeline (execute + witness + prove + submit)
		pipelineTime := cfg.ExecuteTime + cfg.WitnessTime + cfg.ProveTime + cfg.SubmitTime
		pipelineJitter := jitter(rng, cfg.ProveTime/10)

		// Phase 4: Relayer submits withdraw root
		relayerSubmit := cfg.RelayerPollTime/2 + cfg.RelayerLatency

		// Phase 5: User claims on L1
		l1Claim := cfg.L1Finality + jitter(rng, cfg.L1BlockTime/4)

		total := l2Inclusion + batchWait + pipelineTime + pipelineJitter + relayerSubmit + l1Claim
		totalLatency += total
	}

	avgLatency := totalLatency / time.Duration(reps)

	results = append(results, LatencyResult{
		Operation:     "withdrawal",
		Scenario:      scenario,
		TotalLatency:  avgLatency,
		MeetsTarget:   avgLatency < targetLatency,
		TargetLatency: targetLatency,
		Breakdown: map[string]time.Duration{
			"l2_inclusion":    cfg.L2BlockTime,
			"batch_wait":      cfg.BatchInterval / 2,
			"pipeline_execute": cfg.ExecuteTime,
			"pipeline_witness": cfg.WitnessTime,
			"pipeline_prove":  cfg.ProveTime,
			"pipeline_submit": cfg.SubmitTime,
			"relayer_submit":  cfg.RelayerPollTime/2 + cfg.RelayerLatency,
			"l1_claim":        cfg.L1Finality,
		},
	})

	return results
}

// benchmarkWithdrawTrie benchmarks the withdraw trie operations.
func benchmarkWithdrawTrie() WithdrawTrieBenchmark {
	depth := 32
	iterations := 1000

	trie := NewWithdrawTrie(depth)

	// Benchmark inserts
	insertStart := time.Now()
	for i := 0; i < iterations; i++ {
		trie.AppendLeaf(WithdrawTrieEntry{
			Enterprise:      fmt.Sprintf("0x%040x", i),
			Recipient:       fmt.Sprintf("0x%040x", i+1000),
			Amount:          big.NewInt(int64(i+1) * 1e18),
			WithdrawalIndex: uint64(i),
		})
	}
	insertTotal := time.Since(insertStart)

	// Benchmark root computation
	rootStart := time.Now()
	rootReps := 30
	for i := 0; i < rootReps; i++ {
		_ = trie.Root()
	}
	rootTotal := time.Since(rootStart)

	// Benchmark proof generation
	proofStart := time.Now()
	proofReps := 30
	var proofSize int
	for i := 0; i < proofReps; i++ {
		idx := uint64(rand.Intn(iterations))
		proof, _ := trie.GenerateProof(idx)
		proofSize = len(proof) * 32 // Each sibling is 32 bytes
	}
	proofTotal := time.Since(proofStart)

	return WithdrawTrieBenchmark{
		Depth:         depth,
		InsertTimeAvg: insertTotal / time.Duration(iterations),
		RootTimeAvg:   rootTotal / time.Duration(rootReps),
		ProofTimeAvg:  proofTotal / time.Duration(proofReps),
		ProofSize:     proofSize,
		Iterations:    iterations,
	}
}

// analyzeEscapeHatch analyzes escape hatch gas costs and parameters.
func analyzeEscapeHatch() EscapeHatchBenchmark {
	// Gas breakdown for escapeWithdraw:
	// - State proof verification (32 hashes): ~48K gas
	// - Nullifier SSTORE (cold, 0->1): ~20K gas
	// - External call to rollup (getCurrentRoot): ~2.6K gas
	// - ETH transfer: ~2.3K gas
	// - Other overhead: ~45K gas

	return EscapeHatchBenchmark{
		StateProofGas:  48_000,  // 32 keccak256 hashes at ~1.5K each
		NullifierGas:   20_000,  // Cold SSTORE
		TransferGas:    2_300,   // ETH transfer
		TotalGas:       118_500, // Total including all overhead
		TimeoutSeconds: 86_400,  // 24 hours
	}
}

// FormatResults formats benchmark results as a readable string.
func FormatResults(result BenchmarkResult) string {
	s := "=== Bridge Benchmark Results ===\n\n"

	// Gas estimates
	s += "--- Gas Cost Estimates ---\n\n"
	s += fmt.Sprintf("%-25s %10s\n", "Operation", "Gas")
	s += fmt.Sprintf("%-25s %10s\n", "---------", "---")
	for _, est := range result.GasEstimates {
		s += fmt.Sprintf("%-25s %10d\n", est.Operation, est.Gas)
	}

	// Latency results
	s += "\n--- Latency Simulation (30 reps each) ---\n\n"
	s += fmt.Sprintf("%-12s %-12s %12s %12s %8s\n",
		"Operation", "Scenario", "Avg Latency", "Target", "Pass")
	s += fmt.Sprintf("%-12s %-12s %12s %12s %8s\n",
		"---------", "--------", "-----------", "------", "----")
	for _, lat := range result.LatencyResults {
		pass := "OK"
		if !lat.MeetsTarget {
			pass = "FAIL"
		}
		s += fmt.Sprintf("%-12s %-12s %12s %12s %8s\n",
			lat.Operation,
			lat.Scenario,
			lat.TotalLatency.Round(time.Millisecond),
			lat.TargetLatency,
			pass,
		)
	}

	// Withdraw trie benchmark
	s += "\n--- Withdraw Trie Benchmark ---\n\n"
	s += fmt.Sprintf("Depth: %d\n", result.WithdrawTrie.Depth)
	s += fmt.Sprintf("Iterations: %d\n", result.WithdrawTrie.Iterations)
	s += fmt.Sprintf("Avg insert time: %v\n", result.WithdrawTrie.InsertTimeAvg)
	s += fmt.Sprintf("Avg root time: %v\n", result.WithdrawTrie.RootTimeAvg)
	s += fmt.Sprintf("Avg proof gen time: %v\n", result.WithdrawTrie.ProofTimeAvg)
	s += fmt.Sprintf("Proof size: %d bytes\n", result.WithdrawTrie.ProofSize)

	// Escape hatch analysis
	s += "\n--- Escape Hatch Analysis ---\n\n"
	s += fmt.Sprintf("Timeout: %d seconds (%s)\n",
		result.EscapeHatch.TimeoutSeconds,
		time.Duration(result.EscapeHatch.TimeoutSeconds)*time.Second)
	s += fmt.Sprintf("State proof gas: %d\n", result.EscapeHatch.StateProofGas)
	s += fmt.Sprintf("Nullifier gas: %d\n", result.EscapeHatch.NullifierGas)
	s += fmt.Sprintf("Transfer gas: %d\n", result.EscapeHatch.TransferGas)
	s += fmt.Sprintf("Total gas: %d\n", result.EscapeHatch.TotalGas)
	s += fmt.Sprintf("Gas on Basis L1: FREE (zero-fee network)\n")

	return s
}

// jitter adds random variation to a duration.
func jitter(rng *rand.Rand, maxJitter time.Duration) time.Duration {
	if maxJitter <= 0 {
		return 0
	}
	return time.Duration(rng.Int63n(int64(maxJitter)))
}

// --- Statistical helpers ---

func mean(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sum := 0.0
	for _, v := range values {
		sum += v
	}
	return sum / float64(len(values))
}

func stdev(values []float64) float64 {
	if len(values) < 2 {
		return 0
	}
	m := mean(values)
	sumSq := 0.0
	for _, v := range values {
		d := v - m
		sumSq += d * d
	}
	return math.Sqrt(sumSq / float64(len(values)-1))
}

func ci95(values []float64) float64 {
	if len(values) < 2 {
		return 0
	}
	return 1.96 * stdev(values) / math.Sqrt(float64(len(values)))
}
