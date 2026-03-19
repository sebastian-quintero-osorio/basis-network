package statedb

import (
	"math/big"
	"testing"

	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
)

// testConfig returns a small-depth configuration for fast testing.
// Depth 4 gives 16 possible leaf positions, sufficient for invariant testing.
const testAccountDepth = 4
const testStorageDepth = 4

func testConfig() Config {
	return Config{
		AccountDepth: testAccountDepth,
		StorageDepth: testStorageDepth,
	}
}

// fieldElem creates an fr.Element from a uint64 value.
func fieldElem(n uint64) fr.Element {
	var e fr.Element
	e.SetUint64(n)
	return e
}

// computeRootFullRebuild computes the tree root by exhaustive full rebuild.
// TEST-ONLY: exponential in depth. Use only with small trees (depth <= 16).
//
// This is the Go implementation of the TLA+ ComputeRoot operator:
// ComputeRoot(e, depth) == ComputeNode(e, depth, 0)
//
// [Spec: ComputeRoot(AccountEntries, ACCOUNT_DEPTH)]
func computeRootFullRebuild(smt *SparseMerkleTree) fr.Element {
	return computeNodeFull(smt, smt.depth, 0)
}

// computeNodeFull recursively computes the hash of a subtree by visiting all leaves.
//
// [Spec: ComputeNode(e, level, index)]
func computeNodeFull(smt *SparseMerkleTree, level int, index uint64) fr.Element {
	if level == 0 {
		key := Uint64ToKey(index)
		val, ok := smt.Get(key)
		if !ok {
			var empty fr.Element
			return smt.leafHash(key, &empty)
		}
		return smt.leafHash(key, &val)
	}
	left := computeNodeFull(smt, level-1, 2*index)
	right := computeNodeFull(smt, level-1, 2*index+1)
	return smt.poseidonHash(&left, &right)
}

// assertConsistencyInvariant verifies the ConsistencyInvariant:
// the incremental root must equal the full rebuild root.
//
// [Spec: ConsistencyInvariant == accountRoot = ComputeAccountRoot
//        /\ \A c \in Contracts : storageRoots[c] = ComputeStorageRoot(c)]
func assertConsistencyInvariant(t *testing.T, db *StateDB) {
	t.Helper()

	// Check account trie consistency
	incrementalRoot := db.StateRoot()
	fullRoot := computeRootFullRebuild(db.accountTrie)
	if incrementalRoot != fullRoot {
		t.Fatalf("ConsistencyInvariant FAILED: account trie incremental root != full rebuild root")
	}

	// Check all storage trie consistency
	for addr, trie := range db.storageTries {
		incRoot := trie.Root()
		fullSRoot := computeRootFullRebuild(trie)
		if incRoot != fullSRoot {
			t.Fatalf("ConsistencyInvariant FAILED: storage trie for addr %v incremental root != full rebuild root", addr)
		}
	}
}

// assertBalanceConservation verifies the BalanceConservation invariant.
//
// [Spec: BalanceConservation == TotalBalance = MaxBalance]
func assertBalanceConservation(t *testing.T, db *StateDB, expectedTotal *big.Int) {
	t.Helper()
	actual := db.TotalBalance()
	if actual.Cmp(expectedTotal) != 0 {
		t.Fatalf("BalanceConservation FAILED: expected total %s, got %s",
			expectedTotal.String(), actual.String())
	}
}

// --------------------------------------------------------------------------
// SMT Unit Tests
// --------------------------------------------------------------------------

func TestSMTInsertAndRoot(t *testing.T) {
	smt := NewSparseMerkleTree(testAccountDepth)

	// Empty tree root should be DefaultHash(depth)
	emptyRoot := smt.DefaultHash(testAccountDepth)
	if smt.Root() != emptyRoot {
		t.Fatal("empty tree root != DefaultHash(depth)")
	}

	// Insert a value and check root changes
	val := fieldElem(42)
	key := Uint64ToKey(0)
	smt.Insert(key, val)

	if smt.Root() == emptyRoot {
		t.Fatal("root should change after insert")
	}
	if smt.LeafCount() != 1 {
		t.Fatalf("expected 1 leaf, got %d", smt.LeafCount())
	}

	// Verify the value is retrievable
	got, ok := smt.Get(key)
	if !ok {
		t.Fatal("inserted key not found")
	}
	if got != val {
		t.Fatal("retrieved value != inserted value")
	}

	// Verify consistency: incremental root == full rebuild
	fullRoot := computeRootFullRebuild(smt)
	if smt.Root() != fullRoot {
		t.Fatal("incremental root != full rebuild root after insert")
	}
}

func TestSMTMultipleInserts(t *testing.T) {
	smt := NewSparseMerkleTree(testAccountDepth)

	// Insert multiple values
	for i := uint64(0); i < 5; i++ {
		key := Uint64ToKey(i)
		val := fieldElem(100 + i)
		smt.Insert(key, val)
	}

	if smt.LeafCount() != 5 {
		t.Fatalf("expected 5 leaves, got %d", smt.LeafCount())
	}

	// Verify consistency after multiple inserts
	fullRoot := computeRootFullRebuild(smt)
	if smt.Root() != fullRoot {
		t.Fatal("incremental root != full rebuild root after multiple inserts")
	}
}

func TestSMTUpdate(t *testing.T) {
	smt := NewSparseMerkleTree(testAccountDepth)

	key := Uint64ToKey(3)
	val1 := fieldElem(10)
	val2 := fieldElem(20)

	smt.Insert(key, val1)
	root1 := smt.Root()

	smt.Insert(key, val2)
	root2 := smt.Root()

	if root1 == root2 {
		t.Fatal("root should change after update")
	}
	if smt.LeafCount() != 1 {
		t.Fatalf("update should not add leaves, got %d", smt.LeafCount())
	}

	got, _ := smt.Get(key)
	if got != val2 {
		t.Fatal("value should be updated")
	}

	// Verify consistency after update
	fullRoot := computeRootFullRebuild(smt)
	if smt.Root() != fullRoot {
		t.Fatal("incremental root != full rebuild root after update")
	}
}

func TestSMTDelete(t *testing.T) {
	smt := NewSparseMerkleTree(testAccountDepth)
	emptyRoot := smt.Root()

	key := Uint64ToKey(5)
	val := fieldElem(99)

	smt.Insert(key, val)
	if smt.Root() == emptyRoot {
		t.Fatal("root should change after insert")
	}

	// Delete restores the root to the empty tree root
	smt.Delete(key)
	if smt.Root() != emptyRoot {
		t.Fatal("root should return to empty after deleting the only entry")
	}
	if smt.LeafCount() != 0 {
		t.Fatalf("expected 0 leaves after delete, got %d", smt.LeafCount())
	}

	// Verify consistency after delete
	fullRoot := computeRootFullRebuild(smt)
	if smt.Root() != fullRoot {
		t.Fatal("incremental root != full rebuild root after delete")
	}
}

func TestSMTDeleteNonexistent(t *testing.T) {
	smt := NewSparseMerkleTree(testAccountDepth)
	rootBefore := smt.Root()

	// Deleting a key that was never inserted should not change the root
	smt.Delete(Uint64ToKey(7))
	if smt.Root() != rootBefore {
		t.Fatal("deleting nonexistent key should not change root")
	}
}

func TestSMTProofVerification(t *testing.T) {
	smt := NewSparseMerkleTree(testAccountDepth)

	key := Uint64ToKey(2)
	val := fieldElem(77)
	smt.Insert(key, val)

	// Generate and verify inclusion proof
	proof := smt.GetProof(key)
	if !smt.VerifyProof(smt.Root(), proof) {
		t.Fatal("valid inclusion proof should verify")
	}

	// Verify with static verification function
	if !VerifyProofStatic(smt.Root(), proof) {
		t.Fatal("static verification should agree with instance verification")
	}

	// Non-membership proof for uninserted key
	emptyKey := Uint64ToKey(10)
	emptyProof := smt.GetProof(emptyKey)
	if !smt.VerifyProof(smt.Root(), emptyProof) {
		t.Fatal("valid non-membership proof should verify")
	}
	if !emptyProof.Value.IsZero() {
		t.Fatal("non-membership proof value should be zero")
	}
}

func TestSMTProofAfterUpdate(t *testing.T) {
	smt := NewSparseMerkleTree(testAccountDepth)

	key0 := Uint64ToKey(0)
	key1 := Uint64ToKey(1)
	smt.Insert(key0, fieldElem(10))
	smt.Insert(key1, fieldElem(20))

	// Get proofs for both keys
	proof0 := smt.GetProof(key0)
	proof1 := smt.GetProof(key1)
	root := smt.Root()

	if !smt.VerifyProof(root, proof0) {
		t.Fatal("proof for key0 should verify")
	}
	if !smt.VerifyProof(root, proof1) {
		t.Fatal("proof for key1 should verify")
	}

	// Update key0
	smt.Insert(key0, fieldElem(99))
	newRoot := smt.Root()

	// Old proofs should fail against new root
	if smt.VerifyProof(newRoot, proof0) {
		t.Fatal("old proof for key0 should fail against new root")
	}

	// New proofs should verify
	newProof0 := smt.GetProof(key0)
	newProof1 := smt.GetProof(key1)
	if !smt.VerifyProof(newRoot, newProof0) {
		t.Fatal("new proof for key0 should verify")
	}
	if !smt.VerifyProof(newRoot, newProof1) {
		t.Fatal("new proof for key1 should verify after key0 update")
	}
}

// --------------------------------------------------------------------------
// StateDB Unit Tests
// --------------------------------------------------------------------------

func TestCreateAccount(t *testing.T) {
	db := NewStateDB(testConfig())

	addr := Uint64ToKey(0)
	if err := db.CreateAccount(addr); err != nil {
		t.Fatalf("CreateAccount failed: %v", err)
	}

	if !db.IsAlive(addr) {
		t.Fatal("account should be alive after creation")
	}
	if db.GetBalance(addr).Sign() != 0 {
		t.Fatal("new account should have zero balance")
	}

	// Double creation should fail
	if err := db.CreateAccount(addr); err != ErrAccountAlreadyAlive {
		t.Fatalf("expected ErrAccountAlreadyAlive, got %v", err)
	}

	assertConsistencyInvariant(t, db)
}

func TestTransfer(t *testing.T) {
	db := NewStateDB(testConfig())
	supply := big.NewInt(1000)

	// Create two accounts: addr0 with full supply, addr1 with zero
	addr0 := Uint64ToKey(0)
	addr1 := Uint64ToKey(1)
	if err := db.CreateAccount(addr0); err != nil {
		t.Fatal(err)
	}
	if err := db.SetBalance(addr0, supply); err != nil {
		t.Fatal(err)
	}
	if err := db.CreateAccount(addr1); err != nil {
		t.Fatal(err)
	}

	assertBalanceConservation(t, db, supply)
	assertConsistencyInvariant(t, db)

	// Transfer 300 from addr0 to addr1
	if err := db.Transfer(addr0, addr1, big.NewInt(300)); err != nil {
		t.Fatalf("Transfer failed: %v", err)
	}

	if db.GetBalance(addr0).Cmp(big.NewInt(700)) != 0 {
		t.Fatalf("expected sender balance 700, got %s", db.GetBalance(addr0))
	}
	if db.GetBalance(addr1).Cmp(big.NewInt(300)) != 0 {
		t.Fatalf("expected receiver balance 300, got %s", db.GetBalance(addr1))
	}

	assertBalanceConservation(t, db, supply)
	assertConsistencyInvariant(t, db)
}

func TestTransferErrors(t *testing.T) {
	db := NewStateDB(testConfig())

	addr0 := Uint64ToKey(0)
	addr1 := Uint64ToKey(1)
	addr2 := Uint64ToKey(2) // never created

	db.CreateAccount(addr0)
	db.SetBalance(addr0, big.NewInt(100))
	db.CreateAccount(addr1)

	// Self-transfer
	if err := db.Transfer(addr0, addr0, big.NewInt(10)); err != ErrSelfTransfer {
		t.Fatalf("expected ErrSelfTransfer, got %v", err)
	}

	// Zero amount
	if err := db.Transfer(addr0, addr1, big.NewInt(0)); err != ErrZeroAmount {
		t.Fatalf("expected ErrZeroAmount, got %v", err)
	}

	// Negative amount
	if err := db.Transfer(addr0, addr1, big.NewInt(-5)); err != ErrZeroAmount {
		t.Fatalf("expected ErrZeroAmount for negative, got %v", err)
	}

	// Insufficient balance
	if err := db.Transfer(addr0, addr1, big.NewInt(999)); err != ErrInsufficientBalance {
		t.Fatalf("expected ErrInsufficientBalance, got %v", err)
	}

	// Dead receiver
	if err := db.Transfer(addr0, addr2, big.NewInt(10)); err != ErrAccountNotAlive {
		t.Fatalf("expected ErrAccountNotAlive for dead receiver, got %v", err)
	}

	// Dead sender
	if err := db.Transfer(addr2, addr1, big.NewInt(10)); err != ErrAccountNotAlive {
		t.Fatalf("expected ErrAccountNotAlive for dead sender, got %v", err)
	}
}

func TestSetStorage(t *testing.T) {
	db := NewStateDB(testConfig())

	contract := Uint64ToKey(1)
	db.CreateAccount(contract)

	slot0 := Uint64ToKey(0)
	val := fieldElem(42)

	rootBefore := db.StateRoot()

	if err := db.SetStorage(contract, slot0, val); err != nil {
		t.Fatalf("SetStorage failed: %v", err)
	}

	// State root should change
	if db.StateRoot() == rootBefore {
		t.Fatal("state root should change after SetStorage")
	}

	// Retrieve the value
	got := db.GetStorage(contract, slot0)
	if got != val {
		t.Fatal("GetStorage returned wrong value")
	}

	// Storage root should differ from empty
	if db.StorageRoot(contract) == db.emptyStorageRoot {
		t.Fatal("storage root should differ from empty after SetStorage")
	}

	assertConsistencyInvariant(t, db)
}

func TestSetStorageDelete(t *testing.T) {
	db := NewStateDB(testConfig())

	contract := Uint64ToKey(1)
	db.CreateAccount(contract)

	slot := Uint64ToKey(0)

	// Set a value
	db.SetStorage(contract, slot, fieldElem(42))

	// Delete it by setting to zero
	db.SetStorage(contract, slot, fr.Element{})

	got := db.GetStorage(contract, slot)
	if !got.IsZero() {
		t.Fatal("deleted storage slot should return zero")
	}

	// Storage root should be back to empty
	if db.StorageRoot(contract) != db.emptyStorageRoot {
		t.Fatal("storage root should return to empty after deleting all entries")
	}

	assertConsistencyInvariant(t, db)
}

func TestSelfDestruct(t *testing.T) {
	db := NewStateDB(testConfig())
	supply := big.NewInt(1000)

	eoa := Uint64ToKey(0)
	contract := Uint64ToKey(1)

	db.CreateAccount(eoa)
	db.SetBalance(eoa, big.NewInt(700))
	db.CreateAccount(contract)
	db.SetBalance(contract, big.NewInt(300))
	db.SetStorage(contract, Uint64ToKey(0), fieldElem(99))

	assertBalanceConservation(t, db, supply)
	assertConsistencyInvariant(t, db)

	// SelfDestruct: contract -> eoa (beneficiary)
	if err := db.SelfDestruct(contract, eoa); err != nil {
		t.Fatalf("SelfDestruct failed: %v", err)
	}

	// Contract should be dead
	if db.IsAlive(contract) {
		t.Fatal("contract should be dead after SelfDestruct")
	}
	if db.GetBalance(contract).Sign() != 0 {
		t.Fatal("contract balance should be zero after SelfDestruct")
	}

	// Beneficiary should have received the balance
	if db.GetBalance(eoa).Cmp(supply) != 0 {
		t.Fatalf("expected beneficiary balance %s, got %s", supply, db.GetBalance(eoa))
	}

	// Storage should be cleared
	got := db.GetStorage(contract, Uint64ToKey(0))
	if !got.IsZero() {
		t.Fatal("contract storage should be cleared after SelfDestruct")
	}

	assertBalanceConservation(t, db, supply)
	assertConsistencyInvariant(t, db)
}

func TestSelfDestructErrors(t *testing.T) {
	db := NewStateDB(testConfig())

	addr0 := Uint64ToKey(0)
	addr1 := Uint64ToKey(1)
	addr2 := Uint64ToKey(2) // dead

	db.CreateAccount(addr0)
	db.CreateAccount(addr1)

	if err := db.SelfDestruct(addr0, addr0); err != ErrSelfDestructToSelf {
		t.Fatalf("expected ErrSelfDestructToSelf, got %v", err)
	}
	if err := db.SelfDestruct(addr2, addr0); err != ErrAccountNotAlive {
		t.Fatalf("expected ErrAccountNotAlive for dead contract, got %v", err)
	}
	if err := db.SelfDestruct(addr0, addr2); err != ErrAccountNotAlive {
		t.Fatalf("expected ErrAccountNotAlive for dead beneficiary, got %v", err)
	}
}

// --------------------------------------------------------------------------
// TLA+ Verified Invariant Tests
// --------------------------------------------------------------------------

// TestConsistencyInvariant verifies that incremental root updates match
// full tree rebuilds across a sequence of operations.
//
// [Spec: ConsistencyInvariant == accountRoot = ComputeAccountRoot
//        /\ \A c \in Contracts : storageRoots[c] = ComputeStorageRoot(c)]
func TestConsistencyInvariant(t *testing.T) {
	db := NewStateDB(testConfig())
	supply := big.NewInt(1000)

	eoa := Uint64ToKey(0)
	c1 := Uint64ToKey(1)
	c2 := Uint64ToKey(2)

	// Step 1: Create EOA with full supply
	db.CreateAccount(eoa)
	db.SetBalance(eoa, supply)
	assertConsistencyInvariant(t, db)

	// Step 2: Create contracts
	db.CreateAccount(c1)
	assertConsistencyInvariant(t, db)
	db.CreateAccount(c2)
	assertConsistencyInvariant(t, db)

	// Step 3: Transfer
	db.Transfer(eoa, c1, big.NewInt(400))
	assertConsistencyInvariant(t, db)
	db.Transfer(eoa, c2, big.NewInt(200))
	assertConsistencyInvariant(t, db)

	// Step 4: SetStorage
	db.SetStorage(c1, Uint64ToKey(0), fieldElem(11))
	assertConsistencyInvariant(t, db)
	db.SetStorage(c1, Uint64ToKey(1), fieldElem(22))
	assertConsistencyInvariant(t, db)
	db.SetStorage(c2, Uint64ToKey(0), fieldElem(33))
	assertConsistencyInvariant(t, db)

	// Step 5: Update storage (overwrite)
	db.SetStorage(c1, Uint64ToKey(0), fieldElem(99))
	assertConsistencyInvariant(t, db)

	// Step 6: Delete storage
	db.SetStorage(c2, Uint64ToKey(0), fr.Element{})
	assertConsistencyInvariant(t, db)

	// Step 7: Transfer between contracts
	db.Transfer(c1, c2, big.NewInt(100))
	assertConsistencyInvariant(t, db)

	// Step 8: SelfDestruct
	db.SelfDestruct(c2, eoa)
	assertConsistencyInvariant(t, db)
}

// TestAccountIsolation verifies that operations on one account do not
// corrupt another account's Merkle proof.
//
// [Spec: AccountIsolation == \A addr \in AccountLeafIndices :
//        VerifyProof(accountRoot, leafH, siblings, pathBits, ACCOUNT_DEPTH)]
func TestAccountIsolation(t *testing.T) {
	db := NewStateDB(testConfig())

	addr0 := Uint64ToKey(0)
	addr1 := Uint64ToKey(1)
	addr2 := Uint64ToKey(2)

	db.CreateAccount(addr0)
	db.SetBalance(addr0, big.NewInt(1000))
	db.CreateAccount(addr1)
	db.CreateAccount(addr2)

	// Verify proofs for ALL leaf positions (including empty ones)
	numLeaves := uint64(1) << testAccountDepth
	root := db.StateRoot()
	for i := uint64(0); i < numLeaves; i++ {
		key := Uint64ToKey(i)
		proof := db.GetAccountProof(key)
		if !db.accountTrie.VerifyProof(root, proof) {
			t.Fatalf("AccountIsolation FAILED at leaf %d: proof does not verify", i)
		}
	}

	// Modify addr0 (transfer to addr1)
	db.Transfer(addr0, addr1, big.NewInt(500))
	newRoot := db.StateRoot()

	// ALL proofs must still verify against the new root
	for i := uint64(0); i < numLeaves; i++ {
		key := Uint64ToKey(i)
		proof := db.GetAccountProof(key)
		if !db.accountTrie.VerifyProof(newRoot, proof) {
			t.Fatalf("AccountIsolation FAILED at leaf %d after Transfer: proof does not verify", i)
		}
	}

	// Specifically verify that addr2's data was not affected
	if db.GetBalance(addr2).Sign() != 0 {
		t.Fatal("AccountIsolation: addr2 balance should be unchanged")
	}
}

// TestStorageIsolation verifies that contract A's storage is completely
// independent of contract B's storage.
//
// [Spec: StorageIsolation == \A c \in Contracts : alive[c] =>
//        \A s \in StorageLeafIndices :
//            VerifyProof(storageRoots[c], leafH, siblings, pathBits, STORAGE_DEPTH)]
func TestStorageIsolation(t *testing.T) {
	db := NewStateDB(testConfig())

	c1 := Uint64ToKey(1)
	c2 := Uint64ToKey(2)

	db.CreateAccount(c1)
	db.CreateAccount(c2)

	// Set storage on c1 only
	db.SetStorage(c1, Uint64ToKey(0), fieldElem(42))
	db.SetStorage(c1, Uint64ToKey(1), fieldElem(84))

	// Verify c2's storage is unaffected
	got := db.GetStorage(c2, Uint64ToKey(0))
	if !got.IsZero() {
		t.Fatal("StorageIsolation: c2 slot 0 should be empty")
	}

	// Verify all storage proofs for c1
	c1Root := db.StorageRoot(c1)
	c1Trie := db.storageTries[c1]
	numSlots := uint64(1) << testStorageDepth
	for s := uint64(0); s < numSlots; s++ {
		key := Uint64ToKey(s)
		proof := c1Trie.GetProof(key)
		if !c1Trie.VerifyProof(c1Root, proof) {
			t.Fatalf("StorageIsolation FAILED: c1 slot %d proof does not verify", s)
		}
	}

	// Set storage on c2
	db.SetStorage(c2, Uint64ToKey(0), fieldElem(99))

	// Verify c1's storage proofs are still valid (not corrupted by c2's update)
	c1Root = db.StorageRoot(c1)
	for s := uint64(0); s < numSlots; s++ {
		key := Uint64ToKey(s)
		proof := c1Trie.GetProof(key)
		if !c1Trie.VerifyProof(c1Root, proof) {
			t.Fatalf("StorageIsolation FAILED: c1 slot %d proof corrupted after c2 SetStorage", s)
		}
	}

	// Verify c2's storage proofs
	c2Root := db.StorageRoot(c2)
	c2Trie := db.storageTries[c2]
	for s := uint64(0); s < numSlots; s++ {
		key := Uint64ToKey(s)
		proof := c2Trie.GetProof(key)
		if !c2Trie.VerifyProof(c2Root, proof) {
			t.Fatalf("StorageIsolation FAILED: c2 slot %d proof does not verify", s)
		}
	}

	// Verify specific values are correct
	v1 := db.GetStorage(c1, Uint64ToKey(0))
	v2 := db.GetStorage(c2, Uint64ToKey(0))
	expected1 := fieldElem(42)
	expected2 := fieldElem(99)
	if v1 != expected1 {
		t.Fatal("StorageIsolation: c1 slot 0 should be 42")
	}
	if v2 != expected2 {
		t.Fatal("StorageIsolation: c2 slot 0 should be 99")
	}
}

// TestBalanceConservation verifies that total balance is preserved across
// all state transitions.
//
// [Spec: BalanceConservation == TotalBalance = MaxBalance]
func TestBalanceConservation(t *testing.T) {
	db := NewStateDB(testConfig())
	supply := big.NewInt(1000)

	eoa := Uint64ToKey(0)
	c1 := Uint64ToKey(1)
	c2 := Uint64ToKey(2)

	// Genesis: EOA holds full supply
	db.CreateAccount(eoa)
	db.SetBalance(eoa, supply)
	assertBalanceConservation(t, db, supply)

	// CreateAccount: adds 0 balance
	db.CreateAccount(c1)
	assertBalanceConservation(t, db, supply)
	db.CreateAccount(c2)
	assertBalanceConservation(t, db, supply)

	// Transfer: net zero
	db.Transfer(eoa, c1, big.NewInt(400))
	assertBalanceConservation(t, db, supply)
	db.Transfer(eoa, c2, big.NewInt(200))
	assertBalanceConservation(t, db, supply)
	db.Transfer(c1, c2, big.NewInt(100))
	assertBalanceConservation(t, db, supply)

	// SetStorage: no balance change
	db.SetStorage(c1, Uint64ToKey(0), fieldElem(11))
	assertBalanceConservation(t, db, supply)

	// SelfDestruct: balance transferred, not destroyed
	db.SelfDestruct(c2, eoa)
	assertBalanceConservation(t, db, supply)

	// After SelfDestruct, c2 is dead with 0 balance
	if db.GetBalance(c2).Sign() != 0 {
		t.Fatal("dead account should have zero balance")
	}

	// Remaining: eoa has 400+300=700, c1 has 300
	if db.GetBalance(eoa).Cmp(big.NewInt(700)) != 0 {
		t.Fatalf("expected eoa balance 700, got %s", db.GetBalance(eoa))
	}
	if db.GetBalance(c1).Cmp(big.NewInt(300)) != 0 {
		t.Fatalf("expected c1 balance 300, got %s", db.GetBalance(c1))
	}
}

// --------------------------------------------------------------------------
// Adversarial Tests
// --------------------------------------------------------------------------

// TestAdversarialInvalidProof tests that tampered proofs are rejected.
func TestAdversarialInvalidProof(t *testing.T) {
	db := NewStateDB(testConfig())

	addr := Uint64ToKey(0)
	db.CreateAccount(addr)
	db.SetBalance(addr, big.NewInt(500))

	proof := db.GetAccountProof(addr)

	// Tamper with a sibling hash
	tamperedProof := MerkleProof{
		Siblings: make([]fr.Element, len(proof.Siblings)),
		Key:      proof.Key,
		Value:    proof.Value,
		Depth:    proof.Depth,
	}
	copy(tamperedProof.Siblings, proof.Siblings)
	tamperedProof.Siblings[0] = fieldElem(999) // corrupt first sibling

	if db.accountTrie.VerifyProof(db.StateRoot(), tamperedProof) {
		t.Fatal("ADVERSARIAL: tampered proof should NOT verify")
	}

	// Tamper with the value
	valueProof := MerkleProof{
		Siblings: proof.Siblings,
		Key:      proof.Key,
		Value:    fieldElem(12345), // wrong value
		Depth:    proof.Depth,
	}
	if db.accountTrie.VerifyProof(db.StateRoot(), valueProof) {
		t.Fatal("ADVERSARIAL: proof with wrong value should NOT verify")
	}

	// Tamper with the key
	keyProof := MerkleProof{
		Siblings: proof.Siblings,
		Key:      Uint64ToKey(15), // wrong key
		Value:    proof.Value,
		Depth:    proof.Depth,
	}
	if db.accountTrie.VerifyProof(db.StateRoot(), keyProof) {
		t.Fatal("ADVERSARIAL: proof with wrong key should NOT verify")
	}

	// Wrong root
	wrongRoot := fieldElem(77777)
	if db.accountTrie.VerifyProof(wrongRoot, proof) {
		t.Fatal("ADVERSARIAL: proof against wrong root should NOT verify")
	}

	// Truncated proof (wrong length)
	shortProof := MerkleProof{
		Siblings: proof.Siblings[:len(proof.Siblings)-1],
		Key:      proof.Key,
		Value:    proof.Value,
		Depth:    proof.Depth,
	}
	if db.accountTrie.VerifyProof(db.StateRoot(), shortProof) {
		t.Fatal("ADVERSARIAL: truncated proof should NOT verify")
	}
}

// TestAdversarialInvalidStorageProof tests that tampered storage proofs are rejected.
func TestAdversarialInvalidStorageProof(t *testing.T) {
	db := NewStateDB(testConfig())

	contract := Uint64ToKey(1)
	db.CreateAccount(contract)
	db.SetStorage(contract, Uint64ToKey(0), fieldElem(42))

	storageTrie := db.storageTries[contract]
	proof := storageTrie.GetProof(Uint64ToKey(0))
	root := storageTrie.Root()

	// Valid proof should verify
	if !storageTrie.VerifyProof(root, proof) {
		t.Fatal("valid storage proof should verify")
	}

	// Tampered value
	badProof := MerkleProof{
		Siblings: proof.Siblings,
		Key:      proof.Key,
		Value:    fieldElem(9999),
		Depth:    proof.Depth,
	}
	if storageTrie.VerifyProof(root, badProof) {
		t.Fatal("ADVERSARIAL: storage proof with wrong value should NOT verify")
	}
}

// TestAdversarialNonexistentAccount tests operations on nonexistent accounts.
func TestAdversarialNonexistentAccount(t *testing.T) {
	db := NewStateDB(testConfig())

	ghost := Uint64ToKey(7) // never created

	// Balance of nonexistent account is zero
	if db.GetBalance(ghost).Sign() != 0 {
		t.Fatal("nonexistent account should have zero balance")
	}

	// Storage of nonexistent account is zero
	if db.GetStorage(ghost, Uint64ToKey(0)) != (fr.Element{}) {
		t.Fatal("nonexistent account should have empty storage")
	}

	// Transfer from nonexistent fails
	db.CreateAccount(Uint64ToKey(0))
	if err := db.Transfer(ghost, Uint64ToKey(0), big.NewInt(1)); err != ErrAccountNotAlive {
		t.Fatalf("expected ErrAccountNotAlive, got %v", err)
	}

	// SetStorage on nonexistent fails
	if err := db.SetStorage(ghost, Uint64ToKey(0), fieldElem(1)); err != ErrAccountNotAlive {
		t.Fatalf("expected ErrAccountNotAlive, got %v", err)
	}

	// SelfDestruct on nonexistent fails
	if err := db.SelfDestruct(ghost, Uint64ToKey(0)); err != ErrAccountNotAlive {
		t.Fatalf("expected ErrAccountNotAlive, got %v", err)
	}

	// SetBalance on nonexistent fails
	if err := db.SetBalance(ghost, big.NewInt(100)); err != ErrAccountNotAlive {
		t.Fatalf("expected ErrAccountNotAlive, got %v", err)
	}
}

// TestAdversarialDoubleCreate tests that double-creation is rejected.
func TestAdversarialDoubleCreate(t *testing.T) {
	db := NewStateDB(testConfig())

	addr := Uint64ToKey(0)
	if err := db.CreateAccount(addr); err != nil {
		t.Fatal(err)
	}
	if err := db.CreateAccount(addr); err != ErrAccountAlreadyAlive {
		t.Fatalf("expected ErrAccountAlreadyAlive, got %v", err)
	}
}

// TestAdversarialRecreateAfterSelfDestruct tests account recreation after self-destruct.
func TestAdversarialRecreateAfterSelfDestruct(t *testing.T) {
	db := NewStateDB(testConfig())
	supply := big.NewInt(1000)

	eoa := Uint64ToKey(0)
	contract := Uint64ToKey(1)

	db.CreateAccount(eoa)
	db.SetBalance(eoa, supply)
	db.CreateAccount(contract)
	db.Transfer(eoa, contract, big.NewInt(200))
	db.SetStorage(contract, Uint64ToKey(0), fieldElem(42))

	// SelfDestruct
	db.SelfDestruct(contract, eoa)
	assertBalanceConservation(t, db, supply)
	assertConsistencyInvariant(t, db)

	// Recreate the same address
	if err := db.CreateAccount(contract); err != nil {
		t.Fatalf("recreating self-destructed account should succeed: %v", err)
	}

	// New account should have clean state
	if db.GetBalance(contract).Sign() != 0 {
		t.Fatal("recreated account should have zero balance")
	}
	if db.GetStorage(contract, Uint64ToKey(0)) != (fr.Element{}) {
		t.Fatal("recreated account should have empty storage")
	}

	assertBalanceConservation(t, db, supply)
	assertConsistencyInvariant(t, db)
}

// TestAdversarialFullSequence runs the full TLA+ model scenario:
// Genesis -> Create -> Transfer -> SetStorage -> SelfDestruct.
// Verifies all four invariants after every step.
func TestAdversarialFullSequence(t *testing.T) {
	db := NewStateDB(testConfig())
	supply := big.NewInt(1000)

	eoa := Uint64ToKey(0)
	c1 := Uint64ToKey(1)
	c2 := Uint64ToKey(2)

	check := func(step string) {
		t.Helper()
		assertConsistencyInvariant(t, db)
		assertBalanceConservation(t, db, supply)

		// Account isolation: all leaf proofs valid
		root := db.StateRoot()
		numLeaves := uint64(1) << testAccountDepth
		for i := uint64(0); i < numLeaves; i++ {
			proof := db.GetAccountProof(Uint64ToKey(i))
			if !db.accountTrie.VerifyProof(root, proof) {
				t.Fatalf("AccountIsolation FAILED at step '%s', leaf %d", step, i)
			}
		}

		// Storage isolation for alive contracts
		for addr, trie := range db.storageTries {
			acct := db.accounts[addr]
			if acct == nil || !acct.Alive {
				continue
			}
			sr := trie.Root()
			numSlots := uint64(1) << testStorageDepth
			for s := uint64(0); s < numSlots; s++ {
				proof := trie.GetProof(Uint64ToKey(s))
				if !trie.VerifyProof(sr, proof) {
					t.Fatalf("StorageIsolation FAILED at step '%s', contract %v, slot %d", step, addr, s)
				}
			}
		}
	}

	// Genesis
	db.CreateAccount(eoa)
	db.SetBalance(eoa, supply)
	check("genesis")

	// Create contracts
	db.CreateAccount(c1)
	check("create-c1")
	db.CreateAccount(c2)
	check("create-c2")

	// Transfers
	db.Transfer(eoa, c1, big.NewInt(400))
	check("transfer-eoa-c1")
	db.Transfer(eoa, c2, big.NewInt(300))
	check("transfer-eoa-c2")
	db.Transfer(c1, c2, big.NewInt(100))
	check("transfer-c1-c2")

	// Storage operations
	db.SetStorage(c1, Uint64ToKey(0), fieldElem(11))
	check("storage-c1-s0")
	db.SetStorage(c1, Uint64ToKey(1), fieldElem(22))
	check("storage-c1-s1")
	db.SetStorage(c2, Uint64ToKey(0), fieldElem(33))
	check("storage-c2-s0")

	// Storage update
	db.SetStorage(c1, Uint64ToKey(0), fieldElem(99))
	check("storage-update-c1-s0")

	// Storage delete
	db.SetStorage(c2, Uint64ToKey(0), fr.Element{})
	check("storage-delete-c2-s0")

	// SelfDestruct
	db.SelfDestruct(c2, eoa)
	check("selfdestruct-c2")

	// Recreate and resume
	db.CreateAccount(c2)
	check("recreate-c2")
	db.Transfer(eoa, c2, big.NewInt(50))
	check("transfer-after-recreate")
	db.SetStorage(c2, Uint64ToKey(0), fieldElem(77))
	check("storage-after-recreate")
}
