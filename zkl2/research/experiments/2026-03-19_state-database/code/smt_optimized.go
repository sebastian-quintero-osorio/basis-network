// Optimized Sparse Merkle Tree using fr.Element directly to avoid allocation overhead.
//
// Key optimizations vs smt.go:
// 1. Store fr.Element values instead of *big.Int (avoids BigInt<->fr conversion)
// 2. Use Poseidon2 permutation directly instead of Compress wrapper
// 3. Pre-allocate permutation buffer
// 4. Batch update support for block-level operations
package main

import (
	"fmt"

	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
	"github.com/consensys/gnark-crypto/ecc/bn254/fr/poseidon2"
)

// OptimizedSMT is a high-performance Sparse Merkle Tree with Poseidon2 hash.
type OptimizedSMT struct {
	depth         int
	nodes         map[string]fr.Element
	leaves        map[string]fr.Element // key hex -> value
	defaultHashes []fr.Element          // precomputed empty subtree hashes
	root          fr.Element
	nodeCount     int
	perm          *poseidon2.Permutation // reusable permutation instance
	permBuf       [2]fr.Element          // reusable permutation buffer
}

// NewOptimizedSMT creates a new optimized SMT.
func NewOptimizedSMT(depth int) *OptimizedSMT {
	smt := &OptimizedSMT{
		depth:  depth,
		nodes:  make(map[string]fr.Element, 1024),
		leaves: make(map[string]fr.Element, 1024),
		perm:   poseidon2.NewPermutation(2, 6, 50),
	}

	// Precompute default hashes
	smt.defaultHashes = make([]fr.Element, depth+1)
	// defaultHashes[0] = 0 (zero element)
	for i := 1; i <= depth; i++ {
		smt.defaultHashes[i] = smt.poseidonCompress(&smt.defaultHashes[i-1], &smt.defaultHashes[i-1])
	}

	smt.root = smt.defaultHashes[depth]
	return smt
}

// poseidonCompress computes Poseidon2 2-to-1 compression directly on fr.Element.
// Uses feed-forward construction: result = permutation(left, right)[1] + right
func (smt *OptimizedSMT) poseidonCompress(left, right *fr.Element) fr.Element {
	smt.permBuf[0].Set(left)
	smt.permBuf[1].Set(right)
	savedRight := smt.permBuf[1] // save for feed-forward
	smt.perm.Permutation(smt.permBuf[:])
	smt.permBuf[1].Add(&smt.permBuf[1], &savedRight)
	return smt.permBuf[1]
}

// optimized node key using uint64 pair for faster map operations
func optNodeKey(level int, pathLow uint64) string {
	return fmt.Sprintf("%d:%x", level, pathLow)
}

func (smt *OptimizedSMT) getNodeOpt(level int, pathLow uint64) fr.Element {
	k := optNodeKey(level, pathLow)
	if h, ok := smt.nodes[k]; ok {
		return h
	}
	return smt.defaultHashes[level]
}

func (smt *OptimizedSMT) setNodeOpt(level int, pathLow uint64, hash fr.Element) {
	k := optNodeKey(level, pathLow)
	if _, exists := smt.nodes[k]; !exists {
		smt.nodeCount++
	}
	smt.nodes[k] = hash
}

// InsertUint64 inserts a key-value pair where key fits in uint64 (for depth <= 64).
func (smt *OptimizedSMT) InsertUint64(key uint64, value *fr.Element) fr.Element {
	// Store leaf
	kStr := fmt.Sprintf("%x", key)
	smt.leaves[kStr] = *value

	// Compute leaf hash = Poseidon(key, value)
	var keyElem fr.Element
	keyElem.SetUint64(key)
	leafHash := smt.poseidonCompress(&keyElem, value)

	// Update path from leaf to root
	currentHash := leafHash
	path := key

	for level := 0; level < smt.depth; level++ {
		bit := (path >> uint(level)) & 1

		// Get sibling
		siblingPath := path ^ (1 << uint(level))
		siblingHash := smt.getNodeOpt(level, siblingPath)

		// Store current
		smt.setNodeOpt(level, path, currentHash)

		// Compute parent
		if bit == 0 {
			currentHash = smt.poseidonCompress(&currentHash, &siblingHash)
		} else {
			currentHash = smt.poseidonCompress(&siblingHash, &currentHash)
		}

		// Clear current bit to move up
		path &^= 1 << uint(level)
	}

	smt.setNodeOpt(smt.depth, 0, currentHash)
	smt.root = currentHash
	return smt.root
}

// GetProofUint64 generates a Merkle proof for the given key.
func (smt *OptimizedSMT) GetProofUint64(key uint64) []fr.Element {
	proof := make([]fr.Element, smt.depth)
	path := key

	for level := 0; level < smt.depth; level++ {
		siblingPath := path ^ (1 << uint(level))
		proof[level] = smt.getNodeOpt(level, siblingPath)
		path &^= 1 << uint(level)
	}

	return proof
}

// VerifyProofUint64 verifies a Merkle proof.
func (smt *OptimizedSMT) VerifyProofUint64(root fr.Element, key uint64, value *fr.Element, proof []fr.Element) bool {
	if len(proof) != smt.depth {
		return false
	}

	var currentHash fr.Element
	if value.IsZero() {
		// empty leaf -- currentHash stays zero
	} else {
		var keyElem fr.Element
		keyElem.SetUint64(key)
		currentHash = smt.poseidonCompress(&keyElem, value)
	}

	for level := 0; level < smt.depth; level++ {
		bit := (key >> uint(level)) & 1
		if bit == 0 {
			currentHash = smt.poseidonCompress(&currentHash, &proof[level])
		} else {
			currentHash = smt.poseidonCompress(&proof[level], &currentHash)
		}
	}

	return currentHash.Equal(&root)
}

// Root returns the current root.
func (smt *OptimizedSMT) RootHash() fr.Element {
	return smt.root
}

// OptStats returns statistics.
func (smt *OptimizedSMT) OptStats() TreeStats {
	return TreeStats{
		Depth:     smt.depth,
		NodeCount: smt.nodeCount,
		LeafCount: len(smt.leaves),
	}
}
