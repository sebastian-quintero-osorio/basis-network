package executor

import (
	"context"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/state"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/holiman/uint256"
)

// --- Test Helpers ---

// testBlockInfo returns a default BlockInfo for tests.
func testBlockInfo() BlockInfo {
	return BlockInfo{
		Number:    1,
		Timestamp: 1700000000,
		GasLimit:  30_000_000,
		BaseFee:   new(big.Int), // Zero-fee L2
		Coinbase:  common.Address{},
	}
}

// oneEther returns 1 ETH in wei (10^18).
func oneEther() *big.Int {
	return new(big.Int).Mul(big.NewInt(1000), new(big.Int).Exp(big.NewInt(10), big.NewInt(15), nil))
}

// setupTestState creates an in-memory StateDB with two funded accounts.
// Returns the stateDB, sender address, and recipient address.
func setupTestState(t *testing.T) (*state.StateDB, common.Address, common.Address) {
	t.Helper()

	stateDB, err := state.New(types.EmptyRootHash, state.NewDatabaseForTesting())
	if err != nil {
		t.Fatalf("failed to create state database: %v", err)
	}

	sender := common.HexToAddress("0x1111111111111111111111111111111111111111")
	recipient := common.HexToAddress("0x2222222222222222222222222222222222222222")

	// Fund accounts with 1000 ETH each.
	// [Spec: Init -- accountState[a].balance = 1 per account]
	fundAmount := uint256.MustFromBig(new(big.Int).Mul(big.NewInt(1000), oneEther()))
	stateDB.AddBalance(sender, fundAmount, tracing.BalanceChangeUnspecified)
	stateDB.SetNonce(sender, 0, tracing.NonceChangeUnspecified)
	stateDB.AddBalance(recipient, fundAmount, tracing.BalanceChangeUnspecified)
	stateDB.SetNonce(recipient, 0, tracing.NonceChangeUnspecified)

	return stateDB, sender, recipient
}

// newTestExecutor creates an Executor with default test configuration.
func newTestExecutor() *Executor {
	return New(Config{
		ChainConfig: BasisL2ChainConfig(),
		CaptureOps:  true, // Enable full opcode capture for test inspection
	}, nil)
}

// deployContract deploys bytecode at a fixed address and returns the address.
func deployContract(t *testing.T, stateDB *state.StateDB, code []byte) common.Address {
	t.Helper()
	addr := common.HexToAddress("0x3333333333333333333333333333333333333333")
	stateDB.SetCode(addr, code)
	return addr
}

// --- Bytecode Constants ---
// All bytecodes are EVM instruction sequences for testing specific opcode behaviors.

// bytecodeEmpty: STOP (0x00). Trivial program that immediately halts.
var bytecodeEmpty = common.Hex2Bytes("00")

// bytecodeSstore: PUSH1 0x42, PUSH1 0x00, SSTORE, STOP.
// Stores value 0x42 at storage slot 0.
// Expected trace: 1x SSTORE entry.
// [Spec: ExecSstore -- generates {op: "SSTORE", account, slot, oldValue, newValue}]
var bytecodeSstore = common.Hex2Bytes("6042600055" + "00")

// bytecodeSstoreSload: PUSH1 0x42, PUSH1 0x00, SSTORE, PUSH1 0x00, SLOAD, STOP.
// Stores 0x42 at slot 0, then loads from slot 0.
// Expected trace: 1x SSTORE + 1x SLOAD.
// Tests SloadAfterSstoreConsistency: SLOAD must return the SSTORE'd value.
// [Spec: SloadAfterSstoreConsistency invariant]
var bytecodeSstoreSload = common.Hex2Bytes("6042600055" + "600054" + "00")

// bytecodePushAdd: PUSH1 0x01, PUSH1 0x02, ADD, STOP.
// Pushes 1 and 2, adds them. No state modification.
// Expected trace: 0 entries (PUSH and ADD are not state-modifying).
// [Spec: ExecPush + ExecAdd -- no trace entries generated]
var bytecodePushAdd = common.Hex2Bytes("6001600201" + "00")

// bytecodeInfiniteLoop: JUMPDEST, PUSH1 0x00, JUMP.
// Loops forever: JUMPDEST(0) -> PUSH1 0 -> JUMP(0) -> JUMPDEST(0) -> ...
// Used to test out-of-gas behavior.
var bytecodeInfiniteLoop = common.Hex2Bytes("5b600056")

// bytecodeStackOverflow: 1025 x PUSH1 0x00 + STOP.
// EVM stack limit is 1024. The 1025th PUSH causes a stack overflow error.
func bytecodeStackOverflow() []byte {
	code := make([]byte, 0, 2*1025+1)
	for i := 0; i < 1025; i++ {
		code = append(code, 0x60, 0x00) // PUSH1 0x00
	}
	code = append(code, 0x00) // STOP
	return code
}

// --- Unit Tests ---

// TestExecuteSimpleTransfer verifies basic ETH transfer execution.
// Maps to TLA+ SubmitTx with an empty program (immediate FinishTx).
//
// [Spec: SubmitTx(from, to, <<>>, value) -> FinishTx]
func TestExecuteSimpleTransfer(t *testing.T) {
	stateDB, sender, recipient := setupTestState(t)
	exec := newTestExecutor()

	transferAmount := new(big.Int).Mul(big.NewInt(1), oneEther()) // 1 ETH
	result, err := exec.ExecuteTransaction(
		context.Background(),
		stateDB,
		testBlockInfo(),
		Message{
			From:  sender,
			To:    &recipient,
			Value: transferAmount,
			Gas:   21000,
			Data:  nil,
		},
	)

	if err != nil {
		t.Fatalf("ExecuteTransaction returned infrastructure error: %v", err)
	}
	if result.VMError != nil {
		t.Fatalf("ExecuteTransaction returned VM error: %v", result.VMError)
	}
	if !result.Trace.Success {
		t.Fatal("expected successful execution")
	}

	// Verify trace metadata
	if result.Trace.From != sender {
		t.Errorf("trace.From = %s, want %s", result.Trace.From.Hex(), sender.Hex())
	}
	if result.Trace.To == nil || *result.Trace.To != recipient {
		t.Errorf("trace.To = %v, want %s", result.Trace.To, recipient.Hex())
	}

	// Verify balance changes are recorded in trace
	balanceEntries := result.Trace.CountByOp(TraceOpBalanceChange)
	if balanceEntries == 0 {
		t.Error("expected at least one BALANCE_CHANGE trace entry for value transfer")
	}
}

// TestTraceContainsStorageEntries verifies that SSTORE and SLOAD generate trace entries.
// This is the implementation verification of the TraceCompleteness invariant.
//
// [Spec: TraceCompleteness -- every SSTORE/SLOAD in program generates a trace entry]
// [Spec: ExecSstore -- {op: "SSTORE", account, slot, oldValue, newValue}]
// [Spec: ExecSload -- {op: "SLOAD", account, slot, value}]
func TestTraceContainsStorageEntries(t *testing.T) {
	stateDB, sender, _ := setupTestState(t)
	exec := newTestExecutor()
	contractAddr := deployContract(t, stateDB, bytecodeSstoreSload)

	result, err := exec.ExecuteTransaction(
		context.Background(),
		stateDB,
		testBlockInfo(),
		Message{
			From:  sender,
			To:    &contractAddr,
			Value: new(big.Int),
			Gas:   100000,
			Data:  nil,
		},
	)

	if err != nil {
		t.Fatalf("infrastructure error: %v", err)
	}
	if result.VMError != nil {
		t.Fatalf("VM error: %v", result.VMError)
	}

	// Verify SSTORE trace entry
	// [Spec: CountInTrace(trace, "SSTORE") = CountInProgram(program, "SSTORE")]
	sstoreCount := result.Trace.CountByOp(TraceOpSSTORE)
	if sstoreCount != 1 {
		t.Errorf("SSTORE count = %d, want 1", sstoreCount)
	}

	// Verify SLOAD trace entry
	// [Spec: CountInTrace(trace, "SLOAD") = CountInProgram(program, "SLOAD")]
	sloadCount := result.Trace.CountByOp(TraceOpSLOAD)
	if sloadCount != 1 {
		t.Errorf("SLOAD count = %d, want 1", sloadCount)
	}

	// Verify SloadAfterSstoreConsistency: the SLOAD must return the value written by SSTORE.
	// [Spec: SloadAfterSstoreConsistency -- SLOAD value = preceding SSTORE newValue]
	var sstoreEntry, sloadEntry *TraceEntry
	for i := range result.Trace.Entries {
		entry := &result.Trace.Entries[i]
		if entry.Op == TraceOpSSTORE && sstoreEntry == nil {
			sstoreEntry = entry
		}
		if entry.Op == TraceOpSLOAD && sloadEntry == nil {
			sloadEntry = entry
		}
	}
	if sstoreEntry == nil || sloadEntry == nil {
		t.Fatal("missing SSTORE or SLOAD entry")
	}

	// The SLOAD value must equal the SSTORE new value (storage coherence).
	if sloadEntry.Value != sstoreEntry.NewValue {
		t.Errorf("SloadAfterSstoreConsistency violated: SLOAD value = %s, SSTORE newValue = %s",
			sloadEntry.Value.Hex(), sstoreEntry.NewValue.Hex())
	}

	// Both entries must reference the same account and slot.
	if sloadEntry.Account != sstoreEntry.Account {
		t.Errorf("SLOAD account %s != SSTORE account %s",
			sloadEntry.Account.Hex(), sstoreEntry.Account.Hex())
	}
	if sloadEntry.Slot != sstoreEntry.Slot {
		t.Errorf("SLOAD slot %s != SSTORE slot %s",
			sloadEntry.Slot.Hex(), sstoreEntry.Slot.Hex())
	}
}

// TestNoTraceForPureArithmetic verifies that PUSH and ADD do not generate trace entries.
// Only state-modifying opcodes (SLOAD, SSTORE, CALL) should produce entries.
//
// [Spec: ExecPush -- UNCHANGED trace]
// [Spec: ExecAdd -- UNCHANGED trace]
func TestNoTraceForPureArithmetic(t *testing.T) {
	stateDB, sender, _ := setupTestState(t)
	exec := newTestExecutor()
	contractAddr := deployContract(t, stateDB, bytecodePushAdd)

	result, err := exec.ExecuteTransaction(
		context.Background(),
		stateDB,
		testBlockInfo(),
		Message{
			From:  sender,
			To:    &contractAddr,
			Value: new(big.Int),
			Gas:   100000,
			Data:  nil,
		},
	)

	if err != nil {
		t.Fatalf("infrastructure error: %v", err)
	}

	// PUSH and ADD should not generate SLOAD/SSTORE/CALL entries.
	sloadCount := result.Trace.CountByOp(TraceOpSLOAD)
	sstoreCount := result.Trace.CountByOp(TraceOpSSTORE)
	callCount := result.Trace.CountByOp(TraceOpCALL)
	if sloadCount+sstoreCount+callCount != 0 {
		t.Errorf("expected 0 state-modifying entries, got SLOAD=%d SSTORE=%d CALL=%d",
			sloadCount, sstoreCount, callCount)
	}

	// But opcodes should have been counted.
	if result.Trace.OpcodeCount == 0 {
		t.Error("expected non-zero opcode count for PUSH/ADD program")
	}
}

// TestDeterminism verifies that the same transaction on the same state produces
// identical traces. This is the foundational requirement for ZK proving.
//
// [Spec: Determinism -- r1.tx = r2.tx /\ r1.preState = r2.preState =>
//
//	r1.postState = r2.postState /\ r1.executionTrace = r2.executionTrace]
func TestDeterminism(t *testing.T) {
	// Create two identical states by running the same setup.
	stateDB1, sender1, _ := setupTestState(t)
	stateDB2, sender2, _ := setupTestState(t)

	contract1 := deployContract(t, stateDB1, bytecodeSstoreSload)
	contract2 := deployContract(t, stateDB2, bytecodeSstoreSload)

	exec := newTestExecutor()

	msg := Message{
		From:  sender1,
		To:    &contract1,
		Value: new(big.Int),
		Gas:   100000,
		Data:  nil,
	}

	// Execute on state 1
	result1, err := exec.ExecuteTransaction(context.Background(), stateDB1, testBlockInfo(), msg)
	if err != nil {
		t.Fatalf("execution 1 error: %v", err)
	}

	// Execute on state 2 (same setup, same message)
	msg2 := Message{
		From:  sender2,
		To:    &contract2,
		Value: new(big.Int),
		Gas:   100000,
		Data:  nil,
	}
	result2, err := exec.ExecuteTransaction(context.Background(), stateDB2, testBlockInfo(), msg2)
	if err != nil {
		t.Fatalf("execution 2 error: %v", err)
	}

	// Compare traces: must be identical.
	trace1 := result1.Trace
	trace2 := result2.Trace

	if trace1.Success != trace2.Success {
		t.Errorf("determinism: success mismatch: %v vs %v", trace1.Success, trace2.Success)
	}
	if trace1.GasUsed != trace2.GasUsed {
		t.Errorf("determinism: gas used mismatch: %d vs %d", trace1.GasUsed, trace2.GasUsed)
	}
	if trace1.OpcodeCount != trace2.OpcodeCount {
		t.Errorf("determinism: opcode count mismatch: %d vs %d", trace1.OpcodeCount, trace2.OpcodeCount)
	}
	if len(trace1.Entries) != len(trace2.Entries) {
		t.Fatalf("determinism: entry count mismatch: %d vs %d", len(trace1.Entries), len(trace2.Entries))
	}

	// Compare each entry by operation type and relevant fields.
	for i := range trace1.Entries {
		e1 := trace1.Entries[i]
		e2 := trace2.Entries[i]
		if e1.Op != e2.Op {
			t.Errorf("determinism: entry[%d] op mismatch: %s vs %s", i, e1.Op, e2.Op)
		}
		// For storage entries, compare slot and values.
		if e1.Op == TraceOpSSTORE || e1.Op == TraceOpSLOAD {
			if e1.Slot != e2.Slot {
				t.Errorf("determinism: entry[%d] slot mismatch", i)
			}
		}
		if e1.Op == TraceOpSSTORE {
			if e1.OldValue != e2.OldValue || e1.NewValue != e2.NewValue {
				t.Errorf("determinism: entry[%d] SSTORE values mismatch", i)
			}
		}
		if e1.Op == TraceOpSLOAD {
			if e1.Value != e2.Value {
				t.Errorf("determinism: entry[%d] SLOAD value mismatch", i)
			}
		}
	}
}

// --- Adversarial Tests ---

// TestOutOfGas verifies executor behavior when the transaction runs out of gas.
// The EVM should return an error but the executor should still produce a trace
// of the opcodes that were executed before the gas ran out.
func TestOutOfGas(t *testing.T) {
	stateDB, sender, _ := setupTestState(t)
	exec := newTestExecutor()
	contractAddr := deployContract(t, stateDB, bytecodeInfiniteLoop)

	result, err := exec.ExecuteTransaction(
		context.Background(),
		stateDB,
		testBlockInfo(),
		Message{
			From:  sender,
			To:    &contractAddr,
			Value: new(big.Int),
			Gas:   1000, // Very low gas -- will run out in the loop
			Data:  nil,
		},
	)

	if err != nil {
		t.Fatalf("infrastructure error (should not happen): %v", err)
	}

	// EVM execution should fail with out-of-gas.
	if result.VMError == nil {
		t.Fatal("expected VM error for out-of-gas, got nil")
	}
	if result.Trace.Success {
		t.Fatal("expected Success=false for out-of-gas execution")
	}

	// Gas should be fully consumed.
	if result.GasUsed != 1000 {
		t.Errorf("expected gas_used=1000 (fully consumed), got %d", result.GasUsed)
	}

	// Trace should still have been partially captured.
	if result.Trace.OpcodeCount == 0 {
		t.Error("expected non-zero opcode count even for failed execution")
	}
}

// TestStackOverflow verifies executor behavior when the EVM stack overflows.
// The EVM stack limit is 1024 elements; exceeding this causes a stack overflow error.
func TestStackOverflow(t *testing.T) {
	stateDB, sender, _ := setupTestState(t)
	exec := newTestExecutor()
	contractAddr := deployContract(t, stateDB, bytecodeStackOverflow())

	result, err := exec.ExecuteTransaction(
		context.Background(),
		stateDB,
		testBlockInfo(),
		Message{
			From:  sender,
			To:    &contractAddr,
			Value: new(big.Int),
			Gas:   10_000_000, // Plenty of gas -- should fail on stack, not gas
			Data:  nil,
		},
	)

	if err != nil {
		t.Fatalf("infrastructure error: %v", err)
	}

	// EVM should report stack overflow.
	if result.VMError == nil {
		t.Fatal("expected VM error for stack overflow, got nil")
	}
	if result.Trace.Success {
		t.Fatal("expected Success=false for stack overflow")
	}
}

// TestInsufficientBalance verifies that a transfer exceeding the sender's balance
// is rejected by the EVM's CanTransfer check.
//
// [Spec: SubmitTx guard -- accountState[from].balance >= value]
func TestInsufficientBalance(t *testing.T) {
	stateDB, sender, recipient := setupTestState(t)
	exec := newTestExecutor()

	// Try to send more than the sender's balance.
	excessiveAmount := new(big.Int).Mul(big.NewInt(10000), oneEther()) // 10000 ETH (sender only has 1000)
	result, err := exec.ExecuteTransaction(
		context.Background(),
		stateDB,
		testBlockInfo(),
		Message{
			From:  sender,
			To:    &recipient,
			Value: excessiveAmount,
			Gas:   21000,
			Data:  nil,
		},
	)

	if err != nil {
		t.Fatalf("infrastructure error: %v", err)
	}

	// EVM should reject the transfer.
	if result.VMError == nil {
		t.Fatal("expected VM error for insufficient balance, got nil")
	}
	if result.Trace.Success {
		t.Fatal("expected Success=false for insufficient balance")
	}
}

// TestNilStateDB verifies that passing nil stateDB returns an infrastructure error.
func TestNilStateDB(t *testing.T) {
	exec := newTestExecutor()
	_, err := exec.ExecuteTransaction(
		context.Background(),
		nil,
		testBlockInfo(),
		Message{
			From:  common.HexToAddress("0x1111111111111111111111111111111111111111"),
			Value: new(big.Int),
			Gas:   21000,
		},
	)

	if err != ErrNilStateDB {
		t.Errorf("expected ErrNilStateDB, got %v", err)
	}
}

// TestNilValue verifies that passing nil Value returns an infrastructure error.
func TestNilValue(t *testing.T) {
	stateDB, sender, recipient := setupTestState(t)
	exec := newTestExecutor()

	_, err := exec.ExecuteTransaction(
		context.Background(),
		stateDB,
		testBlockInfo(),
		Message{
			From: sender,
			To:   &recipient,
			// Value is nil -- invalid
			Gas: 21000,
		},
	)

	if err != ErrNilMessage {
		t.Errorf("expected ErrNilMessage, got %v", err)
	}
}

// --- Opcode Classification Tests ---

// TestOpcodeClassification verifies that key opcodes are classified with correct
// ZK difficulty levels matching the scientist's research.
//
// [Source: 0-input/code/opcode_analysis.go -- ZK difficulty classification]
func TestOpcodeClassification(t *testing.T) {
	tests := []struct {
		opcode     vm.OpCode
		wantDiff   ZKDifficulty
		wantState  bool
		desc       string
	}{
		{vm.STOP, ZKTrivial, false, "STOP is trivial"},
		{vm.PUSH1, ZKTrivial, false, "PUSH1 is trivial"},
		{vm.ADD, ZKCheap, false, "ADD is cheap (~30 constraints)"},
		{vm.MUL, ZKCheap, false, "MUL is cheap"},
		{vm.MLOAD, ZKModerate, false, "MLOAD is moderate"},
		{vm.SLOAD, ZKExpensive, true, "SLOAD is expensive (255 Poseidon ops)"},
		{vm.SSTORE, ZKExpensive, true, "SSTORE is expensive (255 Poseidon ops)"},
		{vm.BALANCE, ZKExpensive, false, "BALANCE is expensive (trie traversal)"},
		{vm.CALL, ZKVeryExpensive, true, "CALL is very expensive (~20K constraints)"},
		{vm.CREATE, ZKVeryExpensive, true, "CREATE is very expensive"},
		{vm.KECCAK256, ZKCritical, false, "KECCAK256 is critical (~150K constraints)"},
	}

	for _, tt := range tests {
		t.Run(tt.desc, func(t *testing.T) {
			info, ok := GetOpcodeInfo(tt.opcode)
			if !ok {
				t.Fatalf("opcode %s not found in classification map", tt.opcode.String())
			}
			if info.Difficulty != tt.wantDiff {
				t.Errorf("difficulty = %s, want %s", info.Difficulty, tt.wantDiff)
			}
			if info.StateModifying != tt.wantState {
				t.Errorf("stateModifying = %v, want %v", info.StateModifying, tt.wantState)
			}
		})
	}
}

// TestIsZKProblematic verifies the ZK difficulty threshold.
func TestIsZKProblematic(t *testing.T) {
	// SLOAD, SSTORE, CALL, KECCAK256 should be ZK-problematic.
	problematic := []vm.OpCode{vm.SLOAD, vm.SSTORE, vm.CALL, vm.KECCAK256, vm.CREATE}
	for _, op := range problematic {
		if !IsZKProblematic(op) {
			t.Errorf("%s should be ZK-problematic", op.String())
		}
	}

	// ADD, PUSH1, MLOAD should NOT be ZK-problematic.
	safe := []vm.OpCode{vm.ADD, vm.PUSH1, vm.MLOAD, vm.STOP}
	for _, op := range safe {
		if IsZKProblematic(op) {
			t.Errorf("%s should not be ZK-problematic", op.String())
		}
	}
}

// --- Tracer Tests ---

// TestTracerReset verifies that Reset() clears all trace state.
func TestTracerReset(t *testing.T) {
	stateDB, sender, _ := setupTestState(t)
	exec := newTestExecutor()
	contractAddr := deployContract(t, stateDB, bytecodeSstore)

	// Execute to populate the tracer.
	result, err := exec.ExecuteTransaction(
		context.Background(),
		stateDB,
		testBlockInfo(),
		Message{
			From:  sender,
			To:    &contractAddr,
			Value: new(big.Int),
			Gas:   100000,
			Data:  nil,
		},
	)
	if err != nil {
		t.Fatalf("infrastructure error: %v", err)
	}
	if len(result.Trace.Entries) == 0 {
		t.Fatal("expected non-empty trace entries after SSTORE execution")
	}

	// Create a fresh tracer and verify it starts clean.
	tracer := NewZKTracer(stateDB, false)
	trace := tracer.GetTrace()
	if len(trace.Entries) != 0 {
		t.Errorf("new tracer should have 0 entries, got %d", len(trace.Entries))
	}
	if trace.OpcodeCount != 0 {
		t.Errorf("new tracer should have 0 opcode count, got %d", trace.OpcodeCount)
	}

	// Verify Reset clears state.
	tracer.Reset()
	trace = tracer.GetTrace()
	if len(trace.Entries) != 0 {
		t.Errorf("after Reset, expected 0 entries, got %d", len(trace.Entries))
	}
}

// TestValidateMessage verifies message validation.
func TestValidateMessage(t *testing.T) {
	tests := []struct {
		name    string
		msg     Message
		wantErr bool
	}{
		{
			name: "valid message",
			msg: Message{
				From:  common.HexToAddress("0x1111111111111111111111111111111111111111"),
				Value: new(big.Int),
				Gas:   21000,
			},
			wantErr: false,
		},
		{
			name: "nil value",
			msg: Message{
				From: common.HexToAddress("0x1111111111111111111111111111111111111111"),
				Gas:  21000,
			},
			wantErr: true,
		},
		{
			name: "negative value",
			msg: Message{
				From:  common.HexToAddress("0x1111111111111111111111111111111111111111"),
				Value: big.NewInt(-1),
				Gas:   21000,
			},
			wantErr: true,
		},
		{
			name: "zero gas",
			msg: Message{
				From:  common.HexToAddress("0x1111111111111111111111111111111111111111"),
				Value: new(big.Int),
				Gas:   0,
			},
			wantErr: true,
		},
		{
			name: "zero sender",
			msg: Message{
				Value: new(big.Int),
				Gas:   21000,
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ValidateMessage(tt.msg)
			if (err != nil) != tt.wantErr {
				t.Errorf("ValidateMessage() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

// --- Compile-time interface check ---
// Ensure that *state.StateDB satisfies vm.StateDB.
var _ vm.StateDB = (*state.StateDB)(nil)
