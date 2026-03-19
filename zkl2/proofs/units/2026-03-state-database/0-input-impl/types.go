// Package statedb implements the EVM state database for Basis Network zkEVM L2.
//
// The state database uses a two-level Sparse Merkle Tree (SMT) architecture:
//   - Level 1: Account Trie (address -> account hash)
//   - Level 2: Storage Tries (slot -> value, one per contract)
//
// Hash function: Poseidon2 over BN254 scalar field (gnark-crypto).
//
// Verified invariants (TLC model-checked, 883 states, 0 violations):
//   - ConsistencyInvariant: incremental roots match full tree rebuild
//   - AccountIsolation: all account leaves have valid Merkle proofs
//   - StorageIsolation: all storage slots have valid independent proofs
//   - BalanceConservation: total balance preserved across all transitions
//
// [Spec: zkl2/specs/units/2026-03-state-database/1-formalization/v0-analysis/specs/StateDatabase/StateDatabase.tla]
package statedb

import (
	"encoding/binary"
	"errors"
	"math/big"

	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
)

// TreeKey is a 256-bit key for SMT navigation.
// Account trie: 20-byte address zero-padded to 32 bytes (right-aligned).
// Storage trie: 32-byte storage slot.
//
// [Spec: Addresses, Slots -- leaf indices in the respective tries]
type TreeKey [32]byte

// Bit returns the bit at the given level (0 = LSB) for tree navigation.
// Level 0 selects left/right at the leaf level; level depth-1 at the root's children.
//
// [Spec: PathBit(key, level) == (key \div Pow2(level)) % 2]
func (k TreeKey) Bit(level int) uint {
	byteIdx := 31 - (level / 8)
	bitIdx := uint(level % 8)
	return uint((k[byteIdx] >> bitIdx) & 1)
}

// ToFieldElement converts the tree key to a BN254 field element for hashing.
func (k TreeKey) ToFieldElement() fr.Element {
	var e fr.Element
	e.SetBytes(k[:])
	return e
}

// AddressToKey converts a 20-byte address to a TreeKey.
// The address is right-aligned (big-endian) in the 32-byte key.
func AddressToKey(addr [20]byte) TreeKey {
	var k TreeKey
	copy(k[12:], addr[:])
	return k
}

// SlotToKey converts a 32-byte storage slot to a TreeKey.
func SlotToKey(slot [32]byte) TreeKey {
	return TreeKey(slot)
}

// Uint64ToKey converts a uint64 to a TreeKey (big-endian, right-aligned).
// Useful for testing with small integer keys matching the TLA+ model.
func Uint64ToKey(n uint64) TreeKey {
	var k TreeKey
	binary.BigEndian.PutUint64(k[24:], n)
	return k
}

// BigIntToKey converts a *big.Int to a TreeKey (big-endian, right-aligned).
func BigIntToKey(n *big.Int) TreeKey {
	var k TreeKey
	b := n.Bytes()
	if len(b) > 32 {
		b = b[len(b)-32:]
	}
	copy(k[32-len(b):], b)
	return k
}

// MerkleProof contains the sibling hashes for a Merkle inclusion or non-membership proof.
//
// [Spec: ProofSiblings(e, key, depth) -- sequence of sibling hashes]
// [Spec: PathBitsForKey(key, depth) -- direction bits at each level]
type MerkleProof struct {
	Siblings []fr.Element // One per level, from leaf (level 0) to root (level depth-1)
	Key      TreeKey      // The key being proved
	Value    fr.Element   // The value at the key (zero for non-membership)
	Depth    int          // Tree depth
}

// Config holds configuration for the StateDB.
type Config struct {
	// AccountDepth is the depth of the account trie.
	// Default: 160 (matching 20-byte Ethereum addresses).
	// [Spec: ACCOUNT_DEPTH constant]
	AccountDepth int

	// StorageDepth is the depth of each contract's storage trie.
	// Default: 256 (matching 32-byte storage slots).
	// [Spec: STORAGE_DEPTH constant]
	StorageDepth int
}

// DefaultConfig returns the default StateDB configuration for EVM compatibility.
func DefaultConfig() Config {
	return Config{
		AccountDepth: 160,
		StorageDepth: 256,
	}
}

// Errors for state database operations.
// [Spec: Guards on CreateAccount, Transfer, SetStorage, SelfDestruct actions]
var (
	ErrAccountNotAlive     = errors.New("statedb: account not alive")
	ErrAccountAlreadyAlive = errors.New("statedb: account already alive")
	ErrInsufficientBalance = errors.New("statedb: insufficient balance")
	ErrSelfTransfer        = errors.New("statedb: cannot transfer to self")
	ErrZeroAmount          = errors.New("statedb: transfer amount must be positive")
	ErrSelfDestructToSelf  = errors.New("statedb: cannot self-destruct to self")
)
