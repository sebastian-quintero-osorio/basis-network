package main

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
)

const abiJSON = `[{"inputs":[{"name":"enterprise","type":"address"}],"name":"enterprises","outputs":[{"name":"currentRoot","type":"bytes32"},{"name":"committedBatches","type":"uint64"},{"name":"provenBatches","type":"uint64"},{"name":"executedBatches","type":"uint64"},{"name":"initialized","type":"bool"},{"name":"lastL2Block","type":"uint64"}],"stateMutability":"view","type":"function"}]`

func main() {
	client, err := ethclient.Dial("https://rpc.basisnetwork.com.co/")
	if err != nil {
		fmt.Println("dial error:", err)
		return
	}
	parsed, _ := abi.JSON(strings.NewReader(abiJSON))
	contract := bind.NewBoundContract(common.HexToAddress("0x3984a7ab6d7f05A49d11C347b63E7bc7e5c95f49"), parsed, client, client, client)
	var result []interface{}
	err = contract.Call(&bind.CallOpts{Context: context.Background()}, &result, "enterprises", common.HexToAddress("0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD"))
	if err != nil {
		fmt.Println("call error:", err)
		return
	}
	root := result[0].([32]byte)
	committed := result[1].(uint64)
	proven := result[2].(uint64)
	executed := result[3].(uint64)
	initialized := result[4].(bool)
	lastBlock := result[5].(uint64)
	fmt.Printf("currentRoot:      0x%s\n", hex.EncodeToString(root[:]))
	fmt.Printf("committedBatches: %d\n", committed)
	fmt.Printf("provenBatches:    %d\n", proven)
	fmt.Printf("executedBatches:  %d\n", executed)
	fmt.Printf("initialized:      %v\n", initialized)
	fmt.Printf("lastL2Block:      %d\n", lastBlock)
}
