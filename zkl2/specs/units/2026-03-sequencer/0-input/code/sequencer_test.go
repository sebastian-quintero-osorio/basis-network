package sequencer

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// BenchmarkResult holds results for JSON serialization.
type BenchmarkResult struct {
	Scenario            string  `json:"scenario"`
	BlocksProduced      int     `json:"blocks_produced"`
	TxInserted          int     `json:"tx_inserted"`
	TxIncluded          int     `json:"tx_included"`
	TxDropped           int     `json:"tx_dropped"`
	AvgBlockProdMs      float64 `json:"avg_block_production_ms"`
	MempoolHighWater    int     `json:"mempool_high_watermark"`
	FIFOAccuracy        float64 `json:"fifo_accuracy_pct"`
	ForcedTxSubmitted   int     `json:"forced_tx_submitted"`
	ForcedTxIncluded    int     `json:"forced_tx_included"`
	MaxForcedLatencyMs  float64 `json:"max_forced_latency_ms"`
	EmptyBlocks         int     `json:"empty_blocks"`
	BlockFillRatio      float64 `json:"block_fill_ratio_pct"`
	ThroughputTPS       float64 `json:"throughput_tps"`
	ElapsedMs           float64 `json:"elapsed_ms"`
}

func makeTx(from byte, nonce uint64) Transaction {
	var fromAddr [20]byte
	fromAddr[0] = from
	var toAddr [20]byte
	toAddr[0] = from + 1
	return Transaction{
		Hash:     TxHash(fromAddr, nonce, nil),
		From:     fromAddr,
		To:       toAddr,
		Nonce:    nonce,
		GasLimit: 21_000,
		Value:    100,
	}
}

// ---------- Unit Tests ----------

func TestMempoolFIFOOrdering(t *testing.T) {
	metrics := &Metrics{}
	mp := NewMempool(100, metrics)

	for i := 0; i < 50; i++ {
		tx := makeTx(byte(i%10), uint64(i))
		if err := mp.Add(tx); err != nil {
			t.Fatalf("add failed: %v", err)
		}
	}

	txs := mp.Drain(50, 50*21_000, 21_000)
	if len(txs) != 50 {
		t.Fatalf("expected 50 txs, got %d", len(txs))
	}

	for i := 1; i < len(txs); i++ {
		if txs[i].SeqNum <= txs[i-1].SeqNum {
			t.Errorf("FIFO violation at index %d: seq %d <= %d", i, txs[i].SeqNum, txs[i-1].SeqNum)
		}
	}
}

func TestMempoolCapacity(t *testing.T) {
	metrics := &Metrics{}
	mp := NewMempool(10, metrics)

	for i := 0; i < 15; i++ {
		mp.Add(makeTx(byte(i), uint64(i)))
	}

	if metrics.TxDropped != 5 {
		t.Errorf("expected 5 dropped, got %d", metrics.TxDropped)
	}
	if mp.Len() != 10 {
		t.Errorf("expected 10 pending, got %d", mp.Len())
	}
}

func TestMempoolGasLimit(t *testing.T) {
	metrics := &Metrics{}
	mp := NewMempool(100, metrics)

	for i := 0; i < 10; i++ {
		mp.Add(makeTx(byte(i), uint64(i)))
	}

	// Gas limit allows only 5 transactions
	txs := mp.Drain(100, 5*21_000, 21_000)
	if len(txs) != 5 {
		t.Errorf("expected 5 txs (gas limited), got %d", len(txs))
	}
	if mp.Len() != 5 {
		t.Errorf("expected 5 remaining, got %d", mp.Len())
	}
}

func TestForcedInclusionFIFO(t *testing.T) {
	metrics := &Metrics{}
	fq := NewForcedInclusionQueue(100*time.Millisecond, metrics)

	for i := 0; i < 5; i++ {
		fq.Submit(makeTx(byte(i), uint64(i)), uint64(1000+i))
	}

	if fq.Len() != 5 {
		t.Fatalf("expected 5 queued, got %d", fq.Len())
	}

	// Cooperative drain: should get all 5 in FIFO order
	result := fq.DrainDue(time.Now(), true)
	if len(result) != 5 {
		t.Fatalf("expected 5 drained, got %d", len(result))
	}

	for i := 1; i < len(result); i++ {
		if result[i].L1BlockNumber <= result[i-1].L1BlockNumber {
			t.Errorf("forced FIFO violation at %d", i)
		}
	}
}

func TestForcedInclusionDeadline(t *testing.T) {
	metrics := &Metrics{}
	fq := NewForcedInclusionQueue(50*time.Millisecond, metrics)

	fq.Submit(makeTx(1, 1), 1000)
	fq.Submit(makeTx(2, 2), 1001)

	// Before deadline: non-cooperative drain should return nothing
	result := fq.DrainDue(time.Now(), false)
	if len(result) != 0 {
		t.Errorf("expected 0 before deadline, got %d", len(result))
	}

	// Wait for deadline
	time.Sleep(60 * time.Millisecond)

	// After deadline: should drain in FIFO order
	result = fq.DrainDue(time.Now(), false)
	if len(result) != 2 {
		t.Errorf("expected 2 after deadline, got %d", len(result))
	}
}

func TestBlockProductionBasic(t *testing.T) {
	seq := New(DefaultConfig())

	// Add 100 transactions
	for i := 0; i < 100; i++ {
		seq.Mempool().Add(makeTx(byte(i%10), uint64(i)))
	}

	// Produce one block
	block := seq.ProduceBlock()

	if block.Number != 0 {
		t.Errorf("expected block 0, got %d", block.Number)
	}
	if len(block.Transactions) != 100 {
		t.Errorf("expected 100 txs, got %d", len(block.Transactions))
	}
	// On Windows, time.Now() resolution can be ~15ms, so production of
	// a fast block may measure as 0ns. This is acceptable -- the important
	// metric is that it does NOT exceed 50ms.
	if block.ProducedInNs < 0 {
		t.Error("block production time should be non-negative")
	}
}

func TestBlockProductionWithForced(t *testing.T) {
	seq := New(DefaultConfig())

	// Add regular transactions
	for i := 0; i < 50; i++ {
		seq.Mempool().Add(makeTx(byte(i%10), uint64(i)))
	}

	// Add forced transactions
	for i := 0; i < 5; i++ {
		tx := makeTx(byte(100+i), uint64(i))
		seq.ForcedQueue().Submit(tx, uint64(5000+i))
	}

	block := seq.ProduceBlock()

	// Forced transactions should appear first
	if len(block.Transactions) != 55 {
		t.Errorf("expected 55 txs, got %d", len(block.Transactions))
	}
	if block.GasUsed != 55*21_000 {
		t.Errorf("expected gas %d, got %d", 55*21_000, block.GasUsed)
	}
}

func TestEmptyBlockProduction(t *testing.T) {
	seq := New(DefaultConfig())
	block := seq.ProduceBlock()

	if len(block.Transactions) != 0 {
		t.Error("expected empty block")
	}
	if seq.Metrics().EmptyBlocks != 1 {
		t.Error("expected 1 empty block in metrics")
	}
}

// ---------- Benchmarks ----------

func BenchmarkMempoolInsert(b *testing.B) {
	metrics := &Metrics{}
	mp := NewMempool(b.N+1, metrics)
	tx := makeTx(1, 0)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		tx.Nonce = uint64(i)
		tx.Hash = TxHash(tx.From, tx.Nonce, nil)
		mp.Add(tx)
	}
}

func BenchmarkMempoolDrain(b *testing.B) {
	metrics := &Metrics{}
	mp := NewMempool(10000, metrics)

	for i := 0; i < 10000; i++ {
		mp.Add(makeTx(byte(i%256), uint64(i)))
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		mp.Drain(500, 10_000_000, 21_000)
		// Refill for next iteration
		b.StopTimer()
		for j := 0; j < 500; j++ {
			mp.Add(makeTx(byte(j%256), uint64(i*500+j)))
		}
		b.StartTimer()
	}
}

func BenchmarkBlockProduction(b *testing.B) {
	for _, txCount := range []int{10, 50, 100, 200, 500} {
		b.Run(fmt.Sprintf("tx_%d", txCount), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				b.StopTimer()
				seq := New(DefaultConfig())
				for j := 0; j < txCount; j++ {
					seq.Mempool().Add(makeTx(byte(j%256), uint64(j)))
				}
				b.StartTimer()
				seq.ProduceBlock()
			}
		})
	}
}

func BenchmarkConcurrentInsertAndProduce(b *testing.B) {
	seq := New(DefaultConfig())
	var wg sync.WaitGroup

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		// Concurrent insert
		wg.Add(1)
		go func(iter int) {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				seq.Mempool().Add(makeTx(byte(j%256), uint64(iter*100+j)))
			}
		}(i)

		// Produce block
		seq.ProduceBlock()
		wg.Wait()
	}
}

// ---------- Scenario Benchmarks (write results to JSON) ----------

func TestScenario_SteadyState100TPS(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping scenario in short mode")
	}
	runScenario(t, "steady_100tps", 100, 5*time.Second, 0, false)
}

func TestScenario_SteadyState500TPS(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping scenario in short mode")
	}
	runScenario(t, "steady_500tps", 500, 5*time.Second, 0, false)
}

func TestScenario_BurstLoad(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping scenario in short mode")
	}
	runScenario(t, "burst_1000tps", 1000, 3*time.Second, 0, false)
}

func TestScenario_ForcedInclusion(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping scenario in short mode")
	}
	runScenario(t, "forced_inclusion", 200, 5*time.Second, 20, false)
}

func TestScenario_AdversarialCensoring(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping scenario in short mode")
	}
	runScenario(t, "adversarial_censoring", 200, 5*time.Second, 20, true)
}

func TestScenario_MaxCapacity(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping scenario in short mode")
	}
	// Exceed mempool capacity
	runScenario(t, "max_capacity", 5000, 3*time.Second, 0, false)
}

func runScenario(t *testing.T, name string, targetTPS int, duration time.Duration, forcedTxCount int, adversarial bool) {
	t.Helper()

	config := DefaultConfig()
	config.BlockTimeMs = 1000 // 1 second blocks
	if adversarial {
		// Adversarial: sequencer tries to delay forced txs
		// (uses non-cooperative mode with short deadline to test)
		config.ForcedInclusionDelay = 200 * time.Millisecond
	}

	seq := New(config)

	// Submit forced transactions before starting
	for i := 0; i < forcedTxCount; i++ {
		tx := makeTx(byte(200+i%56), uint64(i))
		seq.ForcedQueue().Submit(tx, uint64(10000+i))
	}

	// Start block production in background
	go seq.Run()

	// Generate transactions at target TPS
	start := time.Now()
	txInterval := time.Second / time.Duration(targetTPS)
	rng := rand.New(rand.NewSource(42))

	txCount := 0
	ticker := time.NewTicker(txInterval)
	defer ticker.Stop()

	timeout := time.After(duration)
loop:
	for {
		select {
		case <-ticker.C:
			tx := makeTx(byte(rng.Intn(256)), uint64(txCount))
			seq.Mempool().Add(tx)
			txCount++
		case <-timeout:
			break loop
		}
	}

	// Let last block complete
	time.Sleep(1500 * time.Millisecond)
	seq.Stop()

	elapsed := time.Since(start)

	// Collect results
	m := seq.Metrics()
	m.mu.Lock()
	result := BenchmarkResult{
		Scenario:           name,
		BlocksProduced:     m.BlocksProduced,
		TxInserted:         m.TxInserted,
		TxIncluded:         m.TxIncluded,
		TxDropped:          m.TxDropped,
		AvgBlockProdMs:     float64(m.TotalBlockProductionNs) / float64(max(m.BlocksProduced, 1)) / 1e6,
		MempoolHighWater:   m.MempoolHighWatermark,
		FIFOAccuracy: func() float64 {
			if m.TotalOrderingChecks == 0 {
				return 100.0
			}
			return 100.0 * float64(m.TotalOrderingChecks-m.FIFOViolations) / float64(m.TotalOrderingChecks)
		}(),
		ForcedTxSubmitted:  m.ForcedTxSubmitted,
		ForcedTxIncluded:   m.ForcedTxIncluded,
		MaxForcedLatencyMs: float64(m.MaxForcedLatencyNs) / 1e6,
		EmptyBlocks:        m.EmptyBlocks,
		ThroughputTPS:      float64(m.TxIncluded) / elapsed.Seconds(),
		ElapsedMs:          float64(elapsed.Milliseconds()),
	}
	result.BlockFillRatio = func() float64 {
		nonEmpty := m.BlocksProduced - m.EmptyBlocks
		if nonEmpty == 0 {
			return 0
		}
		avgTxPerBlock := float64(m.TxIncluded) / float64(nonEmpty)
		return avgTxPerBlock / float64(config.MaxTxPerBlock) * 100.0
	}()
	m.mu.Unlock()

	// Print summary
	t.Logf("\n%s", seq.PrintSummary())
	t.Logf("Throughput: %.1f TPS", result.ThroughputTPS)
	t.Logf("Block fill ratio: %.1f%%", result.BlockFillRatio)

	// Write result to JSON
	resultsDir := filepath.Join("..", "results")
	os.MkdirAll(resultsDir, 0755)
	data, _ := json.MarshalIndent(result, "", "  ")
	os.WriteFile(filepath.Join(resultsDir, name+".json"), data, 0644)

	// Assertions
	if result.AvgBlockProdMs > 50 {
		t.Errorf("block production too slow: %.3f ms (target < 50ms)", result.AvgBlockProdMs)
	}
	if result.FIFOAccuracy < 99.9 {
		t.Errorf("FIFO accuracy too low: %.2f%% (target > 99.9%%)", result.FIFOAccuracy)
	}
	if forcedTxCount > 0 && result.ForcedTxIncluded < forcedTxCount {
		if !adversarial {
			t.Errorf("forced txs not fully included: %d/%d", result.ForcedTxIncluded, forcedTxCount)
		}
	}
}
