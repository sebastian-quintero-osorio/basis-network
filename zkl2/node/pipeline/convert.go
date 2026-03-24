// Package pipeline -- executor-to-JSON type conversion for Go-Rust IPC boundary.
//
// The EVM executor produces ExecutionTrace with go-ethereum types (common.Address,
// common.Hash, *big.Int). The Rust witness generator expects JSON with hex strings.
// This file bridges the two representations.
//
// [Spec: zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/specs/E2EPipeline/E2EPipeline.tla]
package pipeline

import (
	"fmt"
	"math/big"

	"basis-network/zkl2/node/executor"

	"github.com/ethereum/go-ethereum/common"
)

// bigIntToHex converts a *big.Int to a "0x" prefixed hex string.
// Returns "0x0" for nil values.
func bigIntToHex(b *big.Int) string {
	if b == nil {
		return "0x0"
	}
	return fmt.Sprintf("0x%x", b)
}

// hashToHex converts a common.Hash to its hex string representation.
func hashToHex(h common.Hash) string {
	return h.Hex()
}

// addressToHex converts a common.Address to its hex string representation.
func addressToHex(a common.Address) string {
	return a.Hex()
}

// ConvertTraceEntry converts an executor.TraceEntry to the JSON-serializable
// TraceEntryJSON format for the Go-Rust IPC boundary.
func ConvertTraceEntry(e *executor.TraceEntry) TraceEntryJSON {
	return TraceEntryJSON{
		Op:          string(e.Op),
		Account:     addressToHex(e.Account),
		Slot:        hashToHex(e.Slot),
		Value:       hashToHex(e.Value),
		OldValue:    hashToHex(e.OldValue),
		NewValue:    hashToHex(e.NewValue),
		From:        addressToHex(e.From),
		To:          addressToHex(e.To),
		CallValue:   bigIntToHex(e.CallValue),
		PrevBalance: bigIntToHex(e.PrevBalance),
		CurrBalance: bigIntToHex(e.CurrBalance),
		Reason:      e.Reason,
		PrevNonce:   e.PrevNonce,
		CurrNonce:   e.CurrNonce,
	}
}

// ConvertExecutionTrace converts an executor.ExecutionTrace to the JSON-serializable
// ExecutionTraceJSON format for the Go-Rust IPC boundary.
//
// This is the critical type bridge between the Go EVM executor (which uses
// go-ethereum types) and the Rust witness generator (which expects hex strings).
func ConvertExecutionTrace(trace *executor.ExecutionTrace) ExecutionTraceJSON {
	entries := make([]TraceEntryJSON, len(trace.Entries))
	for i := range trace.Entries {
		entries[i] = ConvertTraceEntry(&trace.Entries[i])
	}

	var toStr string
	if trace.To != nil {
		toStr = addressToHex(*trace.To)
	}

	return ExecutionTraceJSON{
		TxHash:      hashToHex(trace.TxHash),
		From:        addressToHex(trace.From),
		To:          toStr,
		Value:       bigIntToHex(trace.Value),
		GasUsed:     trace.GasUsed,
		Success:     trace.Success,
		OpcodeCount: trace.OpcodeCount,
		Entries:     entries,
	}
}

// ConvertExecutionTraces converts a slice of executor.ExecutionTrace to JSON format.
func ConvertExecutionTraces(traces []*executor.ExecutionTrace) []ExecutionTraceJSON {
	result := make([]ExecutionTraceJSON, len(traces))
	for i, t := range traces {
		result[i] = ConvertExecutionTrace(t)
	}
	return result
}
