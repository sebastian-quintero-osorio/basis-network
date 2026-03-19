package statedb

import (
	"math/big"

	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
)

// Account represents an EVM account in the state database.
//
// The TLA+ specification models accounts with two fields (balance, storageRoot).
// This implementation adds Nonce and CodeHash for EVM compatibility; these fields
// are orthogonal to the verified invariants (ConsistencyInvariant, AccountIsolation,
// StorageIsolation, BalanceConservation).
//
// The Alive flag corresponds to the TLA+ alive[addr] variable. Dead accounts
// map to EMPTY in the account trie.
//
// [Spec: AccountValue(addr) -- account representation in account trie]
// [Spec: alive[addr] -- BOOLEAN existence flag]
// [Spec: balances[addr] -- 0..MaxBalance]
type Account struct {
	Nonce       uint64     // Transaction sequence number
	Balance     *big.Int   // Account balance (not a field element; arbitrary precision for EVM)
	StorageRoot fr.Element // Root hash of the account's storage trie
	CodeHash    fr.Element // Hash of contract bytecode (zero for EOAs)
	Alive       bool       // Whether the account exists (created/deployed)
}

// NewAccount creates a new alive account with zero balance and empty storage.
//
// [Spec: CreateAccount(addr) -- alive' = TRUE, balances' = 0]
func NewAccount() *Account {
	return &Account{
		Nonce:   0,
		Balance: new(big.Int),
		Alive:   true,
	}
}
