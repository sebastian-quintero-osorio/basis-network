package relayer

import (
	"fmt"
	"math/big"
	"testing"
	"time"
)

func TestWithdrawTrie_InsertAndRoot(t *testing.T) {
	trie := NewWithdrawTrie(32)

	// Empty trie should have zero root
	root := trie.Root()
	zeroRoot := make([]byte, 32)
	for i := range zeroRoot {
		if root[i] != zeroRoot[i] {
			t.Fatal("empty trie should have zero root")
		}
	}

	// Insert a leaf
	idx := trie.AppendLeaf(WithdrawTrieEntry{
		Enterprise:      "0x1234",
		Recipient:       "0x5678",
		Amount:          big.NewInt(1e18),
		WithdrawalIndex: 0,
	})

	if idx != 0 {
		t.Fatalf("first leaf index should be 0, got %d", idx)
	}

	root = trie.Root()
	// Root should no longer be zero
	allZero := true
	for _, b := range root {
		if b != 0 {
			allZero = false
			break
		}
	}
	if allZero {
		t.Fatal("root should not be zero after insert")
	}

	if trie.LeafCount() != 1 {
		t.Fatalf("expected 1 leaf, got %d", trie.LeafCount())
	}
}

func TestWithdrawTrie_ProofVerification(t *testing.T) {
	trie := NewWithdrawTrie(32)

	// Insert multiple leaves
	entries := []WithdrawTrieEntry{
		{Enterprise: "0xAAA", Recipient: "0xBBB", Amount: big.NewInt(1e18), WithdrawalIndex: 0},
		{Enterprise: "0xAAA", Recipient: "0xCCC", Amount: big.NewInt(2e18), WithdrawalIndex: 1},
		{Enterprise: "0xAAA", Recipient: "0xDDD", Amount: big.NewInt(3e18), WithdrawalIndex: 2},
		{Enterprise: "0xAAA", Recipient: "0xEEE", Amount: big.NewInt(4e18), WithdrawalIndex: 3},
	}

	for _, e := range entries {
		trie.AppendLeaf(e)
	}

	root := trie.Root()

	// Verify each leaf's proof
	for i := uint64(0); i < uint64(len(entries)); i++ {
		proof, err := trie.GenerateProof(i)
		if err != nil {
			t.Fatalf("failed to generate proof for index %d: %v", i, err)
		}

		// Manually verify: compute root from leaf + proof
		leaf := computeLeafHash(entries[i])
		computed := leaf
		idx := i
		for _, sibling := range proof {
			if idx%2 == 0 {
				computed = hashPair(computed, sibling)
			} else {
				computed = hashPair(sibling, computed)
			}
			idx = idx / 2
		}

		// Compare with trie root
		for j := range root {
			if computed[j] != root[j] {
				t.Fatalf("proof verification failed for index %d: root mismatch at byte %d", i, j)
			}
		}
	}
}

func TestWithdrawTrie_InvalidProofIndex(t *testing.T) {
	trie := NewWithdrawTrie(32)
	trie.AppendLeaf(WithdrawTrieEntry{
		Enterprise: "0xAAA", Recipient: "0xBBB", Amount: big.NewInt(1e18), WithdrawalIndex: 0,
	})

	_, err := trie.GenerateProof(5)
	if err == nil {
		t.Fatal("expected error for out-of-range index")
	}
}

func TestWithdrawTrie_Determinism(t *testing.T) {
	// Build two identical tries, verify roots match
	entries := []WithdrawTrieEntry{
		{Enterprise: "0xAAA", Recipient: "0xBBB", Amount: big.NewInt(100), WithdrawalIndex: 0},
		{Enterprise: "0xAAA", Recipient: "0xCCC", Amount: big.NewInt(200), WithdrawalIndex: 1},
		{Enterprise: "0xAAA", Recipient: "0xDDD", Amount: big.NewInt(300), WithdrawalIndex: 2},
	}

	trie1 := NewWithdrawTrie(32)
	trie2 := NewWithdrawTrie(32)

	for _, e := range entries {
		trie1.AppendLeaf(e)
		trie2.AppendLeaf(e)
	}

	root1 := trie1.Root()
	root2 := trie2.Root()

	for i := range root1 {
		if root1[i] != root2[i] {
			t.Fatalf("determinism violated: roots differ at byte %d", i)
		}
	}
}

func TestRelayer_ProcessDeposit(t *testing.T) {
	r := newTestRelayer()

	err := r.ProcessDeposit(DepositEvent{
		Enterprise:  "0xAAA",
		Depositor:   "0xBBB",
		L2Recipient: "0xCCC",
		Amount:      big.NewInt(1e18),
		DepositID:   0,
		Timestamp:   uint64(time.Now().Unix()),
		L1TxHash:    "0xdeadbeef",
		L1Block:     100,
	})

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	metrics := r.Metrics()
	if metrics.DepositsProcessed != 1 {
		t.Fatalf("expected 1 deposit processed, got %d", metrics.DepositsProcessed)
	}
}

func TestRelayer_ProcessWithdrawal(t *testing.T) {
	r := newTestRelayer()

	err := r.ProcessWithdrawal(WithdrawalEvent{
		Enterprise:      "0xAAA",
		Recipient:       "0xBBB",
		Amount:          big.NewInt(1e18),
		WithdrawalIndex: 0,
		L2Block:         50,
		L2TxHash:        "0xcafebabe",
	})

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	metrics := r.Metrics()
	if metrics.WithdrawalsProcessed != 1 {
		t.Fatalf("expected 1 withdrawal processed, got %d", metrics.WithdrawalsProcessed)
	}
	if metrics.WithdrawTrieLeaves != 1 {
		t.Fatalf("expected 1 trie leaf, got %d", metrics.WithdrawTrieLeaves)
	}
}

func TestRelayer_GetWithdrawalProof(t *testing.T) {
	r := newTestRelayer()

	// Process a withdrawal
	r.ProcessWithdrawal(WithdrawalEvent{
		Enterprise:      "0xAAA",
		Recipient:       "0xBBB",
		Amount:          big.NewInt(1e18),
		WithdrawalIndex: 0,
	})

	root, proof, err := r.GetWithdrawalProof(0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(root) == 0 {
		t.Fatal("root should not be empty")
	}
	if len(proof) == 0 {
		t.Fatal("proof should not be empty")
	}
}

func TestGasEstimates(t *testing.T) {
	estimates := estimateGasCosts()

	expectedOps := map[string]uint64{
		"deposit":              61_500,
		"claimWithdrawal":      82_000,
		"escapeWithdraw":       118_500,
		"activateEscapeHatch":  32_000,
		"submitWithdrawRoot":   52_000,
	}

	for _, est := range estimates {
		expected, ok := expectedOps[est.Operation]
		if !ok {
			t.Fatalf("unexpected operation: %s", est.Operation)
		}
		if est.Gas != expected {
			t.Fatalf("gas mismatch for %s: expected %d, got %d", est.Operation, expected, est.Gas)
		}

		// Verify components sum approximately to total
		var componentSum int64
		for _, gas := range est.Components {
			componentSum += int64(gas)
		}
		// Allow 20% tolerance for rounding
		diff := abs64(componentSum - int64(est.Gas))
		if diff > int64(est.Gas)/5 {
			t.Fatalf("component sum (%d) diverges >20%% from total (%d) for %s",
				componentSum, est.Gas, est.Operation)
		}
	}
}

func TestLatencySimulation(t *testing.T) {
	results := simulateLatencies()

	if len(results) == 0 {
		t.Fatal("expected latency results")
	}

	for _, r := range results {
		if r.TotalLatency <= 0 {
			t.Fatalf("latency should be positive for %s/%s", r.Operation, r.Scenario)
		}
		// All scenarios should meet targets
		if !r.MeetsTarget {
			t.Fatalf("%s/%s failed target: %v > %v",
				r.Operation, r.Scenario, r.TotalLatency, r.TargetLatency)
		}
	}
}

func TestWithdrawTrieBenchmark(t *testing.T) {
	result := benchmarkWithdrawTrie()

	if result.Depth != 32 {
		t.Fatalf("expected depth 32, got %d", result.Depth)
	}
	if result.Iterations != 1000 {
		t.Fatalf("expected 1000 iterations, got %d", result.Iterations)
	}
	if result.InsertTimeAvg <= 0 {
		t.Fatal("insert time should be positive")
	}
	if result.RootTimeAvg <= 0 {
		t.Fatal("root time should be positive")
	}
	if result.ProofTimeAvg <= 0 {
		t.Fatal("proof gen time should be positive")
	}
	if result.ProofSize <= 0 {
		t.Fatal("proof size should be positive")
	}

	t.Logf("WithdrawTrie benchmark:")
	t.Logf("  Insert avg: %v", result.InsertTimeAvg)
	t.Logf("  Root avg: %v", result.RootTimeAvg)
	t.Logf("  Proof gen avg: %v", result.ProofTimeAvg)
	t.Logf("  Proof size: %d bytes", result.ProofSize)
}

func TestFullBenchmarkSuite(t *testing.T) {
	result := RunBenchmarks()

	output := FormatResults(result)
	fmt.Println(output)

	// Verify all latencies meet targets
	for _, lat := range result.LatencyResults {
		if !lat.MeetsTarget {
			t.Fatalf("FAIL: %s/%s: %v > %v",
				lat.Operation, lat.Scenario, lat.TotalLatency, lat.TargetLatency)
		}
	}

	// Verify gas estimates are reasonable (all < 500K)
	for _, est := range result.GasEstimates {
		if est.Gas > 500_000 {
			t.Fatalf("gas too high for %s: %d > 500K", est.Operation, est.Gas)
		}
	}
}

// --- Helpers ---

func newTestRelayer() *Relayer {
	return New(DefaultConfig(), nil)
}

func abs64(x int64) int64 {
	if x < 0 {
		return -x
	}
	return x
}
