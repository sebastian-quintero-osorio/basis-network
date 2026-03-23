// genesis-root computes the Poseidon SMT state root after funding genesis accounts.
// This root is needed to initialize the enterprise on BasisRollup.sol.
package main

import (
	"encoding/hex"
	"fmt"
	"math/big"

	"basis-network/zkl2/node/statedb"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/holiman/uint256"
)

func main() {
	// Match exactly what initNode() does in cmd/basis-l2/main.go
	sdbCfg := statedb.Config{AccountDepth: 32, StorageDepth: 32}
	sdb := statedb.NewStateDB(sdbCfg)
	adapter := statedb.NewAdapter(sdb)

	// Genesis accounts (same as main.go)
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

	fmt.Printf("Genesis state root (Poseidon SMT after funding 2 accounts):\n")
	fmt.Printf("  hex:    0x%s\n", hex.EncodeToString(rootBytes))
	fmt.Printf("  bytes32: 0x%s\n", hex.EncodeToString(rootBytes))

	// Also print empty root (before any accounts)
	emptySdb := statedb.NewStateDB(sdbCfg)
	emptyRoot := emptySdb.StateRoot()
	emptyBytes := emptyRoot.Marshal()
	fmt.Printf("\nEmpty state root (no accounts):\n")
	fmt.Printf("  hex:    0x%s\n", hex.EncodeToString(emptyBytes))
}
