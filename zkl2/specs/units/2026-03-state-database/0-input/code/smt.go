// Sparse Merkle Tree implementation in Go with Poseidon hash.
//
// This is a research prototype matching the algorithm from RU-V1 (TypeScript).
// Depth: configurable (default 256 for EVM address space).
// Storage: in-memory map of nodeHash -> {left, right} for internal nodes.
//
// Key design decisions:
// - Binary tree: each internal node has exactly two children
// - Sparse: most leaves are empty (default value = 0)
// - Default subtree hashes are precomputed and cached
// - Keys are paths from root to leaf: bit i of key determines left (0) or right (1) at level i
// - Values are field elements (BN254 scalar field)
package main

import (
	"fmt"
	"math/big"
)

// SparseMerkleTree is a depth-N binary Merkle tree with Poseidon hash.
type SparseMerkleTree struct {
	depth         int
	nodes         map[string]*big.Int // key: "level:path" -> hash
	leaves        map[string]*big.Int // key: keyHex -> value
	defaultHashes []*big.Int          // defaultHashes[i] = hash of empty subtree at level i
	root          *big.Int
	nodeCount     int
}

// NewSparseMerkleTree creates a new SMT with the given depth.
func NewSparseMerkleTree(depth int) *SparseMerkleTree {
	smt := &SparseMerkleTree{
		depth:  depth,
		nodes:  make(map[string]*big.Int),
		leaves: make(map[string]*big.Int),
	}

	// Precompute default hashes for empty subtrees.
	// defaultHashes[0] = 0 (empty leaf)
	// defaultHashes[i] = Poseidon(defaultHashes[i-1], defaultHashes[i-1])
	smt.defaultHashes = make([]*big.Int, depth+1)
	smt.defaultHashes[0] = big.NewInt(0)
	for i := 1; i <= depth; i++ {
		smt.defaultHashes[i] = PoseidonHash(smt.defaultHashes[i-1], smt.defaultHashes[i-1])
	}

	smt.root = smt.defaultHashes[depth]
	return smt
}

// nodeKey creates a unique key for a node at a given level and path.
func nodeKey(level int, path *big.Int) string {
	return fmt.Sprintf("%d:%s", level, path.Text(16))
}

// getBit returns the bit at position pos (0-indexed from MSB for depth-based traversal).
// For a depth-D tree, bit 0 is the most significant bit used for the root level.
func getBit(key *big.Int, pos int) int {
	if key.Bit(pos) == 1 {
		return 1
	}
	return 0
}

// getNode returns the hash stored at (level, path), or the default hash if not present.
func (smt *SparseMerkleTree) getNode(level int, path *big.Int) *big.Int {
	k := nodeKey(level, path)
	if h, ok := smt.nodes[k]; ok {
		return h
	}
	return smt.defaultHashes[level]
}

// setNode stores a hash at (level, path).
func (smt *SparseMerkleTree) setNode(level int, path *big.Int, hash *big.Int) {
	k := nodeKey(level, path)
	if _, exists := smt.nodes[k]; !exists {
		smt.nodeCount++
	}
	smt.nodes[k] = hash
}

// Insert adds or updates a key-value pair in the tree.
// The key is used as the leaf index (path through the tree).
// Returns the new root hash.
func (smt *SparseMerkleTree) Insert(key, value *big.Int) *big.Int {
	// Store the leaf value
	smt.leaves[key.Text(16)] = new(big.Int).Set(value)

	// Hash the leaf value (leaf hash = Poseidon(key, value))
	leafHash := PoseidonHash(key, value)

	// Update path from leaf to root
	currentHash := leafHash
	path := new(big.Int).Set(key)

	for level := 0; level < smt.depth; level++ {
		bit := getBit(key, level)

		// Get sibling hash at this level
		siblingPath := new(big.Int).Set(path)
		siblingPath.SetBit(siblingPath, level, uint(1-bit))

		siblingHash := smt.getNode(level, siblingPath)

		// Store current node
		smt.setNode(level, path, currentHash)

		// Compute parent hash
		// Clear the current level bit to get parent path
		parentPath := new(big.Int).Rsh(path, uint(level+1))
		parentPath.Lsh(parentPath, uint(level+1))

		if bit == 0 {
			currentHash = PoseidonHash(currentHash, siblingHash)
		} else {
			currentHash = PoseidonHash(siblingHash, currentHash)
		}

		// Move path up: clear the current bit
		path.SetBit(path, level, 0)
	}

	smt.setNode(smt.depth, big.NewInt(0), currentHash)
	smt.root = currentHash
	return smt.root
}

// GetProof generates a Merkle proof for the given key.
// Returns an array of sibling hashes (one per level, from leaf to root).
func (smt *SparseMerkleTree) GetProof(key *big.Int) []*big.Int {
	proof := make([]*big.Int, smt.depth)
	path := new(big.Int).Set(key)

	for level := 0; level < smt.depth; level++ {
		bit := getBit(key, level)

		// Get sibling at this level
		siblingPath := new(big.Int).Set(path)
		siblingPath.SetBit(siblingPath, level, uint(1-bit))

		proof[level] = smt.getNode(level, siblingPath)

		// Move up
		path.SetBit(path, level, 0)
	}

	return proof
}

// VerifyProof verifies a Merkle proof for a given key-value pair against a root.
func (smt *SparseMerkleTree) VerifyProof(root, key, value *big.Int, proof []*big.Int) bool {
	if len(proof) != smt.depth {
		return false
	}

	// Compute leaf hash
	var currentHash *big.Int
	if value.Sign() == 0 {
		currentHash = big.NewInt(0) // empty leaf
	} else {
		currentHash = PoseidonHash(key, value)
	}

	// Recompute root from leaf to top
	for level := 0; level < smt.depth; level++ {
		bit := getBit(key, level)
		if bit == 0 {
			currentHash = PoseidonHash(currentHash, proof[level])
		} else {
			currentHash = PoseidonHash(proof[level], currentHash)
		}
	}

	return currentHash.Cmp(root) == 0
}

// GetLeafHash returns the hash of the leaf at the given key.
func (smt *SparseMerkleTree) GetLeafHash(key *big.Int) *big.Int {
	if v, ok := smt.leaves[key.Text(16)]; ok {
		return PoseidonHash(key, v)
	}
	return big.NewInt(0)
}

// Root returns the current root hash.
func (smt *SparseMerkleTree) Root() *big.Int {
	return smt.root
}

// Stats returns tree statistics.
type TreeStats struct {
	Depth     int
	NodeCount int
	LeafCount int
}

func (smt *SparseMerkleTree) Stats() TreeStats {
	return TreeStats{
		Depth:     smt.depth,
		NodeCount: smt.nodeCount,
		LeafCount: len(smt.leaves),
	}
}
