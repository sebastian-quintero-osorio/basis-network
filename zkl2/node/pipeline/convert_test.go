package pipeline

import (
	"math/big"
	"testing"

	"basis-network/zkl2/node/executor"

	"github.com/ethereum/go-ethereum/common"
)

func TestConvertExecutionTrace(t *testing.T) {
	to := common.HexToAddress("0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC")
	trace := &executor.ExecutionTrace{
		TxHash:      common.HexToHash("0xabcdef1234567890"),
		From:        common.HexToAddress("0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD"),
		To:          &to,
		Value:       big.NewInt(1000000),
		GasUsed:     21000,
		Success:     true,
		OpcodeCount: 42,
		Entries: []executor.TraceEntry{
			{
				Op:          executor.TraceOpBalanceChange,
				Account:     common.HexToAddress("0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD"),
				PrevBalance: big.NewInt(1000000000),
				CurrBalance: big.NewInt(999000000),
			},
			{
				Op:      executor.TraceOpSSTORE,
				Account: common.HexToAddress("0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC"),
				Slot:    common.HexToHash("0x01"),
				OldValue: common.HexToHash("0x00"),
				NewValue: common.HexToHash("0xff"),
			},
		},
	}

	result := ConvertExecutionTrace(trace)

	// Verify top-level fields
	if result.GasUsed != 21000 {
		t.Errorf("GasUsed = %d, want 21000", result.GasUsed)
	}
	if !result.Success {
		t.Error("Success should be true")
	}
	if result.OpcodeCount != 42 {
		t.Errorf("OpcodeCount = %d, want 42", result.OpcodeCount)
	}
	if result.Value != "0xf4240" {
		t.Errorf("Value = %s, want 0xf4240", result.Value)
	}

	// Verify entries converted
	if len(result.Entries) != 2 {
		t.Fatalf("Entries count = %d, want 2", len(result.Entries))
	}

	entry0 := result.Entries[0]
	if entry0.Op != "BALANCE_CHANGE" {
		t.Errorf("Entry[0].Op = %s, want BALANCE_CHANGE", entry0.Op)
	}
	if entry0.PrevBalance != "0x3b9aca00" {
		t.Errorf("Entry[0].PrevBalance = %s, want 0x3b9aca00", entry0.PrevBalance)
	}

	entry1 := result.Entries[1]
	if entry1.Op != "SSTORE" {
		t.Errorf("Entry[1].Op = %s, want SSTORE", entry1.Op)
	}
}

func TestConvertExecutionTraceNilTo(t *testing.T) {
	trace := &executor.ExecutionTrace{
		TxHash:      common.HexToHash("0x01"),
		From:        common.HexToAddress("0x01"),
		To:          nil, // Contract creation
		Value:       big.NewInt(0),
		GasUsed:     50000,
		Success:     true,
		OpcodeCount: 10,
		Entries:     nil,
	}

	result := ConvertExecutionTrace(trace)

	if result.To != "" {
		t.Errorf("To = %s, want empty string for contract creation", result.To)
	}
	if len(result.Entries) != 0 {
		t.Errorf("Entries count = %d, want 0", len(result.Entries))
	}
}

func TestBigIntToHexNil(t *testing.T) {
	if got := bigIntToHex(nil); got != "0x0" {
		t.Errorf("bigIntToHex(nil) = %s, want 0x0", got)
	}
}

func TestConvertExecutionTraces(t *testing.T) {
	traces := []*executor.ExecutionTrace{
		{TxHash: common.HexToHash("0x01"), Value: big.NewInt(0), Entries: nil},
		{TxHash: common.HexToHash("0x02"), Value: big.NewInt(0), Entries: nil},
	}

	result := ConvertExecutionTraces(traces)
	if len(result) != 2 {
		t.Fatalf("ConvertExecutionTraces returned %d, want 2", len(result))
	}
}
