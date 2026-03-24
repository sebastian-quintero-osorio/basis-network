package da

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

// L1DACClient submits DAC certificates to BasisDAC.sol on L1.
type L1DACClient struct {
	client     *ethclient.Client
	privateKey *ecdsa.PrivateKey
	fromAddr   common.Address
	dacAddr    common.Address
	dacABI     abi.ABI
	chainID    *big.Int
	logger     *slog.Logger
}

// BasisDAC ABI (minimal -- only submitCertificate).
const basisDACABIJSON = `[
	{
		"inputs": [
			{"name":"batchId","type":"uint64"},
			{"name":"dataHash","type":"bytes32"},
			{"name":"signatures","type":"bytes[]"},
			{"name":"signers","type":"address[]"}
		],
		"name": "submitCertificate",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	}
]`

// NewL1DACClient creates a new client for submitting DAC certificates to L1.
func NewL1DACClient(rpcURL, privateKeyHex, dacAddress string, logger *slog.Logger) (*L1DACClient, error) {
	if logger == nil {
		logger = slog.Default()
	}

	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("l1 dac client: dial %s: %w", rpcURL, err)
	}

	pk, err := crypto.HexToECDSA(strings.TrimPrefix(privateKeyHex, "0x"))
	if err != nil {
		return nil, fmt.Errorf("l1 dac client: parse key: %w", err)
	}

	parsed, err := abi.JSON(strings.NewReader(basisDACABIJSON))
	if err != nil {
		return nil, fmt.Errorf("l1 dac client: parse ABI: %w", err)
	}

	chainID, err := client.ChainID(context.Background())
	if err != nil {
		return nil, fmt.Errorf("l1 dac client: get chain ID: %w", err)
	}

	fromAddr := crypto.PubkeyToAddress(pk.PublicKey)
	logger.Info("L1 DAC client initialized",
		"from", fromAddr.Hex(),
		"dac_contract", dacAddress,
		"chain_id", chainID.String(),
	)

	return &L1DACClient{
		client:     client,
		privateKey: pk,
		fromAddr:   fromAddr,
		dacAddr:    common.HexToAddress(dacAddress),
		dacABI:     parsed,
		chainID:    chainID,
		logger:     logger,
	}, nil
}

// SubmitCertificate submits a DAC certificate to BasisDAC.sol on L1.
func (c *L1DACClient) SubmitCertificate(ctx context.Context, batchID uint64, dataHash common.Hash, signatures [][]byte, signers []common.Address) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return fmt.Errorf("create transactor: %w", err)
	}
	auth.Context = ctx
	auth.GasPrice = big.NewInt(1)

	contract := bind.NewBoundContract(c.dacAddr, c.dacABI, c.client, c.client, c.client)
	tx, err := contract.Transact(auth, "submitCertificate", batchID, dataHash, signatures, signers)
	if err != nil {
		return fmt.Errorf("submitCertificate tx: %w", err)
	}

	receipt, err := bind.WaitMined(ctx, c.client, tx)
	if err != nil {
		return fmt.Errorf("submitCertificate receipt: %w", err)
	}
	if receipt.Status != 1 {
		return fmt.Errorf("submitCertificate reverted")
	}

	c.logger.Info("DAC certificate submitted to L1",
		"batch_id", batchID,
		"data_hash", dataHash.Hex()[:18],
		"signers", len(signers),
		"gas", receipt.GasUsed,
		"tx", tx.Hash().Hex()[:10],
	)
	return nil
}

// Close closes the L1 client connection.
func (c *L1DACClient) Close() {
	c.client.Close()
}
