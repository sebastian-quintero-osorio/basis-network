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

	"basis-network/zkl2/node/config"
	"basis-network/zkl2/node/pipeline"
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

	// Override log level from flag.
	if *logLevel != "" {
		cfg.Log.Level = *logLevel
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
	cfg      *config.Config
	logger   *slog.Logger
	state    *statedb.StateDB
	seq      *sequencer.Sequencer
	pipeline *pipeline.Orchestrator
	stopCh   chan struct{}
}

// initNode creates and wires all node components.
func initNode(cfg *config.Config, logger *slog.Logger) (*Node, error) {
	// 1. Initialize State Database (Poseidon SMT).
	sdbCfg := statedb.Config{AccountDepth: 32, StorageDepth: 32}
	sdb := statedb.NewStateDB(sdbCfg)
	logger.Info("state database initialized",
		"account_depth", 32,
		"storage_depth", 32,
	)

	// 2. Initialize Sequencer.
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

	// 3. Initialize Pipeline Orchestrator.
	// Currently uses simulated stages. Production stages (real EVM execution,
	// Rust prover IPC, L1 submission) will be plugged in after the Go-Rust
	// bridge and L1 submitter are implemented (POST_ROADMAP_TODO Section 2.2).
	pipelineCfg := pipeline.DefaultPipelineConfig()
	pipelineCfg.MaxConcurrentBatches = cfg.Pipeline.MaxConcurrentBatches
	orch := pipeline.NewOrchestrator(
		pipelineCfg,
		logger.With("component", "pipeline"),
		pipeline.DefaultSimulatedStages(),
	)
	logger.Info("pipeline orchestrator initialized",
		"max_concurrent", cfg.Pipeline.MaxConcurrentBatches,
		"stages", "simulated",
	)

	return &Node{
		cfg:      cfg,
		logger:   logger,
		state:    sdb,
		seq:      seq,
		pipeline: orch,
		stopCh:   make(chan struct{}),
	}, nil
}

// Start begins the node's event loops.
func (n *Node) Start(ctx context.Context) error {
	// Start the block production loop.
	go n.blockProductionLoop(ctx)

	return nil
}

// Stop gracefully shuts down all node components.
func (n *Node) Stop(_ context.Context) error {
	n.logger.Info("shutting down node components")
	close(n.stopCh)
	return nil
}

// blockProductionLoop runs the sequencer block production cycle.
// Produces blocks at the configured interval, executing included transactions.
func (n *Node) blockProductionLoop(ctx context.Context) {
	ticker := time.NewTicker(n.cfg.L2.BlockInterval)
	defer ticker.Stop()

	var blockNumber uint64
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
				continue // No transactions to process
			}

			blockNumber++
			n.logger.Info("produced L2 block",
				"number", blockNumber,
				"tx_count", len(block.Transactions),
				"gas_used", block.GasUsed,
			)
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
