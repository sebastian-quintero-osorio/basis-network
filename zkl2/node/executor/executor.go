package executor

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/state"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
)

// Config holds the configuration for the EVM executor.
type Config struct {
	// ChainConfig is the go-ethereum chain configuration (chain ID, fork schedule).
	// Use BasisL2ChainConfig() for the default Basis Network L2 configuration.
	ChainConfig *params.ChainConfig

	// CaptureOps controls whether individual opcode executions are logged.
	// When true, every opcode step is recorded in ExecutionTrace.OpcodeLog.
	// This provides detailed diagnostic data but incurs 10-50x overhead.
	// Default: false (production mode).
	CaptureOps bool
}

// Executor executes EVM transactions deterministically, producing execution traces
// suitable for ZK witness generation. It wraps go-ethereum's core/vm.EVM, adding
// a ZKTracer that captures state-modifying operations (SLOAD, SSTORE, CALL).
//
// The executor implements the transaction lifecycle specified in the TLA+ specification:
//   - SubmitTx: validate inputs, set up EVM context, initiate execution
//   - ExecPush/ExecAdd/ExecSload/ExecSstore/ExecCall: opcode execution (delegated to EVM)
//   - FinishTx: collect trace, return result
//
// [Spec: EvmExecutor.tla -- deterministic state machine]
// [Source: 0-input/REPORT.md -- "Geth's EVM role is execution and trace generation"]
type Executor struct {
	config Config
	logger *slog.Logger
}

// New creates a new Executor with the given configuration and logger.
// If logger is nil, a default no-op logger is used.
func New(cfg Config, logger *slog.Logger) *Executor {
	if logger == nil {
		logger = slog.Default()
	}
	return &Executor{
		config: cfg,
		logger: logger,
	}
}

// ExecuteTransaction executes a single transaction against the provided state,
// producing a TransactionResult containing the execution trace.
//
// The caller is responsible for:
//   - Nonce verification and management (not part of EVM execution)
//   - Signature verification (not relevant at the execution layer)
//   - State snapshotting for rollback on failure (if needed)
//
// The returned error is non-nil only for infrastructure failures (nil stateDB,
// invalid configuration). EVM execution errors (out of gas, revert, stack overflow)
// are captured in TransactionResult.VMError and do NOT cause a non-nil return error.
//
// This function is deterministic: given the same stateDB state, block info, and
// message, it produces the same TransactionResult and trace. This is the fundamental
// requirement for ZK proving (Determinism invariant).
//
// [Spec: SubmitTx + ExecPush/Add/Sload/Sstore/Call + FinishTx lifecycle]
// [Spec: Determinism invariant -- same tx + same state => same result + same trace]
func (e *Executor) ExecuteTransaction(
	ctx context.Context,
	stateDB *state.StateDB,
	block BlockInfo,
	msg Message,
) (*TransactionResult, error) {
	// --- Input validation ---
	// [Spec: SubmitTx guards -- from in Accounts, value >= 0]
	if stateDB == nil {
		return nil, ErrNilStateDB
	}
	if msg.Value == nil {
		return nil, ErrNilMessage
	}
	if msg.GasPrice == nil {
		msg.GasPrice = new(big.Int) // Default to zero gas price (Basis Network L2)
	}

	e.logger.DebugContext(ctx, "executing transaction",
		"from", msg.From.Hex(),
		"to", addrToString(msg.To),
		"value", msg.Value.String(),
		"gas", msg.Gas,
	)

	// --- Create tracer and wrap StateDB with hooks ---
	// go-ethereum v1.15+ requires wrapping the StateDB with hooks via NewHookedState
	// to receive OnBalanceChange, OnStorageChange, OnNonceChange callbacks.
	tracer := NewZKTracer(stateDB, e.config.CaptureOps)
	hooks := tracer.Hooks()
	hookedDB := state.NewHookedState(stateDB, hooks)

	// --- Build block context ---
	// [Spec: Not directly modeled -- EVM infrastructure]
	// [Source: 0-input/code/main.go, lines 248-265 -- BlockContext setup]
	blockCtx := vm.BlockContext{
		CanTransfer: canTransfer,
		Transfer:    transfer,
		GetHash: func(n uint64) common.Hash {
			// Block hash oracle not yet implemented for L2.
			// Returns empty hash; BLOCKHASH opcode will return zero.
			return common.Hash{}
		},
		BlockNumber: new(big.Int).SetUint64(block.Number),
		Time:        block.Timestamp,
		Difficulty:  new(big.Int), // Post-merge: always 0
		GasLimit:    block.GasLimit,
		BaseFee:     block.BaseFee,
		Coinbase:    block.Coinbase,
	}
	if blockCtx.BaseFee == nil {
		blockCtx.BaseFee = new(big.Int) // Zero-fee L2
	}

	// --- Create EVM instance ---
	// Use hookedDB so state-change callbacks (OnBalanceChange, OnStorageChange, etc.)
	// are fired to our ZKTracer during execution.
	vmConfig := vm.Config{
		Tracer: hooks,
	}
	evm := vm.NewEVM(blockCtx, hookedDB, e.config.ChainConfig, vmConfig)

	// --- Set transaction context ---
	evm.SetTxContext(vm.TxContext{
		Origin:   msg.From,
		GasPrice: msg.GasPrice,
	})

	// --- Execute ---
	// [Spec: SubmitTx transfers msg.value before opcode execution]
	// go-ethereum's EVM.Call handles value transfer internally via CanTransfer/Transfer.
	// go-ethereum v1.15+ uses *uint256.Int for value parameters and common.Address for callers.
	var (
		ret     []byte
		gasLeft uint64
		execErr error
	)

	value256 := uint256.MustFromBig(msg.Value)

	if msg.To == nil {
		// Contract creation
		// [Spec: Not modeled in current TLA+ -- future extension]
		var contractAddr common.Address
		ret, contractAddr, gasLeft, execErr = evm.Create(
			msg.From,
			msg.Data,
			msg.Gas,
			value256,
		)
		e.logger.DebugContext(ctx, "contract created",
			"address", contractAddr.Hex(),
			"gas_left", gasLeft,
		)
	} else {
		// Regular call or value transfer
		// [Spec: SubmitTx + opcode execution + FinishTx]
		ret, gasLeft, execErr = evm.Call(
			msg.From,
			*msg.To,
			msg.Data,
			msg.Gas,
			value256,
		)
	}

	gasUsed := msg.Gas - gasLeft

	// --- Collect trace ---
	// [Spec: FinishTx -- record {tx, preState, postState, executionTrace}]
	trace := tracer.GetTrace()
	trace.From = msg.From
	trace.To = msg.To
	trace.Value = msg.Value
	trace.GasUsed = gasUsed
	trace.Success = execErr == nil

	result := &TransactionResult{
		GasUsed:    gasUsed,
		ReturnData: ret,
		VMError:    execErr,
		Trace:      trace,
	}

	if execErr != nil {
		e.logger.DebugContext(ctx, "transaction execution failed",
			"error", execErr.Error(),
			"gas_used", gasUsed,
			"opcode_count", trace.OpcodeCount,
		)
	} else {
		e.logger.DebugContext(ctx, "transaction executed successfully",
			"gas_used", gasUsed,
			"opcode_count", trace.OpcodeCount,
			"trace_entries", len(trace.Entries),
		)
	}

	return result, nil
}

// canTransfer checks whether the sender has sufficient balance for the transfer.
// This is the CanTransfer function wired into the EVM's BlockContext.
//
// [Spec: SubmitTx guard -- accountState[from].balance >= value]
// [Source: 0-input/code/main.go, lines 249-251 -- CanTransfer]
func canTransfer(db vm.StateDB, addr common.Address, amount *uint256.Int) bool {
	return db.GetBalance(addr).Cmp(amount) >= 0
}

// transfer moves value from sender to recipient.
// This is the Transfer function wired into the EVM's BlockContext.
//
// [Spec: SubmitTx -- accountState[from].balance - value, accountState[to].balance + value]
// [Source: 0-input/code/main.go, lines 252-254 -- Transfer]
func transfer(db vm.StateDB, sender, recipient common.Address, amount *uint256.Int) {
	db.SubBalance(sender, amount, tracing.BalanceChangeTransfer)
	db.AddBalance(recipient, amount, tracing.BalanceChangeTransfer)
}

// addrToString formats an address pointer for logging.
func addrToString(addr *common.Address) string {
	if addr == nil {
		return "<contract creation>"
	}
	return addr.Hex()
}

// BasisL2ChainConfig returns the chain configuration for Basis Network L2.
// Chain ID 43199, all forks activated at genesis, Cancun enabled, no Pectra.
//
// CRITICAL: evmVersion must be Cancun. Avalanche does NOT support Pectra.
// Do not set PragueTime.
//
// [Source: 0-input/code/main.go, lines 175-193 -- BasisL2Config]
func BasisL2ChainConfig() *params.ChainConfig {
	return &params.ChainConfig{
		ChainID:             big.NewInt(43199), // Basis Network chain ID
		HomesteadBlock:      big.NewInt(0),
		EIP150Block:         big.NewInt(0),
		EIP155Block:         big.NewInt(0),
		EIP158Block:         big.NewInt(0),
		ByzantiumBlock:      big.NewInt(0),
		ConstantinopleBlock: big.NewInt(0),
		PetersburgBlock:     big.NewInt(0),
		IstanbulBlock:       big.NewInt(0),
		MuirGlacierBlock:    big.NewInt(0),
		BerlinBlock:         big.NewInt(0),
		LondonBlock:         big.NewInt(0),
		ShanghaiTime:        uint64Ptr(0),
		CancunTime:          uint64Ptr(0),
		// No PragueTime -- Avalanche does not support Pectra
	}
}

// ValidateMessage checks that a Message has all required fields.
// Returns an error describing the first invalid field found.
func ValidateMessage(msg Message) error {
	if msg.Value == nil {
		return errors.New("executor: message value must not be nil")
	}
	if msg.Value.Sign() < 0 {
		return errors.New("executor: message value must be non-negative")
	}
	if msg.Gas == 0 {
		return errors.New("executor: message gas must be greater than zero")
	}
	if msg.From == (common.Address{}) {
		return fmt.Errorf("executor: message sender must not be zero address")
	}
	return nil
}

func uint64Ptr(n uint64) *uint64 {
	return &n
}
