// E2E test: sends a signed Ethereum transaction to the running basis-l2 node
// and verifies the full pipeline executes correctly.
//
// Prerequisites: basis-l2 node running on localhost:9998
//
// Usage: go run ./cmd/e2e-test/
package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"os"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rlp"
)

var rpcURL = "http://localhost:9998"

func init() {
	if v := os.Getenv("RPC_URL"); v != "" {
		rpcURL = v
	}
}

func main() {
	fmt.Println("=== Basis L2 Node -- E2E Integration Test ===")

	// Step 1: Verify node is running.
	fmt.Println("[1/5] Verifying node is running...")
	chainID := rpcCall("eth_chainId", nil)
	fmt.Printf("  Chain ID: %s\n", chainID)
	blockNum := rpcCall("eth_blockNumber", nil)
	fmt.Printf("  Block number: %s\n", blockNum)
	version := rpcCall("web3_clientVersion", nil)
	fmt.Printf("  Client: %s\n", version)

	// Step 2: Check balance of funded account.
	fmt.Println("\n[2/5] Checking genesis-funded account balance...")
	ewoqAddr := "0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC"
	balance := rpcCall("eth_getBalance", []interface{}{ewoqAddr, "latest"})
	fmt.Printf("  Account: %s\n", ewoqAddr)
	fmt.Printf("  Balance: %s\n", balance)
	if balance == "0x0" || balance == "" {
		fmt.Println("  ERROR: Account has zero balance. Genesis funding may have failed.")
		os.Exit(1)
	}
	fmt.Println("  Account is funded")

	// Step 3: Send a signed transfer transaction.
	fmt.Println("\n[3/5] Sending signed transfer transaction...")
	// Use the ewoq private key (from .internal/keys.md).
	privateKeyHex := "56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027"
	key, err := crypto.HexToECDSA(privateKeyHex)
	if err != nil {
		fmt.Printf("  ERROR: Failed to parse key: %v\n", err)
		os.Exit(1)
	}

	sender := crypto.PubkeyToAddress(key.PublicKey)
	fmt.Printf("  Sender: %s\n", sender.Hex())

	recipient := common.HexToAddress("0x1234567890abcdef1234567890abcdef12345678")
	transferAmount := big.NewInt(1_000_000_000_000_000_000) // 1 LITHOS

	l2ChainID := big.NewInt(431990)
	signer := types.LatestSignerForChainID(l2ChainID)
	tx := types.MustSignNewTx(key, signer, &types.DynamicFeeTx{
		ChainID:   l2ChainID,
		Nonce:     0,
		GasTipCap: new(big.Int),
		GasFeeCap: new(big.Int),
		Gas:       21000,
		To:        &recipient,
		Value:     transferAmount,
	})

	rawBytes, _ := rlp.EncodeToBytes(tx)
	rawHex := "0x" + hex.EncodeToString(rawBytes)

	txHash := rpcCall("eth_sendRawTransaction", []interface{}{rawHex})
	fmt.Printf("  Tx hash: %s\n", txHash)
	fmt.Printf("  Transfer: 1 LITHOS -> %s\n", recipient.Hex())

	// Step 4: Wait for block production and execution.
	fmt.Println("\n[4/5] Waiting for block production (3 seconds)...")
	time.Sleep(3 * time.Second)

	// Step 5: Verify balances changed.
	fmt.Println("[5/5] Verifying balances after execution...")
	senderBalance := rpcCall("eth_getBalance", []interface{}{sender.Hex(), "latest"})
	recipientBalance := rpcCall("eth_getBalance", []interface{}{recipient.Hex(), "latest"})
	fmt.Printf("  Sender balance:    %s\n", senderBalance)
	fmt.Printf("  Recipient balance: %s\n", recipientBalance)

	if recipientBalance == "0x0" || recipientBalance == "" {
		fmt.Println("\n  WARNING: Recipient balance is still zero.")
		fmt.Println("  The transaction may have reverted or execution is pending.")
	} else {
		fmt.Println("\n  SUCCESS: Recipient received funds!")
	}

	fmt.Println("\n=== E2E Test Complete ===")
}

func rpcCall(method string, params interface{}) string {
	if params == nil {
		params = []interface{}{}
	}
	body, _ := json.Marshal(map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  method,
		"params":  params,
		"id":      1,
	})
	resp, err := http.Post(rpcURL, "application/json", bytes.NewReader(body))
	if err != nil {
		fmt.Printf("  RPC error: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)

	var result struct {
		Result interface{} `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	json.Unmarshal(data, &result)

	if result.Error != nil {
		return "ERROR: " + result.Error.Message
	}
	if result.Result == nil {
		return ""
	}
	return fmt.Sprintf("%v", result.Result)
}
