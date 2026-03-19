// Package main implements a minimal EVM executor experiment for Basis Network zkEVM L2.
//
// This experiment validates that go-ethereum's core/vm and core/state modules can be
// imported as a Go module (without forking the repository) to execute EVM transactions
// with custom tracing, producing execution traces suitable for ZK witness generation.
//
// Research Unit: RU-L1 (EVM Execution Engine)
// Target: zkl2
// Date: 2026-03-19
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"os"
	"runtime"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/rawdb"
	"github.com/ethereum/go-ethereum/core/state"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
)

// ZKTrace captures all state-modifying operations during EVM execution.
// This is the data that the downstream Rust prover consumes for witness generation.
type ZKTrace struct {
	TxHash       common.Hash     `json:"tx_hash"`
	From         common.Address  `json:"from"`
	To           *common.Address `json:"to,omitempty"`
	Value        *big.Int        `json:"value"`
	GasUsed      uint64          `json:"gas_used"`
	Success      bool            `json:"success"`
	OpcodeCount  int             `json:"opcode_count"`
	StorageReads []StorageAccess `json:"storage_reads"`
	StorageWrites []StorageAccess `json:"storage_writes"`
	BalanceChanges []BalanceChange `json:"balance_changes"`
	NonceChanges  []NonceChange   `json:"nonce_changes"`
	OpcodeLog    []OpcodeEntry   `json:"opcode_log,omitempty"`
	CreatedContracts []common.Address `json:"created_contracts,omitempty"`
	Logs         []LogEntry      `json:"logs"`
}

// StorageAccess records a single SLOAD or SSTORE operation.
type StorageAccess struct {
	Address common.Address `json:"address"`
	Slot    common.Hash    `json:"slot"`
	Value   common.Hash    `json:"value"`
}

// BalanceChange records a balance modification (transfers, gas payment).
type BalanceChange struct {
	Address  common.Address `json:"address"`
	Previous *big.Int       `json:"previous"`
	New      *big.Int       `json:"new"`
	Reason   string         `json:"reason"`
}

// NonceChange records a nonce modification.
type NonceChange struct {
	Address  common.Address `json:"address"`
	Previous uint64         `json:"previous"`
	New      uint64         `json:"new"`
}

// OpcodeEntry records a single opcode execution (optional, for detailed tracing).
type OpcodeEntry struct {
	PC     uint64 `json:"pc"`
	Op     string `json:"op"`
	Gas    uint64 `json:"gas"`
	Depth  int    `json:"depth"`
}

// LogEntry records an event log emission.
type LogEntry struct {
	Address common.Address `json:"address"`
	Topics  []common.Hash  `json:"topics"`
	Data    []byte         `json:"data"`
}

// ZKTracer implements the tracing hooks to capture execution traces for ZK witness generation.
type ZKTracer struct {
	trace        *ZKTrace
	captureOps   bool // Whether to capture individual opcodes (expensive)
}

// NewZKTracer creates a new tracer instance.
func NewZKTracer(captureOps bool) *ZKTracer {
	return &ZKTracer{
		trace: &ZKTrace{
			StorageReads:   make([]StorageAccess, 0),
			StorageWrites:  make([]StorageAccess, 0),
			BalanceChanges: make([]BalanceChange, 0),
			NonceChanges:   make([]NonceChange, 0),
			OpcodeLog:      make([]OpcodeEntry, 0),
			Logs:           make([]LogEntry, 0),
		},
		captureOps: captureOps,
	}
}

// Hooks returns the tracing.Hooks struct that Geth's EVM uses.
func (t *ZKTracer) Hooks() *tracing.Hooks {
	return &tracing.Hooks{
		OnOpcode: func(pc uint64, op byte, gas, cost uint64, scope tracing.OpContext, rData []byte, depth int, err error) {
			t.trace.OpcodeCount++
			if t.captureOps {
				t.trace.OpcodeLog = append(t.trace.OpcodeLog, OpcodeEntry{
					PC:    pc,
					Op:    vm.OpCode(op).String(),
					Gas:   gas,
					Depth: depth,
				})
			}
		},
		OnStorageChange: func(addr common.Address, slot common.Hash, prev, new common.Hash) {
			t.trace.StorageWrites = append(t.trace.StorageWrites, StorageAccess{
				Address: addr,
				Slot:    slot,
				Value:   new,
			})
		},
		OnBalanceChange: func(addr common.Address, prev, new *big.Int, reason tracing.BalanceChangeReason) {
			t.trace.BalanceChanges = append(t.trace.BalanceChanges, BalanceChange{
				Address:  addr,
				Previous: new(big.Int).Set(prev),
				New:      new(big.Int).Set(new),
				Reason:   reason.String(),
			})
		},
		OnNonceChange: func(addr common.Address, prev, new uint64) {
			t.trace.NonceChanges = append(t.trace.NonceChanges, NonceChange{
				Address:  addr,
				Previous: prev,
				New:      new,
			})
		},
		OnLog: func(log *types.Log) {
			entry := LogEntry{
				Address: log.Address,
				Data:    log.Data,
			}
			for _, topic := range log.Topics {
				entry.Topics = append(entry.Topics, topic)
			}
			t.trace.Logs = append(t.trace.Logs, entry)
		},
	}
}

// GetTrace returns the collected trace.
func (t *ZKTracer) GetTrace() *ZKTrace {
	return t.trace
}

// Reset clears the tracer for reuse.
func (t *ZKTracer) Reset() {
	t.trace = &ZKTrace{
		StorageReads:   make([]StorageAccess, 0),
		StorageWrites:  make([]StorageAccess, 0),
		BalanceChanges: make([]BalanceChange, 0),
		NonceChanges:   make([]NonceChange, 0),
		OpcodeLog:      make([]OpcodeEntry, 0),
		Logs:           make([]LogEntry, 0),
	}
}

// BasisL2Config returns a chain config suitable for Basis Network L2.
func BasisL2Config() *params.ChainConfig {
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

func uint64Ptr(n uint64) *uint64 {
	return &n
}

// createStateDB creates an in-memory StateDB for testing.
func createStateDB() *state.StateDB {
	db := rawdb.NewMemoryDatabase()
	stateDB, err := state.New(types.EmptyRootHash, state.NewDatabase(db), nil)
	if err != nil {
		log.Fatalf("Failed to create StateDB: %v", err)
	}
	return stateDB
}

// setupAccounts creates test accounts with balances.
func setupAccounts(stateDB *state.StateDB, count int) []common.Address {
	addresses := make([]common.Address, count)
	for i := 0; i < count; i++ {
		key, _ := crypto.GenerateKey()
		addr := crypto.PubkeyToAddress(key.PublicKey)
		addresses[i] = addr
		// Give each account 1000 ETH
		stateDB.AddBalance(addr, new(big.Int).Mul(big.NewInt(1000), new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)), tracing.BalanceChangeUnspecified)
		stateDB.SetNonce(addr, 0)
	}
	return addresses
}

// ERC20 minimal bytecode for benchmarking storage operations.
// This is a simplified storage contract: stores a mapping(address => uint256).
// SSTORE at slot keccak256(addr, 0) = value
var storageContractCode = common.Hex2Bytes(
	// Simple contract that stores msg.value at a storage slot derived from calldata
	// PUSH1 0x20 CALLDATALOAD -> slot
	// CALLVALUE -> value
	// SSTORE
	// STOP
	"6020356000355500",
)

// simpleTransferBenchmark measures tx/s for simple ETH transfers.
func simpleTransferBenchmark(iterations int, withTracing bool) BenchmarkResult {
	stateDB := createStateDB()
	accounts := setupAccounts(stateDB, 100)
	chainConfig := BasisL2Config()

	var tracer *ZKTracer
	vmConfig := vm.Config{}
	if withTracing {
		tracer = NewZKTracer(false) // No opcode-level capture for speed test
		vmConfig.Tracer = tracer.Hooks()
	}

	blockCtx := vm.BlockContext{
		CanTransfer: func(db vm.StateDB, addr common.Address, amount *big.Int) bool {
			return db.GetBalance(addr).Cmp(amount) >= 0
		},
		Transfer: func(db vm.StateDB, sender, recipient common.Address, amount *big.Int) {
			db.SubBalance(sender, amount, tracing.BalanceChangeTransfer)
			db.AddBalance(recipient, amount, tracing.BalanceChangeTransfer)
		},
		GetHash: func(n uint64) common.Hash {
			return common.Hash{}
		},
		BlockNumber: big.NewInt(1),
		Time:        uint64(time.Now().Unix()),
		Difficulty:  big.NewInt(0),
		GasLimit:    30_000_000,
		BaseFee:     big.NewInt(0), // Zero-fee L2
		Coinbase:    common.Address{},
	}

	transferAmount := new(big.Int).Mul(big.NewInt(1), new(big.Int).Exp(big.NewInt(10), big.NewInt(15), nil)) // 0.001 ETH

	var memBefore runtime.MemStats
	runtime.ReadMemStats(&memBefore)

	// Warm-up phase (10% of iterations)
	warmup := iterations / 10
	for i := 0; i < warmup; i++ {
		from := accounts[i%len(accounts)]
		to := accounts[(i+1)%len(accounts)]
		evm := vm.NewEVM(blockCtx, vm.TxContext{Origin: from, GasPrice: big.NewInt(0)}, stateDB, chainConfig, vmConfig)
		_, _, _ = evm.Call(from, to, nil, 21000, transferAmount)
		if tracer != nil {
			tracer.Reset()
		}
	}

	// Actual benchmark
	totalTraceSize := 0
	start := time.Now()
	for i := 0; i < iterations; i++ {
		from := accounts[i%len(accounts)]
		to := accounts[(i+1)%len(accounts)]

		evm := vm.NewEVM(blockCtx, vm.TxContext{Origin: from, GasPrice: big.NewInt(0)}, stateDB, chainConfig, vmConfig)
		_, _, err := evm.Call(from, to, nil, 21000, transferAmount)

		if tracer != nil {
			trace := tracer.GetTrace()
			traceJSON, _ := json.Marshal(trace)
			totalTraceSize += len(traceJSON)
			tracer.Reset()
		}

		if err != nil {
			log.Printf("Transfer failed at iteration %d: %v", i, err)
		}
	}
	elapsed := time.Since(start)

	var memAfter runtime.MemStats
	runtime.ReadMemStats(&memAfter)

	return BenchmarkResult{
		Name:            "simple_transfer",
		Iterations:      iterations,
		WithTracing:     withTracing,
		TotalTimeMs:     float64(elapsed.Milliseconds()),
		TxPerSecond:     float64(iterations) / elapsed.Seconds(),
		AvgTxTimeUs:     float64(elapsed.Microseconds()) / float64(iterations),
		TotalTraceSizeB: totalTraceSize,
		AvgTraceSizeB:   totalTraceSize / max(iterations, 1),
		MemoryUsedMB:    float64(memAfter.Alloc-memBefore.Alloc) / 1024 / 1024,
	}
}

// storageWriteBenchmark measures tx/s for SSTORE operations.
func storageWriteBenchmark(iterations int, withTracing bool) BenchmarkResult {
	stateDB := createStateDB()
	accounts := setupAccounts(stateDB, 100)
	chainConfig := BasisL2Config()

	// Deploy storage contract
	contractAddr := common.HexToAddress("0x1000000000000000000000000000000000000001")
	stateDB.SetCode(contractAddr, storageContractCode)

	var tracer *ZKTracer
	vmConfig := vm.Config{}
	if withTracing {
		tracer = NewZKTracer(false)
		vmConfig.Tracer = tracer.Hooks()
	}

	blockCtx := vm.BlockContext{
		CanTransfer: func(db vm.StateDB, addr common.Address, amount *big.Int) bool {
			return db.GetBalance(addr).Cmp(amount) >= 0
		},
		Transfer: func(db vm.StateDB, sender, recipient common.Address, amount *big.Int) {
			db.SubBalance(sender, amount, tracing.BalanceChangeTransfer)
			db.AddBalance(recipient, amount, tracing.BalanceChangeTransfer)
		},
		GetHash: func(n uint64) common.Hash {
			return common.Hash{}
		},
		BlockNumber: big.NewInt(1),
		Time:        uint64(time.Now().Unix()),
		Difficulty:  big.NewInt(0),
		GasLimit:    30_000_000,
		BaseFee:     big.NewInt(0),
		Coinbase:    common.Address{},
	}

	var memBefore runtime.MemStats
	runtime.ReadMemStats(&memBefore)

	// Warm-up
	warmup := iterations / 10
	for i := 0; i < warmup; i++ {
		from := accounts[i%len(accounts)]
		callData := make([]byte, 64)
		copy(callData[12:32], from.Bytes())
		big.NewInt(int64(i)).FillBytes(callData[32:64])

		evm := vm.NewEVM(blockCtx, vm.TxContext{Origin: from, GasPrice: big.NewInt(0)}, stateDB, chainConfig, vmConfig)
		_, _, _ = evm.Call(from, contractAddr, callData, 100000, big.NewInt(0))
		if tracer != nil {
			tracer.Reset()
		}
	}

	totalTraceSize := 0
	start := time.Now()
	for i := 0; i < iterations; i++ {
		from := accounts[i%len(accounts)]
		callData := make([]byte, 64)
		copy(callData[12:32], from.Bytes())
		big.NewInt(int64(i)).FillBytes(callData[32:64])

		evm := vm.NewEVM(blockCtx, vm.TxContext{Origin: from, GasPrice: big.NewInt(0)}, stateDB, chainConfig, vmConfig)
		_, _, err := evm.Call(from, contractAddr, callData, 100000, big.NewInt(0))

		if tracer != nil {
			trace := tracer.GetTrace()
			traceJSON, _ := json.Marshal(trace)
			totalTraceSize += len(traceJSON)
			tracer.Reset()
		}

		if err != nil {
			log.Printf("Storage write failed at iteration %d: %v", i, err)
		}
	}
	elapsed := time.Since(start)

	var memAfter runtime.MemStats
	runtime.ReadMemStats(&memAfter)

	return BenchmarkResult{
		Name:            "storage_write",
		Iterations:      iterations,
		WithTracing:     withTracing,
		TotalTimeMs:     float64(elapsed.Milliseconds()),
		TxPerSecond:     float64(iterations) / elapsed.Seconds(),
		AvgTxTimeUs:     float64(elapsed.Microseconds()) / float64(iterations),
		TotalTraceSizeB: totalTraceSize,
		AvgTraceSizeB:   totalTraceSize / max(iterations, 1),
		MemoryUsedMB:    float64(memAfter.Alloc-memBefore.Alloc) / 1024 / 1024,
	}
}

// opcodeTraceBenchmark measures overhead of full opcode-level tracing.
func opcodeTraceBenchmark(iterations int) BenchmarkResult {
	stateDB := createStateDB()
	accounts := setupAccounts(stateDB, 100)
	chainConfig := BasisL2Config()

	contractAddr := common.HexToAddress("0x1000000000000000000000000000000000000001")
	stateDB.SetCode(contractAddr, storageContractCode)

	tracer := NewZKTracer(true) // Full opcode capture
	vmConfig := vm.Config{
		Tracer: tracer.Hooks(),
	}

	blockCtx := vm.BlockContext{
		CanTransfer: func(db vm.StateDB, addr common.Address, amount *big.Int) bool {
			return db.GetBalance(addr).Cmp(amount) >= 0
		},
		Transfer: func(db vm.StateDB, sender, recipient common.Address, amount *big.Int) {
			db.SubBalance(sender, amount, tracing.BalanceChangeTransfer)
			db.AddBalance(recipient, amount, tracing.BalanceChangeTransfer)
		},
		GetHash: func(n uint64) common.Hash {
			return common.Hash{}
		},
		BlockNumber: big.NewInt(1),
		Time:        uint64(time.Now().Unix()),
		Difficulty:  big.NewInt(0),
		GasLimit:    30_000_000,
		BaseFee:     big.NewInt(0),
		Coinbase:    common.Address{},
	}

	totalTraceSize := 0
	totalOpcodes := 0
	start := time.Now()
	for i := 0; i < iterations; i++ {
		from := accounts[i%len(accounts)]
		callData := make([]byte, 64)
		copy(callData[12:32], from.Bytes())
		big.NewInt(int64(i)).FillBytes(callData[32:64])

		evm := vm.NewEVM(blockCtx, vm.TxContext{Origin: from, GasPrice: big.NewInt(0)}, stateDB, chainConfig, vmConfig)
		_, _, _ = evm.Call(from, contractAddr, callData, 100000, big.NewInt(0))

		trace := tracer.GetTrace()
		totalOpcodes += trace.OpcodeCount
		traceJSON, _ := json.Marshal(trace)
		totalTraceSize += len(traceJSON)
		tracer.Reset()
	}
	elapsed := time.Since(start)

	result := BenchmarkResult{
		Name:            "opcode_trace_full",
		Iterations:      iterations,
		WithTracing:     true,
		TotalTimeMs:     float64(elapsed.Milliseconds()),
		TxPerSecond:     float64(iterations) / elapsed.Seconds(),
		AvgTxTimeUs:     float64(elapsed.Microseconds()) / float64(iterations),
		TotalTraceSizeB: totalTraceSize,
		AvgTraceSizeB:   totalTraceSize / max(iterations, 1),
	}
	result.ExtraMetrics = map[string]float64{
		"total_opcodes":       float64(totalOpcodes),
		"avg_opcodes_per_tx":  float64(totalOpcodes) / float64(iterations),
	}
	return result
}

// BenchmarkResult holds the results of a single benchmark run.
type BenchmarkResult struct {
	Name            string             `json:"name"`
	Iterations      int                `json:"iterations"`
	WithTracing     bool               `json:"with_tracing"`
	TotalTimeMs     float64            `json:"total_time_ms"`
	TxPerSecond     float64            `json:"tx_per_second"`
	AvgTxTimeUs     float64            `json:"avg_tx_time_us"`
	TotalTraceSizeB int                `json:"total_trace_size_bytes"`
	AvgTraceSizeB   int                `json:"avg_trace_size_bytes"`
	MemoryUsedMB    float64            `json:"memory_used_mb"`
	ExtraMetrics    map[string]float64 `json:"extra_metrics,omitempty"`
}

// ExperimentResults holds all benchmark results.
type ExperimentResults struct {
	Timestamp    string            `json:"timestamp"`
	GoVersion    string            `json:"go_version"`
	GethVersion  string            `json:"geth_version"`
	OS           string            `json:"os"`
	Arch         string            `json:"arch"`
	Benchmarks   []BenchmarkResult `json:"benchmarks"`
	TracingOverhead float64        `json:"tracing_overhead_percent"`
}

func main() {
	fmt.Println("=== Basis Network EVM Executor Experiment (RU-L1) ===")
	fmt.Println("Target: zkl2 | Domain: l2-architecture")
	fmt.Println()

	iterations := 10000
	results := ExperimentResults{
		Timestamp:   time.Now().UTC().Format(time.RFC3339),
		GoVersion:   runtime.Version(),
		GethVersion: "v1.14.12",
		OS:          runtime.GOOS,
		Arch:        runtime.GOARCH,
	}

	// Benchmark 1: Simple transfers WITHOUT tracing
	fmt.Println("[1/6] Simple transfer (no tracing)...")
	b1 := simpleTransferBenchmark(iterations, false)
	fmt.Printf("  -> %.0f tx/s (%.1f us/tx)\n", b1.TxPerSecond, b1.AvgTxTimeUs)
	results.Benchmarks = append(results.Benchmarks, b1)

	// Benchmark 2: Simple transfers WITH tracing
	fmt.Println("[2/6] Simple transfer (with ZK tracing)...")
	b2 := simpleTransferBenchmark(iterations, true)
	fmt.Printf("  -> %.0f tx/s (%.1f us/tx), trace: %d bytes/tx\n", b2.TxPerSecond, b2.AvgTxTimeUs, b2.AvgTraceSizeB)
	results.Benchmarks = append(results.Benchmarks, b2)

	// Benchmark 3: Storage writes WITHOUT tracing
	fmt.Println("[3/6] Storage write (no tracing)...")
	b3 := storageWriteBenchmark(iterations, false)
	fmt.Printf("  -> %.0f tx/s (%.1f us/tx)\n", b3.TxPerSecond, b3.AvgTxTimeUs)
	results.Benchmarks = append(results.Benchmarks, b3)

	// Benchmark 4: Storage writes WITH tracing
	fmt.Println("[4/6] Storage write (with ZK tracing)...")
	b4 := storageWriteBenchmark(iterations, true)
	fmt.Printf("  -> %.0f tx/s (%.1f us/tx), trace: %d bytes/tx\n", b4.TxPerSecond, b4.AvgTxTimeUs, b4.AvgTraceSizeB)
	results.Benchmarks = append(results.Benchmarks, b4)

	// Benchmark 5: Full opcode tracing (most expensive)
	fmt.Println("[5/6] Storage write (full opcode trace)...")
	b5 := opcodeTraceBenchmark(iterations)
	fmt.Printf("  -> %.0f tx/s (%.1f us/tx), trace: %d bytes/tx\n", b5.TxPerSecond, b5.AvgTxTimeUs, b5.AvgTraceSizeB)
	results.Benchmarks = append(results.Benchmarks, b5)

	// Calculate tracing overhead
	if b1.TxPerSecond > 0 {
		transferOverhead := ((b1.TxPerSecond - b2.TxPerSecond) / b1.TxPerSecond) * 100
		results.TracingOverhead = transferOverhead
		fmt.Printf("\n[6/6] Tracing overhead analysis:\n")
		fmt.Printf("  Transfer: %.1f%% overhead (%.0f -> %.0f tx/s)\n", transferOverhead, b1.TxPerSecond, b2.TxPerSecond)
	}
	if b3.TxPerSecond > 0 {
		storageOverhead := ((b3.TxPerSecond - b4.TxPerSecond) / b3.TxPerSecond) * 100
		fmt.Printf("  Storage:  %.1f%% overhead (%.0f -> %.0f tx/s)\n", storageOverhead, b3.TxPerSecond, b4.TxPerSecond)
	}
	if b3.TxPerSecond > 0 && b5.TxPerSecond > 0 {
		fullTraceOverhead := ((b3.TxPerSecond - b5.TxPerSecond) / b3.TxPerSecond) * 100
		fmt.Printf("  Full trace: %.1f%% overhead (%.0f -> %.0f tx/s)\n", fullTraceOverhead, b3.TxPerSecond, b5.TxPerSecond)
	}

	// Print single trace example
	fmt.Println("\n=== Example ZK Trace (single transfer) ===")
	exampleStateDB := createStateDB()
	exampleAccounts := setupAccounts(exampleStateDB, 2)
	exampleTracer := NewZKTracer(true)
	exampleConfig := vm.Config{Tracer: exampleTracer.Hooks()}
	exampleBlockCtx := vm.BlockContext{
		CanTransfer: func(db vm.StateDB, addr common.Address, amount *big.Int) bool {
			return db.GetBalance(addr).Cmp(amount) >= 0
		},
		Transfer: func(db vm.StateDB, sender, recipient common.Address, amount *big.Int) {
			db.SubBalance(sender, amount, tracing.BalanceChangeTransfer)
			db.AddBalance(recipient, amount, tracing.BalanceChangeTransfer)
		},
		GetHash:     func(n uint64) common.Hash { return common.Hash{} },
		BlockNumber: big.NewInt(1),
		Time:        uint64(time.Now().Unix()),
		GasLimit:    30_000_000,
		BaseFee:     big.NewInt(0),
	}

	transferAmt := new(big.Int).Mul(big.NewInt(1), new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil))
	evm := vm.NewEVM(exampleBlockCtx, vm.TxContext{Origin: exampleAccounts[0], GasPrice: big.NewInt(0)}, exampleStateDB, BasisL2Config(), exampleConfig)
	_, _, _ = evm.Call(exampleAccounts[0], exampleAccounts[1], nil, 21000, transferAmt)

	trace := exampleTracer.GetTrace()
	traceJSON, _ := json.MarshalIndent(trace, "", "  ")
	fmt.Println(string(traceJSON))

	// Write results to file
	resultsJSON, _ := json.MarshalIndent(results, "", "  ")
	if err := os.WriteFile("../results/benchmark_results.json", resultsJSON, 0644); err != nil {
		fmt.Printf("Warning: could not write results file: %v\n", err)
		// Print to stdout as fallback
		fmt.Println("\n=== Full Results (JSON) ===")
		fmt.Println(string(resultsJSON))
	} else {
		fmt.Println("\nResults written to results/benchmark_results.json")
	}

	fmt.Println("\n=== Experiment Complete ===")
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
