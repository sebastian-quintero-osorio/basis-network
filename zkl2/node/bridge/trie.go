package bridge

import (
	"fmt"
	"math/big"
	"sync"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// WithdrawTrie is a keccak256 binary Merkle tree for L2->L1 withdrawals.
// The leaf encoding matches BasisBridge.sol's claimWithdrawal function:
//
//	leaf = keccak256(abi.encodePacked(enterprise, recipient, amount, withdrawalIndex))
//
// [Spec: zkl2/specs/units/2026-03-bridge/1-formalization/v0-analysis/specs/BasisBridge/BasisBridge.tla]
// [Spec: BasisBridge.tla, FinalizeBatch -- withdraw trie root submitted to L1]
type WithdrawTrie struct {
	mu     sync.RWMutex
	leaves []common.Hash
	depth  int
}

// NewWithdrawTrie creates a new withdraw trie with the given depth.
// Depth determines the maximum number of leaves: 2^depth.
func NewWithdrawTrie(depth int) *WithdrawTrie {
	return &WithdrawTrie{
		depth:  depth,
		leaves: make([]common.Hash, 0),
	}
}

// AppendLeaf adds a withdrawal leaf to the trie and returns its index.
func (wt *WithdrawTrie) AppendLeaf(entry WithdrawTrieEntry) uint64 {
	wt.mu.Lock()
	defer wt.mu.Unlock()

	leaf := ComputeLeafHash(entry)
	index := uint64(len(wt.leaves))
	wt.leaves = append(wt.leaves, leaf)
	return index
}

// Root computes the Merkle root of the trie.
// Returns the zero hash for an empty trie.
func (wt *WithdrawTrie) Root() common.Hash {
	wt.mu.RLock()
	defer wt.mu.RUnlock()

	if len(wt.leaves) == 0 {
		return common.Hash{}
	}

	// Pad leaves to next power of 2
	n := nextPowerOf2(len(wt.leaves))
	nodes := make([]common.Hash, n)
	copy(nodes, wt.leaves)
	// Remaining nodes are already zero-value (common.Hash{})

	// Build tree bottom-up
	for len(nodes) > 1 {
		next := make([]common.Hash, len(nodes)/2)
		for i := 0; i < len(nodes); i += 2 {
			next[i/2] = hashPair(nodes[i], nodes[i+1])
		}
		nodes = next
	}

	return nodes[0]
}

// GenerateProof generates a Merkle proof for the leaf at the given index.
// Returns the sibling hashes from leaf to root.
func (wt *WithdrawTrie) GenerateProof(index uint64) ([]common.Hash, error) {
	wt.mu.RLock()
	defer wt.mu.RUnlock()

	if int(index) >= len(wt.leaves) {
		return nil, fmt.Errorf("%w: index %d, trie has %d leaves",
			ErrTrieIndexOutOfRange, index, len(wt.leaves))
	}

	// Pad leaves to next power of 2
	n := nextPowerOf2(len(wt.leaves))
	nodes := make([]common.Hash, n)
	copy(nodes, wt.leaves)

	proof := make([]common.Hash, 0)
	idx := index

	// Build proof from leaf to root
	for len(nodes) > 1 {
		// Sibling index
		var sibling uint64
		if idx%2 == 0 {
			sibling = idx + 1
		} else {
			sibling = idx - 1
		}

		if int(sibling) < len(nodes) {
			proof = append(proof, nodes[sibling])
		} else {
			proof = append(proof, common.Hash{})
		}

		// Move up one level
		next := make([]common.Hash, len(nodes)/2)
		for i := 0; i < len(nodes); i += 2 {
			next[i/2] = hashPair(nodes[i], nodes[i+1])
		}
		nodes = next
		idx = idx / 2
	}

	return proof, nil
}

// LeafCount returns the number of leaves in the trie.
func (wt *WithdrawTrie) LeafCount() int {
	wt.mu.RLock()
	defer wt.mu.RUnlock()
	return len(wt.leaves)
}

// Reset clears the trie for reuse with a new batch.
func (wt *WithdrawTrie) Reset() {
	wt.mu.Lock()
	defer wt.mu.Unlock()
	wt.leaves = wt.leaves[:0]
}

// VerifyProof verifies a Merkle proof for a given leaf, index, and root.
// This mirrors BasisBridge.sol's _verifyMerkleProof function exactly.
func VerifyProof(proof []common.Hash, root common.Hash, leaf common.Hash, index uint64) bool {
	computedHash := leaf

	for _, sibling := range proof {
		if index%2 == 0 {
			computedHash = hashPair(computedHash, sibling)
		} else {
			computedHash = hashPair(sibling, computedHash)
		}
		index = index / 2
	}

	return computedHash == root
}

// ComputeLeafHash computes the leaf hash for a withdraw trie entry.
// Matches BasisBridge.sol:
//
//	keccak256(abi.encodePacked(enterprise, recipient, amount, withdrawalIndex))
//
// abi.encodePacked layout:
//
//	[20 bytes enterprise][20 bytes recipient][32 bytes amount][32 bytes index]
//	Total: 104 bytes
func ComputeLeafHash(entry WithdrawTrieEntry) common.Hash {
	buf := make([]byte, 0, 104)
	buf = append(buf, entry.Enterprise.Bytes()...)                              // 20 bytes
	buf = append(buf, entry.Recipient.Bytes()...)                               // 20 bytes
	buf = append(buf, common.LeftPadBytes(entry.Amount.Bytes(), 32)...)         // 32 bytes
	indexBig := new(big.Int).SetUint64(entry.WithdrawalIndex)
	buf = append(buf, common.LeftPadBytes(indexBig.Bytes(), 32)...) // 32 bytes
	return crypto.Keccak256Hash(buf)
}

// ComputeWithdrawalHash computes the nullifier hash for a withdrawal claim.
// Matches BasisBridge.sol:
//
//	keccak256(abi.encodePacked(enterprise, batchId, recipient, amount, withdrawalIndex))
//
// abi.encodePacked layout:
//
//	[20 bytes enterprise][32 bytes batchId][20 bytes recipient][32 bytes amount][32 bytes index]
//	Total: 136 bytes
func ComputeWithdrawalHash(
	enterprise common.Address,
	batchID *big.Int,
	recipient common.Address,
	amount *big.Int,
	withdrawalIndex uint64,
) common.Hash {
	buf := make([]byte, 0, 136)
	buf = append(buf, enterprise.Bytes()...)                                    // 20 bytes
	buf = append(buf, common.LeftPadBytes(batchID.Bytes(), 32)...)              // 32 bytes
	buf = append(buf, recipient.Bytes()...)                                     // 20 bytes
	buf = append(buf, common.LeftPadBytes(amount.Bytes(), 32)...)               // 32 bytes
	indexBig := new(big.Int).SetUint64(withdrawalIndex)
	buf = append(buf, common.LeftPadBytes(indexBig.Bytes(), 32)...) // 32 bytes
	return crypto.Keccak256Hash(buf)
}

// hashPair computes keccak256(left || right) for two 32-byte values.
// Matches BasisBridge.sol Merkle tree construction.
func hashPair(left, right common.Hash) common.Hash {
	buf := make([]byte, 64)
	copy(buf[:32], left.Bytes())
	copy(buf[32:], right.Bytes())
	return crypto.Keccak256Hash(buf)
}

// nextPowerOf2 returns the smallest power of 2 >= n.
func nextPowerOf2(n int) int {
	if n <= 1 {
		return 1
	}
	p := 1
	for p < n {
		p *= 2
	}
	return p
}
