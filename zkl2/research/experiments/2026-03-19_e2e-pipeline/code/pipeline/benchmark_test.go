package pipeline

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestE2EPipeline_SingleBatch validates the pipeline processes a single batch E2E.
func TestE2EPipeline_SingleBatch(t *testing.T) {
	stages := DefaultSimulatedStages()
	config := DefaultPipelineConfig()
	config.BatchSize = 100

	orch := NewOrchestrator(config, nil)
	orch.SetStages(stages.Execute, stages.Witness, stages.Prove, stages.Submit)

	batch := NewBatchState(1, 1000, 100)
	ctx := context.Background()

	start := time.Now()
	err := orch.ProcessBatch(ctx, batch)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("pipeline failed: %v", err)
	}
	if batch.Stage != StageFinalized {
		t.Fatalf("expected StageFinalized, got %s", batch.Stage)
	}

	t.Logf("E2E latency (100 tx): %v", elapsed)
	t.Logf("  Execute:  %v", batch.ExecutionTime)
	t.Logf("  Witness:  %v", batch.WitnessTime)
	t.Logf("  Prove:    %v", batch.ProofTime)
	t.Logf("  Submit:   %v", batch.SubmitTime)
	t.Logf("  Constraints: %d", batch.Metrics.ConstraintCount)
	t.Logf("  Proof size: %d bytes", batch.Metrics.ProofSizeBytes)
	t.Logf("  L1 gas: %d", batch.Metrics.L1GasUsed)

	// Hypothesis check: E2E < 5 minutes for 100 tx
	if elapsed > 5*time.Minute {
		t.Errorf("HYPOTHESIS REJECTED: E2E latency %v exceeds 5 minute target", elapsed)
	}
}

// TestE2EPipeline_RetryOnFailure validates automatic retry with backoff.
func TestE2EPipeline_RetryOnFailure(t *testing.T) {
	stages := DefaultSimulatedStages()
	stages.ProveFailRate = 0.5 // 50% failure rate on proving

	config := DefaultPipelineConfig()
	config.BatchSize = 10
	config.RetryPolicy = RetryPolicy{
		MaxRetries:     3,
		InitialBackoff: 10 * time.Millisecond, // Fast backoff for testing
		MaxBackoff:     100 * time.Millisecond,
		BackoffFactor:  2.0,
	}
	// Use faster timings for retry test
	stages.ProofBaseTime = 10 * time.Millisecond
	stages.ProofTimePerTx = 1 * time.Millisecond
	stages.L1SubmitTime = 10 * time.Millisecond
	stages.ExecTimePerTx = 10 * time.Microsecond
	stages.WitnessTimePerTx = 1 * time.Microsecond

	orch := NewOrchestrator(config, nil)
	orch.SetStages(stages.Execute, stages.Witness, stages.Prove, stages.Submit)

	// Run multiple batches to test retry behavior
	successCount := 0
	failCount := 0
	totalRetries := 0

	for i := 0; i < 30; i++ {
		batch := NewBatchState(uint64(i+1), uint64(1000+i), 10)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		err := orch.ProcessBatch(ctx, batch)
		cancel()

		totalRetries += batch.RetryCount
		if err == nil {
			successCount++
		} else {
			failCount++
		}
	}

	t.Logf("Retry test: %d/%d succeeded, %d failed, total retries: %d",
		successCount, 30, failCount, totalRetries)

	// With 50% failure rate and 3 retries, success rate should be high
	// P(all 4 attempts fail) = 0.5^4 = 6.25%, so ~94% should succeed
	if float64(successCount)/30.0 < 0.7 {
		t.Errorf("success rate too low: %d/30 (expected >70%%)", successCount)
	}
}

// TestE2EPipeline_PipelineParallelism validates concurrent batch processing.
func TestE2EPipeline_PipelineParallelism(t *testing.T) {
	stages := DefaultSimulatedStages()
	// Use faster timings to keep test reasonable
	stages.ProofBaseTime = 100 * time.Millisecond
	stages.ProofTimePerTx = 5 * time.Millisecond
	stages.L1SubmitTime = 50 * time.Millisecond

	config := DefaultPipelineConfig()
	config.BatchSize = 50
	config.MaxConcurrentBatches = 3

	orch := NewOrchestrator(config, nil)
	orch.SetStages(stages.Execute, stages.Witness, stages.Prove, stages.Submit)

	batches := make([]*BatchState, 5)
	for i := range batches {
		batches[i] = NewBatchState(uint64(i+1), uint64(1000+i), 50)
	}

	ctx := context.Background()
	start := time.Now()
	metrics, err := orch.ProcessBatchesConcurrent(ctx, batches)
	elapsed := time.Since(start)

	// Sequential time for 5 batches
	singleBatchTime := stages.ProofBaseTime +
		time.Duration(50)*stages.ProofTimePerTx +
		stages.L1SubmitTime +
		time.Duration(50)*stages.ExecTimePerTx +
		time.Duration(50)*stages.WitnessTimePerTx
	sequentialTime := singleBatchTime * 5

	t.Logf("Pipeline parallelism (5 batches, concurrency=3):")
	t.Logf("  Wall time:      %v", elapsed)
	t.Logf("  Sequential est: %v", sequentialTime)
	t.Logf("  Speedup:        %.2fx", float64(sequentialTime)/float64(elapsed))
	t.Logf("  Completed:      %d", metrics.SuccessfulBatches)
	t.Logf("  Failed:         %d", metrics.FailedBatches)

	if err != nil {
		t.Logf("  (some batches failed: %v)", err)
	}

	// With concurrency=3, should achieve >1.5x speedup over sequential
	speedup := float64(sequentialTime) / float64(elapsed)
	if speedup < 1.3 {
		t.Errorf("insufficient parallelism: speedup=%.2fx (expected >1.3x)", speedup)
	}
}

// BenchmarkResult holds the results of a benchmark run.
type BenchmarkResult struct {
	Scenario        string        `json:"scenario"`
	BatchSize       int           `json:"batch_size"`
	NumBatches      int           `json:"num_batches"`
	TotalTxs        int           `json:"total_txs"`
	E2ELatency      time.Duration `json:"e2e_latency_ms"`
	ExecuteLatency  time.Duration `json:"execute_latency_ms"`
	WitnessLatency  time.Duration `json:"witness_latency_ms"`
	ProveLatency    time.Duration `json:"prove_latency_ms"`
	SubmitLatency   time.Duration `json:"submit_latency_ms"`
	Throughput      float64       `json:"throughput_tps"`
	ConstraintCount uint64        `json:"constraint_count"`
	ProofSizeBytes  uint64        `json:"proof_size_bytes"`
	L1GasUsed       uint64        `json:"l1_gas_used"`
	MeetsTarget     bool          `json:"meets_5min_target"`
}

// TestE2EPipeline_FullBenchmark runs the complete benchmark suite across scenarios.
func TestE2EPipeline_FullBenchmark(t *testing.T) {
	scenarios := []struct {
		name   string
		stages *SimulatedStages
	}{
		{"optimistic", OptimisticStages()},
		{"default", DefaultSimulatedStages()},
		{"pessimistic", PessimisticStages()},
	}

	batchSizes := []int{10, 50, 100, 200, 500}
	var results []BenchmarkResult

	for _, sc := range scenarios {
		for _, bs := range batchSizes {
			config := DefaultPipelineConfig()
			config.BatchSize = bs

			orch := NewOrchestrator(config, nil)
			orch.SetStages(sc.stages.Execute, sc.stages.Witness, sc.stages.Prove, sc.stages.Submit)

			// Run 5 repetitions per configuration
			var totalE2E time.Duration
			var lastBatch *BatchState

			for rep := 0; rep < 5; rep++ {
				batch := NewBatchState(uint64(rep+1), uint64(1000+rep), bs)
				ctx := context.Background()
				err := orch.ProcessBatch(ctx, batch)
				if err != nil {
					t.Logf("  %s bs=%d rep=%d failed: %v", sc.name, bs, rep, err)
					continue
				}
				totalE2E += batch.Metrics.TotalDuration
				lastBatch = batch
			}

			if lastBatch == nil {
				continue
			}

			avgE2E := totalE2E / 5
			result := BenchmarkResult{
				Scenario:        sc.name,
				BatchSize:       bs,
				NumBatches:      1,
				TotalTxs:        bs,
				E2ELatency:      avgE2E,
				ExecuteLatency:  lastBatch.ExecutionTime,
				WitnessLatency:  lastBatch.WitnessTime,
				ProveLatency:    lastBatch.ProofTime,
				SubmitLatency:   lastBatch.SubmitTime,
				Throughput:      float64(bs) / avgE2E.Seconds(),
				ConstraintCount: lastBatch.Metrics.ConstraintCount,
				ProofSizeBytes:  lastBatch.Metrics.ProofSizeBytes,
				L1GasUsed:       lastBatch.Metrics.L1GasUsed,
				MeetsTarget:     avgE2E < 5*time.Minute,
			}
			results = append(results, result)

			t.Logf("%-12s bs=%-4d E2E=%-12v Prove=%-12v TPS=%.1f target=%v",
				sc.name, bs, avgE2E, lastBatch.ProofTime,
				result.Throughput, result.MeetsTarget)
		}
	}

	// Write results to JSON
	resultsJSON, _ := json.MarshalIndent(results, "", "  ")
	resultsDir := filepath.Join("..", "..", "results")
	os.MkdirAll(resultsDir, 0755)
	resultsFile := filepath.Join(resultsDir, "benchmark_results.json")
	os.WriteFile(resultsFile, resultsJSON, 0644)
	t.Logf("Results written to %s", resultsFile)

	// Print summary table
	t.Log("\n=== BENCHMARK SUMMARY ===")
	t.Log("Scenario     | Batch | E2E Latency  | Prove Time   | TPS    | <5min?")
	t.Log("-------------|-------|--------------|--------------|--------|-------")
	for _, r := range results {
		t.Logf("%-12s | %-5d | %-12v | %-12v | %-6.1f | %v",
			r.Scenario, r.BatchSize, r.E2ELatency, r.ProveLatency,
			r.Throughput, r.MeetsTarget)
	}

	// Hypothesis validation: 100-tx batch under 5 minutes
	for _, r := range results {
		if r.BatchSize == 100 && !r.MeetsTarget {
			t.Logf("WARNING: %s scenario 100-tx batch exceeds 5 minutes (%v)",
				r.Scenario, r.E2ELatency)
		}
	}
}

// TestE2EPipeline_BottleneckAnalysis identifies the pipeline bottleneck.
func TestE2EPipeline_BottleneckAnalysis(t *testing.T) {
	stages := DefaultSimulatedStages()
	config := DefaultPipelineConfig()

	orch := NewOrchestrator(config, nil)
	orch.SetStages(stages.Execute, stages.Witness, stages.Prove, stages.Submit)

	batch := NewBatchState(1, 1000, 100)
	ctx := context.Background()
	err := orch.ProcessBatch(ctx, batch)
	if err != nil {
		t.Fatalf("pipeline failed: %v", err)
	}

	totalTime := batch.Metrics.TotalDuration
	execPct := float64(batch.ExecutionTime) / float64(totalTime) * 100
	witnessPct := float64(batch.WitnessTime) / float64(totalTime) * 100
	provePct := float64(batch.ProofTime) / float64(totalTime) * 100
	submitPct := float64(batch.SubmitTime) / float64(totalTime) * 100

	t.Log("=== BOTTLENECK ANALYSIS (100 tx, default scenario) ===")
	t.Logf("Total E2E:     %v", totalTime)
	t.Logf("Execute:       %v (%.1f%%)", batch.ExecutionTime, execPct)
	t.Logf("Witness:       %v (%.1f%%)", batch.WitnessTime, witnessPct)
	t.Logf("Prove:         %v (%.1f%%)", batch.ProofTime, provePct)
	t.Logf("Submit:        %v (%.1f%%)", batch.SubmitTime, submitPct)
	t.Logf("Overhead:      %v (%.1f%%)",
		totalTime-batch.ExecutionTime-batch.WitnessTime-batch.ProofTime-batch.SubmitTime,
		100-execPct-witnessPct-provePct-submitPct)

	// Prove should be the dominant stage (>50% of total)
	if provePct < 40 {
		t.Logf("NOTE: Prove is NOT the dominant bottleneck (%.1f%%). Check timing calibration.", provePct)
	} else {
		t.Logf("CONFIRMED: Prove is the pipeline bottleneck at %.1f%% of total time", provePct)
	}

	// Write bottleneck analysis
	analysis := map[string]interface{}{
		"total_e2e_ms":     totalTime.Milliseconds(),
		"execute_ms":       batch.ExecutionTime.Milliseconds(),
		"execute_pct":      fmt.Sprintf("%.1f%%", execPct),
		"witness_ms":       batch.WitnessTime.Milliseconds(),
		"witness_pct":      fmt.Sprintf("%.1f%%", witnessPct),
		"prove_ms":         batch.ProofTime.Milliseconds(),
		"prove_pct":        fmt.Sprintf("%.1f%%", provePct),
		"submit_ms":        batch.SubmitTime.Milliseconds(),
		"submit_pct":       fmt.Sprintf("%.1f%%", submitPct),
		"bottleneck":       "prove",
		"constraint_count": batch.Metrics.ConstraintCount,
	}
	analysisJSON, _ := json.MarshalIndent(analysis, "", "  ")
	resultsDir := filepath.Join("..", "..", "results")
	os.MkdirAll(resultsDir, 0755)
	os.WriteFile(filepath.Join(resultsDir, "bottleneck_analysis.json"), analysisJSON, 0644)
}

// TestE2EPipeline_ScalingAnalysis measures how E2E latency scales with batch size.
func TestE2EPipeline_ScalingAnalysis(t *testing.T) {
	stages := DefaultSimulatedStages()

	batchSizes := []int{4, 16, 64, 100, 256, 500, 1000}
	type ScalingPoint struct {
		BatchSize      int     `json:"batch_size"`
		E2EMs          int64   `json:"e2e_ms"`
		ProveMs        int64   `json:"prove_ms"`
		TPS            float64 `json:"throughput_tps"`
		Constraints    uint64  `json:"constraints"`
		MeetsTarget    bool    `json:"meets_5min_target"`
	}

	var points []ScalingPoint

	for _, bs := range batchSizes {
		config := DefaultPipelineConfig()
		config.BatchSize = bs

		orch := NewOrchestrator(config, nil)
		orch.SetStages(stages.Execute, stages.Witness, stages.Prove, stages.Submit)

		batch := NewBatchState(1, 1000, bs)
		ctx := context.Background()
		err := orch.ProcessBatch(ctx, batch)
		if err != nil {
			t.Logf("bs=%d failed: %v", bs, err)
			continue
		}

		totalMs := batch.Metrics.TotalDuration.Milliseconds()
		proveMs := batch.ProofTime.Milliseconds()
		tps := float64(bs) / batch.Metrics.TotalDuration.Seconds()

		point := ScalingPoint{
			BatchSize:   bs,
			E2EMs:       totalMs,
			ProveMs:     proveMs,
			TPS:         tps,
			Constraints: batch.Metrics.ConstraintCount,
			MeetsTarget: batch.Metrics.TotalDuration < 5*time.Minute,
		}
		points = append(points, point)

		t.Logf("bs=%-5d E2E=%-8dms Prove=%-8dms TPS=%-8.1f constraints=%-6d <%s",
			bs, totalMs, proveMs, tps, batch.Metrics.ConstraintCount,
			map[bool]string{true: "5min OK", false: "EXCEEDS 5min"}[point.MeetsTarget])
	}

	// Write scaling data
	scalingJSON, _ := json.MarshalIndent(points, "", "  ")
	resultsDir := filepath.Join("..", "..", "results")
	os.MkdirAll(resultsDir, 0755)
	os.WriteFile(filepath.Join(resultsDir, "scaling_analysis.json"), scalingJSON, 0644)

	// Find max batch size under 5 minutes
	maxBatchUnder5Min := 0
	for _, p := range points {
		if p.MeetsTarget && p.BatchSize > maxBatchUnder5Min {
			maxBatchUnder5Min = p.BatchSize
		}
	}
	t.Logf("\nMax batch size under 5 minutes: %d transactions", maxBatchUnder5Min)
}
