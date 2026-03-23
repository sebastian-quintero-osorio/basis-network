// Package executor implements the EVM execution engine for Basis Network zkEVM L2.
//
// It wraps go-ethereum's EVM interpreter to execute transactions deterministically,
// producing execution traces suitable for ZK witness generation. The implementation
// is derived from the formally verified TLA+ specification.
//
// [Spec: zkl2/specs/units/2026-03-evm-executor/1-formalization/v0-analysis/specs/EVMExecutor/EvmExecutor.tla]
package executor

import (
	"errors"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
)

// TraceOp identifies the type of state-modifying operation in an execution trace entry.
// The TLA+ specification defines three core ops (SLOAD, SSTORE, CALL); the implementation
// extends this with BALANCE_CHANGE, NONCE_CHANGE, and LOG for complete witness generation.
//
// [Spec: TraceEntrySet -- op field discriminates SLOAD, SSTORE, CALL]
type TraceOp string

const (
	// TraceOpSLOAD records a storage read operation.
	// The ZK prover uses this to construct Poseidon SMT inclusion proofs.
	// [Spec: TraceEntrySet -- op: {"SLOAD"}, ~255 Poseidon ops]
	TraceOpSLOAD TraceOp = "SLOAD"

	// TraceOpSSTORE records a storage write operation.
	// The ZK prover uses this to construct Poseidon SMT update proofs.
	// [Spec: TraceEntrySet -- op: {"SSTORE"}, ~255 Poseidon ops]
	TraceOpSSTORE TraceOp = "SSTORE"

	// TraceOpCALL records a value transfer via CALL opcode.
	// [Spec: TraceEntrySet -- op: {"CALL"}, ~20K R1CS constraints]
	TraceOpCALL TraceOp = "CALL"

	// TraceOpBalanceChange records a balance modification (transfer, gas refund, etc.).
	// Not in TLA+ spec; captured for complete witness generation.
	TraceOpBalanceChange TraceOp = "BALANCE_CHANGE"

	// TraceOpNonceChange records a nonce modification.
	// Not in TLA+ spec; captured for complete witness generation.
	TraceOpNonceChange TraceOp = "NONCE_CHANGE"

	// TraceOpLog records an event log emission.
	// Not in TLA+ spec; captured for L1 event bridging.
	TraceOpLog TraceOp = "LOG"

	// -- Extended EVM opcodes for full witness generation --

	// Arithmetic
	TraceOpADD TraceOp = "ADD"
	TraceOpSUB TraceOp = "SUB"
	TraceOpMUL TraceOp = "MUL"
	TraceOpDIV TraceOp = "DIV"
	TraceOpMOD TraceOp = "MOD"
	TraceOpEXP TraceOp = "EXP"

	// Bitwise
	TraceOpSHL  TraceOp = "SHL"
	TraceOpSHR  TraceOp = "SHR"
	TraceOpBYTE TraceOp = "BYTE"

	// Memory
	TraceOpMLOAD  TraceOp = "MLOAD"
	TraceOpMSTORE TraceOp = "MSTORE"

	// Stack
	TraceOpPUSH TraceOp = "PUSH"
	TraceOpPOP  TraceOp = "POP"
	TraceOpDUP  TraceOp = "DUP"
	TraceOpSWAP TraceOp = "SWAP"

	// Control
	TraceOpJUMP   TraceOp = "JUMP"
	TraceOpJUMPI  TraceOp = "JUMPI"
	TraceOpRETURN TraceOp = "RETURN"
	TraceOpREVERT TraceOp = "REVERT"

	// Crypto
	TraceOpSHA3 TraceOp = "SHA3"

	// Lifecycle
	TraceOpCREATE  TraceOp = "CREATE"
	TraceOpCREATE2 TraceOp = "CREATE2"
)

// TraceEntry records a single state-modifying operation during EVM execution.
// The ZK prover consumes these entries to construct the witness for proof generation.
//
// This is a discriminated union: the Op field determines which other fields are populated.
//   - SLOAD: Account, Slot, Value
//   - SSTORE: Account, Slot, OldValue, NewValue
//   - CALL: From, To, CallValue
//   - BALANCE_CHANGE: Account, PrevBalance, CurrBalance, Reason
//   - NONCE_CHANGE: Account, PrevNonce, CurrNonce
//
// [Spec: TraceEntrySet in EvmExecutor.tla]
type TraceEntry struct {
	// Op identifies which type of state-modifying operation this entry represents.
	Op TraceOp `json:"op"`

	// Storage fields (SLOAD, SSTORE)
	Account  common.Address `json:"account,omitempty"`
	Slot     common.Hash    `json:"slot,omitempty"`
	Value    common.Hash    `json:"value,omitempty"`      // SLOAD: value read from storage
	OldValue common.Hash    `json:"old_value,omitempty"`  // SSTORE: value before write
	NewValue common.Hash    `json:"new_value,omitempty"`  // SSTORE: value after write

	// Call fields (CALL)
	From      common.Address `json:"from,omitempty"`
	To        common.Address `json:"to,omitempty"`
	CallValue *big.Int       `json:"call_value,omitempty"`

	// Balance fields (BALANCE_CHANGE)
	PrevBalance *big.Int `json:"prev_balance,omitempty"`
	CurrBalance *big.Int `json:"curr_balance,omitempty"`
	Reason      string   `json:"reason,omitempty"`

	// Nonce fields (NONCE_CHANGE)
	PrevNonce uint64 `json:"prev_nonce,omitempty"`
	CurrNonce uint64 `json:"curr_nonce,omitempty"`

	// Arithmetic fields (ADD, SUB, MUL, DIV, MOD, EXP)
	OperandA *big.Int `json:"operand_a,omitempty"`
	OperandB *big.Int `json:"operand_b,omitempty"`
	Result   *big.Int `json:"result,omitempty"`

	// Shift fields (SHL, SHR)
	ShiftAmount uint64 `json:"shift_amount,omitempty"`

	// Memory fields (MLOAD, MSTORE)
	MemOffset uint64      `json:"mem_offset,omitempty"`
	MemValue  common.Hash `json:"mem_value,omitempty"`

	// SHA3 fields
	Sha3Hash common.Hash `json:"sha3_hash,omitempty"`
	Sha3Size uint64      `json:"sha3_size,omitempty"`

	// Stack fields (PUSH, DUP)
	StackValue *big.Int `json:"stack_value,omitempty"`

	// Control flow fields
	Destination uint64 `json:"destination,omitempty"`
	Condition   uint64 `json:"condition,omitempty"`
}

// OpcodeEntry records a single EVM opcode execution step.
// Optional: controlled by Config.CaptureOps. High overhead when enabled.
// Each entry captures the opcode, program counter, gas state, and optionally
// the storage key/value for state-modifying opcodes.
//
// [Spec: Not directly modeled in TLA+ -- diagnostic/debugging aid]
type OpcodeEntry struct {
	PC           uint64       `json:"pc"`
	Op           string       `json:"op"`
	Gas          uint64       `json:"gas"`
	GasCost      uint64       `json:"gas_cost"`
	Depth        int          `json:"depth"`
	StackSize    int          `json:"stack_size"`
	StorageKey   *common.Hash `json:"storage_key,omitempty"`
	StorageValue *common.Hash `json:"storage_value,omitempty"`
}

// ExecutionTrace captures the complete execution trace of a single transaction.
// The trace is an ordered sequence of state-modifying operations, preserving
// the exact execution order required for ZK witness generation.
//
// [Spec: trace variable in EvmExecutor.tla -- Seq(TraceEntrySet)]
type ExecutionTrace struct {
	// TxHash identifies the transaction that produced this trace.
	TxHash common.Hash `json:"tx_hash"`

	// From is the sender (origin) address.
	From common.Address `json:"from"`

	// To is the recipient address (nil for contract creation).
	To *common.Address `json:"to,omitempty"`

	// Value is the ETH value transferred with the transaction.
	Value *big.Int `json:"value"`

	// GasUsed is the total gas consumed by execution.
	GasUsed uint64 `json:"gas_used"`

	// Success indicates whether execution completed without error.
	Success bool `json:"success"`

	// OpcodeCount is the total number of opcodes executed.
	OpcodeCount int `json:"opcode_count"`

	// Entries is the ordered sequence of state-modifying operations.
	// This is the primary output consumed by the ZK prover.
	// Order matches execution order (required by TraceCompleteness invariant).
	// [Spec: trace variable -- Seq(TraceEntrySet)]
	Entries []TraceEntry `json:"entries"`

	// OpcodeLog is the full opcode execution log (optional, expensive).
	// Only populated when Config.CaptureOps is true.
	OpcodeLog []OpcodeEntry `json:"opcode_log,omitempty"`

	// Logs contains EVM event log emissions.
	Logs []*types.Log `json:"logs,omitempty"`
}

// CountByOp returns the number of trace entries with the given operation type.
// This is the implementation counterpart of CountInTrace from the TLA+ specification.
//
// [Spec: CountInTrace(traceSeq, opType)]
func (t *ExecutionTrace) CountByOp(op TraceOp) int {
	count := 0
	for i := range t.Entries {
		if t.Entries[i].Op == op {
			count++
		}
	}
	return count
}

// TransactionResult holds the complete output of executing a single transaction.
//
// [Spec: completedResults set element -- {tx, preState, postState, executionTrace}]
type TransactionResult struct {
	// GasUsed is the total gas consumed by the transaction.
	GasUsed uint64

	// ReturnData is the raw bytes returned by the EVM execution.
	ReturnData []byte

	// VMError contains the EVM execution error, if any (e.g., out of gas, revert).
	// A non-nil VMError indicates the transaction failed.
	// This is NOT an infrastructure error; it is a normal execution outcome.
	VMError error

	// Trace is the execution trace for ZK witness generation.
	Trace *ExecutionTrace
}

// BlockInfo holds block-level context for transaction execution.
// [Spec: Not directly modeled -- EVM infrastructure]
type BlockInfo struct {
	Number    uint64
	Timestamp uint64
	GasLimit  uint64
	BaseFee   *big.Int
	Coinbase  common.Address
}

// Message represents a transaction to be executed by the executor.
// The caller is responsible for signature verification and nonce management.
//
// [Spec: currentTx record -- {from, to, program, value}]
type Message struct {
	From     common.Address
	To       *common.Address // nil for contract creation
	Value    *big.Int
	Gas      uint64
	GasPrice *big.Int
	Data     []byte
	Nonce    uint64
}

// Executor errors.
var (
	// ErrNilStateDB is returned when a nil StateDB is passed to ExecuteTransaction.
	ErrNilStateDB = errors.New("executor: nil state database")

	// ErrNilMessage is returned when Message fields are invalid.
	ErrNilMessage = errors.New("executor: nil value in message")
)
