package pipeline

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

// L1AggregatorClient submits aggregated proofs to BasisAggregator.sol on L1.
type L1AggregatorClient struct {
	client         *ethclient.Client
	privateKey     *ecdsa.PrivateKey
	fromAddr       common.Address
	aggregatorAddr common.Address
	aggregatorABI  abi.ABI
	chainID        *big.Int
	logger         *slog.Logger
}

// BasisAggregator ABI (minimal -- only verifyAggregatedProof).
const basisAggregatorABIJSON = `[
	{
		"inputs": [
			{"name":"a","type":"uint256[2]"},
			{"name":"b","type":"uint256[2][2]"},
			{"name":"c","type":"uint256[2]"},
			{"name":"publicSignals","type":"uint256[]"},
			{"name":"enterprises","type":"address[]"},
			{"name":"batchHashes","type":"bytes32[]"}
		],
		"name": "verifyAggregatedProof",
		"outputs": [
			{"name":"aggregationId","type":"uint256"},
			{"name":"valid","type":"bool"}
		],
		"stateMutability": "nonpayable",
		"type": "function"
	}
]`

// NewL1AggregatorClient creates a new client for submitting aggregated proofs to L1.
func NewL1AggregatorClient(rpcURL, privateKeyHex, aggregatorAddress string, logger *slog.Logger) (*L1AggregatorClient, error) {
	if logger == nil {
		logger = slog.Default()
	}

	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("l1 aggregator client: dial %s: %w", rpcURL, err)
	}

	pk, err := crypto.HexToECDSA(strings.TrimPrefix(privateKeyHex, "0x"))
	if err != nil {
		return nil, fmt.Errorf("l1 aggregator client: parse key: %w", err)
	}

	parsed, err := abi.JSON(strings.NewReader(basisAggregatorABIJSON))
	if err != nil {
		return nil, fmt.Errorf("l1 aggregator client: parse ABI: %w", err)
	}

	chainID, err := client.ChainID(context.Background())
	if err != nil {
		return nil, fmt.Errorf("l1 aggregator client: get chain ID: %w", err)
	}

	fromAddr := crypto.PubkeyToAddress(pk.PublicKey)
	logger.Info("L1 aggregator client initialized",
		"from", fromAddr.Hex(),
		"aggregator_contract", aggregatorAddress,
		"chain_id", chainID.String(),
	)

	return &L1AggregatorClient{
		client:         client,
		privateKey:     pk,
		fromAddr:       fromAddr,
		aggregatorAddr: common.HexToAddress(aggregatorAddress),
		aggregatorABI:  parsed,
		chainID:        chainID,
		logger:         logger,
	}, nil
}

// SubmitAggregatedProof submits an aggregated Groth16 decider proof to BasisAggregator.sol.
func (c *L1AggregatorClient) SubmitAggregatedProof(
	ctx context.Context,
	a [2]*big.Int, b [2][2]*big.Int, cProof [2]*big.Int,
	publicSignals []*big.Int,
	enterprises []common.Address,
	batchHashes []common.Hash,
) (uint64, bool, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return 0, false, fmt.Errorf("create transactor: %w", err)
	}
	auth.Context = ctx
	auth.GasPrice = big.NewInt(1)

	contract := bind.NewBoundContract(c.aggregatorAddr, c.aggregatorABI, c.client, c.client, c.client)
	tx, err := contract.Transact(auth, "verifyAggregatedProof", a, b, cProof, publicSignals, enterprises, batchHashes)
	if err != nil {
		return 0, false, fmt.Errorf("verifyAggregatedProof tx: %w", err)
	}

	receipt, err := bind.WaitMined(ctx, c.client, tx)
	if err != nil {
		return 0, false, fmt.Errorf("verifyAggregatedProof receipt: %w", err)
	}
	if receipt.Status != 1 {
		return 0, false, fmt.Errorf("verifyAggregatedProof reverted")
	}

	c.logger.Info("aggregated proof submitted to L1",
		"enterprises", len(enterprises),
		"gas", receipt.GasUsed,
		"tx", tx.Hash().Hex()[:10],
	)
	return 0, true, nil
}

// Close closes the L1 client connection.
func (c *L1AggregatorClient) Close() {
	c.client.Close()
}
