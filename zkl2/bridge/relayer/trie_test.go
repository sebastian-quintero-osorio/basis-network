package relayer

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// Test addresses (deterministic for reproducibility).
var (
	testEnterprise = common.HexToAddress("0x1111111111111111111111111111111111111111")
	testRecipient1 = common.HexToAddress("0x2222222222222222222222222222222222222222")
	testRecipient2 = common.HexToAddress("0x3333333333333333333333333333333333333333")
)

func makeEntry(recipient common.Address, amount int64, index uint64) WithdrawTrieEntry {
	return WithdrawTrieEntry{
		Enterprise:      testEnterprise,
		Recipient:       recipient,
		Amount:          big.NewInt(amount),
		WithdrawalIndex: index,
	}
}

// --- WithdrawTrie basic operations ---

func TestNewWithdrawTrie(t *testing.T) {
	trie := NewWithdrawTrie(32)
	if trie.LeafCount() != 0 {
		t.Errorf("new trie should have 0 leaves, got %d", trie.LeafCount())
	}
}

func TestWithdrawTrie_EmptyRoot(t *testing.T) {
	trie := NewWithdrawTrie(32)
	root := trie.Root()
	if root != (common.Hash{}) {
		t.Errorf("empty trie root should be zero hash, got %s", root.Hex())
	}
}

func TestWithdrawTrie_AppendLeaf(t *testing.T) {
	trie := NewWithdrawTrie(32)

	idx0 := trie.AppendLeaf(makeEntry(testRecipient1, 1000, 0))
	if idx0 != 0 {
		t.Errorf("first leaf index should be 0, got %d", idx0)
	}
	if trie.LeafCount() != 1 {
		t.Errorf("leaf count should be 1, got %d", trie.LeafCount())
	}

	idx1 := trie.AppendLeaf(makeEntry(testRecipient2, 2000, 1))
	if idx1 != 1 {
		t.Errorf("second leaf index should be 1, got %d", idx1)
	}
	if trie.LeafCount() != 2 {
		t.Errorf("leaf count should be 2, got %d", trie.LeafCount())
	}
}

func TestWithdrawTrie_SingleLeafRoot(t *testing.T) {
	trie := NewWithdrawTrie(32)
	trie.AppendLeaf(makeEntry(testRecipient1, 1000, 0))

	root := trie.Root()
	if root == (common.Hash{}) {
		t.Error("single-leaf trie root should not be zero hash")
	}

	// Root of single leaf padded to 2 nodes:
	// root = keccak256(leaf || 0x00...00)
	leaf := ComputeLeafHash(makeEntry(testRecipient1, 1000, 0))
	expected := hashPair(leaf, common.Hash{})
	if root != expected {
		t.Errorf("root mismatch: got %s, expected %s", root.Hex(), expected.Hex())
	}
}

func TestWithdrawTrie_TwoLeafRoot(t *testing.T) {
	trie := NewWithdrawTrie(32)
	trie.AppendLeaf(makeEntry(testRecipient1, 1000, 0))
	trie.AppendLeaf(makeEntry(testRecipient2, 2000, 1))

	root := trie.Root()

	leaf0 := ComputeLeafHash(makeEntry(testRecipient1, 1000, 0))
	leaf1 := ComputeLeafHash(makeEntry(testRecipient2, 2000, 1))
	expected := hashPair(leaf0, leaf1)

	if root != expected {
		t.Errorf("root mismatch: got %s, expected %s", root.Hex(), expected.Hex())
	}
}

func TestWithdrawTrie_RootDeterminism(t *testing.T) {
	// Same entries should produce same root
	trie1 := NewWithdrawTrie(32)
	trie1.AppendLeaf(makeEntry(testRecipient1, 1000, 0))
	trie1.AppendLeaf(makeEntry(testRecipient2, 2000, 1))

	trie2 := NewWithdrawTrie(32)
	trie2.AppendLeaf(makeEntry(testRecipient1, 1000, 0))
	trie2.AppendLeaf(makeEntry(testRecipient2, 2000, 1))

	if trie1.Root() != trie2.Root() {
		t.Error("identical entries should produce identical roots")
	}
}

func TestWithdrawTrie_DifferentEntriesDifferentRoots(t *testing.T) {
	trie1 := NewWithdrawTrie(32)
	trie1.AppendLeaf(makeEntry(testRecipient1, 1000, 0))

	trie2 := NewWithdrawTrie(32)
	trie2.AppendLeaf(makeEntry(testRecipient1, 2000, 0)) // different amount

	if trie1.Root() == trie2.Root() {
		t.Error("different entries should produce different roots")
	}
}

// --- Merkle proof generation and verification ---

func TestWithdrawTrie_ProofSingleLeaf(t *testing.T) {
	trie := NewWithdrawTrie(32)
	trie.AppendLeaf(makeEntry(testRecipient1, 1000, 0))

	root := trie.Root()
	proof, err := trie.GenerateProof(0)
	if err != nil {
		t.Fatalf("GenerateProof failed: %v", err)
	}

	leaf := ComputeLeafHash(makeEntry(testRecipient1, 1000, 0))
	if !VerifyProof(proof, root, leaf, 0) {
		t.Error("valid proof should verify")
	}
}

func TestWithdrawTrie_ProofTwoLeaves(t *testing.T) {
	trie := NewWithdrawTrie(32)
	trie.AppendLeaf(makeEntry(testRecipient1, 1000, 0))
	trie.AppendLeaf(makeEntry(testRecipient2, 2000, 1))

	root := trie.Root()

	// Verify proof for leaf 0
	proof0, err := trie.GenerateProof(0)
	if err != nil {
		t.Fatalf("GenerateProof(0) failed: %v", err)
	}
	leaf0 := ComputeLeafHash(makeEntry(testRecipient1, 1000, 0))
	if !VerifyProof(proof0, root, leaf0, 0) {
		t.Error("proof for leaf 0 should verify")
	}

	// Verify proof for leaf 1
	proof1, err := trie.GenerateProof(1)
	if err != nil {
		t.Fatalf("GenerateProof(1) failed: %v", err)
	}
	leaf1 := ComputeLeafHash(makeEntry(testRecipient2, 2000, 1))
	if !VerifyProof(proof1, root, leaf1, 1) {
		t.Error("proof for leaf 1 should verify")
	}
}

func TestWithdrawTrie_ProofFourLeaves(t *testing.T) {
	trie := NewWithdrawTrie(32)
	entries := []WithdrawTrieEntry{
		makeEntry(testRecipient1, 1000, 0),
		makeEntry(testRecipient2, 2000, 1),
		makeEntry(testRecipient1, 3000, 2),
		makeEntry(testRecipient2, 4000, 3),
	}

	for _, e := range entries {
		trie.AppendLeaf(e)
	}

	root := trie.Root()

	// Verify all proofs
	for i, e := range entries {
		proof, err := trie.GenerateProof(uint64(i))
		if err != nil {
			t.Fatalf("GenerateProof(%d) failed: %v", i, err)
		}
		leaf := ComputeLeafHash(e)
		if !VerifyProof(proof, root, leaf, uint64(i)) {
			t.Errorf("proof for leaf %d should verify", i)
		}
	}
}

func TestWithdrawTrie_ProofThreeLeaves(t *testing.T) {
	// Non-power-of-2 leaf count (padded to 4)
	trie := NewWithdrawTrie(32)
	entries := []WithdrawTrieEntry{
		makeEntry(testRecipient1, 1000, 0),
		makeEntry(testRecipient2, 2000, 1),
		makeEntry(testRecipient1, 3000, 2),
	}

	for _, e := range entries {
		trie.AppendLeaf(e)
	}

	root := trie.Root()

	for i, e := range entries {
		proof, err := trie.GenerateProof(uint64(i))
		if err != nil {
			t.Fatalf("GenerateProof(%d) failed: %v", i, err)
		}
		leaf := ComputeLeafHash(e)
		if !VerifyProof(proof, root, leaf, uint64(i)) {
			t.Errorf("proof for leaf %d should verify", i)
		}
	}
}

func TestWithdrawTrie_InvalidProofWrongLeaf(t *testing.T) {
	trie := NewWithdrawTrie(32)
	trie.AppendLeaf(makeEntry(testRecipient1, 1000, 0))
	trie.AppendLeaf(makeEntry(testRecipient2, 2000, 1))

	root := trie.Root()
	proof, _ := trie.GenerateProof(0)

	// Use wrong leaf
	wrongLeaf := ComputeLeafHash(makeEntry(testRecipient2, 9999, 99))
	if VerifyProof(proof, root, wrongLeaf, 0) {
		t.Error("proof with wrong leaf should NOT verify")
	}
}

func TestWithdrawTrie_InvalidProofWrongIndex(t *testing.T) {
	trie := NewWithdrawTrie(32)
	trie.AppendLeaf(makeEntry(testRecipient1, 1000, 0))
	trie.AppendLeaf(makeEntry(testRecipient2, 2000, 1))

	root := trie.Root()
	proof, _ := trie.GenerateProof(0)

	// Use correct leaf but wrong index
	leaf := ComputeLeafHash(makeEntry(testRecipient1, 1000, 0))
	if VerifyProof(proof, root, leaf, 1) {
		t.Error("proof with wrong index should NOT verify")
	}
}

func TestWithdrawTrie_InvalidProofWrongRoot(t *testing.T) {
	trie := NewWithdrawTrie(32)
	trie.AppendLeaf(makeEntry(testRecipient1, 1000, 0))

	proof, _ := trie.GenerateProof(0)
	leaf := ComputeLeafHash(makeEntry(testRecipient1, 1000, 0))

	wrongRoot := common.HexToHash("0xdeadbeef")
	if VerifyProof(proof, wrongRoot, leaf, 0) {
		t.Error("proof with wrong root should NOT verify")
	}
}

func TestWithdrawTrie_ProofOutOfRange(t *testing.T) {
	trie := NewWithdrawTrie(32)
	trie.AppendLeaf(makeEntry(testRecipient1, 1000, 0))

	_, err := trie.GenerateProof(1)
	if err == nil {
		t.Error("GenerateProof for out-of-range index should return error")
	}
}

// --- Reset ---

func TestWithdrawTrie_Reset(t *testing.T) {
	trie := NewWithdrawTrie(32)
	trie.AppendLeaf(makeEntry(testRecipient1, 1000, 0))
	trie.AppendLeaf(makeEntry(testRecipient2, 2000, 1))

	if trie.LeafCount() != 2 {
		t.Fatalf("expected 2 leaves before reset, got %d", trie.LeafCount())
	}

	trie.Reset()

	if trie.LeafCount() != 0 {
		t.Errorf("expected 0 leaves after reset, got %d", trie.LeafCount())
	}
	if trie.Root() != (common.Hash{}) {
		t.Error("reset trie root should be zero hash")
	}
}

// --- ComputeLeafHash ABI encoding ---

func TestComputeLeafHash_MatchesSolidity(t *testing.T) {
	// Verify encoding matches: keccak256(abi.encodePacked(enterprise, recipient, amount, index))
	// abi.encodePacked: [20 bytes][20 bytes][32 bytes][32 bytes] = 104 bytes
	entry := WithdrawTrieEntry{
		Enterprise:      common.HexToAddress("0x1111111111111111111111111111111111111111"),
		Recipient:       common.HexToAddress("0x2222222222222222222222222222222222222222"),
		Amount:          big.NewInt(1000000000000000000), // 1 ETH in wei
		WithdrawalIndex: 0,
	}

	hash := ComputeLeafHash(entry)

	// Manual computation
	buf := make([]byte, 0, 104)
	buf = append(buf, entry.Enterprise.Bytes()...)
	buf = append(buf, entry.Recipient.Bytes()...)
	buf = append(buf, common.LeftPadBytes(entry.Amount.Bytes(), 32)...)
	buf = append(buf, common.LeftPadBytes(big.NewInt(0).Bytes(), 32)...)
	expected := crypto.Keccak256Hash(buf)

	if hash != expected {
		t.Errorf("leaf hash mismatch: got %s, expected %s", hash.Hex(), expected.Hex())
	}
}

func TestComputeWithdrawalHash_MatchesSolidity(t *testing.T) {
	// Verify: keccak256(abi.encodePacked(enterprise, batchId, recipient, amount, index))
	// [20][32][20][32][32] = 136 bytes
	enterprise := common.HexToAddress("0x1111111111111111111111111111111111111111")
	batchID := big.NewInt(0)
	recipient := common.HexToAddress("0x2222222222222222222222222222222222222222")
	amount := big.NewInt(1000000000000000000)
	index := uint64(0)

	hash := ComputeWithdrawalHash(enterprise, batchID, recipient, amount, index)

	// Manual computation
	buf := make([]byte, 0, 136)
	buf = append(buf, enterprise.Bytes()...)
	buf = append(buf, common.LeftPadBytes(batchID.Bytes(), 32)...)
	buf = append(buf, recipient.Bytes()...)
	buf = append(buf, common.LeftPadBytes(amount.Bytes(), 32)...)
	buf = append(buf, common.LeftPadBytes(big.NewInt(int64(index)).Bytes(), 32)...)
	expected := crypto.Keccak256Hash(buf)

	if hash != expected {
		t.Errorf("withdrawal hash mismatch: got %s, expected %s", hash.Hex(), expected.Hex())
	}
}

// --- nextPowerOf2 ---

func TestNextPowerOf2(t *testing.T) {
	tests := []struct {
		input    int
		expected int
	}{
		{0, 1},
		{1, 1},
		{2, 2},
		{3, 4},
		{4, 4},
		{5, 8},
		{7, 8},
		{8, 8},
		{9, 16},
		{100, 128},
	}

	for _, tt := range tests {
		result := nextPowerOf2(tt.input)
		if result != tt.expected {
			t.Errorf("nextPowerOf2(%d) = %d, expected %d", tt.input, result, tt.expected)
		}
	}
}
