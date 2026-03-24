package sequencer

import (
	"context"
	"fmt"
	"math/big"
	"sync"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

func makeTx(from byte, nonce uint64) Transaction {
	var fromAddr Address
	fromAddr[0] = from
	return Transaction{
		Hash:     ComputeTxHash(fromAddr, nonce, nil),
		From:     fromAddr,
		Nonce:    nonce,
		GasLimit: 21_000,
		Value:    big.NewInt(100),
	}
}

func testConfig() Config {
	return Config{
		BlockInterval:        100 * time.Millisecond,
		BlockGasLimit:        10_000_000,
		MaxTxPerBlock:        500,
		MempoolCapacity:      10_000,
		ForcedDeadlineBlocks: 3,
		DefaultTxGas:         21_000,
	}
}

func testSequencer(t *testing.T) *Sequencer {
	t.Helper()
	seq, err := New(testConfig(), nil)
	if err != nil {
		t.Fatalf("failed to create sequencer: %v", err)
	}
	return seq
}

// collectTxHashes builds a set of tx hashes from a block for invariant checking.
func collectHashes(txs []Transaction) map[TxHash]struct{} {
	m := make(map[TxHash]struct{}, len(txs))
	for i := range txs {
		m[txs[i].Hash] = struct{}{}
	}
	return m
}

// ---------------------------------------------------------------------------
// Unit Tests: Mempool
// ---------------------------------------------------------------------------

func TestMempoolFIFOOrdering(t *testing.T) {
	mp := NewMempool(100, nil)

	for i := 0; i < 50; i++ {
		if err := mp.Add(makeTx(byte(i%10), uint64(i))); err != nil {
			t.Fatalf("add failed: %v", err)
		}
	}

	txs := mp.Drain(50, 50*21_000, 21_000)
	if len(txs) != 50 {
		t.Fatalf("expected 50 txs, got %d", len(txs))
	}

	// [Spec: FIFOWithinBlock -- submitOrder[block[i]] < submitOrder[block[j]] for i < j]
	for i := 1; i < len(txs); i++ {
		if txs[i].SeqNum <= txs[i-1].SeqNum {
			t.Errorf("FIFO violation at index %d: seq %d <= %d", i, txs[i].SeqNum, txs[i-1].SeqNum)
		}
	}
}

func TestMempoolCapacity(t *testing.T) {
	mp := NewMempool(10, nil)

	for i := 0; i < 15; i++ {
		mp.Add(makeTx(byte(i), uint64(i)))
	}

	if mp.Len() != 10 {
		t.Errorf("expected 10 pending, got %d", mp.Len())
	}
}

func TestMempoolGasLimit(t *testing.T) {
	mp := NewMempool(100, nil)

	for i := 0; i < 10; i++ {
		mp.Add(makeTx(byte(i), uint64(i)))
	}

	// Gas limit allows only 5 transactions (5 * 21000 = 105000)
	txs := mp.Drain(100, 5*21_000, 21_000)
	if len(txs) != 5 {
		t.Errorf("expected 5 txs (gas limited), got %d", len(txs))
	}
	if mp.Len() != 5 {
		t.Errorf("expected 5 remaining, got %d", mp.Len())
	}
}

func TestMempoolDrainRemovesFromQueue(t *testing.T) {
	mp := NewMempool(100, nil)

	for i := 0; i < 20; i++ {
		mp.Add(makeTx(byte(i), uint64(i)))
	}

	batch1 := mp.Drain(10, 10*21_000, 21_000)
	batch2 := mp.Drain(10, 10*21_000, 21_000)

	if len(batch1) != 10 || len(batch2) != 10 {
		t.Fatalf("expected 10+10, got %d+%d", len(batch1), len(batch2))
	}

	// [Spec: NoDoubleInclusion -- drained txs cannot appear again]
	seen := make(map[TxHash]struct{})
	for _, tx := range batch1 {
		seen[tx.Hash] = struct{}{}
	}
	for _, tx := range batch2 {
		if _, exists := seen[tx.Hash]; exists {
			t.Errorf("double inclusion: tx %x appeared in both batches", tx.Hash[:8])
		}
	}
}

func TestMempoolDeduplication(t *testing.T) {
	mp := NewMempool(100, nil)

	tx := makeTx(1, 1)
	mp.Add(tx)
	mp.Add(tx) // Same hash, should be ignored

	if mp.Len() != 1 {
		t.Errorf("expected 1 (deduplicated), got %d", mp.Len())
	}
}

func TestMempoolBatchAdd(t *testing.T) {
	mp := NewMempool(5, nil)

	txs := make([]Transaction, 8)
	for i := range txs {
		txs[i] = makeTx(byte(i), uint64(i))
	}

	added, dropped := mp.AddBatch(txs)
	if added != 5 {
		t.Errorf("expected 5 added, got %d", added)
	}
	if dropped != 3 {
		t.Errorf("expected 3 dropped, got %d", dropped)
	}
}

// ---------------------------------------------------------------------------
// Unit Tests: Forced Inclusion Queue
// ---------------------------------------------------------------------------

func TestForcedInclusionFIFO(t *testing.T) {
	fq := NewForcedInclusionQueue(10, nil)

	for i := 0; i < 5; i++ {
		fq.Submit(makeTx(byte(i), uint64(i)), uint64(1000+i), 0)
	}

	if fq.Len() != 5 {
		t.Fatalf("expected 5 queued, got %d", fq.Len())
	}

	// Cooperative drain: should get all 5 in FIFO order
	result := fq.DrainForBlock(0, 10, true)
	if len(result) != 5 {
		t.Fatalf("expected 5 drained, got %d", len(result))
	}

	for i := 1; i < len(result); i++ {
		if result[i].L1BlockNumber <= result[i-1].L1BlockNumber {
			t.Errorf("forced FIFO violation at %d: l1Block %d <= %d",
				i, result[i].L1BlockNumber, result[i-1].L1BlockNumber)
		}
	}
}

func TestForcedInclusionDeadlineNonCooperative(t *testing.T) {
	// Deadline: 3 blocks. Submit at block 0. Expired at block 3.
	fq := NewForcedInclusionQueue(3, nil)

	fq.Submit(makeTx(1, 1), 100, 0) // submitBlock=0, deadline at block 3
	fq.Submit(makeTx(2, 2), 101, 0) // submitBlock=0, deadline at block 3

	// At block 1: non-cooperative drain should return nothing (not expired)
	result := fq.DrainForBlock(1, 10, false)
	if len(result) != 0 {
		t.Errorf("expected 0 before deadline, got %d", len(result))
	}

	// At block 3: deadline hit, must drain both
	result = fq.DrainForBlock(3, 10, false)
	if len(result) != 2 {
		t.Errorf("expected 2 after deadline, got %d", len(result))
	}
}

func TestForcedInclusionMinRequired(t *testing.T) {
	// Test that expired forced txs are included even in non-cooperative mode
	// and that non-expired ones are NOT included.
	fq := NewForcedInclusionQueue(2, nil)

	fq.Submit(makeTx(1, 1), 100, 0) // deadline at block 2
	fq.Submit(makeTx(2, 2), 101, 0) // deadline at block 2
	fq.Submit(makeTx(3, 3), 102, 5) // deadline at block 7 (not expired at block 3)

	// At block 3: first two expired, third not
	result := fq.DrainForBlock(3, 10, false)
	if len(result) != 2 {
		t.Errorf("expected 2 (minRequired), got %d", len(result))
	}

	// Third should still be in queue
	if fq.Len() != 1 {
		t.Errorf("expected 1 remaining, got %d", fq.Len())
	}
}

func TestForcedInclusionHasOverdue(t *testing.T) {
	fq := NewForcedInclusionQueue(3, nil)

	if fq.HasOverdue(0) {
		t.Error("empty queue should not be overdue")
	}

	fq.Submit(makeTx(1, 1), 100, 0)

	if fq.HasOverdue(2) {
		t.Error("should not be overdue at block 2 (deadline=3)")
	}

	if !fq.HasOverdue(3) {
		t.Error("should be overdue at block 3")
	}
}

// ---------------------------------------------------------------------------
// Unit Tests: Block Builder
// ---------------------------------------------------------------------------

func TestBuildBlockEmpty(t *testing.T) {
	cfg := testConfig()
	mp := NewMempool(cfg.MempoolCapacity, nil)
	fq := NewForcedInclusionQueue(cfg.ForcedDeadlineBlocks, nil)
	bb := NewBlockBuilder(cfg, mp, fq, nil)

	block := bb.BuildBlock(0, TxHash{}, true)

	if !block.IsEmpty() {
		t.Error("expected empty block")
	}
	if block.State != BlockSealed {
		t.Errorf("expected sealed state, got %s", block.State)
	}
}

func TestBuildBlockForcedBeforeMempool(t *testing.T) {
	cfg := testConfig()
	mp := NewMempool(cfg.MempoolCapacity, nil)
	fq := NewForcedInclusionQueue(cfg.ForcedDeadlineBlocks, nil)
	bb := NewBlockBuilder(cfg, mp, fq, nil)

	// Add regular transactions
	mempoolHashes := make(map[TxHash]struct{})
	for i := 0; i < 10; i++ {
		tx := makeTx(byte(i), uint64(i))
		mp.Add(tx)
		mempoolHashes[tx.Hash] = struct{}{}
	}

	// Add forced transactions
	forcedHashes := make(map[TxHash]struct{})
	for i := 0; i < 3; i++ {
		tx := makeTx(byte(100+i), uint64(i))
		fq.Submit(tx, uint64(500+i), 0)
		forcedHashes[tx.Hash] = struct{}{}
	}

	block := bb.BuildBlock(0, TxHash{}, true)

	if block.TxCount() != 13 {
		t.Errorf("expected 13 txs, got %d", block.TxCount())
	}

	// [Spec: ForcedBeforeMempool -- forced txs appear before mempool txs]
	if err := ValidateBlockInvariants(block, forcedHashes, mempoolHashes); err != nil {
		t.Errorf("invariant violation: %v", err)
	}

	// Verify first 3 are forced
	for i := 0; i < 3; i++ {
		if _, ok := forcedHashes[block.Transactions[i].Hash]; !ok {
			t.Errorf("transaction at index %d should be forced", i)
		}
	}
	// Verify remaining are mempool
	for i := 3; i < 13; i++ {
		if _, ok := mempoolHashes[block.Transactions[i].Hash]; !ok {
			t.Errorf("transaction at index %d should be mempool", i)
		}
	}
}

func TestBuildBlockGasLimitEnforced(t *testing.T) {
	cfg := testConfig()
	cfg.BlockGasLimit = 3 * 21_000 // Only 3 txs fit
	cfg.MaxTxPerBlock = 100        // Slot limit not the constraint
	mp := NewMempool(cfg.MempoolCapacity, nil)
	fq := NewForcedInclusionQueue(cfg.ForcedDeadlineBlocks, nil)
	bb := NewBlockBuilder(cfg, mp, fq, nil)

	for i := 0; i < 10; i++ {
		mp.Add(makeTx(byte(i), uint64(i)))
	}

	block := bb.BuildBlock(0, TxHash{}, true)
	if block.TxCount() != 3 {
		t.Errorf("expected 3 txs (gas limited), got %d", block.TxCount())
	}
}

func TestBuildBlockMaxTxEnforced(t *testing.T) {
	cfg := testConfig()
	cfg.MaxTxPerBlock = 5
	mp := NewMempool(cfg.MempoolCapacity, nil)
	fq := NewForcedInclusionQueue(cfg.ForcedDeadlineBlocks, nil)
	bb := NewBlockBuilder(cfg, mp, fq, nil)

	for i := 0; i < 20; i++ {
		mp.Add(makeTx(byte(i), uint64(i)))
	}

	block := bb.BuildBlock(0, TxHash{}, true)
	if block.TxCount() != 5 {
		t.Errorf("expected 5 txs (slot limited), got %d", block.TxCount())
	}
}

// ---------------------------------------------------------------------------
// Unit Tests: Sequencer
// ---------------------------------------------------------------------------

func TestSequencerProduceBlock(t *testing.T) {
	seq := testSequencer(t)

	for i := 0; i < 100; i++ {
		seq.Mempool().Add(makeTx(byte(i%10), uint64(i)))
	}

	block := seq.ProduceBlock()

	if block.Number != 0 {
		t.Errorf("expected block 0, got %d", block.Number)
	}
	if block.TxCount() != 100 {
		t.Errorf("expected 100 txs, got %d", block.TxCount())
	}
	if block.State != BlockSealed {
		t.Errorf("expected sealed, got %s", block.State)
	}
}

func TestSequencerBlockNumberAdvances(t *testing.T) {
	seq := testSequencer(t)

	for i := 0; i < 5; i++ {
		block := seq.ProduceBlock()
		if block.Number != uint64(i) {
			t.Errorf("expected block %d, got %d", i, block.Number)
		}
	}

	if seq.BlockNumber() != 5 {
		t.Errorf("expected block number 5, got %d", seq.BlockNumber())
	}
}

func TestSequencerHashChain(t *testing.T) {
	seq := testSequencer(t)

	seq.Mempool().Add(makeTx(1, 1))
	b0 := seq.ProduceBlock()

	seq.Mempool().Add(makeTx(2, 2))
	b1 := seq.ProduceBlock()

	if b1.ParentHash != b0.BlockHash() {
		t.Error("block 1 parent hash should equal block 0 hash")
	}
}

func TestSequencerStartStop(t *testing.T) {
	cfg := testConfig()
	cfg.BlockInterval = 50 * time.Millisecond
	seq, err := New(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}

	// Add some transactions
	for i := 0; i < 20; i++ {
		seq.Mempool().Add(makeTx(byte(i), uint64(i)))
	}

	ctx, cancel := context.WithCancel(context.Background())
	go seq.StartSequencer(ctx)

	// Let it run for a few block intervals
	time.Sleep(250 * time.Millisecond)
	cancel()

	// Wait for shutdown
	time.Sleep(100 * time.Millisecond)

	blocks := seq.Blocks()
	if len(blocks) == 0 {
		t.Error("expected at least one block produced")
	}

	// All included txs should be from our submission
	totalTx := 0
	for _, b := range blocks {
		totalTx += b.TxCount()
	}
	if totalTx > 20 {
		t.Errorf("included more txs (%d) than submitted (20)", totalTx)
	}
}

func TestSequencerSealBlock(t *testing.T) {
	seq := testSequencer(t)
	seq.Mempool().Add(makeTx(1, 1))
	block := seq.SealBlock()
	if block.State != BlockSealed {
		t.Errorf("SealBlock should return sealed block, got %s", block.State)
	}
}

func TestSequencerStats(t *testing.T) {
	seq := testSequencer(t)

	// Produce empty block
	seq.ProduceBlock()

	// Produce block with txs
	for i := 0; i < 10; i++ {
		seq.Mempool().Add(makeTx(byte(i), uint64(i)))
	}
	seq.ProduceBlock()

	stats := seq.Stats()
	if stats.BlocksProduced != 2 {
		t.Errorf("expected 2 blocks, got %d", stats.BlocksProduced)
	}
	if stats.EmptyBlocks != 1 {
		t.Errorf("expected 1 empty block, got %d", stats.EmptyBlocks)
	}
	if stats.TotalTxIncluded != 10 {
		t.Errorf("expected 10 txs, got %d", stats.TotalTxIncluded)
	}
}

func TestSequencerGetBlock(t *testing.T) {
	seq := testSequencer(t)

	seq.ProduceBlock()
	seq.ProduceBlock()

	b := seq.GetBlock(1)
	if b == nil {
		t.Fatal("expected block 1")
	}
	if b.Number != 1 {
		t.Errorf("expected number 1, got %d", b.Number)
	}

	if seq.GetBlock(99) != nil {
		t.Error("expected nil for non-existent block")
	}
}

func TestSequencerInvalidConfig(t *testing.T) {
	cfg := Config{} // All zeros
	_, err := New(cfg, nil)
	if err == nil {
		t.Error("expected error for invalid config")
	}
}

// ---------------------------------------------------------------------------
// TLA+ Invariant Tests
// These tests directly correspond to the verified invariants from the spec.
// ---------------------------------------------------------------------------

// TestInvariant_NoDoubleInclusion verifies that no transaction appears in
// more than one block.
// [Spec: NoDoubleInclusion == \A i, j \in 1..Len(blocks) : i /= j => Range(blocks[i]) \cap Range(blocks[j]) = {}]
func TestInvariant_NoDoubleInclusion(t *testing.T) {
	seq := testSequencer(t)

	for i := 0; i < 50; i++ {
		seq.Mempool().Add(makeTx(byte(i%10), uint64(i)))
	}

	cfg := testConfig()
	cfg.MaxTxPerBlock = 10
	seq2, _ := New(cfg, nil)
	for i := 0; i < 50; i++ {
		seq2.Mempool().Add(makeTx(byte(i%10), uint64(i)))
	}

	// Produce multiple blocks
	for i := 0; i < 10; i++ {
		seq2.ProduceBlock()
	}

	// Check no tx appears in more than one block
	seen := make(map[TxHash]uint64) // hash -> block number
	for _, block := range seq2.Blocks() {
		for _, tx := range block.Transactions {
			if prevBlock, exists := seen[tx.Hash]; exists {
				t.Errorf("NoDoubleInclusion violated: tx %x in blocks %d and %d",
					tx.Hash[:8], prevBlock, block.Number)
			}
			seen[tx.Hash] = block.Number
		}
	}
}

// TestInvariant_ForcedInclusionDeadline verifies that forced txs submitted
// at block B are included by block B + ForcedDeadlineBlocks.
// [Spec: ForcedInclusionDeadline == \A ftx \in forcedSubmitted :
//
//	blockNum > forcedSubmitBlock[ftx] + ForcedDeadlineBlocks => ftx \in included]
func TestInvariant_ForcedInclusionDeadline(t *testing.T) {
	cfg := testConfig()
	cfg.ForcedDeadlineBlocks = 2
	cfg.MaxTxPerBlock = 5
	seq, _ := New(cfg, nil)

	// Submit forced txs at block 0
	forcedHashes := make(map[TxHash]struct{})
	for i := 0; i < 3; i++ {
		tx := makeTx(byte(200+i), uint64(i))
		seq.ForcedQueue().Submit(tx, uint64(1000+i), 0)
		forcedHashes[tx.Hash] = struct{}{}
	}

	// Fill mempool with regular txs
	for i := 0; i < 50; i++ {
		seq.Mempool().Add(makeTx(byte(i%10), uint64(100+i)))
	}

	// Produce blocks past the deadline (deadline=2, so at block 2+ they must be included)
	for i := 0; i < 5; i++ {
		seq.ProduceBlock()
	}

	// All forced txs must be included
	included := make(map[TxHash]struct{})
	for _, block := range seq.Blocks() {
		for _, tx := range block.Transactions {
			included[tx.Hash] = struct{}{}
		}
	}

	for h := range forcedHashes {
		if _, ok := included[h]; !ok {
			t.Errorf("ForcedInclusionDeadline violated: forced tx %x not included after deadline", h[:8])
		}
	}
}

// TestInvariant_IncludedWereSubmitted verifies that only submitted transactions
// appear in blocks.
// [Spec: IncludedWereSubmitted == included \subseteq (submitted \union forcedSubmitted)]
func TestInvariant_IncludedWereSubmitted(t *testing.T) {
	seq := testSequencer(t)

	submittedHashes := make(map[TxHash]struct{})
	for i := 0; i < 20; i++ {
		tx := makeTx(byte(i), uint64(i))
		seq.Mempool().Add(tx)
		submittedHashes[tx.Hash] = struct{}{}
	}

	forcedHashes := make(map[TxHash]struct{})
	for i := 0; i < 3; i++ {
		tx := makeTx(byte(100+i), uint64(i))
		seq.ForcedQueue().Submit(tx, uint64(500+i), 0)
		forcedHashes[tx.Hash] = struct{}{}
	}

	seq.ProduceBlock()

	for _, block := range seq.Blocks() {
		for _, tx := range block.Transactions {
			_, inMempool := submittedHashes[tx.Hash]
			_, inForced := forcedHashes[tx.Hash]
			if !inMempool && !inForced {
				t.Errorf("IncludedWereSubmitted violated: tx %x not in any source", tx.Hash[:8])
			}
		}
	}
}

// TestInvariant_ForcedBeforeMempool verifies that forced txs always precede
// mempool txs within each block.
// [Spec: ForcedBeforeMempool == ~ \E i, j : i < j /\ block[i] \in Txs /\ block[j] \in ForcedTxs]
func TestInvariant_ForcedBeforeMempool(t *testing.T) {
	seq := testSequencer(t)

	// Add mempool txs first
	mempoolHashes := make(map[TxHash]struct{})
	for i := 0; i < 10; i++ {
		tx := makeTx(byte(i), uint64(i))
		seq.Mempool().Add(tx)
		mempoolHashes[tx.Hash] = struct{}{}
	}

	// Add forced txs
	forcedHashes := make(map[TxHash]struct{})
	for i := 0; i < 5; i++ {
		tx := makeTx(byte(100+i), uint64(i))
		seq.ForcedQueue().Submit(tx, uint64(500+i), 0)
		forcedHashes[tx.Hash] = struct{}{}
	}

	block := seq.ProduceBlock()

	if err := ValidateBlockInvariants(block, forcedHashes, mempoolHashes); err != nil {
		t.Errorf("invariant violation: %v", err)
	}
}

// TestInvariant_FIFOWithinBlock verifies FIFO ordering within each category.
// [Spec: FIFOWithinBlock -- submitOrder[block[i]] < submitOrder[block[j]] for same category]
func TestInvariant_FIFOWithinBlock(t *testing.T) {
	seq := testSequencer(t)

	for i := 0; i < 100; i++ {
		seq.Mempool().Add(makeTx(byte(i%50), uint64(i)))
	}

	block := seq.ProduceBlock()

	// Verify strict FIFO by SeqNum
	for i := 1; i < len(block.Transactions); i++ {
		if block.Transactions[i].SeqNum <= block.Transactions[i-1].SeqNum {
			t.Errorf("FIFOWithinBlock violated at index %d: seq %d <= %d",
				i, block.Transactions[i].SeqNum, block.Transactions[i-1].SeqNum)
		}
	}
}

// ---------------------------------------------------------------------------
// Adversarial Tests
// ---------------------------------------------------------------------------

// TestAdversarial_CensoringSequencerForcedDeadline tests that even a
// non-cooperative (censoring) sequencer must include forced txs after deadline.
func TestAdversarial_CensoringSequencerForcedDeadline(t *testing.T) {
	cfg := testConfig()
	cfg.ForcedDeadlineBlocks = 2
	cfg.MaxTxPerBlock = 500
	seq, _ := New(cfg, nil)

	// Submit forced txs at block 0
	forcedHashes := make(map[TxHash]struct{})
	for i := 0; i < 5; i++ {
		tx := makeTx(byte(200+i), uint64(i))
		seq.ForcedQueue().Submit(tx, uint64(1000+i), 0)
		forcedHashes[tx.Hash] = struct{}{}
	}

	// Produce blocks using non-cooperative builder
	fq := seq.ForcedQueue()
	mp := seq.Mempool()
	builder := NewBlockBuilder(cfg, mp, fq, nil)

	// Block 0, 1: non-cooperative, forced txs not expired yet
	b0 := builder.BuildBlock(0, TxHash{}, false)
	b1 := builder.BuildBlock(1, b0.BlockHash(), false)

	if b0.TxCount() != 0 {
		t.Errorf("block 0 should be empty (non-cooperative, not expired), got %d", b0.TxCount())
	}
	if b1.TxCount() != 0 {
		t.Errorf("block 1 should be empty (non-cooperative, not expired), got %d", b1.TxCount())
	}

	// Block 2: deadline hit, MUST include forced txs
	b2 := builder.BuildBlock(2, b1.BlockHash(), false)
	if b2.TxCount() != 5 {
		t.Errorf("block 2 should include all 5 forced txs (deadline), got %d", b2.TxCount())
	}

	// Verify all forced txs are included
	for _, tx := range b2.Transactions {
		if _, ok := forcedHashes[tx.Hash]; !ok {
			t.Errorf("unexpected tx in block 2: %x", tx.Hash[:8])
		}
	}
}

// TestAdversarial_NoDoubleInclusionAcrossBlocks tests that draining from
// queues prevents the same tx from appearing in multiple blocks.
func TestAdversarial_NoDoubleInclusionAcrossBlocks(t *testing.T) {
	cfg := testConfig()
	cfg.MaxTxPerBlock = 5
	seq, _ := New(cfg, nil)

	for i := 0; i < 30; i++ {
		seq.Mempool().Add(makeTx(byte(i), uint64(i)))
	}

	// Produce 6 blocks to drain all 30 txs
	for i := 0; i < 8; i++ {
		seq.ProduceBlock()
	}

	// Global deduplication check
	globalSeen := make(map[TxHash]uint64)
	for _, block := range seq.Blocks() {
		for _, tx := range block.Transactions {
			if prevBlock, exists := globalSeen[tx.Hash]; exists {
				t.Errorf("double inclusion: tx %x in blocks %d and %d",
					tx.Hash[:8], prevBlock, block.Number)
			}
			globalSeen[tx.Hash] = block.Number
		}
	}

	// Should have included exactly 30 unique txs
	if len(globalSeen) != 30 {
		t.Errorf("expected 30 unique txs, got %d", len(globalSeen))
	}
}

// TestAdversarial_ForcedQueueFIFOCannotSkip verifies that the FIFO constraint
// on the forced queue prevents selective censorship.
func TestAdversarial_ForcedQueueFIFOCannotSkip(t *testing.T) {
	fq := NewForcedInclusionQueue(5, nil)

	// Submit 3 forced txs: A at block 0, B at block 0, C at block 3
	txA := makeTx(1, 1)
	txB := makeTx(2, 2)
	txC := makeTx(3, 3)

	fq.Submit(txA, 100, 0) // deadline block 5
	fq.Submit(txB, 101, 0) // deadline block 5
	fq.Submit(txC, 102, 3) // deadline block 8

	// At block 6: A and B expired, C not expired.
	// Non-cooperative: should drain A and B only (FIFO stops at C).
	result := fq.DrainForBlock(6, 10, false)
	if len(result) != 2 {
		t.Errorf("expected 2 (A and B expired), got %d", len(result))
	}
	if result[0].Tx.Hash != txA.Hash {
		t.Error("first drained should be A")
	}
	if result[1].Tx.Hash != txB.Hash {
		t.Error("second drained should be B")
	}

	// C remains
	if fq.Len() != 1 {
		t.Errorf("expected 1 remaining (C), got %d", fq.Len())
	}
}

// TestAdversarial_MempoolFloodDoesNotBreakFIFO tests that flooding the mempool
// does not cause FIFO ordering violations.
func TestAdversarial_MempoolFloodDoesNotBreakFIFO(t *testing.T) {
	cfg := testConfig()
	cfg.MempoolCapacity = 100
	cfg.MaxTxPerBlock = 20
	seq, _ := New(cfg, nil)

	// Flood: submit 200 txs (100 will be accepted, 100 dropped)
	for i := 0; i < 200; i++ {
		seq.Mempool().Add(makeTx(byte(i%256), uint64(i)))
	}

	// Produce blocks to drain
	for i := 0; i < 10; i++ {
		seq.ProduceBlock()
	}

	// Check FIFO across all blocks
	var lastSeq uint64
	for _, block := range seq.Blocks() {
		for _, tx := range block.Transactions {
			if tx.SeqNum <= lastSeq && tx.SeqNum != 0 {
				t.Errorf("cross-block FIFO violation: seq %d <= %d", tx.SeqNum, lastSeq)
			}
			lastSeq = tx.SeqNum
		}
	}
}

// TestAdversarial_ConcurrentInsertAndProduce tests thread safety under
// concurrent mempool insertion and block production.
func TestAdversarial_ConcurrentInsertAndProduce(t *testing.T) {
	cfg := testConfig()
	cfg.BlockInterval = 10 * time.Millisecond
	cfg.MaxTxPerBlock = 50
	seq, _ := New(cfg, nil)

	ctx, cancel := context.WithCancel(context.Background())
	go seq.StartSequencer(ctx)

	// 4 goroutines inserting concurrently
	var wg sync.WaitGroup
	const goroutines = 4
	const txPerGoroutine = 500

	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func(gid int) {
			defer wg.Done()
			for i := 0; i < txPerGoroutine; i++ {
				tx := makeTx(byte(gid), uint64(gid*txPerGoroutine+i))
				seq.Mempool().Add(tx)
			}
		}(g)
	}

	wg.Wait()
	time.Sleep(200 * time.Millisecond)
	cancel()
	time.Sleep(50 * time.Millisecond)

	// No panics = thread safety holds. Check no double inclusion.
	globalSeen := make(map[TxHash]struct{})
	for _, block := range seq.Blocks() {
		for _, tx := range block.Transactions {
			if _, exists := globalSeen[tx.Hash]; exists {
				t.Errorf("concurrent double inclusion: tx %x", tx.Hash[:8])
			}
			globalSeen[tx.Hash] = struct{}{}
		}
	}

	stats := seq.Stats()
	t.Logf("concurrent test: %d blocks, %d txs included, %d pending",
		stats.BlocksProduced, stats.TotalTxIncluded, stats.MempoolPending)
}

// TestAdversarial_ForcedTxExceedsBlockGas tests behavior when forced txs
// alone exceed the block gas limit.
func TestAdversarial_ForcedTxExceedsBlockGas(t *testing.T) {
	cfg := testConfig()
	cfg.BlockGasLimit = 3 * 21_000 // Only 3 txs fit
	cfg.ForcedDeadlineBlocks = 1
	seq, _ := New(cfg, nil)

	// Submit 5 forced txs -- only 3 can fit in one block
	for i := 0; i < 5; i++ {
		tx := makeTx(byte(200+i), uint64(i))
		seq.ForcedQueue().Submit(tx, uint64(1000+i), 0)
	}

	// Add mempool txs -- these should NOT appear (no gas left)
	for i := 0; i < 10; i++ {
		seq.Mempool().Add(makeTx(byte(i), uint64(i)))
	}

	// First block: forced txs fill the gas limit
	b0 := seq.ProduceBlock()
	if b0.TxCount() != 3 {
		t.Errorf("expected 3 forced txs (gas limited), got %d", b0.TxCount())
	}

	// Second block: remaining forced txs
	b1 := seq.ProduceBlock()
	if b1.TxCount() < 2 {
		t.Errorf("expected at least 2 remaining forced txs, got %d", b1.TxCount())
	}
}

// TestAdversarial_EmptyBlockChain verifies that empty blocks still advance
// the block number and maintain the hash chain.
func TestAdversarial_EmptyBlockChain(t *testing.T) {
	seq := testSequencer(t)

	for i := 0; i < 5; i++ {
		seq.ProduceBlock()
	}

	blocks := seq.Blocks()
	if len(blocks) != 5 {
		t.Fatalf("expected 5 blocks, got %d", len(blocks))
	}

	for i := 1; i < len(blocks); i++ {
		if blocks[i].ParentHash != blocks[i-1].BlockHash() {
			t.Errorf("hash chain broken at block %d", i)
		}
		if blocks[i].Number != uint64(i) {
			t.Errorf("block number wrong: expected %d, got %d", i, blocks[i].Number)
		}
	}
}

// TestAdversarial_BlockStateTransitions verifies the block lifecycle.
func TestAdversarial_BlockStateTransitions(t *testing.T) {
	tests := []struct {
		state BlockState
		str   string
	}{
		{BlockPending, "pending"},
		{BlockSealed, "sealed"},
		{BlockCommitted, "committed"},
		{BlockProved, "proved"},
		{BlockFinalized, "finalized"},
		{BlockState(99), "unknown(99)"},
	}

	for _, tt := range tests {
		if tt.state.String() != tt.str {
			t.Errorf("BlockState(%d).String() = %q, want %q", tt.state, tt.state.String(), tt.str)
		}
	}
}

// ---------------------------------------------------------------------------
// Benchmarks
// ---------------------------------------------------------------------------

func BenchmarkMempoolInsert(b *testing.B) {
	mp := NewMempool(b.N+1, nil)
	tx := makeTx(1, 0)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		tx.Nonce = uint64(i)
		tx.Hash = ComputeTxHash(tx.From, tx.Nonce, nil)
		mp.Add(tx)
	}
}

func BenchmarkMempoolDrain(b *testing.B) {
	mp := NewMempool(10000, nil)
	for i := 0; i < 10000; i++ {
		mp.Add(makeTx(byte(i%256), uint64(i)))
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		mp.Drain(500, 10_000_000, 21_000)
		b.StopTimer()
		for j := 0; j < 500; j++ {
			mp.Add(makeTx(byte(j%256), uint64(b.N*500+i*500+j)))
		}
		b.StartTimer()
	}
}

func BenchmarkBlockProduction(b *testing.B) {
	for _, txCount := range []int{10, 100, 500, 1000} {
		b.Run(
			func() string { return fmt.Sprintf("tx_%d", txCount) }(),
			func(b *testing.B) {
				for i := 0; i < b.N; i++ {
					b.StopTimer()
					seq, _ := New(DefaultConfig(), nil)
					for j := 0; j < txCount; j++ {
						seq.Mempool().Add(makeTx(byte(j%256), uint64(j)))
					}
					b.StartTimer()
					seq.ProduceBlock()
				}
			},
		)
	}
}
