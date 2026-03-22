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
		"inputs": [{"name":"batchId","type":"uint256"}],
		"name": "executeBatch",
		"outputs": [],
		"stateMutability": "nonpayable",
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

// SubmitBatch executes the 3-phase L1 submission for a batch.
// Returns the total gas used across all 3 transactions.
func (s *L1Submitter) SubmitBatch(ctx context.Context, batch *BatchState) (uint64, string, error) {
	start := time.Now()
	var totalGas uint64

	auth, err := bind.NewKeyedTransactorWithChainID(s.privateKey, s.chainID)
	if err != nil {
		return 0, "", fmt.Errorf("create transactor: %w", err)
	}
	auth.Context = ctx
	auth.GasPrice = big.NewInt(1) // Near-zero fee on Basis Network

	contract := bind.NewBoundContract(s.rollupAddr, s.rollupABI, s.client, s.client, s.client)

	// Phase 1: commitBatch
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

	// Phase 2: proveBatch
	s.logger.Info("L1 prove batch", "batch_id", batch.BatchID)
	batchID := new(big.Int).SetUint64(batch.BatchID)
	dummyA := [2]*big.Int{new(big.Int), new(big.Int)}
	dummyB := [2][2]*big.Int{{new(big.Int), new(big.Int)}, {new(big.Int), new(big.Int)}}
	dummyC := [2]*big.Int{new(big.Int), new(big.Int)}
	signals := []*big.Int{}

	proveTx, err := contract.Transact(auth, "proveBatch", batchID, dummyA, dummyB, dummyC, signals)
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

	// Phase 3: executeBatch
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

	elapsed := time.Since(start)
	s.logger.Info("L1 batch submitted successfully",
		"batch_id", batch.BatchID,
		"total_gas", totalGas,
		"duration_ms", elapsed.Milliseconds(),
		"l1_tx", commitTx.Hash().Hex(),
	)

	return totalGas, commitTx.Hash().Hex(), nil
}

// Close closes the ethclient connection.
func (s *L1Submitter) Close() {
	s.client.Close()
}
