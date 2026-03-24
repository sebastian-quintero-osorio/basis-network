// send-tx sends a test transaction to the zkL2 node for E2E pipeline testing.
package main

import (
	"context"
	"fmt"
	"math/big"
	"os"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

func main() {
	rpc := "http://localhost:8545"
	if v := os.Getenv("L2_RPC_URL"); v != "" {
		rpc = v
	}

	// ewoq test account
	pk, _ := crypto.HexToECDSA("56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027")
	from := crypto.PubkeyToAddress(pk.PublicKey)
	to := common.HexToAddress("0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD")

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	client, err := ethclient.DialContext(ctx, rpc)
	if err != nil {
		fmt.Printf("dial error: %v\n", err)
		os.Exit(1)
	}

	chainID, _ := client.ChainID(ctx)
	fmt.Printf("L2 Chain ID: %s\n", chainID.String())
	fmt.Printf("From: %s\n", from.Hex())
	fmt.Printf("To:   %s\n", to.Hex())

	// Create a simple transfer: 0.001 ETH
	value := new(big.Int).Mul(big.NewInt(1e15), big.NewInt(1)) // 0.001 ETH
	tx := types.NewTx(&types.LegacyTx{
		Nonce:    0,
		To:       &to,
		Value:    value,
		Gas:      21000,
		GasPrice: big.NewInt(0),
		Data:     nil,
	})

	signer := types.NewEIP155Signer(chainID)
	signedTx, err := types.SignTx(tx, signer, pk)
	if err != nil {
		fmt.Printf("sign error: %v\n", err)
		os.Exit(1)
	}

	err = client.SendTransaction(ctx, signedTx)
	if err != nil {
		fmt.Printf("send error: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("TX sent: %s\n", signedTx.Hash().Hex())
	fmt.Printf("Value:   %s wei (0.001 ETH)\n", value.String())
	fmt.Println("Waiting for batch pipeline to process...")
}
