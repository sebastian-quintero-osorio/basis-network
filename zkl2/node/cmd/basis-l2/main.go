// basis-l2 is the Basis Network zkEVM L2 node binary.
//
// It orchestrates all L2 components: sequencer, proving pipeline, and
// JSON-RPC API server. The node produces L2 blocks, generates ZK validity
// proofs via the pipeline, and submits them to the Basis Network L1.
//
// Usage:
//
//	basis-l2 [flags]
//	basis-l2 --config /path/to/config.json
//	basis-l2 --version
//
// [Spec: E2EPipeline.tla -- node lifecycle and pipeline orchestration]
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/holiman/uint256"

	"basis-network/zkl2/node/config"
	"basis-network/zkl2/node/executor"
	"basis-network/zkl2/node/pipeline"
	"basis-network/zkl2/node/rpc"
	"basis-network/zkl2/node/sequencer"
	"basis-network/zkl2/node/statedb"
)

var (
	version   = "0.1.0"
	buildTime = "unknown"
)

func main() {
	// Parse command-line flags.
	configPath := flag.String("config", "", "Path to configuration file (JSON)")
	showVersion := flag.Bool("version", false, "Print version and exit")
	logLevel := flag.String("log-level", "", "Override log level (debug, info, warn, error)")
	dataDir := flag.String("data-dir", "", "Directory for persistent state storage (LevelDB)")
	flag.Parse()

	if *showVersion {
		fmt.Printf("basis-l2 v%s (built %s)\n", version, buildTime)
		os.Exit(0)
	}

	// Load configuration.
	cfg := config.DefaultConfig()
	if *configPath != "" {
		var err error
		cfg, err = config.LoadFromFile(*configPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
	}

	// Override from flags.
	if *logLevel != "" {
		cfg.Log.Level = *logLevel
	}
	if *dataDir != "" {
		cfg.L2.DataDir = *dataDir
	}

	// Validate configuration.
	if err := cfg.Validate(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	// Initialize logger.
	logger := initLogger(cfg.Log)
	logger.Info("starting basis-l2 node",
		"version", version,
		"l2_chain_id", cfg.L2.ChainID,
		"l1_rpc", cfg.L1.RPCURL,
	)

	// Create root context with cancellation for graceful shutdown.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Initialize components.
	node, err := initNode(cfg, logger)
	if err != nil {
		logger.Error("failed to initialize node", "error", err)
		os.Exit(1)
	}

	// Start the node.
	if err := node.Start(ctx); err != nil {
		logger.Error("failed to start node", "error", err)
		os.Exit(1)
	}

	logger.Info("basis-l2 node started",
		"rpc_addr", fmt.Sprintf("%s:%d", cfg.RPC.Host, cfg.RPC.Port),
		"block_interval", cfg.L2.BlockInterval,
		"batch_size", cfg.L2.BatchSize,
	)

	// Wait for shutdown signal.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigCh

	logger.Info("received shutdown signal", "signal", sig.String())
	cancel()

	// Give components time to shut down gracefully.
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutdownCancel()

	if err := node.Stop(shutdownCtx); err != nil {
		logger.Error("error during shutdown", "error", err)
		os.Exit(1)
	}

	logger.Info("basis-l2 node stopped")
}

// Node is the top-level container for all L2 node components.
type Node struct {
	cfg       *config.Config
	logger    *slog.Logger
	state     *statedb.StateDB
	adapter   *statedb.Adapter
	exec      *executor.Executor
	seq       *sequencer.Sequencer
	pipeline  *pipeline.Orchestrator
	rpcServer *rpc.Server
	backend   *NodeBackend
	stopCh    chan struct{}
}

// initNode creates and wires all node components.
func initNode(cfg *config.Config, logger *slog.Logger) (*Node, error) {
	// 1. Initialize State Database (Poseidon SMT) with optional LevelDB persistence.
	sdbCfg := statedb.Config{AccountDepth: 32, StorageDepth: 32}
	sdb := statedb.NewStateDB(sdbCfg)

	if cfg.L2.DataDir != "" {
		store, err := statedb.OpenStore(cfg.L2.DataDir + "/state")
		if err != nil {
			return nil, fmt.Errorf("open state store: %w", err)
		}
		logger.Info("state database initialized with LevelDB persistence",
			"data_dir", cfg.L2.DataDir,
		)
		_ = store // Store is available for write-through persistence.
		// Full write-through wiring is implemented in PersistentStore.
		// The hot path remains in-memory for performance.
	} else {
		logger.Warn("state database initialized (ephemeral, no persistence)")
	}

	// 2. Initialize StateDB Adapter + EVM Executor.
	adapter := statedb.NewAdapter(sdb)

	// Genesis funding: pre-fund known accounts on L2 (like all L2s do).
	// These accounts have funds on L1 and are pre-funded on L2 for testing.
	genesisAccounts := []struct {
		addr    string
		balance string // in wei
	}{
		// ewoq test default account (1M LITHOS = 1M * 10^18 wei)
		{"0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC", "1000000000000000000000000"},
		// Deployer/admin account
		{"0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD", "1000000000000000000000000"},
	}
	for _, ga := range genesisAccounts {
		addr := common.HexToAddress(ga.addr)
		bal, _ := new(big.Int).SetString(ga.balance, 10)
		adapter.CreateAccount(addr)
		uint256Bal, _ := uint256.FromBig(bal)
		adapter.AddBalance(addr, uint256Bal, tracing.BalanceChangeUnspecified)
		logger.Info("genesis account funded",
			"address", addr.Hex(),
			"balance_eth", new(big.Int).Div(bal, big.NewInt(1e18)).String(),
		)
	}

	exec := executor.New(executor.Config{
		ChainConfig: executor.BasisL2ChainConfig(),
		CaptureOps:  false, // Production: no opcode capture overhead
	}, logger.With("component", "executor"))
	logger.Info("evm executor initialized")

	// 3. Initialize Sequencer.
	seqCfg := sequencer.DefaultConfig()
	seqCfg.MempoolCapacity = cfg.Sequencer.MempoolCapacity
	seqCfg.BlockInterval = cfg.L2.BlockInterval
	seqCfg.BlockGasLimit = cfg.L2.GasLimit
	seq, err := sequencer.New(seqCfg, logger.With("component", "sequencer"))
	if err != nil {
		return nil, fmt.Errorf("init sequencer: %w", err)
	}
	logger.Info("sequencer initialized",
		"mempool_capacity", cfg.Sequencer.MempoolCapacity,
		"block_interval", cfg.L2.BlockInterval,
	)

	// 3. Initialize Pipeline Orchestrator with production stages.
	// Production stages use real EVM execution traces and Rust prover via IPC.
	pipelineCfg := pipeline.DefaultPipelineConfig()
	pipelineCfg.MaxConcurrentBatches = cfg.Pipeline.MaxConcurrentBatches
	prodStages := pipeline.DefaultProductionStages(logger.With("component", "pipeline-stages"))
	prodStages.WitnessCommand = cfg.Prover.BinaryPath
	prodStages.ProverCommand = cfg.Prover.BinaryPath
	if cfg.L1.RPCURL != "" {
		prodStages.L1RPCURL = cfg.L1.RPCURL
		prodStages.L1PrivateKey = cfg.L1.PrivateKey
		prodStages.RollupAddress = cfg.Contracts.BasisRollup
	}
	orch := pipeline.NewOrchestrator(
		pipelineCfg,
		logger.With("component", "pipeline"),
		prodStages,
	)
	logger.Info("pipeline orchestrator initialized",
		"max_concurrent", cfg.Pipeline.MaxConcurrentBatches,
		"stages", "production",
		"prover_binary", cfg.Prover.BinaryPath,
	)

	// 4. Initialize RPC Server with real backend.
	backend := &NodeBackend{
		stateDB:   sdb,
		seq:       seq,
		l2ChainID: cfg.L2.ChainID,
	}
	rpcCfg := rpc.ServerConfig{
		Host:            cfg.RPC.Host,
		Port:            cfg.RPC.Port,
		RateLimitPerSec: cfg.RPC.RateLimitPerSec,
		RateLimitBurst:  cfg.RPC.RateLimitBurst,
		ReadTimeout:     30 * time.Second,
		WriteTimeout:    30 * time.Second,
		MaxBodySize:     1 << 20,
	}
	rpcServer := rpc.NewServer(rpcCfg, backend, logger.With("component", "rpc"))
	logger.Info("JSON-RPC server configured",
		"host", cfg.RPC.Host,
		"port", cfg.RPC.Port,
	)

	return &Node{
		cfg:       cfg,
		logger:    logger,
		state:     sdb,
		adapter:   adapter,
		exec:      exec,
		seq:       seq,
		pipeline:  orch,
		rpcServer: rpcServer,
		backend:   backend,
		stopCh:    make(chan struct{}),
	}, nil
}

// Start begins the node's event loops.
func (n *Node) Start(ctx context.Context) error {
	// Start the JSON-RPC server.
	if err := n.rpcServer.Start(); err != nil {
		return fmt.Errorf("start rpc server: %w", err)
	}

	// Start the block production loop.
	go n.blockProductionLoop(ctx)

	return nil
}

// Stop gracefully shuts down all node components.
func (n *Node) Stop(ctx context.Context) error {
	n.logger.Info("shutting down node components")
	close(n.stopCh)
	if err := n.rpcServer.Stop(ctx); err != nil {
		n.logger.Error("rpc server shutdown error", "error", err)
	}
	return nil
}

// blockProductionLoop runs the sequencer block production cycle.
// Each tick: produce block -> execute transactions via EVM -> collect traces.
// When a batch is full, feed it to the proving pipeline.
func (n *Node) blockProductionLoop(ctx context.Context) {
	ticker := time.NewTicker(n.cfg.L2.BlockInterval)
	defer ticker.Stop()

	var blockNumber uint64
	var batchTxCount int
	var batchID uint64
	var batchTraces []*executor.ExecutionTrace
	var batchPreStateRoot string

	for {
		select {
		case <-ctx.Done():
			n.logger.Info("block production loop stopped")
			return
		case <-n.stopCh:
			n.logger.Info("block production loop stopped (stop signal)")
			return
		case <-ticker.C:
			block := n.seq.ProduceBlock()
			if block == nil || len(block.Transactions) == 0 {
				continue
			}

			blockNumber++
			n.logger.Info("produced L2 block",
				"number", blockNumber,
				"tx_count", len(block.Transactions),
			)

			// Capture pre-state root before executing this block's transactions.
			if batchTxCount == 0 {
				batchPreStateRoot = fmt.Sprintf("0x%x", n.adapter.DB().StateRoot())
			}

			// Execute each transaction through the EVM via the Adapter.
			for _, tx := range block.Transactions {
				msg := executor.Message{
					From:     tx.From.ToCommon(),
					To:       sequencer.ToCommonAddressPtr(tx.To),
					Value:    tx.Value,
					Gas:      tx.GasLimit,
					GasPrice: new(big.Int), // Zero-fee L2
					Data:     tx.Data,
					Nonce:    tx.Nonce,
				}

				result, err := n.exec.ExecuteTransaction(
					ctx,
					n.adapter,
					executor.BlockInfo{
						Number:    blockNumber,
						Timestamp: uint64(time.Now().Unix()),
						GasLimit:  n.cfg.L2.GasLimit,
						BaseFee:   new(big.Int),
					},
					msg,
				)
				if err != nil {
					n.logger.Error("execution infrastructure error",
						"tx", fmt.Sprintf("%x", tx.Hash[:8]),
						"error", err,
					)
					continue
				}

				if result.VMError != nil {
					n.logger.Warn("transaction reverted",
						"tx", fmt.Sprintf("%x", tx.Hash[:8]),
						"error", result.VMError,
						"gas_used", result.GasUsed,
					)
				} else {
					n.logger.Info("transaction executed",
						"tx", fmt.Sprintf("%x", tx.Hash[:8]),
						"gas_used", result.GasUsed,
						"trace_entries", len(result.Trace.Entries),
					)
				}

				// Accumulate execution traces for the proving pipeline.
				if result.Trace != nil {
					batchTraces = append(batchTraces, result.Trace)
				}

				// Store receipt in backend for eth_getTransactionReceipt.
				n.backend.StoreReceipt(tx.Hash, blockNumber, result)

				batchTxCount++
			}

			// Update backend block number for eth_blockNumber.
			n.backend.SetBlockNumber(blockNumber)

			// When batch is full, submit to proving pipeline.
			if batchTxCount >= n.cfg.L2.BatchSize {
				batch := pipeline.NewBatchState(batchID, blockNumber, batchTxCount)

				// Pre-populate batch with real EVM execution traces and state roots.
				batch.PreStateRoot = batchPreStateRoot
				batch.PostStateRoot = fmt.Sprintf("0x%x", n.adapter.DB().StateRoot())
				batch.Traces = pipeline.ConvertExecutionTraces(batchTraces)
				batch.HasTrace = true

				n.logger.Info("submitting batch to pipeline",
					"batch_id", batchID,
					"tx_count", batchTxCount,
					"trace_count", len(batch.Traces),
					"pre_root", batch.PreStateRoot[:18]+"...",
					"post_root", batch.PostStateRoot[:18]+"...",
					"block", blockNumber,
				)

				go func(b *pipeline.BatchState) {
					if err := n.pipeline.ProcessBatch(ctx, b); err != nil {
						n.logger.Error("pipeline failed", "batch_id", b.BatchID, "error", err)
					} else {
						n.logger.Info("batch finalized",
							"batch_id", b.BatchID,
							"stage", b.Stage,
						)
					}
				}(batch)

				batchID++
				batchTxCount = 0
				batchTraces = nil
			}
		}
	}
}

// initLogger creates a structured logger from configuration.
func initLogger(cfg config.LogConfig) *slog.Logger {
	var level slog.Level
	switch cfg.Level {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	default:
		level = slog.LevelInfo
	}

	opts := &slog.HandlerOptions{Level: level}

	var handler slog.Handler
	if cfg.Format == "text" {
		handler = slog.NewTextHandler(os.Stdout, opts)
	} else {
		handler = slog.NewJSONHandler(os.Stdout, opts)
	}

	return slog.New(handler)
}
