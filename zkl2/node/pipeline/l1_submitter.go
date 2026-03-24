package pipeline

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"log/slog"
	"math/big"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

// L1Submitter handles submitting ZK proofs to BasisRollup.sol on the Basis Network L1.
//
// The submission is a 3-phase atomic operation:
//   1. commitBatch: register the batch with state root and block range
//   2. proveBatch: submit the ZK proof for verification
//   3. executeBatch: finalize the batch and update the on-chain state root
//
// [Spec: SubmitSuccess in E2EPipeline.tla -- proofOnL1' = TRUE]
type L1Submitter struct {
	client     *ethclient.Client
	privateKey *ecdsa.PrivateKey
	fromAddr   common.Address
	rollupAddr common.Address
	rollupABI  abi.ABI
	chainID    *big.Int
	logger     *slog.Logger
}

// BasisRollup ABI (minimal -- only the methods we call).
const basisRollupABIJSON = `[
	{
		"inputs": [{"components":[
			{"name":"newStateRoot","type":"bytes32"},
			{"name":"l2BlockStart","type":"uint64"},
			{"name":"l2BlockEnd","type":"uint64"},
			{"name":"priorityOpsHash","type":"bytes32"},
			{"name":"timestamp","type":"uint64"}
		],"name":"data","type":"tuple"}],
		"name": "commitBatch",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{"name":"batchId","type":"uint256"},
			{"name":"a","type":"uint256[2]"},
			{"name":"b","type":"uint256[2][2]"},
			{"name":"c","type":"uint256[2]"},
			{"name":"publicSignals","type":"uint256[]"}
		],
		"name": "proveBatch",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{"name":"batchId","type":"uint256"},
			{"name":"proof","type":"bytes"},
			{"name":"publicInputs","type":"uint256[]"}
		],
		"name": "proveBatchV2",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [{"name":"batchId","type":"uint256"}],
		"name": "executeBatch",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [{"name":"enterprise","type":"address"}],
		"name": "enterprises",
		"outputs": [
			{"name":"currentRoot","type":"bytes32"},
			{"name":"committedBatches","type":"uint64"},
			{"name":"provenBatches","type":"uint64"},
			{"name":"executedBatches","type":"uint64"},
			{"name":"initialized","type":"bool"},
			{"name":"lastL2Block","type":"uint64"}
		],
		"stateMutability": "view",
		"type": "function"
	}
]`

// NewL1Submitter creates a new L1 submitter connected to the Basis Network L1.
func NewL1Submitter(rpcURL, privateKeyHex, rollupAddress string, logger *slog.Logger) (*L1Submitter, error) {
	if logger == nil {
		logger = slog.Default()
	}

	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("l1 submitter: dial %s: %w", rpcURL, err)
	}

	privateKey, err := crypto.HexToECDSA(strings.TrimPrefix(privateKeyHex, "0x"))
	if err != nil {
		return nil, fmt.Errorf("l1 submitter: parse private key: %w", err)
	}

	fromAddr := crypto.PubkeyToAddress(privateKey.PublicKey)

	parsed, err := abi.JSON(strings.NewReader(basisRollupABIJSON))
	if err != nil {
		return nil, fmt.Errorf("l1 submitter: parse ABI: %w", err)
	}

	chainID, err := client.ChainID(context.Background())
	if err != nil {
		return nil, fmt.Errorf("l1 submitter: get chain ID: %w", err)
	}

	logger.Info("L1 submitter initialized",
		"rpc", rpcURL,
		"from", fromAddr.Hex(),
		"rollup", rollupAddress,
		"chain_id", chainID.String(),
	)

	return &L1Submitter{
		client:     client,
		privateKey: privateKey,
		fromAddr:   fromAddr,
		rollupAddr: common.HexToAddress(rollupAddress),
		rollupABI:  parsed,
		chainID:    chainID,
		logger:     logger,
	}, nil
}

// PreFlightCheck verifies that the submitter enterprise is initialized on BasisRollup.sol
// and that the on-chain state root matches the batch's pre-state root (chain continuity).
// This prevents sending transactions that will inevitably revert, providing a clear
// error message instead of an obscure on-chain revert.
func (s *L1Submitter) PreFlightCheck(ctx context.Context, preStateRoot string) error {
	contract := bind.NewBoundContract(s.rollupAddr, s.rollupABI, s.client, s.client, s.client)

	var result []interface{}
	err := contract.Call(&bind.CallOpts{Context: ctx}, &result, "enterprises", s.fromAddr)
	if err != nil {
		return fmt.Errorf("pre-flight: query enterprises(%s): %w", s.fromAddr.Hex(), err)
	}

	if len(result) < 5 {
		return fmt.Errorf("pre-flight: unexpected result length %d from enterprises()", len(result))
	}

	currentRoot, ok := result[0].([32]byte)
	if !ok {
		return fmt.Errorf("pre-flight: unexpected currentRoot type %T", result[0])
	}
	initialized, ok := result[4].(bool)
	if !ok {
		return fmt.Errorf("pre-flight: unexpected initialized type %T", result[4])
	}

	if !initialized {
		return fmt.Errorf(
			"pre-flight FAILED: enterprise %s is NOT initialized on BasisRollup %s. "+
				"Call initializeEnterprise(address, genesisRoot) on the rollup contract first",
			s.fromAddr.Hex(), s.rollupAddr.Hex(),
		)
	}

	onChainRoot := common.BytesToHash(currentRoot[:])
	expectedRoot := common.HexToHash(preStateRoot)

	if onChainRoot != expectedRoot {
		s.logger.Warn("pre-flight: state root mismatch (batch may still succeed if this is the first batch)",
			"on_chain_root", onChainRoot.Hex(),
			"batch_pre_state_root", expectedRoot.Hex(),
		)
	}

	s.logger.Info("pre-flight check passed",
		"enterprise", s.fromAddr.Hex(),
		"initialized", true,
		"on_chain_root", onChainRoot.Hex(),
	)
	return nil
}

// SubmitBatch executes the 3-phase L1 submission for a batch.
// Returns the total gas used across all 3 transactions.
func (s *L1Submitter) SubmitBatch(ctx context.Context, batch *BatchState) (uint64, string, error) {
	start := time.Now()
	var totalGas uint64

	// Pre-flight check: verify enterprise is initialized before sending txs.
	if err := s.PreFlightCheck(ctx, batch.PreStateRoot); err != nil {
		return 0, "", fmt.Errorf("l1 submission aborted: %w", err)
	}

	auth, err := bind.NewKeyedTransactorWithChainID(s.privateKey, s.chainID)
	if err != nil {
		return 0, "", fmt.Errorf("create transactor: %w", err)
	}
	auth.Context = ctx
	auth.GasPrice = big.NewInt(1) // Near-zero fee on Basis Network

	contract := bind.NewBoundContract(s.rollupAddr, s.rollupABI, s.client, s.client, s.client)

	// Query on-chain state for idempotent retry support.
	committed, proven, executed, stateErr := s.enterpriseState(ctx)
	if stateErr != nil {
		s.logger.Warn("could not query on-chain state (proceeding anyway)", "error", stateErr)
		committed, proven, executed = 0, 0, 0
	}

	// Phase 1: commitBatch (skip if already committed)
	if committed > batch.BatchID {
		s.logger.Info("L1 commit: batch already committed, skipping",
			"batch_id", batch.BatchID, "on_chain_committed", committed)
	} else {
		s.logger.Info("L1 commit batch", "batch_id", batch.BatchID)
		stateRoot := common.HexToHash(batch.PostStateRoot)
		priorityHash := common.HexToHash("0x0000000000000000000000000000000000000000000000000000000000000000")

		type CommitBatchData struct {
			NewStateRoot    [32]byte
			L2BlockStart    uint64
			L2BlockEnd      uint64
			PriorityOpsHash [32]byte
			Timestamp       uint64
		}
		commitData := CommitBatchData{
			NewStateRoot:    stateRoot,
			L2BlockStart:    batch.BlockNumber,
			L2BlockEnd:      batch.BlockNumber + uint64(batch.TxCount),
			PriorityOpsHash: priorityHash,
			Timestamp:       uint64(time.Now().Unix()),
		}

		commitTx, err := contract.Transact(auth, "commitBatch", commitData)
		if err != nil {
			return 0, "", fmt.Errorf("commitBatch tx: %w", err)
		}
		commitReceipt, err := bind.WaitMined(ctx, s.client, commitTx)
		if err != nil {
			return 0, "", fmt.Errorf("commitBatch receipt: %w", err)
		}
		if commitReceipt.Status != 1 {
			return 0, "", fmt.Errorf("commitBatch reverted")
		}
		totalGas += commitReceipt.GasUsed
		s.logger.Info("L1 commit success", "gas", commitReceipt.GasUsed, "tx", commitTx.Hash().Hex()[:10])
	}

	// Phase 2: proveBatchV2 (skip if already proven)
	batchID := new(big.Int).SetUint64(batch.BatchID)
	if proven > batch.BatchID {
		s.logger.Info("L1 prove: batch already proven, skipping",
			"batch_id", batch.BatchID, "on_chain_proven", proven)
	} else {
		s.logger.Info("L1 prove batch (V2/PLONK)", "batch_id", batch.BatchID,
			"proof_size", len(batch.ProofResult.ProofBytes),
			"public_inputs_size", len(batch.ProofResult.PublicInputs),
		)

		// Use EVM-formatted proof (decompressed G1 points) if available.
		// The generated Halo2Verifier expects uncompressed G1 (64 bytes each),
		// while halo2's create_proof outputs compressed G1 (32 bytes each).
		proofBytes := batch.ProofResult.ProofBytes
		if len(batch.ProofResult.EvmProofBytes) > 0 {
			proofBytes = batch.ProofResult.EvmProofBytes
			s.logger.Info("using EVM-decompressed proof",
				"compressed_size", len(batch.ProofResult.ProofBytes),
				"evm_size", len(proofBytes),
			)
		}
		var publicInputs []*big.Int
		if batch.ProofResult != nil && batch.ProofResult.PublicInputs != nil {
			for i := 0; i+32 <= len(batch.ProofResult.PublicInputs); i += 32 {
				// Public inputs from Rust prover are Fr::to_repr() = little-endian.
				// Solidity expects big-endian uint256. Reverse byte order.
				chunk := batch.ProofResult.PublicInputs[i : i+32]
				beBytes := make([]byte, 32)
				for j := 0; j < 32; j++ {
					beBytes[j] = chunk[31-j]
				}
				publicInputs = append(publicInputs, new(big.Int).SetBytes(beBytes))
			}
		}

		proveTx, err := contract.Transact(auth, "proveBatchV2", batchID, proofBytes, publicInputs)
		if err != nil {
			return totalGas, "", fmt.Errorf("proveBatch tx: %w", err)
		}
		proveReceipt, err := bind.WaitMined(ctx, s.client, proveTx)
		if err != nil {
			return totalGas, "", fmt.Errorf("proveBatch receipt: %w", err)
		}
		if proveReceipt.Status != 1 {
			return totalGas, "", fmt.Errorf("proveBatch reverted")
		}
		totalGas += proveReceipt.GasUsed
		s.logger.Info("L1 prove success", "gas", proveReceipt.GasUsed)
	}

	// Phase 3: executeBatch (skip if already executed)
	if executed > batch.BatchID {
		s.logger.Info("L1 execute: batch already executed, skipping",
			"batch_id", batch.BatchID, "on_chain_executed", executed)
	} else {
		s.logger.Info("L1 execute batch", "batch_id", batch.BatchID)
		execTx, err := contract.Transact(auth, "executeBatch", batchID)
		if err != nil {
			return totalGas, "", fmt.Errorf("executeBatch tx: %w", err)
		}
		execReceipt, err := bind.WaitMined(ctx, s.client, execTx)
		if err != nil {
			return totalGas, "", fmt.Errorf("executeBatch receipt: %w", err)
		}
		if execReceipt.Status != 1 {
			return totalGas, "", fmt.Errorf("executeBatch reverted")
		}
		totalGas += execReceipt.GasUsed
	}

	elapsed := time.Since(start)
	s.logger.Info("L1 batch submitted successfully",
		"batch_id", batch.BatchID,
		"total_gas", totalGas,
		"duration_ms", elapsed.Milliseconds(),
	)

	return totalGas, fmt.Sprintf("batch_%d", batch.BatchID), nil
}

// enterpriseState queries the on-chain state for the submitter's enterprise.
// Returns (committedBatches, provenBatches, executedBatches, error).
func (s *L1Submitter) enterpriseState(ctx context.Context) (uint64, uint64, uint64, error) {
	contract := bind.NewBoundContract(s.rollupAddr, s.rollupABI, s.client, s.client, s.client)
	var result []interface{}
	err := contract.Call(&bind.CallOpts{Context: ctx}, &result, "enterprises", s.fromAddr)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("query enterprises: %w", err)
	}
	// ABI returns: currentRoot, committedBatches, provenBatches, executedBatches, initialized, lastL2Block
	committed := result[1].(uint64)
	proven := result[2].(uint64)
	executed := result[3].(uint64)
	return committed, proven, executed, nil
}

// Close closes the ethclient connection.
func (s *L1Submitter) Close() {
	s.client.Close()
}
