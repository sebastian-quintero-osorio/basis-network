package relayer

import (
	"log/slog"
	"math/big"
	"os"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
}

func validConfig() Config {
	cfg := DefaultConfig()
	cfg.Enterprise = common.HexToAddress("0x1111111111111111111111111111111111111111")
	return cfg
}

// --- Config validation ---

func TestConfig_Validate_Valid(t *testing.T) {
	cfg := validConfig()
	if err := cfg.Validate(); err != nil {
		t.Errorf("valid config should not return error, got: %v", err)
	}
}

func TestConfig_Validate_MissingEnterprise(t *testing.T) {
	cfg := DefaultConfig()
	// Enterprise is zero address
	if err := cfg.Validate(); err != ErrMissingEnterprise {
		t.Errorf("expected ErrMissingEnterprise, got: %v", err)
	}
}

func TestConfig_Validate_InvalidPollInterval(t *testing.T) {
	cfg := validConfig()
	cfg.L1PollInterval = 0
	if err := cfg.Validate(); err != ErrInvalidPollInterval {
		t.Errorf("expected ErrInvalidPollInterval, got: %v", err)
	}
}

func TestConfig_Validate_InvalidTrieDepth(t *testing.T) {
	cfg := validConfig()
	cfg.TrieDepth = 0
	if err := cfg.Validate(); err != ErrInvalidTrieDepth {
		t.Errorf("expected ErrInvalidTrieDepth, got: %v", err)
	}

	cfg.TrieDepth = 257
	if err := cfg.Validate(); err != ErrInvalidTrieDepth {
		t.Errorf("expected ErrInvalidTrieDepth for 257, got: %v", err)
	}
}

// --- Relayer construction ---

func TestNew_ValidConfig(t *testing.T) {
	r, err := New(validConfig(), testLogger())
	if err != nil {
		t.Fatalf("New() returned error: %v", err)
	}
	if r == nil {
		t.Fatal("New() returned nil relayer")
	}
}

func TestNew_InvalidConfig(t *testing.T) {
	cfg := DefaultConfig() // missing enterprise
	_, err := New(cfg, testLogger())
	if err == nil {
		t.Error("New() with invalid config should return error")
	}
}

func TestNew_NilLogger(t *testing.T) {
	r, err := New(validConfig(), nil)
	if err != nil {
		t.Fatalf("New() with nil logger should not error: %v", err)
	}
	if r == nil {
		t.Fatal("New() returned nil relayer")
	}
}

// --- ProcessDeposit ---

func TestProcessDeposit(t *testing.T) {
	r, _ := New(validConfig(), testLogger())

	deposit := DepositEvent{
		Enterprise:  testEnterprise,
		Depositor:   testRecipient1,
		L2Recipient: testRecipient2,
		Amount:      big.NewInt(1000000000000000000),
		DepositID:   0,
		Timestamp:   1234567890,
		L1TxHash:    common.HexToHash("0xabc"),
		L1Block:     100,
	}

	err := r.ProcessDeposit(deposit)
	if err != nil {
		t.Errorf("ProcessDeposit should not error: %v", err)
	}

	m := r.GetMetrics()
	if m.DepositsProcessed != 1 {
		t.Errorf("expected 1 deposit processed, got %d", m.DepositsProcessed)
	}
}

func TestProcessDeposit_Multiple(t *testing.T) {
	r, _ := New(validConfig(), testLogger())

	for i := 0; i < 5; i++ {
		err := r.ProcessDeposit(DepositEvent{
			Enterprise:  testEnterprise,
			Depositor:   testRecipient1,
			L2Recipient: testRecipient2,
			Amount:      big.NewInt(int64(1000 * (i + 1))),
			DepositID:   uint64(i),
		})
		if err != nil {
			t.Fatalf("ProcessDeposit(%d) error: %v", i, err)
		}
	}

	m := r.GetMetrics()
	if m.DepositsProcessed != 5 {
		t.Errorf("expected 5 deposits processed, got %d", m.DepositsProcessed)
	}
}

// --- ProcessWithdrawal ---

func TestProcessWithdrawal(t *testing.T) {
	r, _ := New(validConfig(), testLogger())

	withdrawal := WithdrawalEvent{
		Enterprise:      testEnterprise,
		Recipient:       testRecipient1,
		Amount:          big.NewInt(500000000000000000),
		WithdrawalIndex: 0,
		L2Block:         50,
	}

	err := r.ProcessWithdrawal(withdrawal)
	if err != nil {
		t.Errorf("ProcessWithdrawal should not error: %v", err)
	}

	m := r.GetMetrics()
	if m.WithdrawalsProcessed != 1 {
		t.Errorf("expected 1 withdrawal processed, got %d", m.WithdrawalsProcessed)
	}
	if m.WithdrawTrieLeaves != 1 {
		t.Errorf("expected 1 trie leaf, got %d", m.WithdrawTrieLeaves)
	}
}

// --- GetWithdrawalProof ---

func TestGetWithdrawalProof(t *testing.T) {
	r, _ := New(validConfig(), testLogger())

	entry := WithdrawTrieEntry{
		Enterprise:      testEnterprise,
		Recipient:       testRecipient1,
		Amount:          big.NewInt(1000000000000000000),
		WithdrawalIndex: 0,
	}

	_ = r.ProcessWithdrawal(WithdrawalEvent{
		Enterprise:      entry.Enterprise,
		Recipient:       entry.Recipient,
		Amount:          entry.Amount,
		WithdrawalIndex: entry.WithdrawalIndex,
	})

	root, proof, err := r.GetWithdrawalProof(0)
	if err != nil {
		t.Fatalf("GetWithdrawalProof error: %v", err)
	}

	if root == (common.Hash{}) {
		t.Error("root should not be zero hash")
	}

	// Verify the proof
	leaf := ComputeLeafHash(entry)
	if !VerifyProof(proof, root, leaf, 0) {
		t.Error("withdrawal proof should verify")
	}
}

func TestGetWithdrawalProof_OutOfRange(t *testing.T) {
	r, _ := New(validConfig(), testLogger())

	_, _, err := r.GetWithdrawalProof(0)
	if err == nil {
		t.Error("GetWithdrawalProof on empty trie should error")
	}
}

// --- Lifecycle ---

func TestStartStop(t *testing.T) {
	r, _ := New(validConfig(), testLogger())

	err := r.Start()
	if err != nil {
		t.Fatalf("Start() error: %v", err)
	}

	r.Stop()
	// Should not panic or hang
}

// --- Metrics ---

func TestGetMetrics_Initial(t *testing.T) {
	r, _ := New(validConfig(), testLogger())

	m := r.GetMetrics()
	if m.DepositsProcessed != 0 || m.WithdrawalsProcessed != 0 ||
		m.WithdrawRootsPosted != 0 || m.ErrorsEncountered != 0 ||
		m.WithdrawTrieLeaves != 0 {
		t.Error("initial metrics should all be zero")
	}
}
