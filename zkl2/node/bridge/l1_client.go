package bridge

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"log/slog"
)

// L1BridgeClient submits withdraw roots to BasisBridge.sol on L1.
type L1BridgeClient struct {
	client     *ethclient.Client
	privateKey *ecdsa.PrivateKey
	fromAddr   common.Address
	bridgeAddr common.Address
	bridgeABI  abi.ABI
	chainID    *big.Int
	logger     *slog.Logger
}

// BasisBridge ABI (minimal -- only submitWithdrawRoot).
const basisBridgeABIJSON = `[
	{
		"inputs": [
			{"name":"enterprise","type":"address"},
			{"name":"batchId","type":"uint256"},
			{"name":"withdrawRoot","type":"bytes32"}
		],
		"name": "submitWithdrawRoot",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	}
]`

// NewL1BridgeClient creates a new client for submitting withdraw roots to L1.
func NewL1BridgeClient(rpcURL, privateKeyHex, bridgeAddress string, logger *slog.Logger) (*L1BridgeClient, error) {
	if logger == nil {
		logger = slog.Default()
	}

	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("l1 bridge client: dial %s: %w", rpcURL, err)
	}

	pk, err := crypto.HexToECDSA(strings.TrimPrefix(privateKeyHex, "0x"))
	if err != nil {
		return nil, fmt.Errorf("l1 bridge client: parse key: %w", err)
	}

	parsed, err := abi.JSON(strings.NewReader(basisBridgeABIJSON))
	if err != nil {
		return nil, fmt.Errorf("l1 bridge client: parse ABI: %w", err)
	}

	chainID, err := client.ChainID(context.Background())
	if err != nil {
		return nil, fmt.Errorf("l1 bridge client: get chain ID: %w", err)
	}

	fromAddr := crypto.PubkeyToAddress(pk.PublicKey)
	logger.Info("L1 bridge client initialized",
		"from", fromAddr.Hex(),
		"bridge", bridgeAddress,
		"chain_id", chainID.String(),
	)

	return &L1BridgeClient{
		client:     client,
		privateKey: pk,
		fromAddr:   fromAddr,
		bridgeAddr: common.HexToAddress(bridgeAddress),
		bridgeABI:  parsed,
		chainID:    chainID,
		logger:     logger,
	}, nil
}

// SubmitWithdrawRoot submits a withdraw trie root to BasisBridge.sol on L1.
func (c *L1BridgeClient) SubmitWithdrawRoot(ctx context.Context, enterprise common.Address, batchID uint64, root common.Hash) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return fmt.Errorf("create transactor: %w", err)
	}
	auth.Context = ctx
	auth.GasPrice = big.NewInt(1)

	contract := bind.NewBoundContract(c.bridgeAddr, c.bridgeABI, c.client, c.client, c.client)
	tx, err := contract.Transact(auth, "submitWithdrawRoot", enterprise, new(big.Int).SetUint64(batchID), root)
	if err != nil {
		return fmt.Errorf("submitWithdrawRoot tx: %w", err)
	}

	receipt, err := bind.WaitMined(ctx, c.client, tx)
	if err != nil {
		return fmt.Errorf("submitWithdrawRoot receipt: %w", err)
	}
	if receipt.Status != 1 {
		return fmt.Errorf("submitWithdrawRoot reverted")
	}

	c.logger.Info("withdraw root submitted to L1",
		"enterprise", enterprise.Hex(),
		"batch_id", batchID,
		"root", root.Hex(),
		"gas", receipt.GasUsed,
		"tx", tx.Hash().Hex()[:10],
	)
	return nil
}

// Close closes the L1 client connection.
func (c *L1BridgeClient) Close() {
	c.client.Close()
}
