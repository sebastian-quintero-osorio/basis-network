// Optimized benchmark suite comparing:
// 1. Original SMT (big.Int based) vs Optimized SMT (fr.Element based)
// 2. Batch update performance (block-level: 50, 100, 250, 500 updates on 10K-entry tree)
// 3. State root computation as it applies to L2 block processing
package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"time"

	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
)

// BatchUpdateResult holds results for batch update benchmarks.
type BatchUpdateResult struct {
	TreeSize       int     `json:"tree_size"`
	BatchSize      int     `json:"batch_size"`
	MeanMs         float64 `json:"mean_ms"`
	P95Ms          float64 `json:"p95_ms"`
	MeanPerUpdateUs float64 `json:"mean_per_update_us"`
	Reps           int     `json:"reps"`
}

// ComparisonResult holds original vs optimized comparison.
type ComparisonResult struct {
	EntryCount        int     `json:"entry_count"`
	OrigInsertUs      float64 `json:"orig_insert_us"`
	OptInsertUs       float64 `json:"opt_insert_us"`
	Speedup           float64 `json:"speedup"`
	OrigVerifyUs      float64 `json:"orig_verify_us"`
	OptVerifyUs       float64 `json:"opt_verify_us"`
	VerifySpeedup     float64 `json:"verify_speedup"`
	TSInsertUs        float64 `json:"typescript_insert_us"`
	GoVsTSSpeedup     float64 `json:"go_vs_ts_speedup"`
}

func computeStatsFloat(values []float64) (mean, p95, stddev float64) {
	sorted := make([]float64, len(values))
	copy(sorted, values)
	sort.Float64s(sorted)
	n := len(sorted)

	sum := 0.0
	for _, v := range sorted {
		sum += v
	}
	mean = sum / float64(n)

	variance := 0.0
	for _, v := range sorted {
		variance += (v - mean) * (v - mean)
	}
	if n > 1 {
		variance /= float64(n - 1)
	}
	stddev = math.Sqrt(variance)
	p95 = sorted[int(float64(n)*0.95)]
	return
}

func runOptimizedBenchmarks() {
	fmt.Println("\n\n========================================")
	fmt.Println("=== OPTIMIZED SMT BENCHMARK SUITE ===")
	fmt.Println("========================================")

	// Phase 1: Poseidon2 hash benchmark with fr.Element (no big.Int conversion)
	fmt.Println("\n--- Poseidon2 Hash (fr.Element direct) ---")
	{
		perm := NewOptimizedSMT(32)
		var a, b fr.Element
		a.SetUint64(12345)
		b.SetUint64(67890)

		// Warmup
		for i := 0; i < 100; i++ {
			perm.poseidonCompress(&a, &b)
		}

		samples := 1000
		times := make([]float64, samples)
		for i := 0; i < samples; i++ {
			a.SetUint64(uint64(i * 100))
			b.SetUint64(uint64(i*100 + 1))
			start := time.Now()
			perm.poseidonCompress(&a, &b)
			elapsed := time.Since(start)
			times[i] = float64(elapsed.Nanoseconds()) / 1000.0
		}
		mean, p95, _ := computeStatsFloat(times)
		fmt.Printf("  Poseidon2 (fr.Element): mean=%.2f us, p95=%.2f us, %.0f hashes/s\n",
			mean, p95, 1_000_000/mean)
	}

	// Phase 2: Optimized SMT benchmarks
	entryCounts := []int{100, 1_000, 10_000}
	comparisons := []ComparisonResult{}

	// TypeScript baseline from RU-V1 (in microseconds for comparison)
	tsInsertUs := map[int]float64{100: 1877.0, 1000: 1788.0, 10000: 1792.0}
	tsVerifyUs := map[int]float64{100: 1685.0, 1000: 1677.0, 10000: 1719.0}

	for _, count := range entryCounts {
		fmt.Printf("\n--- Optimized SMT: %d entries (depth 32) ---\n", count)

		smt := NewOptimizedSMT(32)

		// Insert all entries
		insertTimes := make([]float64, 0, 50)
		start := time.Now()
		for i := 0; i < count; i++ {
			key := uint64(i)*6364136223846793005 + 1442695040888963407
			key &= (1 << 32) - 1

			var value fr.Element
			value.SetUint64(uint64(i+1)*1000000007 + 999999937)

			iStart := time.Now()
			smt.InsertUint64(key, &value)
			iElapsed := time.Since(iStart)

			if i >= 10 {
				step := (count - 10) / 50
				if step < 1 {
					step = 1
				}
				if (i-10)%step == 0 && len(insertTimes) < 50 {
					insertTimes = append(insertTimes, float64(iElapsed.Microseconds()))
				}
			}
		}
		totalInsert := time.Since(start)
		insertMean, insertP95, _ := computeStatsFloat(insertTimes)

		// Proof generation benchmark
		proofGenTimes := make([]float64, 0, 50)
		for i := 0; i < 10; i++ { // warmup
			k := uint64(i)*6364136223846793005 + 1442695040888963407
			k &= (1 << 32) - 1
			smt.GetProofUint64(k)
		}
		for i := 0; i < 50; i++ {
			idx := i * (count / 50)
			k := uint64(idx)*6364136223846793005 + 1442695040888963407
			k &= (1 << 32) - 1
			pStart := time.Now()
			smt.GetProofUint64(k)
			pElapsed := time.Since(pStart)
			proofGenTimes = append(proofGenTimes, float64(pElapsed.Microseconds()))
		}
		proofMean, proofP95, _ := computeStatsFloat(proofGenTimes)

		// Proof verification benchmark
		type proofEntry struct {
			key   uint64
			value fr.Element
			proof []fr.Element
		}
		var entries []proofEntry
		for i := 0; i < 60; i++ {
			k := uint64(i)*6364136223846793005 + 1442695040888963407
			k &= (1 << 32) - 1
			var v fr.Element
			v.SetUint64(uint64(i+1)*1000000007 + 999999937)
			proof := smt.GetProofUint64(k)
			entries = append(entries, proofEntry{key: k, value: v, proof: proof})
		}
		root := smt.RootHash()

		// Warmup
		for i := 0; i < 10; i++ {
			e := entries[i]
			smt.VerifyProofUint64(root, e.key, &e.value, e.proof)
		}
		verifyTimes := make([]float64, 0, 50)
		for i := 10; i < 60; i++ {
			e := entries[i]
			vStart := time.Now()
			valid := smt.VerifyProofUint64(root, e.key, &e.value, e.proof)
			vElapsed := time.Since(vStart)
			verifyTimes = append(verifyTimes, float64(vElapsed.Microseconds()))
			if !valid {
				fmt.Printf("  ERROR: verification failed for key %d\n", e.key)
			}
		}
		verifyMean, verifyP95, _ := computeStatsFloat(verifyTimes)

		stats := smt.OptStats()
		runtime.GC()
		var m runtime.MemStats
		runtime.ReadMemStats(&m)

		fmt.Printf("  Total insert:   %.3fs\n", totalInsert.Seconds())
		fmt.Printf("  Insert latency: mean=%.2f us, p95=%.2f us\n", insertMean, insertP95)
		fmt.Printf("  Proof gen:      mean=%.2f us, p95=%.2f us\n", proofMean, proofP95)
		fmt.Printf("  Proof verify:   mean=%.2f us, p95=%.2f us\n", verifyMean, verifyP95)
		fmt.Printf("  Memory:         %.1f MB (alloc)\n", float64(m.Alloc)/(1024*1024))
		fmt.Printf("  Nodes stored:   %d\n", stats.NodeCount)

		comp := ComparisonResult{
			EntryCount:    count,
			OptInsertUs:   insertMean,
			OptVerifyUs:   verifyMean,
			TSInsertUs:    tsInsertUs[count],
			GoVsTSSpeedup: tsInsertUs[count] / insertMean,
		}
		if tsV, ok := tsVerifyUs[count]; ok {
			comp.VerifySpeedup = tsV / verifyMean
		}
		comparisons = append(comparisons, comp)
	}

	// Phase 3: Batch update benchmark (CRITICAL for hypothesis)
	fmt.Println("\n\n=== BATCH UPDATE BENCHMARK (Block Processing) ===")
	fmt.Println("Tree: 10,000 entries pre-loaded, measuring batch update times")

	batchSizes := []int{10, 50, 100, 250, 500}
	batchResults := []BatchUpdateResult{}

	for _, batchSize := range batchSizes {
		fmt.Printf("\n--- Batch size: %d updates on 10K-entry tree ---\n", batchSize)

		reps := 30
		batchTimes := make([]float64, 0, reps)

		for rep := 0; rep < reps; rep++ {
			// Build tree with 10K entries
			smt := NewOptimizedSMT(32)
			for i := 0; i < 10_000; i++ {
				key := uint64(i)*6364136223846793005 + 1442695040888963407
				key &= (1 << 32) - 1
				var value fr.Element
				value.SetUint64(uint64(i+1)*1000000007 + 999999937)
				smt.InsertUint64(key, &value)
			}

			// Now measure batch update
			start := time.Now()
			for j := 0; j < batchSize; j++ {
				// Update existing entries (simulating tx execution modifying accounts)
				idx := (rep*batchSize + j) % 10_000
				key := uint64(idx)*6364136223846793005 + 1442695040888963407
				key &= (1 << 32) - 1
				var newValue fr.Element
				newValue.SetUint64(uint64(rep*batchSize+j+1) * 999999937)
				smt.InsertUint64(key, &newValue)
			}
			elapsed := time.Since(start)
			batchTimes = append(batchTimes, float64(elapsed.Microseconds())/1000.0) // ms
		}

		mean, p95, _ := computeStatsFloat(batchTimes)
		perUpdate := mean * 1000.0 / float64(batchSize) // us

		passStr := "PASS"
		if mean >= 50.0 {
			passStr = "FAIL"
		}

		fmt.Printf("  Batch update: mean=%.2fms, p95=%.2fms, per-update=%.2f us -- %s (target < 50ms)\n",
			mean, p95, perUpdate, passStr)

		batchResults = append(batchResults, BatchUpdateResult{
			TreeSize:        10_000,
			BatchSize:       batchSize,
			MeanMs:          math.Round(mean*100) / 100,
			P95Ms:           math.Round(p95*100) / 100,
			MeanPerUpdateUs: math.Round(perUpdate*100) / 100,
			Reps:            reps,
		})
	}

	// Print comparison table
	fmt.Println("\n\n=== Go vs TypeScript Comparison ===")
	fmt.Printf("%-12s %-15s %-15s %-10s %-15s %-15s %-10s\n",
		"Entries", "Go Insert(us)", "TS Insert(us)", "Speedup", "Go Verify(us)", "TS Verify(us)", "Speedup")
	for _, c := range comparisons {
		fmt.Printf("%-12d %-15.2f %-15.2f %-10.1fx %-15.2f %-15.2f %-10.1fx\n",
			c.EntryCount, c.OptInsertUs, c.TSInsertUs, c.GoVsTSSpeedup,
			c.OptVerifyUs, tsVerifyUs[c.EntryCount], c.VerifySpeedup)
	}

	// Save optimized results
	type OptResults struct {
		Comparisons  []ComparisonResult  `json:"comparisons"`
		BatchUpdates []BatchUpdateResult `json:"batch_updates"`
	}
	optResults := OptResults{
		Comparisons:  comparisons,
		BatchUpdates: batchResults,
	}
	resultsDir := filepath.Join("..", "results")
	data, _ := json.MarshalIndent(optResults, "", "  ")
	os.WriteFile(filepath.Join(resultsDir, "optimized-benchmark-results.json"), data, 0644)
	fmt.Println("\nOptimized results saved.")
}
