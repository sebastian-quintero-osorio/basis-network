package statedb

import (
	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
	"github.com/consensys/gnark-crypto/ecc/bn254/fr/poseidon2"
)

// SparseMerkleTree is a depth-N binary Merkle tree with Poseidon2 hash over BN254.
//
// The tree stores field element values indexed by TreeKey. Empty (unoccupied)
// leaves have value zero (EMPTY sentinel). Default subtree hashes are precomputed
// and cached for O(depth) updates and proofs.
//
// Not thread-safe. Callers must synchronize concurrent access externally.
//
// [Spec: StateDatabase.tla -- tree computation, path operations, proof operations]
// [Source: 0-input/code/smt_optimized.go -- OptimizedSMT]
type SparseMerkleTree struct {
	depth         int
	nodes         map[nodeID]fr.Element  // internal node hashes (sparse)
	leaves        map[TreeKey]fr.Element // leaf values (non-empty only)
	defaultHashes []fr.Element           // defaultHashes[i] = hash of empty subtree at level i
	root          fr.Element
	perm          *poseidon2.Permutation // Poseidon2 permutation instance
}

// nodeID uniquely identifies an internal node in the tree.
// At level L, path has bits 0..L-1 cleared (identifying the ancestor node).
type nodeID struct {
	level uint16
	path  TreeKey
}

// NewSparseMerkleTree creates a new empty SMT with the given depth.
// The hash function is Poseidon2 2-to-1 compression over BN254 scalar field.
//
// [Spec: DefaultHash(level) precomputation]
// [Source: 0-input/code/smt.go -- NewSparseMerkleTree]
func NewSparseMerkleTree(depth int) *SparseMerkleTree {
	smt := &SparseMerkleTree{
		depth:  depth,
		nodes:  make(map[nodeID]fr.Element),
		leaves: make(map[TreeKey]fr.Element),
		perm:   poseidon2.NewPermutation(2, 6, 50),
	}

	// Precompute default hashes for empty subtrees.
	// defaultHashes[0] = 0 (empty leaf)
	// defaultHashes[i] = Poseidon(defaultHashes[i-1], defaultHashes[i-1])
	// [Spec: RECURSIVE DefaultHash(_)]
	smt.defaultHashes = make([]fr.Element, depth+1)
	// defaultHashes[0] is already zero (fr.Element zero value)
	for i := 1; i <= depth; i++ {
		smt.defaultHashes[i] = smt.poseidonHash(&smt.defaultHashes[i-1], &smt.defaultHashes[i-1])
	}

	smt.root = smt.defaultHashes[depth]
	return smt
}

// poseidonHash computes Poseidon2 2-to-1 compression over BN254.
// Uses gnark-crypto's Compress method for correctness.
//
// [Spec: Hash(a, b) -- production Poseidon2 replaces algebraic model hash]
// [Source: 0-input/code/poseidon.go -- PoseidonHash using perm.Compress]
func (smt *SparseMerkleTree) poseidonHash(left, right *fr.Element) fr.Element {
	lBytes := left.Marshal()
	rBytes := right.Marshal()
	digest, err := smt.perm.Compress(lBytes, rBytes)
	if err != nil {
		// Poseidon2 compress cannot fail with valid field elements.
		// Panic is justified: this indicates a gnark-crypto bug or memory corruption.
		panic("statedb: poseidon2 compress failed: " + err.Error())
	}
	var result fr.Element
	result.SetBytes(digest)
	return result
}

// Hash computes Poseidon2(left, right) using this tree's permutation instance.
// Public wrapper for use by StateDB and external callers.
func (smt *SparseMerkleTree) Hash(left, right *fr.Element) fr.Element {
	return smt.poseidonHash(left, right)
}

// leafHash computes the hash of a leaf node.
// Empty leaves (value == 0) return zero (EMPTY sentinel).
// Occupied leaves: Poseidon(key, value).
//
// [Spec: LeafHash(key, value) == IF value = EMPTY THEN EMPTY ELSE Hash(key, value)]
func (smt *SparseMerkleTree) leafHash(key TreeKey, value *fr.Element) fr.Element {
	if value.IsZero() {
		return fr.Element{} // EMPTY
	}
	keyElem := key.ToFieldElement()
	return smt.poseidonHash(&keyElem, value)
}

// getNode returns the hash at (level, path), or the default hash if not stored.
func (smt *SparseMerkleTree) getNode(level int, path TreeKey) fr.Element {
	id := nodeID{level: uint16(level), path: path}
	if h, ok := smt.nodes[id]; ok {
		return h
	}
	return smt.defaultHashes[level]
}

// setNode stores a hash at (level, path).
// If the hash equals the default hash for that level, the entry is removed
// to keep the map sparse and memory usage proportional to non-empty leaves.
func (smt *SparseMerkleTree) setNode(level int, path TreeKey, hash fr.Element) {
	id := nodeID{level: uint16(level), path: path}
	if hash == smt.defaultHashes[level] {
		delete(smt.nodes, id)
		return
	}
	smt.nodes[id] = hash
}

// clearBit returns a copy of key with the bit at the given level cleared.
func clearBit(key TreeKey, level int) TreeKey {
	result := key
	byteIdx := 31 - (level / 8)
	bitIdx := uint(level % 8)
	result[byteIdx] &^= 1 << bitIdx
	return result
}

// flipBit returns a copy of key with the bit at the given level flipped.
func flipBit(key TreeKey, level int) TreeKey {
	result := key
	byteIdx := 31 - (level / 8)
	bitIdx := uint(level % 8)
	result[byteIdx] ^= 1 << bitIdx
	return result
}

// Insert adds or updates a key-value pair in the tree.
// If value is zero, the key is deleted (equivalent to setting it to EMPTY).
// Returns the new root hash.
//
// The update is O(depth): only the path from the modified leaf to the root
// is recomputed using sibling hashes from the current tree.
//
// [Spec: WalkUp(oldEntries, currentHash, key, level, depth)]
// [Source: 0-input/code/smt.go -- Insert method]
func (smt *SparseMerkleTree) Insert(key TreeKey, value fr.Element) fr.Element {
	if value.IsZero() {
		return smt.Delete(key)
	}

	smt.leaves[key] = value
	currentHash := smt.leafHash(key, &value)

	// Walk from leaf (level 0) to root (level depth), updating each node.
	path := key
	for level := 0; level < smt.depth; level++ {
		bit := key.Bit(level)
		siblingPath := flipBit(path, level)
		siblingHash := smt.getNode(level, siblingPath)

		smt.setNode(level, path, currentHash)

		if bit == 0 {
			currentHash = smt.poseidonHash(&currentHash, &siblingHash)
		} else {
			currentHash = smt.poseidonHash(&siblingHash, &currentHash)
		}

		path = clearBit(path, level)
	}

	smt.root = currentHash
	return smt.root
}

// Delete removes a key from the tree (sets its value to EMPTY).
// Returns the new root hash.
//
// [Spec: LeafHash(key, EMPTY) = EMPTY; WalkUp with EMPTY leaf hash]
func (smt *SparseMerkleTree) Delete(key TreeKey) fr.Element {
	delete(smt.leaves, key)

	// Empty leaf hash = 0 (EMPTY)
	var currentHash fr.Element

	path := key
	for level := 0; level < smt.depth; level++ {
		bit := key.Bit(level)
		siblingPath := flipBit(path, level)
		siblingHash := smt.getNode(level, siblingPath)

		smt.setNode(level, path, currentHash)

		if bit == 0 {
			currentHash = smt.poseidonHash(&currentHash, &siblingHash)
		} else {
			currentHash = smt.poseidonHash(&siblingHash, &currentHash)
		}

		path = clearBit(path, level)
	}

	smt.root = currentHash
	return smt.root
}

// Get returns the value at the given key.
// Returns (value, true) if the key has a non-empty value, (zero, false) otherwise.
func (smt *SparseMerkleTree) Get(key TreeKey) (fr.Element, bool) {
	val, ok := smt.leaves[key]
	return val, ok
}

// Root returns the current root hash of the tree.
// [Spec: accountRoot, storageRoots[c]]
func (smt *SparseMerkleTree) Root() fr.Element {
	return smt.root
}

// Depth returns the tree depth.
func (smt *SparseMerkleTree) Depth() int {
	return smt.depth
}

// LeafCount returns the number of non-empty leaves in the tree.
func (smt *SparseMerkleTree) LeafCount() int {
	return len(smt.leaves)
}

// DefaultHash returns the default hash at the given level (hash of empty subtree).
// Returns zero for out-of-range levels.
//
// [Spec: DefaultHash(level)]
func (smt *SparseMerkleTree) DefaultHash(level int) fr.Element {
	if level < 0 || level > smt.depth {
		return fr.Element{}
	}
	return smt.defaultHashes[level]
}

// AllLeaves returns a copy of all non-empty leaf entries in the tree.
// Used for persistence: iterate and write each leaf to LevelDB.
func (smt *SparseMerkleTree) AllLeaves() map[TreeKey]fr.Element {
	result := make(map[TreeKey]fr.Element, len(smt.leaves))
	for k, v := range smt.leaves {
		result[k] = v
	}
	return result
}

// GetProof generates a Merkle proof for the given key.
// The proof contains sibling hashes from leaf (level 0) to root (level depth-1).
// Works for both existing keys (inclusion proof) and missing keys (non-membership proof).
//
// [Spec: ProofSiblings(e, key, depth)]
func (smt *SparseMerkleTree) GetProof(key TreeKey) MerkleProof {
	siblings := make([]fr.Element, smt.depth)
	path := key

	for level := 0; level < smt.depth; level++ {
		siblingPath := flipBit(path, level)
		siblings[level] = smt.getNode(level, siblingPath)
		path = clearBit(path, level)
	}

	val, _ := smt.Get(key)
	return MerkleProof{
		Siblings: siblings,
		Key:      key,
		Value:    val,
		Depth:    smt.depth,
	}
}

// VerifyProof verifies a Merkle proof against an expected root hash.
// Returns true if the proof is valid (the leaf hash walks up to the expected root).
//
// [Spec: VerifyProof(expectedRoot, leafHash, siblings, pathBits, depth)]
func (smt *SparseMerkleTree) VerifyProof(expectedRoot fr.Element, proof MerkleProof) bool {
	if len(proof.Siblings) != smt.depth {
		return false
	}

	currentHash := smt.leafHash(proof.Key, &proof.Value)

	for level := 0; level < smt.depth; level++ {
		bit := proof.Key.Bit(level)
		if bit == 0 {
			currentHash = smt.poseidonHash(&currentHash, &proof.Siblings[level])
		} else {
			currentHash = smt.poseidonHash(&proof.Siblings[level], &currentHash)
		}
	}

	return currentHash == expectedRoot
}

// VerifyProofStatic verifies a Merkle proof without requiring a tree instance.
// Creates a temporary Poseidon2 permutation for hashing.
// Use for standalone proof verification (e.g., in smart contracts or external verifiers).
//
// [Spec: VerifyProof(expectedRoot, leafHash, siblings, pathBits, depth)]
func VerifyProofStatic(expectedRoot fr.Element, proof MerkleProof) bool {
	if len(proof.Siblings) != proof.Depth {
		return false
	}

	perm := poseidon2.NewPermutation(2, 6, 50)
	hashFn := func(left, right *fr.Element) fr.Element {
		lBytes := left.Marshal()
		rBytes := right.Marshal()
		digest, err := perm.Compress(lBytes, rBytes)
		if err != nil {
			return fr.Element{}
		}
		var result fr.Element
		result.SetBytes(digest)
		return result
	}

	// Compute leaf hash
	var currentHash fr.Element
	if !proof.Value.IsZero() {
		keyElem := proof.Key.ToFieldElement()
		currentHash = hashFn(&keyElem, &proof.Value)
	}

	for level := 0; level < proof.Depth; level++ {
		bit := proof.Key.Bit(level)
		if bit == 0 {
			currentHash = hashFn(&currentHash, &proof.Siblings[level])
		} else {
			currentHash = hashFn(&proof.Siblings[level], &currentHash)
		}
	}

	return currentHash == expectedRoot
}
