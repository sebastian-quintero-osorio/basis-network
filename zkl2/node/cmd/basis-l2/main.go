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
	"encoding/hex"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/holiman/uint256"

	"basis-network/zkl2/node/config"
	"basis-network/zkl2/node/executor"
	"basis-network/zkl2/node/pipeline"
	"basis-network/zkl2/node/rpc"
	"basis-network/zkl2/node/sequencer"
	"basis-network/zkl2/node/statedb"
	nodesync "basis-network/zkl2/node/sync"

	"basis-network/zkl2/node/bridge"
	"basis-network/zkl2/node/cross"
	"basis-network/zkl2/node/da"
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
	} else {
		// When no config file, apply environment variable overrides to defaults.
		config.ApplyEnvOverrides(cfg)
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
	l1Sync    *nodesync.Synchronizer
	bridge    *bridge.Relayer
	dacServer *da.GRPCServer
	crossHub  *cross.Hub
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
		if err := sdb.SetStore(store); err != nil {
			return nil, fmt.Errorf("load state from store: %w", err)
		}
		acctCount := sdb.AccountCount()
		if acctCount > 0 {
			logger.Info("state loaded from LevelDB",
				"data_dir", cfg.L2.DataDir,
				"accounts", acctCount,
				"state_root", fmt.Sprintf("%v", sdb.StateRoot()),
			)
		} else {
			logger.Info("state database initialized with LevelDB persistence (empty)",
				"data_dir", cfg.L2.DataDir,
			)
		}
	} else {
		logger.Warn("state database initialized (ephemeral, no persistence)")
	}

	// 2. Initialize StateDB Adapter + EVM Executor.
	adapter := statedb.NewAdapter(sdb)

	// Genesis funding: pre-fund known accounts on L2 (like all L2s do).
	// Only fund if state is empty (fresh database or no persistence).
	if sdb.AccountCount() == 0 {
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
		// Persist genesis state.
		if err := sdb.PersistBlock(); err != nil {
			logger.Error("failed to persist genesis state", "error", err)
		}
	} else {
		logger.Info("skipping genesis funding (state loaded from disk)",
			"accounts", sdb.AccountCount(),
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

		// Wire L1Submitter for real on-chain proof submission.
		if cfg.L1.PrivateKey != "" && cfg.Contracts.BasisRollup != "" {
			l1Sub, err := pipeline.NewL1Submitter(
				cfg.L1.RPCURL,
				cfg.L1.PrivateKey,
				cfg.Contracts.BasisRollup,
				logger.With("component", "l1-submitter"),
			)
			if err != nil {
				logger.Warn("L1 submitter not initialized (proofs will not reach L1)",
					"error", err,
				)
			} else {
				prodStages.L1Submitter = l1Sub
				logger.Info("L1 submitter initialized",
					"rollup", cfg.Contracts.BasisRollup,
				)
			}
		}
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
	// Enterprise address is derived from EnterpriseRegistry config.
	// Fallback to deployer address if not set.
	enterpriseAddr := common.HexToAddress(cfg.Contracts.EnterpriseRegistry)
	if enterpriseAddr == (common.Address{}) {
		enterpriseAddr = common.HexToAddress(cfg.Contracts.BasisBridge)
	}
	backend := &NodeBackend{
		stateDB:    sdb,
		adapter:    adapter,
		exec:       exec,
		seq:        seq,
		l2ChainID:  cfg.L2.ChainID,
		enterprise: enterpriseAddr,
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

	// Wire health provider with pipeline stats (L1 sync check wired after l1Sync creation).
	rpcServer.Health().SetPipelineStats(orch.PipelineStats)

	logger.Info("JSON-RPC server configured",
		"host", cfg.RPC.Host,
		"port", cfg.RPC.Port,
		"health_endpoint", "/health",
		"metrics_endpoint", "/metrics",
	)

	// 5. Initialize L1 Synchronizer for forced inclusion and deposit detection.
	syncCfg := nodesync.DefaultConfig()
	syncCfg.L1RPCURL = cfg.L1.RPCURL
	syncCfg.Contracts = nodesync.ContractAddresses{
		BasisRollup:        common.HexToAddress(cfg.Contracts.BasisRollup),
		BasisBridge:        common.HexToAddress(cfg.Contracts.BasisBridge),
		BasisDAC:           common.HexToAddress(cfg.Contracts.BasisDAC),
		EnterpriseRegistry: common.HexToAddress(cfg.Contracts.EnterpriseRegistry),
	}
	l1Sync := nodesync.New(syncCfg, logger.With("component", "l1-sync"))

	// Wire L1 sync health check now that l1Sync is created.
	rpcServer.Health().SetL1SyncCheck(func() bool { return l1Sync.IsRunning() })

	// 6. Initialize Bridge Relayer for L1<->L2 deposits/withdrawals.
	bridgeCfg := bridge.DefaultConfig()
	bridgeCfg.L1RPCURL = cfg.L1.RPCURL
	bridgeCfg.L2RPCURL = fmt.Sprintf("http://%s:%d", cfg.RPC.Host, cfg.RPC.Port)
	bridgeCfg.BridgeAddress = common.HexToAddress(cfg.Contracts.BasisBridge)
	bridgeCfg.RollupAddress = common.HexToAddress(cfg.Contracts.BasisRollup)
	bridgeCfg.Enterprise = enterpriseAddr
	bridgeRelay, err := bridge.New(bridgeCfg, logger.With("component", "bridge"))
	if err != nil {
		logger.Warn("bridge relayer not initialized (non-critical)", "error", err)
		bridgeRelay = nil
	} else {
		// Register deposit handler: credit balance on L2 StateDB
		// Deposit: credit balance on L2
		bridgeRelay.OnDeposit(func(recipient common.Address, amount *big.Int, depositID uint64) error {
			key := statedb.AddressToKey(recipient)
			current := sdb.GetBalance(key)
			newBalance := new(big.Int).Add(current, amount)
			return sdb.SetBalance(key, newBalance)
		})
		// Withdrawal: debit balance on L2
		bridgeRelay.OnWithdrawal(func(sender common.Address, amount *big.Int) error {
			key := statedb.AddressToKey(sender)
			current := sdb.GetBalance(key)
			if current.Cmp(amount) < 0 {
				return fmt.Errorf("insufficient balance: have %s, want %s", current, amount)
			}
			newBalance := new(big.Int).Sub(current, amount)
			return sdb.SetBalance(key, newBalance)
		})
		// Withdraw root: submit to BasisBridge.sol on L1.
		if cfg.L1.PrivateKey != "" && cfg.Contracts.BasisBridge != "" {
			l1Bridge, err := bridge.NewL1BridgeClient(
				cfg.L1.RPCURL, cfg.L1.PrivateKey, cfg.Contracts.BasisBridge,
				logger.With("component", "bridge-l1"),
			)
			if err != nil {
				logger.Warn("L1 bridge client not initialized (withdraw roots will be logged only)",
					"error", err,
				)
				bridgeRelay.OnWithdrawRootSubmit(func(root common.Hash, batchID uint64) error {
					logger.Info("withdraw root ready (no L1 client)", "root", root.Hex(), "batch_id", batchID)
					return nil
				})
			} else {
				bridgeRelay.OnWithdrawRootSubmit(func(root common.Hash, batchID uint64) error {
					return l1Bridge.SubmitWithdrawRoot(context.Background(), enterpriseAddr, batchID, root)
				})
			}
		} else {
			bridgeRelay.OnWithdrawRootSubmit(func(root common.Hash, batchID uint64) error {
				logger.Info("withdraw root ready (no L1 config)", "root", root.Hex(), "batch_id", batchID)
				return nil
			})
		}
		logger.Info("bridge relayer initialized with deposit/withdrawal handlers",
			"bridge_contract", cfg.Contracts.BasisBridge,
		)
		rpcServer.Health().SetBridgeEnabled(true)
		// Wire bridge to RPC backend for basis_initiateWithdrawal.
		backend.bridge = bridgeRelay
	}

	// 7. Initialize DAC server (optional, when DAC_ENABLED=true).
	var dacServer *da.GRPCServer
	if cfg.DAC.Enabled {
		dacListenAddr := cfg.DAC.ListenAddr
		if dacListenAddr == "" {
			dacListenAddr = "0.0.0.0:50051"
		}
		// Generate an ECDSA key for DAC attestation signing.
		dacKey, err := crypto.GenerateKey()
		if err != nil {
			return nil, fmt.Errorf("generate DAC key: %w", err)
		}
		dacGRPCConfig := da.GRPCServerConfig{
			ListenAddr: dacListenAddr,
			NodeID:     da.NodeID(0),
			PrivateKey: dacKey,
		}
		dacServer, err = da.NewGRPCServer(dacGRPCConfig, logger.With("component", "dac"))
		if err != nil {
			logger.Warn("DAC gRPC server not initialized (non-critical)", "error", err)
			dacServer = nil
		} else {
			logger.Info("DAC gRPC server initialized",
				"listen_addr", dacListenAddr,
				"threshold", cfg.DAC.Threshold,
				"committee_size", cfg.DAC.CommitteeSize,
			)
		}
	} else {
		logger.Info("DAC disabled (set DAC_ENABLED=true to enable)")
	}

	// 8. Initialize Cross-Enterprise Hub (optional, when hub contract is configured).
	var crossHub *cross.Hub
	if cfg.Contracts.BasisHub != "" {
		crossCfg := cross.DefaultConfig()
		// Simple in-memory enterprise registry that accepts all registered enterprises.
		registry := &localEnterpriseRegistry{
			registered: map[common.Address]bool{
				common.HexToAddress(cfg.Contracts.EnterpriseRegistry): true,
			},
		}
		crossHub, err = cross.NewHub(crossCfg, registry, logger.With("component", "cross-hub"))
		if err != nil {
			logger.Warn("cross-enterprise hub not initialized (non-critical)", "error", err)
			crossHub = nil
		} else {
			logger.Info("cross-enterprise hub initialized",
				"hub_contract", cfg.Contracts.BasisHub,
				"timeout_blocks", crossCfg.TimeoutBlocks,
			)
		}
	}

	// Register L1 synchronizer event handlers
	l1Sync.OnEvent(nodesync.EventForcedInclusion, func(event nodesync.L1Event) {
		logger.Info("forced inclusion received from L1",
			"block", event.BlockNumber,
			"tx", event.TxHash.Hex()[:10],
		)
		// Forward to sequencer forced inclusion queue
		if data, ok := event.Data.(nodesync.ForcedInclusionData); ok {
			logger.Info("forced tx data",
				"enterprise", data.Enterprise.Hex(),
				"data_len", len(data.TxData),
			)
		}
	})
	l1Sync.OnEvent(nodesync.EventDeposit, func(event nodesync.L1Event) {
		logger.Info("deposit detected on L1",
			"block", event.BlockNumber,
			"tx", event.TxHash.Hex()[:10],
		)
		// Forward to bridge relayer to credit on L2
		if bridgeRelay != nil {
			if data, ok := event.Data.(nodesync.DepositData); ok {
				_ = bridgeRelay.ProcessDeposit(bridge.DepositEvent{
					Enterprise:  bridgeCfg.Enterprise,
					Depositor:   data.From,
					L2Recipient: data.To,
					Amount:      data.Amount,
					DepositID:   data.Nonce,
					L1TxHash:    event.TxHash,
					L1Block:     event.BlockNumber,
				})
			}
		}
	})
	logger.Info("L1 synchronizer initialized",
		"rpc", cfg.L1.RPCURL,
		"rollup", cfg.Contracts.BasisRollup,
		"bridge", cfg.Contracts.BasisBridge,
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
		l1Sync:    l1Sync,
		bridge:    bridgeRelay,
		dacServer: dacServer,
		crossHub:  crossHub,
		stopCh:    make(chan struct{}),
	}, nil
}

// Start begins the node's event loops.
func (n *Node) Start(ctx context.Context) error {
	// Start the JSON-RPC server.
	if err := n.rpcServer.Start(); err != nil {
		return fmt.Errorf("start rpc server: %w", err)
	}

	// Start the L1 synchronizer (polls for forced inclusion and deposits).
	if err := n.l1Sync.Start(ctx); err != nil {
		return fmt.Errorf("start l1 sync: %w", err)
	}

	// Start the bridge relayer (processes deposits and withdrawals).
	if n.bridge != nil {
		if err := n.bridge.Start(); err != nil {
			return fmt.Errorf("start bridge relayer: %w", err)
		}
	}

	// Start the DAC gRPC server.
	if n.dacServer != nil {
		if err := n.dacServer.Start(); err != nil {
			return fmt.Errorf("start DAC server: %w", err)
		}
	}

	// Start the block production loop.
	go n.blockProductionLoop(ctx)

	return nil
}

// Stop gracefully shuts down all node components.
// It first signals the block production loop to stop, then waits for in-flight
// pipeline batches to complete before shutting down other components.
func (n *Node) Stop(ctx context.Context) error {
	n.logger.Info("shutting down node components")

	// Signal block production to stop (no new batches).
	close(n.stopCh)

	// Wait for in-flight pipeline batches to drain (up to 60s).
	drainCtx, drainCancel := context.WithTimeout(ctx, 60*time.Second)
	defer drainCancel()
	remaining := n.pipeline.DrainAndWait(drainCtx)
	if len(remaining) > 0 {
		n.logger.Warn("pipeline drain timeout, batches still in-flight",
			"remaining_batches", len(remaining),
		)
	} else {
		n.logger.Info("pipeline drained successfully")
	}

	n.l1Sync.Stop()
	if n.bridge != nil {
		n.bridge.Stop()
	}
	if n.dacServer != nil {
		n.dacServer.Stop()
	}
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

	// Aggregation tracking: collect finalized batches for ProtoGalaxy folding.
	var finalizedBatches []*pipeline.BatchState
	var finalizedBatchesMu sync.Mutex

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
				func() { r := n.adapter.DB().StateRoot(); batchPreStateRoot = "0x" + hex.EncodeToString(r.Marshal()) }()
			}

			// Execute each transaction through the EVM via the Adapter.
			// Lock adapter to prevent concurrent access from eth_call/eth_estimateGas.
			n.backend.AdapterMu.Lock()
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
				n.backend.StoreReceipt(tx.Hash, blockNumber, tx.From.ToCommon(), sequencer.ToCommonAddressPtr(tx.To), result)

				batchTxCount++
			}

			n.backend.AdapterMu.Unlock()

			// Store block data for eth_getBlockByNumber.
			if len(block.Transactions) > 0 {
				txHashes := make([]string, len(block.Transactions))
				for i, tx := range block.Transactions {
					txHashes[i] = fmt.Sprintf("0x%x", tx.Hash)
				}
				blockHash := crypto.Keccak256Hash(
					[]byte(fmt.Sprintf("%d:%d", blockNumber, time.Now().UnixNano())),
				)
				n.backend.StoreBlock(&StoredBlock{
					Number:    blockNumber,
					Hash:      blockHash,
					Timestamp: uint64(time.Now().Unix()),
					GasUsed:   0, // Individual tx gas tracked in receipts
					TxHashes:  txHashes,
				})
			}

			// Collect logs from adapter for eth_getLogs indexing.
			adapterLogs := n.adapter.GetLogs()
			if len(adapterLogs) > 0 {
				var logEntries []map[string]interface{}
				for i, l := range adapterLogs {
					topics := make([]string, len(l.Topics))
					for j, t := range l.Topics {
						topics[j] = t.Hex()
					}
					logEntries = append(logEntries, map[string]interface{}{
						"address":          l.Address.Hex(),
						"topics":           topics,
						"data":             fmt.Sprintf("0x%x", l.Data),
						"blockNumber":      fmt.Sprintf("0x%x", blockNumber),
						"transactionHash":  "0x0",
						"transactionIndex": "0x0",
						"blockHash":        common.Hash{}.Hex(),
						"logIndex":         fmt.Sprintf("0x%x", i),
						"removed":          false,
					})
				}
				n.backend.StoreLogs(blockNumber, logEntries)
			}

			// Update backend block number for eth_blockNumber.
			n.backend.SetBlockNumber(blockNumber)

			// Persist state to LevelDB after each block with transactions.
			if len(block.Transactions) > 0 {
				if err := n.adapter.DB().PersistBlock(); err != nil {
					n.logger.Error("failed to persist block state", "block", blockNumber, "error", err)
				}
			}

			// When batch is full, submit to proving pipeline.
			if batchTxCount >= n.cfg.L2.BatchSize {
				batch := pipeline.NewBatchState(batchID, blockNumber, batchTxCount)

				// Pre-populate batch with real EVM execution traces and state roots.
				batch.PreStateRoot = batchPreStateRoot
				func() { r := n.adapter.DB().StateRoot(); batch.PostStateRoot = "0x" + hex.EncodeToString(r.Marshal()) }()
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

						// Update bridge relayer batch ID for withdraw root submission.
						if n.bridge != nil {
							n.bridge.SetBatchID(b.BatchID)
						}

						// Update cross-enterprise hub with new state root after finalization.
						if n.crossHub != nil && b.PostStateRoot != "" {
							var root [32]byte
							rootBytes, _ := hex.DecodeString(b.PostStateRoot[2:])
							copy(root[:], rootBytes)
							enterprise := common.HexToAddress(n.cfg.Contracts.EnterpriseRegistry)
							n.crossHub.SetStateRoot(enterprise, root)
						}
						// Track finalized batch for aggregation.
						finalizedBatchesMu.Lock()
						finalizedBatches = append(finalizedBatches, b)
						count := len(finalizedBatches)
						finalizedBatchesMu.Unlock()

						// Trigger aggregation after every 4 finalized batches.
						if count >= 4 && count%4 == 0 {
							finalizedBatchesMu.Lock()
							toAggregate := make([]*pipeline.BatchState, len(finalizedBatches))
							copy(toAggregate, finalizedBatches)
							finalizedBatchesMu.Unlock()

							go func() {
								result, err := n.pipeline.Stages().Aggregate(ctx, toAggregate)
								if err != nil {
									n.logger.Warn("aggregation failed (non-critical)", "error", err)
								} else {
									n.logger.Info("proof aggregation complete",
										"instances", result.InstanceCount,
										"satisfiable", result.IsSatisfiable,
										"gas_estimate", result.EstimatedGas,
									)
								}
							}()
						}
					}
				}(batch)

				batchID++
				batchTxCount = 0
				batchTraces = nil
			}
		}
	}
}

// localEnterpriseRegistry is a simple in-memory enterprise registry.
// In production, this reads from L1's IEnterpriseRegistry.isAuthorized().
type localEnterpriseRegistry struct {
	registered map[common.Address]bool
}

func (r *localEnterpriseRegistry) IsRegistered(enterprise common.Address) bool {
	return r.registered[enterprise]
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
