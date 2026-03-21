package sync

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

func TestNewSynchronizer(t *testing.T) {
	cfg := DefaultConfig()
	s := New(cfg, nil)

	if s.lastBlock != 0 {
		t.Errorf("expected lastBlock 0, got %d", s.lastBlock)
	}
	if len(s.handlers) != 0 {
		t.Errorf("expected no handlers, got %d", len(s.handlers))
	}
}

func TestDefaultConfig(t *testing.T) {
	cfg := DefaultConfig()
	if cfg.PollInterval != 5*time.Second {
		t.Errorf("expected 5s poll interval, got %v", cfg.PollInterval)
	}
	if cfg.L1RPCURL != "https://rpc.basisnetwork.com.co" {
		t.Errorf("unexpected RPC URL: %s", cfg.L1RPCURL)
	}
}

func TestOnEvent(t *testing.T) {
	s := New(DefaultConfig(), nil)

	var called int32
	s.OnEvent(EventDeposit, func(e L1Event) {
		atomic.AddInt32(&called, 1)
	})
	s.OnEvent(EventDeposit, func(e L1Event) {
		atomic.AddInt32(&called, 1)
	})

	if len(s.handlers[EventDeposit]) != 2 {
		t.Errorf("expected 2 handlers, got %d", len(s.handlers[EventDeposit]))
	}

	// Dispatch manually.
	s.dispatchEvent(L1Event{Type: EventDeposit, BlockNumber: 1, TxHash: common.Hash{}})
	if atomic.LoadInt32(&called) != 2 {
		t.Errorf("expected 2 calls, got %d", atomic.LoadInt32(&called))
	}
}

func TestDispatchEvent_NoHandler(t *testing.T) {
	s := New(DefaultConfig(), nil)

	// Should not panic with no handlers registered.
	s.dispatchEvent(L1Event{Type: EventForcedInclusion, BlockNumber: 1})
}

func TestEventTypeString(t *testing.T) {
	tests := []struct {
		eventType EventType
		expected  string
	}{
		{EventForcedInclusion, "ForcedInclusion"},
		{EventDeposit, "Deposit"},
		{EventDACAttestation, "DACAttestation"},
		{EventEnterpriseRegistered, "EnterpriseRegistered"},
		{EventType(99), "Unknown(99)"},
	}

	for _, tt := range tests {
		if got := tt.eventType.String(); got != tt.expected {
			t.Errorf("EventType(%d).String() = %q, want %q", int(tt.eventType), got, tt.expected)
		}
	}
}

func TestScanNewBlocks(t *testing.T) {
	s := New(DefaultConfig(), nil)

	if s.lastBlock != 0 {
		t.Fatalf("expected initial lastBlock 0, got %d", s.lastBlock)
	}

	// Each scan should increment lastBlock.
	ctx := context.Background()
	for i := 0; i < 5; i++ {
		if err := s.scanNewBlocks(ctx); err != nil {
			t.Fatalf("scan failed: %v", err)
		}
	}

	if s.lastBlock != 5 {
		t.Errorf("expected lastBlock 5 after 5 scans, got %d", s.lastBlock)
	}
}

func TestStartStop(t *testing.T) {
	cfg := DefaultConfig()
	cfg.PollInterval = 10 * time.Millisecond
	s := New(cfg, nil)

	ctx, cancel := context.WithCancel(context.Background())

	if err := s.Start(ctx); err != nil {
		t.Fatalf("start failed: %v", err)
	}

	// Let it scan a few blocks.
	time.Sleep(50 * time.Millisecond)

	cancel()
	s.Stop()

	lastBlock := s.LastBlock()
	if lastBlock == 0 {
		t.Error("expected some blocks scanned after 50ms")
	}
}

func TestTopicHashes(t *testing.T) {
	s := New(DefaultConfig(), nil)

	// Verify topic hashes are non-zero (Keccak of event signatures).
	if s.topicForcedInclusion == (common.Hash{}) {
		t.Error("topicForcedInclusion should be non-zero")
	}
	if s.topicDeposit == (common.Hash{}) {
		t.Error("topicDeposit should be non-zero")
	}
	if s.topicDACAttestation == (common.Hash{}) {
		t.Error("topicDACAttestation should be non-zero")
	}
	if s.topicEnterpriseRegister == (common.Hash{}) {
		t.Error("topicEnterpriseRegister should be non-zero")
	}

	// Verify they are all different.
	topics := []common.Hash{
		s.topicForcedInclusion,
		s.topicDeposit,
		s.topicDACAttestation,
		s.topicEnterpriseRegister,
	}
	for i := 0; i < len(topics); i++ {
		for j := i + 1; j < len(topics); j++ {
			if topics[i] == topics[j] {
				t.Errorf("topic %d and %d are identical", i, j)
			}
		}
	}
}
