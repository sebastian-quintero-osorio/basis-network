package pipeline

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// TestGoRustIPCWitness verifies the Go pipeline can invoke the real Rust
// basis-prover binary for witness generation via stdin/stdout JSON IPC.
func TestGoRustIPCWitness(t *testing.T) {
	binary := findProverBinary(t)

	stages := &ProductionStages{
		WitnessCommand: binary,
		ProverCommand:  binary,
		WitnessTimeout: 30 * time.Second,
		ProverTimeout:  5 * time.Minute,
		Logger:         testLogger(),
	}

	// Create a batch with pre-populated traces (mimicking real EVM execution).
	batch := NewBatchState(1, 100, 1)
	batch.PreStateRoot = "0x0000000000000000000000000000000000000000000000000000000000000001"
	batch.PostStateRoot = "0x0000000000000000000000000000000000000000000000000000000000000002"
	batch.Traces = []ExecutionTraceJSON{
		{
			TxHash:      "0x000000000000000000000000000000000000000000000000000000000000abcd",
			From:        "0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD",
			To:          "0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC",
			Value:       "0x0",
			GasUsed:     21000,
			Success:     true,
			OpcodeCount: 2,
			Entries: []TraceEntryJSON{
				{
					Op:          "BALANCE_CHANGE",
					Account:     "0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD",
					PrevBalance: "0x0de0b6b3a7640000",
					CurrBalance: "0x0",
				},
			},
		},
	}
	batch.HasTrace = true

	ctx := context.Background()

	// Execute should see pre-populated traces and skip synthetic generation.
	if err := stages.Execute(ctx, batch); err != nil {
		t.Fatalf("Execute failed: %v", err)
	}

	// WitnessGen invokes the real Rust binary.
	err := stages.WitnessGen(ctx, batch)
	if err != nil {
		t.Fatalf("WitnessGen failed: %v", err)
	}

	// Verify witness output.
	if batch.WitnessResult == nil {
		t.Fatal("WitnessResult is nil")
	}
	if batch.WitnessResult.TotalRows == 0 {
		t.Error("TotalRows should be > 0")
	}
	if batch.WitnessResult.TotalFieldElems == 0 {
		t.Error("TotalFieldElems should be > 0")
	}
	if batch.WitnessResult.SizeBytes == 0 {
		t.Error("SizeBytes should be > 0")
	}

	t.Logf("Witness result: rows=%d, fields=%d, bytes=%d, time=%dms",
		batch.WitnessResult.TotalRows,
		batch.WitnessResult.TotalFieldElems,
		batch.WitnessResult.SizeBytes,
		batch.WitnessResult.GenerationTimeMs,
	)
}

// TestGoRustIPCProve verifies the full witness+prove pipeline via IPC.
func TestGoRustIPCProve(t *testing.T) {
	binary := findProverBinary(t)

	stages := &ProductionStages{
		WitnessCommand: binary,
		ProverCommand:  binary,
		WitnessTimeout: 30 * time.Second,
		ProverTimeout:  5 * time.Minute,
		Logger:         testLogger(),
	}

	batch := NewBatchState(2, 200, 1)
	batch.PreStateRoot = "0x0000000000000000000000000000000000000000000000000000000000000003"
	batch.PostStateRoot = "0x0000000000000000000000000000000000000000000000000000000000000004"
	batch.Traces = []ExecutionTraceJSON{
		{
			TxHash:      "0x000000000000000000000000000000000000000000000000000000000000beef",
			From:        "0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD",
			To:          "0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC",
			Value:       "0x0",
			GasUsed:     21000,
			Success:     true,
			OpcodeCount: 1,
			Entries: []TraceEntryJSON{
				{
					Op:          "BALANCE_CHANGE",
					Account:     "0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD",
					PrevBalance: "0x1000",
					CurrBalance: "0x0",
				},
			},
		},
	}
	batch.HasTrace = true

	ctx := context.Background()

	// Execute (uses pre-populated traces)
	if err := stages.Execute(ctx, batch); err != nil {
		t.Fatalf("Execute failed: %v", err)
	}

	// WitnessGen
	if err := stages.WitnessGen(ctx, batch); err != nil {
		t.Fatalf("WitnessGen failed: %v", err)
	}

	// Prove
	err := stages.Prove(ctx, batch)
	if err != nil {
		t.Fatalf("Prove failed: %v", err)
	}

	if batch.ProofResult == nil {
		t.Fatal("ProofResult is nil")
	}
	if batch.ProofResult.ConstraintCount == 0 {
		t.Error("ConstraintCount should be > 0")
	}

	t.Logf("Proof result: constraints=%d, proof_size=%d, time=%dms",
		batch.ProofResult.ConstraintCount,
		batch.ProofResult.ProofSizeBytes,
		batch.ProofResult.GenerationTimeMs,
	)
}

// findProverBinary locates the basis-prover binary.
func findProverBinary(t *testing.T) string {
	t.Helper()

	// Try relative path from zkl2/node/pipeline/ to zkl2/prover/target/release/
	candidates := []string{
		"../../prover/target/release/basis-prover",
		filepath.Join("..", "..", "prover", "target", "release", "basis-prover"),
	}

	if runtime.GOOS == "windows" {
		for i, c := range candidates {
			candidates[i] = c + ".exe"
		}
	}

	for _, candidate := range candidates {
		abs, err := filepath.Abs(candidate)
		if err != nil {
			continue
		}
		if _, err := os.Stat(abs); err == nil {
			return abs
		}
	}

	t.Skip("basis-prover binary not found; build with: cd zkl2/prover && cargo build --release")
	return ""
}

func testLogger() *slog.Logger {
	return slog.Default()
}
