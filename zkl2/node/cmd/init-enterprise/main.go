// init-enterprise initializes the submitter enterprise on BasisRollup.sol.
// Usage: go run ./cmd/init-enterprise/
//
// Environment variables:
//   L1_RPC_URL       - RPC URL of the Basis Network L1 (default: https://rpc.basisnetwork.com.co/ext/bc/2VtYqDeZ5RabHM8zA4x94T6DMdzs3svkfcpF7TLEmTpETUTufR/rpc)
//   L1_PRIVATE_KEY   - Private key of the admin account (required)
//   BASIS_ROLLUP     - Address of BasisRollup contract (default: 0x3984a7ab6d7f05A49d11C347b63E7bc7e5c95f49)
//   ENTERPRISE_ADDR  - Enterprise address to initialize (default: same as admin)
package main

import (
	"context"
	"encoding/hex"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"

	"basis-network/zkl2/node/statedb"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/holiman/uint256"
)

const rollupABI = `[
	{
		"inputs":[{"name":"enterprise","type":"address"},{"name":"genesisRoot","type":"bytes32"}],
		"name":"initializeEnterprise",
		"outputs":[],
		"stateMutability":"nonpayable",
		"type":"function"
	},
	{
		"inputs":[{"name":"enterprise","type":"address"}],
		"name":"enterprises",
		"outputs":[
			{"name":"currentRoot","type":"bytes32"},
			{"name":"committedBatches","type":"uint64"},
			{"name":"provenBatches","type":"uint64"},
			{"name":"executedBatches","type":"uint64"},
			{"name":"initialized","type":"bool"},
			{"name":"lastL2Block","type":"uint64"}
		],
		"stateMutability":"view",
		"type":"function"
	}
]`

func main() {
	rpcURL := envOrDefault("L1_RPC_URL", "https://rpc.basisnetwork.com.co/ext/bc/2VtYqDeZ5RabHM8zA4x94T6DMdzs3svkfcpF7TLEmTpETUTufR/rpc")
	privateKeyHex := os.Getenv("L1_PRIVATE_KEY")
	rollupAddr := envOrDefault("BASIS_ROLLUP", "0x3984a7ab6d7f05A49d11C347b63E7bc7e5c95f49")

	if privateKeyHex == "" {
		fmt.Println("ERROR: L1_PRIVATE_KEY environment variable is required")
		fmt.Println("Usage: L1_PRIVATE_KEY=<hex> go run ./cmd/init-enterprise/")
		os.Exit(1)
	}

	// Compute genesis root (same as what the node computes)
	genesisRoot := computeGenesisRoot()
	fmt.Printf("Genesis root: 0x%s\n", hex.EncodeToString(genesisRoot[:]))

	// Connect to L1
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	client, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		fmt.Printf("ERROR: dial L1: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	chainID, err := client.ChainID(ctx)
	if err != nil {
		fmt.Printf("ERROR: get chain ID: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Connected to L1 (chain ID: %s)\n", chainID.String())

	// Parse private key
	pk, err := crypto.HexToECDSA(strings.TrimPrefix(privateKeyHex, "0x"))
	if err != nil {
		fmt.Printf("ERROR: parse private key: %v\n", err)
		os.Exit(1)
	}
	fromAddr := crypto.PubkeyToAddress(pk.PublicKey)
	fmt.Printf("Admin/Submitter: %s\n", fromAddr.Hex())

	enterpriseAddr := fromAddr
	if ea := os.Getenv("ENTERPRISE_ADDR"); ea != "" {
		enterpriseAddr = common.HexToAddress(ea)
	}
	fmt.Printf("Enterprise: %s\n", enterpriseAddr.Hex())

	// Parse ABI
	parsed, err := abi.JSON(strings.NewReader(rollupABI))
	if err != nil {
		fmt.Printf("ERROR: parse ABI: %v\n", err)
		os.Exit(1)
	}

	contract := bind.NewBoundContract(common.HexToAddress(rollupAddr), parsed, client, client, client)

	// Check if already initialized
	var result []interface{}
	err = contract.Call(&bind.CallOpts{Context: ctx}, &result, "enterprises", enterpriseAddr)
	if err != nil {
		fmt.Printf("ERROR: query enterprises: %v\n", err)
		os.Exit(1)
	}

	if len(result) >= 5 {
		initialized, ok := result[4].(bool)
		if ok && initialized {
			currentRoot := result[0].([32]byte)
			fmt.Printf("\nEnterprise is ALREADY initialized!\n")
			fmt.Printf("  currentRoot: 0x%s\n", hex.EncodeToString(currentRoot[:]))
			fmt.Printf("  genesis root: 0x%s\n", hex.EncodeToString(genesisRoot[:]))
			if currentRoot == genesisRoot {
				fmt.Println("  Status: Roots match -- ready for batch submission")
			} else {
				fmt.Println("  Status: Roots DO NOT match -- enterprise was initialized with different root")
				fmt.Println("  If needed, deploy a new BasisRollup contract or revert batches")
			}
			os.Exit(0)
		}
	}

	// Initialize enterprise
	fmt.Printf("\nInitializing enterprise on BasisRollup at %s...\n", rollupAddr)

	auth, err := bind.NewKeyedTransactorWithChainID(pk, chainID)
	if err != nil {
		fmt.Printf("ERROR: create transactor: %v\n", err)
		os.Exit(1)
	}
	auth.Context = ctx
	auth.GasPrice = big.NewInt(1) // Near-zero fee on Basis Network

	tx, err := contract.Transact(auth, "initializeEnterprise", enterpriseAddr, genesisRoot)
	if err != nil {
		fmt.Printf("ERROR: initializeEnterprise tx: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Transaction sent: %s\n", tx.Hash().Hex())

	receipt, err := bind.WaitMined(ctx, client, tx)
	if err != nil {
		fmt.Printf("ERROR: wait for receipt: %v\n", err)
		os.Exit(1)
	}

	if receipt.Status != 1 {
		fmt.Printf("ERROR: transaction reverted (status=0)\n")
		os.Exit(1)
	}

	fmt.Printf("SUCCESS! Enterprise initialized.\n")
	fmt.Printf("  Gas used: %d\n", receipt.GasUsed)
	fmt.Printf("  Block: %d\n", receipt.BlockNumber.Uint64())
	fmt.Printf("  Genesis root: 0x%s\n", hex.EncodeToString(genesisRoot[:]))
}

func computeGenesisRoot() [32]byte {
	sdbCfg := statedb.Config{AccountDepth: 32, StorageDepth: 32}
	sdb := statedb.NewStateDB(sdbCfg)
	adapter := statedb.NewAdapter(sdb)

	genesisAccounts := []struct {
		addr    string
		balance string
	}{
		{"0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC", "1000000000000000000000000"},
		{"0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD", "1000000000000000000000000"},
	}

	for _, ga := range genesisAccounts {
		addr := common.HexToAddress(ga.addr)
		bal, _ := new(big.Int).SetString(ga.balance, 10)
		adapter.CreateAccount(addr)
		uint256Bal, _ := uint256.FromBig(bal)
		adapter.AddBalance(addr, uint256Bal, tracing.BalanceChangeUnspecified)
	}

	root := sdb.StateRoot()
	rootBytes := root.Marshal()
	var result [32]byte
	copy(result[:], rootBytes)
	return result
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
