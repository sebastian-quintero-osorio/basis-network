package cross

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

// L1HubClient submits cross-enterprise settlements to BasisHub.sol on L1.
type L1HubClient struct {
	client     *ethclient.Client
	privateKey *ecdsa.PrivateKey
	fromAddr   common.Address
	hubAddr    common.Address
	hubABI     abi.ABI
	chainID    *big.Int
	logger     *slog.Logger
}

// BasisHub ABI (minimal -- prepareMessage, verifyMessage, settleMessage).
const basisHubABIJSON = `[
	{
		"inputs": [
			{"name":"dest","type":"address"},
			{"name":"commitment","type":"bytes32"},
			{"name":"sourceStateRoot","type":"bytes32"},
			{"name":"a","type":"uint256[2]"},
			{"name":"b","type":"uint256[2][2]"},
			{"name":"c","type":"uint256[2]"},
			{"name":"publicSignals","type":"uint256[]"}
		],
		"name": "prepareMessage",
		"outputs": [{"name":"msgId","type":"bytes32"}],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{"name":"msgId","type":"bytes32"},
			{"name":"currentSourceRoot","type":"bytes32"}
		],
		"name": "verifyMessage",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{"name":"msgId","type":"bytes32"},
			{"name":"currentSourceRoot","type":"bytes32"},
			{"name":"currentDestRoot","type":"bytes32"}
		],
		"name": "settleMessage",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	}
]`

// NewL1HubClient creates a new client for cross-enterprise settlement on L1.
func NewL1HubClient(rpcURL, privateKeyHex, hubAddress string, logger *slog.Logger) (*L1HubClient, error) {
	if logger == nil {
		logger = slog.Default()
	}

	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("l1 hub client: dial %s: %w", rpcURL, err)
	}

	pk, err := crypto.HexToECDSA(strings.TrimPrefix(privateKeyHex, "0x"))
	if err != nil {
		return nil, fmt.Errorf("l1 hub client: parse key: %w", err)
	}

	parsed, err := abi.JSON(strings.NewReader(basisHubABIJSON))
	if err != nil {
		return nil, fmt.Errorf("l1 hub client: parse ABI: %w", err)
	}

	chainID, err := client.ChainID(context.Background())
	if err != nil {
		return nil, fmt.Errorf("l1 hub client: get chain ID: %w", err)
	}

	fromAddr := crypto.PubkeyToAddress(pk.PublicKey)
	logger.Info("L1 hub client initialized",
		"from", fromAddr.Hex(),
		"hub_contract", hubAddress,
		"chain_id", chainID.String(),
	)

	return &L1HubClient{
		client:     client,
		privateKey: pk,
		fromAddr:   fromAddr,
		hubAddr:    common.HexToAddress(hubAddress),
		hubABI:     parsed,
		chainID:    chainID,
		logger:     logger,
	}, nil
}

// PrepareMessage submits a cross-enterprise message to BasisHub.sol on L1.
func (c *L1HubClient) PrepareMessage(
	ctx context.Context,
	dest common.Address,
	commitment, sourceStateRoot common.Hash,
	a [2]*big.Int, b [2][2]*big.Int, cProof [2]*big.Int,
	publicSignals []*big.Int,
) (common.Hash, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return common.Hash{}, fmt.Errorf("create transactor: %w", err)
	}
	auth.Context = ctx
	auth.GasPrice = big.NewInt(1)

	contract := bind.NewBoundContract(c.hubAddr, c.hubABI, c.client, c.client, c.client)
	tx, err := contract.Transact(auth, "prepareMessage", dest, commitment, sourceStateRoot, a, b, cProof, publicSignals)
	if err != nil {
		return common.Hash{}, fmt.Errorf("prepareMessage tx: %w", err)
	}

	receipt, err := bind.WaitMined(ctx, c.client, tx)
	if err != nil {
		return common.Hash{}, fmt.Errorf("prepareMessage receipt: %w", err)
	}
	if receipt.Status != 1 {
		return common.Hash{}, fmt.Errorf("prepareMessage reverted")
	}

	c.logger.Info("cross-enterprise message prepared on L1",
		"dest", dest.Hex(),
		"gas", receipt.GasUsed,
		"tx", tx.Hash().Hex()[:10],
	)
	return tx.Hash(), nil
}

// SettleMessage settles a cross-enterprise message on L1.
func (c *L1HubClient) SettleMessage(ctx context.Context, msgID, sourceRoot, destRoot common.Hash) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return fmt.Errorf("create transactor: %w", err)
	}
	auth.Context = ctx
	auth.GasPrice = big.NewInt(1)

	contract := bind.NewBoundContract(c.hubAddr, c.hubABI, c.client, c.client, c.client)
	tx, err := contract.Transact(auth, "settleMessage", msgID, sourceRoot, destRoot)
	if err != nil {
		return fmt.Errorf("settleMessage tx: %w", err)
	}

	receipt, err := bind.WaitMined(ctx, c.client, tx)
	if err != nil {
		return fmt.Errorf("settleMessage receipt: %w", err)
	}
	if receipt.Status != 1 {
		return fmt.Errorf("settleMessage reverted")
	}

	c.logger.Info("cross-enterprise message settled on L1",
		"msg_id", msgID.Hex()[:18],
		"gas", receipt.GasUsed,
		"tx", tx.Hash().Hex()[:10],
	)
	return nil
}

// Close closes the L1 client connection.
func (c *L1HubClient) Close() {
	c.client.Close()
}
