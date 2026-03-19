package sequencer

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// HighThroughputResult holds results for direct throughput measurement.
type HighThroughputResult struct {
	Scenario             string  `json:"scenario"`
	TxPreloaded          int     `json:"tx_preloaded"`
	BlocksProduced       int     `json:"blocks_produced"`
	TxIncluded           int     `json:"tx_included"`
	AvgBlockProdUs       float64 `json:"avg_block_production_us"`
	MinBlockProdUs       float64 `json:"min_block_production_us"`
	MaxBlockProdUs       float64 `json:"max_block_production_us"`
	MempoolInsertRateKps float64 `json:"mempool_insert_rate_kps"`
	MempoolDrainRateKps  float64 `json:"mempool_drain_rate_kps"`
	FIFOAccuracy         float64 `json:"fifo_accuracy_pct"`
	ForcedTxIncluded     int     `json:"forced_tx_included"`
	ForcedTxSubmitted    int     `json:"forced_tx_submitted"`
}

// TestHighThroughput_DirectMeasurement bypasses ticker-based generation
// and pre-loads transactions for precise block production measurement.
func TestHighThroughput_DirectMeasurement(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping in short mode")
	}

	scenarios := []struct {
		name       string
		txCount    int
		blockCount int
		forcedTx   int
	}{
		{"direct_100tx_10blocks", 1000, 10, 0},
		{"direct_500tx_10blocks", 5000, 10, 0},
		{"direct_1000tx_20blocks", 20000, 20, 0},
		{"direct_500tx_forced", 4500, 10, 50},
		{"direct_5000tx_50blocks", 250000, 50, 0},
	}

	for _, sc := range scenarios {
		t.Run(sc.name, func(t *testing.T) {
			config := DefaultConfig()
			config.MempoolCapacity = sc.txCount + sc.forcedTx + 1000
			config.MaxTxPerBlock = sc.txCount / sc.blockCount
			seq := New(config)

			// Pre-generate and insert all transactions
			insertStart := time.Now()
			txs := make([]Transaction, sc.txCount)
			for i := range txs {
				txs[i] = makeTx(byte(i%256), uint64(i))
			}
			added, dropped := seq.Mempool().AddBatch(txs)
			insertElapsed := time.Since(insertStart)

			insertRateKps := float64(added) / insertElapsed.Seconds() / 1000.0

			// Submit forced transactions
			for i := 0; i < sc.forcedTx; i++ {
				tx := makeTx(byte(200+i%56), uint64(sc.txCount+i))
				seq.ForcedQueue().Submit(tx, uint64(10000+i))
			}

			// Produce blocks and measure each one
			var blockTimes []float64
			totalTx := 0

			for b := 0; b < sc.blockCount; b++ {
				start := time.Now()
				block := seq.ProduceBlock()
				elapsed := time.Since(start)

				blockTimes = append(blockTimes, float64(elapsed.Microseconds()))
				totalTx += len(block.Transactions)
			}

			// Calculate stats
			var sum, minT, maxT float64
			minT = blockTimes[0]
			maxT = blockTimes[0]
			for _, bt := range blockTimes {
				sum += bt
				if bt < minT {
					minT = bt
				}
				if bt > maxT {
					maxT = bt
				}
			}
			avgUs := sum / float64(len(blockTimes))

			m := seq.Metrics()
			result := HighThroughputResult{
				Scenario:             sc.name,
				TxPreloaded:          sc.txCount,
				BlocksProduced:       sc.blockCount,
				TxIncluded:           totalTx,
				AvgBlockProdUs:       avgUs,
				MinBlockProdUs:       minT,
				MaxBlockProdUs:       maxT,
				MempoolInsertRateKps: insertRateKps,
				FIFOAccuracy:         m.FIFOAccuracy(),
				ForcedTxSubmitted:    sc.forcedTx,
				ForcedTxIncluded:     m.ForcedTxIncluded,
			}

			// Measure drain rate
			drainMetrics := &Metrics{}
			drainPool := NewMempool(10000, drainMetrics)
			drainTxs := make([]Transaction, 10000)
			for i := range drainTxs {
				drainTxs[i] = makeTx(byte(i%256), uint64(i))
			}
			drainPool.AddBatch(drainTxs)
			drainStart := time.Now()
			for i := 0; i < 20; i++ {
				drainPool.Drain(500, 10_000_000, 21_000)
				// Refill
				refill := make([]Transaction, 500)
				for j := range refill {
					refill[j] = makeTx(byte(j%256), uint64(10000+i*500+j))
				}
				drainPool.AddBatch(refill)
			}
			drainElapsed := time.Since(drainStart)
			result.MempoolDrainRateKps = 10.0 / drainElapsed.Seconds() // 10K drained

			t.Logf("\n=== %s ===", sc.name)
			t.Logf("  TX preloaded:         %d", sc.txCount)
			t.Logf("  Blocks produced:      %d", sc.blockCount)
			t.Logf("  TX included:          %d", totalTx)
			t.Logf("  TX dropped:           %d", dropped)
			t.Logf("  Avg block production: %.1f us (%.3f ms)", avgUs, avgUs/1000.0)
			t.Logf("  Min block production: %.1f us", minT)
			t.Logf("  Max block production: %.1f us", maxT)
			t.Logf("  Mempool insert rate:  %.1f K tx/s", insertRateKps)
			t.Logf("  Mempool drain rate:   %.1f K tx/s", result.MempoolDrainRateKps)
			t.Logf("  FIFO accuracy:        %.2f%%", result.FIFOAccuracy)
			t.Logf("  Forced TX:            %d/%d included", result.ForcedTxIncluded, sc.forcedTx)

			// Write to results
			resultsDir := filepath.Join("..", "results")
			os.MkdirAll(resultsDir, 0755)
			data, _ := json.MarshalIndent(result, "", "  ")
			os.WriteFile(filepath.Join(resultsDir, sc.name+".json"), data, 0644)

			// Assertions
			if avgUs > 50000 { // 50ms
				t.Errorf("avg block production too slow: %.1f us", avgUs)
			}
			if result.FIFOAccuracy < 99.9 {
				t.Errorf("FIFO accuracy too low: %.2f%%", result.FIFOAccuracy)
			}
			if sc.forcedTx > 0 && result.ForcedTxIncluded != sc.forcedTx {
				t.Errorf("forced TX not fully included: %d/%d", result.ForcedTxIncluded, sc.forcedTx)
			}
		})
	}
}

// TestConcurrent_InsertAndProduce measures concurrent mempool access.
func TestConcurrent_InsertAndProduce(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping in short mode")
	}

	config := DefaultConfig()
	config.MempoolCapacity = 100_000
	config.MaxTxPerBlock = 500
	seq := New(config)

	const producers = 4
	const txPerProducer = 5000
	const numBlocks = 50

	var wg sync.WaitGroup

	// Start concurrent producers
	start := time.Now()
	for p := 0; p < producers; p++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for i := 0; i < txPerProducer; i++ {
				tx := makeTx(byte(id), uint64(i))
				seq.Mempool().Add(tx)
				// Small yield to simulate realistic arrival
				if i%100 == 0 {
					time.Sleep(time.Microsecond)
				}
			}
		}(p)
	}

	// Produce blocks concurrently
	var blockTimes []int64
	var blockMu sync.Mutex
	go func() {
		for i := 0; i < numBlocks; i++ {
			block := seq.ProduceBlock()
			blockMu.Lock()
			blockTimes = append(blockTimes, block.ProducedInNs)
			blockMu.Unlock()
			time.Sleep(10 * time.Millisecond) // ~100 blocks/s rate
		}
	}()

	wg.Wait()
	elapsed := time.Since(start)

	m := seq.Metrics()
	t.Logf("\n=== Concurrent Insert + Produce ===")
	t.Logf("  Producers:            %d x %d tx = %d total", producers, txPerProducer, producers*txPerProducer)
	t.Logf("  Blocks produced:      %d", m.BlocksProduced)
	t.Logf("  TX included:          %d", m.TxIncluded)
	t.Logf("  FIFO accuracy:        %.2f%%", m.FIFOAccuracy())
	t.Logf("  Elapsed:              %.1f ms", float64(elapsed.Milliseconds()))
	t.Logf("  Insert throughput:    %.1f K tx/s", float64(producers*txPerProducer)/elapsed.Seconds()/1000.0)

	// Write result
	result := map[string]interface{}{
		"scenario":           "concurrent_insert_produce",
		"producers":          producers,
		"tx_per_producer":    txPerProducer,
		"total_tx":           producers * txPerProducer,
		"blocks_produced":    m.BlocksProduced,
		"tx_included":        m.TxIncluded,
		"fifo_accuracy_pct":  m.FIFOAccuracy(),
		"elapsed_ms":         float64(elapsed.Milliseconds()),
		"insert_throughput_kps": float64(producers*txPerProducer) / elapsed.Seconds() / 1000.0,
	}
	resultsDir := filepath.Join("..", "results")
	os.MkdirAll(resultsDir, 0755)
	data, _ := json.MarshalIndent(result, "", "  ")
	os.WriteFile(filepath.Join(resultsDir, "concurrent_insert_produce.json"), data, 0644)

	if m.FIFOAccuracy() < 99.0 {
		t.Errorf("FIFO accuracy under concurrent load: %.2f%%", m.FIFOAccuracy())
	}
}

// TestBlockProduction_Scaling measures block production time across tx counts.
func TestBlockProduction_Scaling(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping in short mode")
	}

	txCounts := []int{10, 50, 100, 200, 500, 1000, 2000, 5000}
	reps := 30 // 30 repetitions per configuration for statistical validity

	type ScalingResult struct {
		TxCount int     `json:"tx_count"`
		AvgUs   float64 `json:"avg_us"`
		MinUs   float64 `json:"min_us"`
		MaxUs   float64 `json:"max_us"`
		StdUs   float64 `json:"std_us"`
	}

	var results []ScalingResult

	for _, txCount := range txCounts {
		var times []float64

		for r := 0; r < reps; r++ {
			config := DefaultConfig()
			config.MempoolCapacity = txCount + 100
			config.MaxTxPerBlock = txCount + 100
			config.BlockGasLimit = uint64(txCount+100) * 21_000
			seq := New(config)

			txs := make([]Transaction, txCount)
			for i := range txs {
				txs[i] = makeTx(byte(i%256), uint64(i))
			}
			seq.Mempool().AddBatch(txs)

			start := time.Now()
			seq.ProduceBlock()
			elapsed := float64(time.Since(start).Microseconds())
			times = append(times, elapsed)
		}

		// Calculate stats
		var sum float64
		minT, maxT := times[0], times[0]
		for _, v := range times {
			sum += v
			if v < minT {
				minT = v
			}
			if v > maxT {
				maxT = v
			}
		}
		avg := sum / float64(len(times))

		var sqDiff float64
		for _, v := range times {
			sqDiff += (v - avg) * (v - avg)
		}
		std := 0.0
		if len(times) > 1 {
			std = sqDiff / float64(len(times)-1)
			if std > 0 {
				// sqrt manually
				x := std
				for i := 0; i < 20; i++ {
					x = (x + std/x) / 2
				}
				std = x
			}
		}

		results = append(results, ScalingResult{
			TxCount: txCount,
			AvgUs:   avg,
			MinUs:   minT,
			MaxUs:   maxT,
			StdUs:   std,
		})

		t.Logf("  tx=%5d: avg=%.1f us, min=%.1f us, max=%.1f us, std=%.1f us (%.3f ms)",
			txCount, avg, minT, maxT, std, avg/1000.0)
	}

	// Write scaling results
	resultsDir := filepath.Join("..", "results")
	os.MkdirAll(resultsDir, 0755)
	data, _ := json.MarshalIndent(results, "", "  ")
	os.WriteFile(filepath.Join(resultsDir, "block_production_scaling.json"), data, 0644)

	// Generate CSV for plotting
	csv := "tx_count,avg_us,min_us,max_us,std_us\n"
	for _, r := range results {
		csv += fmt.Sprintf("%d,%.1f,%.1f,%.1f,%.1f\n", r.TxCount, r.AvgUs, r.MinUs, r.MaxUs, r.StdUs)
	}
	os.WriteFile(filepath.Join(resultsDir, "block_production_scaling.csv"), []byte(csv), 0644)
}
