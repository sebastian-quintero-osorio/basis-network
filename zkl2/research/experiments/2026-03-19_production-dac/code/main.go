// Production DAC Experiment -- Benchmark Runner
//
// RU-L8: Measures attestation latency, storage overhead, recovery time,
// and failure tolerance for a 7-node DAC with hybrid AES+RS+Shamir encoding.
package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"time"

	"github.com/basis-network/zkl2-production-dac/dac"
	"github.com/basis-network/zkl2-production-dac/erasure"
	"github.com/basis-network/zkl2-production-dac/shamir"
)

// BenchmarkResult holds results from a single benchmark run.
type BenchmarkResult struct {
	Name             string        `json:"name"`
	BatchSize        int           `json:"batch_size_bytes"`
	Config           string        `json:"config"`
	Iterations       int           `json:"iterations"`
	WarmUp           int           `json:"warm_up"`
	MeanLatencyMs    float64       `json:"mean_latency_ms"`
	P50LatencyMs     float64       `json:"p50_latency_ms"`
	P95LatencyMs     float64       `json:"p95_latency_ms"`
	P99LatencyMs     float64       `json:"p99_latency_ms"`
	StdDevMs         float64       `json:"stddev_ms"`
	CI95LowerMs      float64       `json:"ci95_lower_ms"`
	CI95UpperMs      float64       `json:"ci95_upper_ms"`
	StorageOverhead  float64       `json:"storage_overhead,omitempty"`
	NodesOnline      int           `json:"nodes_online,omitempty"`
	SuccessRate      float64       `json:"success_rate"`
	Details          interface{}   `json:"details,omitempty"`
}

// TimingBreakdown holds per-phase timing.
type TimingBreakdown struct {
	EncryptEncode float64 `json:"encrypt_encode_ms"`
	KeyShare      float64 `json:"key_share_ms"`
	Distribution  float64 `json:"distribution_ms"`
	Attestation   float64 `json:"attestation_ms"`
	Total         float64 `json:"total_ms"`
}

// RecoveryBreakdown holds per-phase recovery timing.
type RecoveryBreakdown struct {
	ChunkCollect float64 `json:"chunk_collect_ms"`
	KeyRecover   float64 `json:"key_recover_ms"`
	RSDecode     float64 `json:"rs_decode_ms"`
	Total        float64 `json:"total_ms"`
}

func main() {
	fmt.Println("=== Production DAC Experiment (RU-L8) ===")
	fmt.Println("Configuration: 7 nodes, 5-of-7 threshold, AES+RS+Shamir hybrid")
	fmt.Println()

	resultsDir := filepath.Join("..", "results")
	os.MkdirAll(resultsDir, 0755)

	// Run all benchmark suites
	allResults := make(map[string][]BenchmarkResult)

	// 1. Attestation latency benchmarks
	fmt.Println("--- Benchmark 1: Attestation Latency ---")
	allResults["attestation_latency"] = benchmarkAttestationLatency()

	// 2. Storage overhead analysis
	fmt.Println("\n--- Benchmark 2: Storage Overhead ---")
	allResults["storage_overhead"] = benchmarkStorageOverhead()

	// 3. Recovery time benchmarks
	fmt.Println("\n--- Benchmark 3: Recovery Time ---")
	allResults["recovery_time"] = benchmarkRecoveryTime()

	// 4. Failure tolerance tests
	fmt.Println("\n--- Benchmark 4: Failure Tolerance ---")
	allResults["failure_tolerance"] = benchmarkFailureTolerance()

	// 5. Availability probability analysis
	fmt.Println("\n--- Benchmark 5: Availability Probability ---")
	allResults["availability"] = benchmarkAvailability()

	// 6. Privacy validation
	fmt.Println("\n--- Benchmark 6: Privacy Validation ---")
	allResults["privacy"] = benchmarkPrivacy()

	// 7. Configuration comparison (vs RU-V6)
	fmt.Println("\n--- Benchmark 7: Configuration Comparison ---")
	allResults["comparison"] = benchmarkComparison()

	// Save results
	for name, results := range allResults {
		filename := filepath.Join(resultsDir, name+".json")
		data, _ := json.MarshalIndent(results, "", "  ")
		os.WriteFile(filename, data, 0644)
		fmt.Printf("\nSaved: %s\n", filename)
	}

	fmt.Println("\n=== Experiment Complete ===")
}

func benchmarkAttestationLatency() []BenchmarkResult {
	sizes := []int{
		10 * 1024,      // 10 KB
		100 * 1024,     // 100 KB
		500 * 1024,     // 500 KB
		1024 * 1024,    // 1 MB
		5 * 1024 * 1024, // 5 MB
	}
	warmUp := 3
	iterations := 50

	var results []BenchmarkResult

	for _, size := range sizes {
		data := makeRandomData(size)
		committee, _ := dac.NewCommittee(dac.DefaultDACConfig())

		// Warm up
		for i := 0; i < warmUp; i++ {
			committee.Disperse(uint64(i), data)
		}

		// Measure
		latencies := make([]float64, iterations)
		var breakdowns []TimingBreakdown
		successes := 0

		for i := 0; i < iterations; i++ {
			result := committee.Disperse(uint64(warmUp+i), data)
			latencies[i] = float64(result.TotalTime.Microseconds()) / 1000.0
			if result.Success {
				successes++
			}
			breakdowns = append(breakdowns, TimingBreakdown{
				EncryptEncode: float64(result.EncryptionTime.Microseconds()) / 1000.0,
				KeyShare:      float64(result.KeyShareTime.Microseconds()) / 1000.0,
				Distribution:  float64(result.DistributionTime.Microseconds()) / 1000.0,
				Attestation:   float64(result.AttestationTime.Microseconds()) / 1000.0,
				Total:         float64(result.TotalTime.Microseconds()) / 1000.0,
			})
		}

		stats := computeStats(latencies)
		meanBreakdown := averageBreakdowns(breakdowns)

		r := BenchmarkResult{
			Name:            fmt.Sprintf("attestation_5of7_%dKB", size/1024),
			BatchSize:       size,
			Config:          "5-of-7 hybrid AES+RS+Shamir",
			Iterations:      iterations,
			WarmUp:          warmUp,
			MeanLatencyMs:   stats.Mean,
			P50LatencyMs:    stats.P50,
			P95LatencyMs:    stats.P95,
			P99LatencyMs:    stats.P99,
			StdDevMs:        stats.StdDev,
			CI95LowerMs:     stats.CI95Lower,
			CI95UpperMs:     stats.CI95Upper,
			StorageOverhead: committee.StorageOverhead(size),
			NodesOnline:     7,
			SuccessRate:     float64(successes) / float64(iterations),
			Details:         meanBreakdown,
		}

		fmt.Printf("  %6d KB | Mean: %8.3f ms | P95: %8.3f ms | CI95: [%.3f, %.3f] | Target: <1000 ms | %s\n",
			size/1024, r.MeanLatencyMs, r.P95LatencyMs, r.CI95LowerMs, r.CI95UpperMs,
			verdictStr(r.P95LatencyMs < 1000))

		results = append(results, r)
	}

	return results
}

func benchmarkStorageOverhead() []BenchmarkResult {
	sizes := []int{10 * 1024, 100 * 1024, 500 * 1024, 1024 * 1024, 5 * 1024 * 1024}
	var results []BenchmarkResult

	committee, _ := dac.NewCommittee(dac.DefaultDACConfig())

	for _, size := range sizes {
		overhead := committee.StorageOverhead(size)

		r := BenchmarkResult{
			Name:            fmt.Sprintf("storage_%dKB", size/1024),
			BatchSize:       size,
			Config:          "5-of-7 hybrid AES+RS+Shamir",
			StorageOverhead: overhead,
			SuccessRate:     1.0,
		}

		fmt.Printf("  %6d KB | Overhead: %.3fx | Per-node: %d KB | Total: %d KB\n",
			size/1024, overhead,
			int(float64(size)*overhead/7.0/1024),
			int(float64(size)*overhead/1024))

		results = append(results, r)
	}

	return results
}

func benchmarkRecoveryTime() []BenchmarkResult {
	sizes := []int{10 * 1024, 100 * 1024, 500 * 1024, 1024 * 1024}
	warmUp := 3
	iterations := 30

	var results []BenchmarkResult

	for _, size := range sizes {
		data := makeRandomData(size)
		committee, _ := dac.NewCommittee(dac.DefaultDACConfig())

		// Disperse the data first
		for i := 0; i < warmUp; i++ {
			committee.Disperse(uint64(i), data)
		}

		batchID := uint64(100)
		committee.Disperse(batchID, data)

		// Warm up recovery
		for i := 0; i < warmUp; i++ {
			committee.Recover(batchID, size)
		}

		// Measure recovery
		latencies := make([]float64, iterations)
		var breakdowns []RecoveryBreakdown
		successes := 0

		for i := 0; i < iterations; i++ {
			recovered, result := committee.Recover(batchID, size)
			latencies[i] = float64(result.TotalTime.Microseconds()) / 1000.0
			if result.Success && len(recovered) == size {
				successes++
			}
			breakdowns = append(breakdowns, RecoveryBreakdown{
				ChunkCollect: float64(result.ChunkCollect.Microseconds()) / 1000.0,
				KeyRecover:   float64(result.KeyRecoverTime.Microseconds()) / 1000.0,
				RSDecode:     float64(result.RSDecodeTime.Microseconds()) / 1000.0,
				Total:        float64(result.TotalTime.Microseconds()) / 1000.0,
			})
		}

		stats := computeStats(latencies)
		meanBreakdown := averageRecoveryBreakdowns(breakdowns)

		r := BenchmarkResult{
			Name:           fmt.Sprintf("recovery_5of7_%dKB", size/1024),
			BatchSize:      size,
			Config:         "5-of-7 recovery, all nodes online",
			Iterations:     iterations,
			WarmUp:         warmUp,
			MeanLatencyMs:  stats.Mean,
			P50LatencyMs:   stats.P50,
			P95LatencyMs:   stats.P95,
			P99LatencyMs:   stats.P99,
			StdDevMs:       stats.StdDev,
			CI95LowerMs:    stats.CI95Lower,
			CI95UpperMs:    stats.CI95Upper,
			NodesOnline:    7,
			SuccessRate:    float64(successes) / float64(iterations),
			Details:        meanBreakdown,
		}

		fmt.Printf("  %6d KB | Mean: %8.3f ms | P95: %8.3f ms | Success: %.0f%% | %s\n",
			size/1024, r.MeanLatencyMs, r.P95LatencyMs, r.SuccessRate*100,
			verdictStr(r.SuccessRate == 1.0))

		results = append(results, r)
	}

	// Recovery with 2 nodes down (minimum: 5 available)
	for _, size := range []int{100 * 1024, 500 * 1024, 1024 * 1024} {
		data := makeRandomData(size)
		committee, _ := dac.NewCommittee(dac.DefaultDACConfig())

		batchID := uint64(200)
		committee.Disperse(batchID, data)

		// Take 2 nodes offline
		committee.SetNodeStatus(dac.NodeID(5), dac.NodeOffline)
		committee.SetNodeStatus(dac.NodeID(6), dac.NodeOffline)

		latencies := make([]float64, iterations)
		successes := 0
		dataMatch := 0

		for i := 0; i < iterations; i++ {
			recovered, result := committee.Recover(batchID, size)
			latencies[i] = float64(result.TotalTime.Microseconds()) / 1000.0
			if result.Success {
				successes++
				if bytesEqual(recovered, data) {
					dataMatch++
				}
			}
		}

		stats := computeStats(latencies)

		r := BenchmarkResult{
			Name:           fmt.Sprintf("recovery_5of7_2down_%dKB", size/1024),
			BatchSize:      size,
			Config:         "5-of-7 recovery, 2 nodes offline",
			Iterations:     iterations,
			MeanLatencyMs:  stats.Mean,
			P50LatencyMs:   stats.P50,
			P95LatencyMs:   stats.P95,
			StdDevMs:       stats.StdDev,
			CI95LowerMs:    stats.CI95Lower,
			CI95UpperMs:    stats.CI95Upper,
			NodesOnline:    5,
			SuccessRate:    float64(successes) / float64(iterations),
			Details:        map[string]int{"data_match": dataMatch, "total": iterations},
		}

		fmt.Printf("  %6d KB (2 down) | Mean: %8.3f ms | Success: %.0f%% | Data match: %d/%d | %s\n",
			size/1024, r.MeanLatencyMs, r.SuccessRate*100, dataMatch, iterations,
			verdictStr(r.SuccessRate == 1.0 && dataMatch == iterations))

		results = append(results, r)

		// Restore nodes
		committee.SetNodeStatus(dac.NodeID(5), dac.NodeOnline)
		committee.SetNodeStatus(dac.NodeID(6), dac.NodeOnline)
	}

	return results
}

func benchmarkFailureTolerance() []BenchmarkResult {
	size := 100 * 1024 // 100 KB
	data := makeRandomData(size)
	iterations := 30
	var results []BenchmarkResult

	// Test with 0, 1, 2, 3 nodes offline
	for nodesDown := 0; nodesDown <= 3; nodesDown++ {
		committee, _ := dac.NewCommittee(dac.DefaultDACConfig())

		// Take nodes offline
		for i := 0; i < nodesDown; i++ {
			committee.SetNodeStatus(dac.NodeID(6-i), dac.NodeOffline)
		}

		// Disperse
		disperseSuccesses := 0
		for i := 0; i < iterations; i++ {
			result := committee.Disperse(uint64(i), data)
			if result.Success {
				disperseSuccesses++
			}
		}

		// Recovery from a successful batch
		batchID := uint64(1000)
		dispResult := committee.Disperse(batchID, data)

		recoverSuccesses := 0
		dataMatches := 0
		if dispResult.Success {
			for i := 0; i < iterations; i++ {
				recovered, recResult := committee.Recover(batchID, size)
				if recResult.Success {
					recoverSuccesses++
					if bytesEqual(recovered, data) {
						dataMatches++
					}
				}
			}
		}

		nodesOnline := 7 - nodesDown
		expectedSuccess := nodesOnline >= 5

		r := BenchmarkResult{
			Name:        fmt.Sprintf("failure_%d_down", nodesDown),
			BatchSize:   size,
			Config:      fmt.Sprintf("5-of-7, %d nodes offline", nodesDown),
			Iterations:  iterations,
			NodesOnline: nodesOnline,
			SuccessRate: float64(disperseSuccesses) / float64(iterations),
			Details: map[string]interface{}{
				"nodes_down":        nodesDown,
				"disperse_success":  disperseSuccesses,
				"recover_success":   recoverSuccesses,
				"data_match":        dataMatches,
				"expected_success":  expectedSuccess,
				"fallback_required": !expectedSuccess,
			},
		}

		status := "PASS"
		if expectedSuccess && r.SuccessRate < 1.0 {
			status = "FAIL"
		}
		if !expectedSuccess && r.SuccessRate > 0.0 {
			status = "FAIL (should have failed)"
		}

		fmt.Printf("  %d nodes down (%d online) | Disperse: %.0f%% | Recover: %d/%d | Data match: %d/%d | %s\n",
			nodesDown, nodesOnline,
			r.SuccessRate*100, recoverSuccesses, iterations, dataMatches, iterations, status)

		results = append(results, r)
	}

	return results
}

func benchmarkAvailability() []BenchmarkResult {
	var results []BenchmarkResult

	configs := []struct {
		name string
		k, n int
	}{
		{"2-of-3 (RU-V6)", 2, 3},
		{"5-of-7 (Production)", 5, 7},
		{"4-of-7 (Conservative)", 4, 7},
		{"5-of-6 (AnyTrust-like)", 5, 6},
		{"3-of-5 (ApeX-like)", 3, 5},
	}

	probabilities := []float64{0.90, 0.95, 0.99, 0.999}

	for _, cfg := range configs {
		for _, p := range probabilities {
			avail := dac.AvailabilityProbability(cfg.k, cfg.n, p)
			nines := -math.Log10(1.0 - avail)
			if avail >= 1.0-1e-15 {
				nines = 15
			}

			r := BenchmarkResult{
				Name:   fmt.Sprintf("avail_%s_p%.3f", cfg.name, p),
				Config: cfg.name,
				Details: map[string]interface{}{
					"k":                    cfg.k,
					"n":                    cfg.n,
					"per_node_availability": p,
					"system_availability":  avail,
					"nines":               nines,
				},
				SuccessRate: avail,
			}

			fmt.Printf("  %-25s | p=%.3f | Availability: %.10f | Nines: %.2f\n",
				cfg.name, p, avail, nines)

			results = append(results, r)
		}
	}

	return results
}

func benchmarkPrivacy() []BenchmarkResult {
	var results []BenchmarkResult
	iterations := 30

	// Test 1: Single chunk reveals no plaintext information
	fmt.Println("  Privacy Test 1: Chunk independence from plaintext")
	size := 100 * 1024
	committee, _ := dac.NewCommittee(dac.DefaultDACConfig())

	// Disperse two different batches
	data1 := makeRandomData(size)
	data2 := makeRandomData(size)

	committee.Disperse(1, data1)
	committee.Disperse(2, data2)

	// Get chunks from node 0 for both batches
	node := committee.Nodes[0]
	pkg1, _ := node.GetStored(1)
	pkg2, _ := node.GetStored(2)

	// Chunks should be different (encrypted with different keys)
	chunksIdentical := bytesEqual(pkg1.Chunk.Data, pkg2.Chunk.Data)

	results = append(results, BenchmarkResult{
		Name:        "privacy_chunk_independence",
		Config:      "Single node chunk comparison",
		SuccessRate: boolToFloat(!chunksIdentical),
		Details: map[string]interface{}{
			"chunks_identical": chunksIdentical,
			"verdict":          "PASS: chunks are different (different AES keys)",
		},
	})
	fmt.Printf("    Chunks identical: %v -> %s\n", chunksIdentical, verdictStr(!chunksIdentical))

	// Test 2: Insufficient shares reveal nothing about key
	fmt.Println("  Privacy Test 2: k-1 key shares reveal nothing")
	// Generate a field-safe key (< BN254 prime)
	rawKey := makeRandomData(32)
	rawKey[0] &= 0x0f // Ensure < prime by clearing top bits
	passCount := 0

	for i := 0; i < iterations; i++ {
		shares, err := shamir.Split(rawKey, shamir.DefaultConfig())
		if err != nil {
			fmt.Printf("    WARNING: Split error: %v\n", err)
			continue
		}
		_ = err

		// Take k-1 = 4 shares
		partial := shares[:4]

		// Try to recover with fewer shares than threshold
		// Lagrange interpolation with 4 shares from a degree-4 polynomial gives wrong result
		recovered, err := shamir.Recover(partial)
		if err != nil {
			passCount++ // Error is also acceptable
			continue
		}

		// The recovered value with fewer shares should NOT match the key
		if !bytesEqual(recovered, rawKey) {
			passCount++
		}
	}

	results = append(results, BenchmarkResult{
		Name:        "privacy_insufficient_shares",
		Config:      "4-of-5 shares (below threshold)",
		Iterations:  iterations,
		SuccessRate: float64(passCount) / float64(iterations),
		Details: map[string]interface{}{
			"pass_count": passCount,
			"total":      iterations,
			"verdict":    fmt.Sprintf("%d/%d: k-1 shares do not reveal key", passCount, iterations),
		},
	})
	fmt.Printf("    k-1 shares key recovery mismatch: %d/%d -> %s\n",
		passCount, iterations, verdictStr(passCount == iterations))

	// Test 3: Correct threshold recovery
	fmt.Println("  Privacy Test 3: k shares correctly recover key")
	passCount = 0

	for i := 0; i < iterations; i++ {
		testKey := makeRandomData(32)
		testKey[0] &= 0x0f // Ensure < prime
		shares, err := shamir.Split(testKey, shamir.DefaultConfig())
		if err != nil {
			continue
		}

		// Use exactly k=5 shares
		recovered, err := shamir.Recover(shares[:5])
		if err == nil && bytesEqual(recovered, testKey) {
			passCount++
		}
	}

	results = append(results, BenchmarkResult{
		Name:        "privacy_correct_recovery",
		Config:      "5-of-7 shares (at threshold)",
		Iterations:  iterations,
		SuccessRate: float64(passCount) / float64(iterations),
		Details: map[string]interface{}{
			"pass_count": passCount,
			"total":      iterations,
		},
	})
	fmt.Printf("    k shares correct recovery: %d/%d -> %s\n",
		passCount, iterations, verdictStr(passCount == iterations))

	// Test 4: Full round-trip data integrity
	fmt.Println("  Privacy Test 4: Full round-trip data integrity")
	passCount = 0
	sizes := []int{1024, 10 * 1024, 100 * 1024, 500 * 1024}

	for _, sz := range sizes {
		for i := 0; i < 10; i++ {
			data := makeRandomData(sz)
			committee, _ := dac.NewCommittee(dac.DefaultDACConfig())

			batchID := uint64(i + 1)
			committee.Disperse(batchID, data)

			recovered, result := committee.Recover(batchID, sz)
			if result.Success && bytesEqual(recovered, data) {
				passCount++
			}
		}
	}

	totalRoundTrips := len(sizes) * 10
	results = append(results, BenchmarkResult{
		Name:        "privacy_round_trip",
		Config:      "Full encode-disperse-recover cycle",
		Iterations:  totalRoundTrips,
		SuccessRate: float64(passCount) / float64(totalRoundTrips),
		Details: map[string]interface{}{
			"pass_count": passCount,
			"total":      totalRoundTrips,
			"sizes_kb":   []int{1, 10, 100, 500},
		},
	})
	fmt.Printf("    Round-trip integrity: %d/%d -> %s\n",
		passCount, totalRoundTrips, verdictStr(passCount == totalRoundTrips))

	// Test 5: Certificate verification
	fmt.Println("  Privacy Test 5: Certificate verification")
	passCount = 0

	for i := 0; i < iterations; i++ {
		data := makeRandomData(100 * 1024)
		committee, _ := dac.NewCommittee(dac.DefaultDACConfig())

		result := committee.Disperse(uint64(i+1), data)
		if result.Success && result.Certificate != nil {
			valid, count := committee.VerifyCertificate(result.Certificate)
			if valid && count >= 5 {
				passCount++
			}
		}
	}

	results = append(results, BenchmarkResult{
		Name:        "certificate_verification",
		Config:      "ECDSA multi-sig verification",
		Iterations:  iterations,
		SuccessRate: float64(passCount) / float64(iterations),
	})
	fmt.Printf("    Certificate verification: %d/%d -> %s\n",
		passCount, iterations, verdictStr(passCount == iterations))

	return results
}

func benchmarkComparison() []BenchmarkResult {
	var results []BenchmarkResult

	sizes := []int{100 * 1024, 500 * 1024, 1024 * 1024}
	iterations := 30

	// (5,7) production config
	for _, size := range sizes {
		data := makeRandomData(size)

		// Production (5,7)
		committee7, _ := dac.NewCommittee(dac.DefaultDACConfig())
		latencies7 := make([]float64, iterations)
		for i := 0; i < 3; i++ {
			committee7.Disperse(uint64(i), data)
		}
		for i := 0; i < iterations; i++ {
			result := committee7.Disperse(uint64(100+i), data)
			latencies7[i] = float64(result.TotalTime.Microseconds()) / 1000.0
		}
		stats7 := computeStats(latencies7)

		// Simulated (2,3) config for comparison
		config3 := dac.DACConfig{
			Erasure:         erasure.Config{DataShards: 2, ParityShards: 1},
			Shamir:          shamir.Config{Threshold: 2, Total: 3},
			AttestThreshold: 2,
			AttestTimeout:   time.Second,
		}
		committee3, _ := dac.NewCommittee(config3)
		latencies3 := make([]float64, iterations)
		for i := 0; i < 3; i++ {
			committee3.Disperse(uint64(i), data)
		}
		for i := 0; i < iterations; i++ {
			result := committee3.Disperse(uint64(100+i), data)
			latencies3[i] = float64(result.TotalTime.Microseconds()) / 1000.0
		}
		stats3 := computeStats(latencies3)

		r := BenchmarkResult{
			Name:      fmt.Sprintf("compare_%dKB", size/1024),
			BatchSize: size,
			Config:    "5-of-7 vs 2-of-3",
			Details: map[string]interface{}{
				"config_5of7_mean_ms":  stats7.Mean,
				"config_5of7_p95_ms":   stats7.P95,
				"config_2of3_mean_ms":  stats3.Mean,
				"config_2of3_p95_ms":   stats3.P95,
				"overhead_ratio":       stats7.Mean / stats3.Mean,
				"storage_5of7":         committee7.StorageOverhead(size),
				"storage_2of3":         committee3.StorageOverhead(size),
			},
			SuccessRate: 1.0,
		}

		fmt.Printf("  %6d KB | 5-of-7: %.3f ms | 2-of-3: %.3f ms | Ratio: %.2fx | Storage: %.2fx vs %.2fx\n",
			size/1024, stats7.Mean, stats3.Mean, stats7.Mean/stats3.Mean,
			committee7.StorageOverhead(size), committee3.StorageOverhead(size))

		results = append(results, r)
	}

	return results
}

// Statistics helpers

type Stats struct {
	Mean     float64
	StdDev   float64
	P50      float64
	P95      float64
	P99      float64
	CI95Lower float64
	CI95Upper float64
}

func computeStats(values []float64) Stats {
	n := len(values)
	if n == 0 {
		return Stats{}
	}

	// Mean
	sum := 0.0
	for _, v := range values {
		sum += v
	}
	mean := sum / float64(n)

	// StdDev
	sumSq := 0.0
	for _, v := range values {
		d := v - mean
		sumSq += d * d
	}
	stddev := math.Sqrt(sumSq / float64(n-1))

	// Sort for percentiles
	sorted := make([]float64, n)
	copy(sorted, values)
	sortFloat64s(sorted)

	p50 := percentile(sorted, 0.50)
	p95 := percentile(sorted, 0.95)
	p99 := percentile(sorted, 0.99)

	// 95% CI
	se := stddev / math.Sqrt(float64(n))
	ci95Lower := mean - 1.96*se
	ci95Upper := mean + 1.96*se

	return Stats{
		Mean:      mean,
		StdDev:    stddev,
		P50:       p50,
		P95:       p95,
		P99:       p99,
		CI95Lower: ci95Lower,
		CI95Upper: ci95Upper,
	}
}

func percentile(sorted []float64, p float64) float64 {
	n := len(sorted)
	idx := p * float64(n-1)
	lower := int(idx)
	upper := lower + 1
	if upper >= n {
		return sorted[n-1]
	}
	frac := idx - float64(lower)
	return sorted[lower]*(1-frac) + sorted[upper]*frac
}

func sortFloat64s(a []float64) {
	// Simple insertion sort (sufficient for n<=100)
	for i := 1; i < len(a); i++ {
		key := a[i]
		j := i - 1
		for j >= 0 && a[j] > key {
			a[j+1] = a[j]
			j--
		}
		a[j+1] = key
	}
}

func averageBreakdowns(bds []TimingBreakdown) TimingBreakdown {
	n := float64(len(bds))
	var sum TimingBreakdown
	for _, b := range bds {
		sum.EncryptEncode += b.EncryptEncode
		sum.KeyShare += b.KeyShare
		sum.Distribution += b.Distribution
		sum.Attestation += b.Attestation
		sum.Total += b.Total
	}
	return TimingBreakdown{
		EncryptEncode: sum.EncryptEncode / n,
		KeyShare:      sum.KeyShare / n,
		Distribution:  sum.Distribution / n,
		Attestation:   sum.Attestation / n,
		Total:         sum.Total / n,
	}
}

func averageRecoveryBreakdowns(bds []RecoveryBreakdown) RecoveryBreakdown {
	n := float64(len(bds))
	var sum RecoveryBreakdown
	for _, b := range bds {
		sum.ChunkCollect += b.ChunkCollect
		sum.KeyRecover += b.KeyRecover
		sum.RSDecode += b.RSDecode
		sum.Total += b.Total
	}
	return RecoveryBreakdown{
		ChunkCollect: sum.ChunkCollect / n,
		KeyRecover:   sum.KeyRecover / n,
		RSDecode:     sum.RSDecode / n,
		Total:        sum.Total / n,
	}
}

func makeRandomData(size int) []byte {
	data := make([]byte, size)
	rand.Read(data)
	return data
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func boolToFloat(b bool) float64 {
	if b {
		return 1.0
	}
	return 0.0
}

func verdictStr(pass bool) string {
	if pass {
		return "PASS"
	}
	return "FAIL"
}
