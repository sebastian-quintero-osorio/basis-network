// Package-level integration tests for the Basis L2 node.
//
// These tests verify that multiple packages work together correctly,
// covering the interfaces between sequencer, statedb, pipeline, and
// cross-enterprise modules.
//
// [Spec: E2EPipeline.tla -- cross-module interaction]
package node_test

import (
	"context"
	"log/slog"
	"math/big"
	"os"
	"testing"
	"time"

	"basis-network/zkl2/node/pipeline"
	"basis-network/zkl2/node/sequencer"
	"basis-network/zkl2/node/statedb"

	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
)

// testLogger returns a logger for integration tests.
func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
}

// ---------------------------------------------------------------------------
// Sequencer integration tests
// ---------------------------------------------------------------------------

// TestSequencerProducesBlocks verifies the sequencer produces blocks
// with transactions from the mempool.
func TestSequencerProducesBlocks(t *testing.T) {
	cfg := sequencer.DefaultConfig()
	cfg.MempoolCapacity = 100
	seq, err := sequencer.New(cfg, testLogger())
	if err != nil {
		t.Fatalf("failed to create sequencer: %v", err)
	}

	// Add transactions to the mempool.
	for i := 0; i < 5; i++ {
		tx := sequencer.Transaction{
			Hash:     sequencer.ComputeTxHash(sequencer.Address{byte(i)}, uint64(i), nil),
			From:     sequencer.Address{byte(i)},
			To:       sequencer.Address{byte(i + 10)},
			Nonce:    uint64(i),
			GasLimit: 21000,
			Value:    1000,
		}
		seq.Mempool().Add(tx)
	}

	// Produce a block.
	block := seq.ProduceBlock()
	if block == nil {
		t.Fatal("expected non-nil block")
	}
	if len(block.Transactions) != 5 {
		t.Errorf("expected 5 transactions, got %d", len(block.Transactions))
	}

	// Second block should have zero transactions (mempool drained).
	block2 := seq.ProduceBlock()
	if block2 != nil && len(block2.Transactions) > 0 {
		t.Errorf("expected empty second block, got %d transactions", len(block2.Transactions))
	}
}

// ---------------------------------------------------------------------------
// StateDB integration tests
// ---------------------------------------------------------------------------

// TestStateDBAccountLifecycle verifies account creation, balance, and
// state root changes on the Poseidon SMT-based StateDB.
func TestStateDBAccountLifecycle(t *testing.T) {
	cfg := statedb.Config{AccountDepth: 8, StorageDepth: 8}
	db := statedb.NewStateDB(cfg)

	// Create an address key (TreeKey is [32]byte).
	var addr statedb.TreeKey
	addr[31] = 0x01

	// Create the account first (required before SetBalance).
	if err := db.CreateAccount(addr); err != nil {
		t.Fatalf("CreateAccount failed: %v", err)
	}

	// Set balance.
	if err := db.SetBalance(addr, big.NewInt(1000)); err != nil {
		t.Fatalf("SetBalance failed: %v", err)
	}
	bal := db.GetBalance(addr)
	if bal.Cmp(big.NewInt(1000)) != 0 {
		t.Errorf("expected balance 1000, got %s", bal.String())
	}

	// Root should be non-zero after modifications.
	root := db.StateRoot()
	if root.IsZero() {
		t.Error("expected non-zero state root after modifications")
	}

	// Account count.
	if cnt := db.AccountCount(); cnt != 1 {
		t.Errorf("expected 1 account, got %d", cnt)
	}
}

// TestStateDBStorageIsolation verifies that storage operations on one
// account do not affect another account's storage.
func TestStateDBStorageIsolation(t *testing.T) {
	cfg := statedb.Config{AccountDepth: 8, StorageDepth: 8}
	db := statedb.NewStateDB(cfg)

	var addr1, addr2, slot statedb.TreeKey
	addr1[31] = 0x01
	addr2[31] = 0x02
	slot[31] = 0x01

	// Create both accounts first.
	if err := db.CreateAccount(addr1); err != nil {
		t.Fatalf("CreateAccount addr1 failed: %v", err)
	}
	if err := db.CreateAccount(addr2); err != nil {
		t.Fatalf("CreateAccount addr2 failed: %v", err)
	}

	// Set storage value for addr1.
	var value42 fr.Element
	value42.SetUint64(42)
	if err := db.SetStorage(addr1, slot, value42); err != nil {
		t.Fatalf("SetStorage failed: %v", err)
	}

	// addr2 should have zero storage at the same slot.
	val2 := db.GetStorage(addr2, slot)
	if !val2.IsZero() {
		t.Errorf("expected zero storage for addr2, got non-zero")
	}

	// addr1 should still have 42.
	val1 := db.GetStorage(addr1, slot)
	if val1 != value42 {
		t.Errorf("expected 42 for addr1 storage, got different value")
	}
}

// TestStateDBRootConsistency verifies that the state root is deterministic:
// same operations in the same order produce the same root.
//
// [Spec: ConsistencyInvariant -- incremental root == full rebuild root]
func TestStateDBRootConsistency(t *testing.T) {
	cfg := statedb.Config{AccountDepth: 8, StorageDepth: 8}

	// First database.
	db1 := statedb.NewStateDB(cfg)
	var addr1, addr2 statedb.TreeKey
	addr1[31] = 0x01
	addr2[31] = 0x02
	db1.SetBalance(addr1, big.NewInt(100))
	db1.SetBalance(addr2, big.NewInt(200))
	root1 := db1.StateRoot()

	// Second database with same operations.
	db2 := statedb.NewStateDB(cfg)
	db2.SetBalance(addr1, big.NewInt(100))
	db2.SetBalance(addr2, big.NewInt(200))
	root2 := db2.StateRoot()

	if root1 != root2 {
		t.Error("same operations should produce the same state root")
	}
}

// ---------------------------------------------------------------------------
// Pipeline integration tests
// ---------------------------------------------------------------------------

// TestPipelineSimulatedE2E verifies the full pipeline lifecycle using
// simulated stages: pending -> executed -> witnessed -> proved -> submitted -> finalized.
func TestPipelineSimulatedE2E(t *testing.T) {
	cfg := pipeline.DefaultPipelineConfig()
	cfg.MaxConcurrentBatches = 1

	stages := pipeline.DefaultSimulatedStages()
	stages.ExecTimePerTx = 1 * time.Microsecond
	stages.WitnessTimePerTx = 1 * time.Microsecond
	stages.ProofBaseTime = 1 * time.Millisecond
	stages.ProofTimePerTx = 1 * time.Microsecond
	stages.L1SubmitTime = 1 * time.Millisecond

	orch := pipeline.NewOrchestrator(cfg, testLogger(), stages)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Submit a batch.
	batch := pipeline.NewBatchState(1, 1, 10)
	err := orch.ProcessBatch(ctx, batch)
	if err != nil {
		t.Fatalf("pipeline failed: %v", err)
	}

	// Verify the batch reached finalized state.
	if batch.Stage != pipeline.StageFinalized {
		t.Errorf("expected finalized, got %s", batch.Stage)
	}

	// Verify all TLA+ invariants hold.
	if err := pipeline.CheckAllInvariants(batch); err != nil {
		t.Errorf("invariant violation: %v", err)
	}

	// Verify artifacts exist.
	if !batch.HasTrace {
		t.Error("expected HasTrace=true for finalized batch")
	}
	if !batch.HasWitness {
		t.Error("expected HasWitness=true for finalized batch")
	}
	if !batch.HasProof {
		t.Error("expected HasProof=true for finalized batch")
	}
	if !batch.ProofOnL1 {
		t.Error("expected ProofOnL1=true for finalized batch")
	}
}

// TestPipelineConcurrentBatches verifies that multiple batches can be
// processed concurrently without interference.
func TestPipelineConcurrentBatches(t *testing.T) {
	cfg := pipeline.DefaultPipelineConfig()
	cfg.MaxConcurrentBatches = 4

	stages := pipeline.DefaultSimulatedStages()
	stages.ExecTimePerTx = 1 * time.Microsecond
	stages.WitnessTimePerTx = 1 * time.Microsecond
	stages.ProofBaseTime = 1 * time.Millisecond
	stages.ProofTimePerTx = 1 * time.Microsecond
	stages.L1SubmitTime = 1 * time.Millisecond

	orch := pipeline.NewOrchestrator(cfg, testLogger(), stages)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Process 4 batches concurrently.
	const numBatches = 4
	errCh := make(chan error, numBatches)
	batches := make([]*pipeline.BatchState, numBatches)

	for i := 0; i < numBatches; i++ {
		batches[i] = pipeline.NewBatchState(uint64(i+1), uint64(i*10+1), 10)
		go func(b *pipeline.BatchState) {
			errCh <- orch.ProcessBatch(ctx, b)
		}(batches[i])
	}

	for i := 0; i < numBatches; i++ {
		if err := <-errCh; err != nil {
			t.Errorf("batch failed: %v", err)
		}
	}

	// Verify all batches are finalized and invariants hold.
	for i, b := range batches {
		if b.Stage != pipeline.StageFinalized {
			t.Errorf("batch %d: expected finalized, got %s", i+1, b.Stage)
		}
		if err := pipeline.CheckAllInvariants(b); err != nil {
			t.Errorf("batch %d: invariant violation: %v", i+1, err)
		}
	}
}
