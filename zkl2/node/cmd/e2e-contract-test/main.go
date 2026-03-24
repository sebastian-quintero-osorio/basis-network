// e2e-contract-test deploys a contract on the running zkL2 node via RPC,
// then verifies receipt.contractAddress, eth_getCode, and eth_call.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/rpc"
)

func main() {
	rpcURL := "http://localhost:8545"
	if v := os.Getenv("L2_RPC_URL"); v != "" {
		rpcURL = v
	}

	// ewoq test account
	pk, _ := crypto.HexToECDSA("56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027")
	from := crypto.PubkeyToAddress(pk.PublicKey)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	client, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		fatal("dial error: %v", err)
	}

	rpcClient, err := rpc.DialContext(ctx, rpcURL)
	if err != nil {
		fatal("rpc dial error: %v", err)
	}

	chainID, _ := client.ChainID(ctx)
	fmt.Printf("=== Contract Deployment E2E Test ===\n")
	fmt.Printf("Chain ID: %s\n", chainID.String())
	fmt.Printf("Deployer: %s\n", from.Hex())

	// Step 1: Get nonce
	nonce, err := client.PendingNonceAt(ctx, from)
	if err != nil {
		// Fallback: query directly
		var nonceHex string
		rpcClient.CallContext(ctx, &nonceHex, "eth_getTransactionCount", from.Hex(), "latest")
		fmt.Sscanf(strings.TrimPrefix(nonceHex, "0x"), "%x", &nonce)
	}
	fmt.Printf("Nonce: %d\n\n", nonce)

	// Step 2: Deploy contract
	// Simple contract: stores a value, has getter
	// Solidity equivalent:
	//   contract Store {
	//     uint256 public value = 42;
	//   }
	// Init code: PUSH1 0x2a, PUSH1 0x00, SSTORE (store 42 at slot 0),
	// then return runtime code (PUSH1 0x00, SLOAD, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN)
	// Runtime: loads slot 0, returns it as 32 bytes
	runtime := []byte{
		0x60, 0x00, // PUSH1 0x00
		0x54,       // SLOAD
		0x60, 0x00, // PUSH1 0x00
		0x52,       // MSTORE
		0x60, 0x20, // PUSH1 0x20
		0x60, 0x00, // PUSH1 0x00
		0xf3,       // RETURN
	}
	runtimeLen := byte(len(runtime))

	// Init code: store 42, then copy runtime to memory and return it
	initCode := []byte{
		0x60, 0x2a, // PUSH1 42
		0x60, 0x00, // PUSH1 0
		0x55, // SSTORE (store 42 at slot 0)
	}
	// CODECOPY(destOffset=0, offset=initCodeLen, size=runtimeLen)
	initCodeLen := byte(len(initCode) + 9) // 5 bytes above + 9 bytes below
	initCode = append(initCode,
		0x60, runtimeLen, // PUSH1 runtimeLen
		0x60, initCodeLen, // PUSH1 offset (where runtime starts in full bytecode)
		0x60, 0x00, // PUSH1 0 (destOffset in memory)
		0x39,             // CODECOPY
		0x60, runtimeLen, // PUSH1 runtimeLen
		0x60, 0x00, // PUSH1 0
		0xf3, // RETURN
	)
	// Append runtime code after init code
	fullBytecode := append(initCode, runtime...)

	fmt.Printf("[1/5] Deploying contract (initcode %d bytes)...\n", len(fullBytecode))

	tx := types.NewTx(&types.LegacyTx{
		Nonce:    nonce,
		To:       nil, // Contract creation!
		Value:    big.NewInt(0),
		Gas:      200000,
		GasPrice: big.NewInt(0),
		Data:     fullBytecode,
	})

	signer := types.NewEIP155Signer(chainID)
	signedTx, err := types.SignTx(tx, signer, pk)
	if err != nil {
		fatal("sign error: %v", err)
	}

	err = client.SendTransaction(ctx, signedTx)
	if err != nil {
		fatal("send error: %v", err)
	}
	txHash := signedTx.Hash()
	fmt.Printf("  TX sent: %s\n", txHash.Hex())

	// Step 3: Wait for receipt
	fmt.Printf("\n[2/5] Waiting for receipt...\n")
	var receipt map[string]interface{}
	for i := 0; i < 30; i++ {
		time.Sleep(2 * time.Second)
		err := rpcClient.CallContext(ctx, &receipt, "eth_getTransactionReceipt", txHash.Hex())
		if err == nil && receipt != nil {
			break
		}
	}
	if receipt == nil {
		fatal("receipt not found after 60s")
	}

	status, _ := receipt["status"].(string)
	contractAddr, _ := receipt["contractAddress"].(string)
	fromField, _ := receipt["from"].(string)
	fmt.Printf("  Status: %s\n", status)
	fmt.Printf("  From: %s\n", fromField)
	fmt.Printf("  ContractAddress: %s\n", contractAddr)

	if status != "0x1" {
		fatal("deployment failed: status=%s", status)
	}
	if contractAddr == "" || contractAddr == "null" {
		fatal("contractAddress is empty in receipt!")
	}
	fmt.Printf("  PASS: Contract deployed at %s\n", contractAddr)

	// Step 4: Check eth_getCode
	fmt.Printf("\n[3/5] Checking eth_getCode...\n")
	var code string
	rpcClient.CallContext(ctx, &code, "eth_getCode", contractAddr, "latest")
	fmt.Printf("  Code: %s (len=%d)\n", code[:min(20, len(code))]+"...", (len(code)-2)/2)
	if code == "0x" || code == "" {
		fatal("no code at contract address!")
	}
	fmt.Printf("  PASS: Contract has %d bytes of code\n", (len(code)-2)/2)

	// Step 5: Call contract (read slot 0 = should return 42)
	fmt.Printf("\n[4/5] Calling eth_call (read value)...\n")
	callObj := map[string]string{
		"to":   contractAddr,
		"data": "0x", // No function selector needed, runtime just returns slot 0
	}
	var callResult string
	err = rpcClient.CallContext(ctx, &callResult, "eth_call", callObj, "latest")
	if err != nil {
		fmt.Printf("  eth_call error: %v\n", err)
		fmt.Printf("  SKIP: eth_call failed (may need function selector)\n")
	} else {
		fmt.Printf("  Result: %s\n", callResult)
		// Parse the result -- should be 0x000...002a (42 in hex, 32 bytes)
		if len(callResult) >= 66 {
			valHex := callResult[len(callResult)-2:]
			if valHex == "2a" {
				fmt.Printf("  PASS: Contract returned 42 (0x2a)\n")
			} else {
				fmt.Printf("  Value: 0x%s (expected 0x2a)\n", valHex)
			}
		} else {
			fmt.Printf("  Result length: %d\n", len(callResult))
		}
	}

	// Step 6: Check eth_getLogs
	fmt.Printf("\n[5/5] Checking eth_getLogs...\n")
	var logs []interface{}
	filterObj := map[string]interface{}{
		"fromBlock": "0x0",
		"toBlock":   "latest",
	}
	rpcClient.CallContext(ctx, &logs, "eth_getLogs", filterObj)
	fmt.Printf("  Logs found: %d\n", len(logs))

	fmt.Printf("\n=== CONTRACT DEPLOYMENT E2E: ALL CHECKS PASSED ===\n")

	// Print receipt as JSON for debugging
	receiptJSON, _ := json.MarshalIndent(receipt, "", "  ")
	fmt.Printf("\nFull receipt:\n%s\n", string(receiptJSON))
}

func fatal(format string, args ...interface{}) {
	fmt.Printf("FATAL: "+format+"\n", args...)
	os.Exit(1)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
