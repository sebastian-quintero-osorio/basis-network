package executor

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/vm"
)

// ZKTracer captures EVM execution traces optimized for ZK witness generation.
// It implements go-ethereum's core/tracing hooks to record state-modifying operations
// (SLOAD, SSTORE, CALL) that the downstream Rust ZK prover needs for proof construction.
//
// The tracer maintains a single ordered sequence of TraceEntry values, preserving
// execution order. This ordering is critical: the TraceCompleteness invariant requires
// a bijection between state-modifying opcodes in the program and entries in the trace.
//
// [Spec: trace variable in EvmExecutor.tla -- accumulates TraceEntrySet entries]
// [Source: 0-input/code/main.go -- ZKTracer struct and hook implementations]
type ZKTracer struct {
	trace      *ExecutionTrace
	stateDB    vm.StateDB // Read-only access for SLOAD value lookup
	captureOps bool       // Whether to capture individual opcode entries (high overhead)
}

// NewZKTracer creates a new tracer instance.
//
// stateDB provides read access to the current state during execution. The tracer
// calls GetState to resolve storage values during SLOAD (the OnOpcode hook fires
// before the opcode executes, so the value must be looked up from state).
//
// If captureOps is true, every opcode execution is logged in OpcodeLog. This
// provides detailed diagnostic data but incurs significant overhead (10-50x
// slowdown based on Geth structLogger benchmarks). Use false for production.
func NewZKTracer(stateDB vm.StateDB, captureOps bool) *ZKTracer {
	return &ZKTracer{
		trace: &ExecutionTrace{
			Entries:   make([]TraceEntry, 0, 64),
			OpcodeLog: make([]OpcodeEntry, 0),
			Logs:      make([]*types.Log, 0),
		},
		stateDB:    stateDB,
		captureOps: captureOps,
	}
}

// Hooks returns the tracing.Hooks struct consumed by go-ethereum's EVM.
// Wire this into vm.Config.Tracer before creating the EVM instance.
//
// [Source: 0-input/code/main.go, lines 109-155 -- Hooks() method]
func (t *ZKTracer) Hooks() *tracing.Hooks {
	return &tracing.Hooks{
		OnOpcode:        t.onOpcode,
		OnStorageChange: t.onStorageChange,
		OnBalanceChange: t.onBalanceChange,
		OnNonceChange:   t.onNonceChange,
		OnLog:           t.onLog,
	}
}

// onOpcode is called before each opcode executes. It captures:
//   - SLOAD: reads the storage slot from the stack and looks up the current value
//     via stateDB.GetState. Generates a TraceOpSLOAD entry.
//   - CALL/CALLCODE: reads the target address and value from the stack.
//     Generates a TraceOpCALL entry.
//   - All opcodes: increments OpcodeCount and optionally logs to OpcodeLog.
//
// The OnOpcode hook fires BEFORE the opcode modifies state. For SLOAD, the slot
// key is on top of the stack; the value is read from stateDB which already reflects
// any preceding SSTORE operations in this transaction.
//
// [Spec: ExecSload -- generates TraceEntry{op: "SLOAD", account, slot, value}]
// [Spec: ExecCall -- generates TraceEntry{op: "CALL", from, to, value}]
func (t *ZKTracer) onOpcode(pc uint64, op byte, gas, cost uint64, scope tracing.OpContext, rData []byte, depth int, err error) {
	t.trace.OpcodeCount++

	opCode := vm.OpCode(op)
	stack := scope.StackData()
	n := len(stack)

	// Capture SLOAD: read storage key from stack top, look up current value.
	// [Spec: ExecSload action in EvmExecutor.tla]
	// SLOAD pops 1 value (the slot key) and pushes the storage value.
	// At OnOpcode time, the slot key is still on the stack (not yet popped).
	if opCode == vm.SLOAD && n >= 1 {
		slotBytes := stack[n-1].Bytes32()
		slot := common.Hash(slotBytes)
		account := scope.Address()
		value := t.stateDB.GetState(account, slot)
		t.trace.Entries = append(t.trace.Entries, TraceEntry{
			Op:      TraceOpSLOAD,
			Account: account,
			Slot:    slot,
			Value:   value,
		})
	}

	// Capture CALL/CALLCODE: extract target address and value from stack.
	// [Spec: ExecCall action in EvmExecutor.tla]
	// CALL stack layout (top to bottom): gas, to, value, inOff, inSize, outOff, outSize
	// CALLCODE has the same layout.
	if (opCode == vm.CALL || opCode == vm.CALLCODE) && n >= 3 {
		toBytes := stack[n-2].Bytes32()
		to := common.BytesToAddress(toBytes[12:])
		callValue := stack[n-3].ToBig()
		t.trace.Entries = append(t.trace.Entries, TraceEntry{
			Op:        TraceOpCALL,
			From:      scope.Address(),
			To:        to,
			CallValue: new(big.Int).Set(callValue),
		})
	}

	// Optionally capture full opcode execution log.
	if t.captureOps {
		entry := OpcodeEntry{
			PC:        pc,
			Op:        opCode.String(),
			Gas:       gas,
			GasCost:   cost,
			Depth:     depth,
			StackSize: n,
		}
		// Annotate state-modifying opcodes with storage key/value.
		if opCode == vm.SLOAD && n >= 1 {
			slotBytes := stack[n-1].Bytes32()
			slot := common.Hash(slotBytes)
			entry.StorageKey = &slot
			value := t.stateDB.GetState(scope.Address(), slot)
			entry.StorageValue = &value
		}
		if opCode == vm.SSTORE && n >= 2 {
			slotBytes := stack[n-1].Bytes32()
			slot := common.Hash(slotBytes)
			entry.StorageKey = &slot
			valueBytes := stack[n-2].Bytes32()
			value := common.Hash(valueBytes)
			entry.StorageValue = &value
		}
		t.trace.OpcodeLog = append(t.trace.OpcodeLog, entry)
	}
}

// onStorageChange is called after an SSTORE modifies a storage slot.
// Records the account, slot, previous value, and new value.
//
// The OnStorageChange hook fires AFTER the SSTORE executes, so both old and new
// values are available. The ZK prover needs both to construct a Poseidon SMT
// update proof (proving the transition from oldValue to newValue at the given slot).
//
// [Spec: ExecSstore -- generates TraceEntry{op: "SSTORE", account, slot, oldValue, newValue}]
// [Source: 0-input/code/main.go, lines 122-127 -- OnStorageChange hook]
func (t *ZKTracer) onStorageChange(addr common.Address, slot common.Hash, prev, current common.Hash) {
	t.trace.Entries = append(t.trace.Entries, TraceEntry{
		Op:       TraceOpSSTORE,
		Account:  addr,
		Slot:     slot,
		OldValue: prev,
		NewValue: current,
	})
}

// onBalanceChange is called when an account's balance changes.
// Records the account address, previous balance, new balance, and reason.
//
// Balance changes are not directly modeled in the TLA+ specification but are
// essential for complete witness generation. The prover needs balance change
// proofs for value transfers, gas payments, and refunds.
//
// Note: The parameter types match go-ethereum v1.14.x tracing.BalanceChangeHook.
// If the go-ethereum version uses *uint256.Int instead of *big.Int, adjust
// the signature and convert via .ToBig().
//
// [Source: 0-input/code/main.go, lines 129-135 -- OnBalanceChange hook]
func (t *ZKTracer) onBalanceChange(addr common.Address, prev, current *big.Int, reason tracing.BalanceChangeReason) {
	t.trace.Entries = append(t.trace.Entries, TraceEntry{
		Op:          TraceOpBalanceChange,
		Account:     addr,
		PrevBalance: new(big.Int).Set(prev),
		CurrBalance: new(big.Int).Set(current),
		Reason:      reason.String(),
	})
}

// onNonceChange is called when an account's nonce changes.
// Records the account address, previous nonce, and new nonce.
func (t *ZKTracer) onNonceChange(addr common.Address, prev, current uint64) {
	t.trace.Entries = append(t.trace.Entries, TraceEntry{
		Op:        TraceOpNonceChange,
		Account:   addr,
		PrevNonce: prev,
		CurrNonce: current,
	})
}

// onLog is called when an EVM LOG opcode emits an event.
// Event logs are captured for L1 event bridging (cross-layer communication).
func (t *ZKTracer) onLog(log *types.Log) {
	t.trace.Logs = append(t.trace.Logs, log)
}

// GetTrace returns the collected execution trace.
// The returned trace is a snapshot; subsequent tracer operations may modify it.
// Call Reset() before reusing the tracer for another transaction.
func (t *ZKTracer) GetTrace() *ExecutionTrace {
	return t.trace
}

// Reset clears the tracer for reuse with a new transaction.
// Preserves the stateDB reference and captureOps setting.
func (t *ZKTracer) Reset() {
	t.trace = &ExecutionTrace{
		Entries:   make([]TraceEntry, 0, 64),
		OpcodeLog: make([]OpcodeEntry, 0),
		Logs:      make([]*types.Log, 0),
	}
}

// SetStateDB updates the stateDB reference for the tracer.
// Call this when the underlying state changes between transactions.
func (t *ZKTracer) SetStateDB(stateDB vm.StateDB) {
	t.stateDB = stateDB
}
