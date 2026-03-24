package statedb

import (
	"math/big"
	"path/filepath"
	"testing"

	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
)

func TestOpenCloseStore(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(filepath.Join(dir, "testdb"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
}

func TestAccountPersistence(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(filepath.Join(dir, "testdb"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer store.Close()

	addr := TreeKey{31: 0x42}
	acct := NewAccount()
	acct.Balance = big.NewInt(999)
	acct.Nonce = 7

	// Put and get.
	if err := store.PutAccount(addr, acct); err != nil {
		t.Fatalf("put: %v", err)
	}

	loaded, err := store.GetAccount(addr)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if loaded == nil {
		t.Fatal("expected non-nil account")
	}
	if loaded.Balance.Cmp(big.NewInt(999)) != 0 {
		t.Errorf("balance: got %s, want 999", loaded.Balance)
	}
	if loaded.Nonce != 7 {
		t.Errorf("nonce: got %d, want 7", loaded.Nonce)
	}
	if !loaded.Alive {
		t.Error("expected alive=true")
	}
}

func TestAccountNotFound(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(filepath.Join(dir, "testdb"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer store.Close()

	loaded, err := store.GetAccount(TreeKey{})
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if loaded != nil {
		t.Error("expected nil for nonexistent account")
	}
}

func TestAccountRootPersistence(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(filepath.Join(dir, "testdb"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer store.Close()

	var root fr.Element
	root.SetUint64(123456789)

	if err := store.PutAccountRoot(root); err != nil {
		t.Fatalf("put root: %v", err)
	}

	loaded, err := store.GetAccountRoot()
	if err != nil {
		t.Fatalf("get root: %v", err)
	}
	if loaded != root {
		t.Error("root mismatch after persistence roundtrip")
	}
}

func TestWriteBatchAtomic(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(filepath.Join(dir, "testdb"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer store.Close()

	batch := store.NewBatch()

	// Write 3 accounts atomically.
	for i := byte(0); i < 3; i++ {
		addr := TreeKey{31: i}
		acct := NewAccount()
		acct.Balance = big.NewInt(int64(i) * 100)
		batch.PutAccount(addr, acct)
	}

	if batch.Size() != 3 {
		t.Errorf("batch size: got %d, want 3", batch.Size())
	}

	if err := batch.Commit(); err != nil {
		t.Fatalf("commit: %v", err)
	}

	// Verify all 3 accounts were written.
	for i := byte(0); i < 3; i++ {
		addr := TreeKey{31: i}
		loaded, err := store.GetAccount(addr)
		if err != nil {
			t.Fatalf("get [%d]: %v", i, err)
		}
		if loaded == nil {
			t.Fatalf("account [%d] not found", i)
		}
		expected := int64(i) * 100
		if loaded.Balance.Cmp(big.NewInt(expected)) != 0 {
			t.Errorf("[%d] balance: got %s, want %d", i, loaded.Balance, expected)
		}
	}
}

func TestStorageLeafPersistence(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(filepath.Join(dir, "testdb"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer store.Close()

	contract := TreeKey{31: 0x01}
	slot := TreeKey{31: 0x42}
	var val fr.Element
	val.SetUint64(777)

	batch := store.NewBatch()
	batch.PutStorageLeaf(contract, slot, val)
	if err := batch.Commit(); err != nil {
		t.Fatalf("commit: %v", err)
	}

	loaded, err := store.GetStorageLeaf(contract, slot)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if loaded != val {
		t.Error("storage value mismatch after persistence roundtrip")
	}
}

func TestAccountCount(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(filepath.Join(dir, "testdb"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer store.Close()

	// Initially empty.
	count, err := store.AccountCount()
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 0 {
		t.Errorf("expected 0 accounts, got %d", count)
	}

	// Add 5 accounts.
	for i := byte(0); i < 5; i++ {
		store.PutAccount(TreeKey{31: i}, NewAccount())
	}

	count, err = store.AccountCount()
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 5 {
		t.Errorf("expected 5 accounts, got %d", count)
	}
}

func TestAccountSerializationRoundtrip(t *testing.T) {
	acct := &Account{
		Balance:     new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil), // 1 ETH
		Nonce:       42,
		Alive:       true,
		StorageRoot: fr.Element{},
	}
	acct.StorageRoot.SetUint64(999)

	data := serializeAccount(acct)
	if len(data) != 73 {
		t.Fatalf("serialized length: got %d, want 73", len(data))
	}

	restored, err := deserializeAccount(data)
	if err != nil {
		t.Fatalf("deserialize: %v", err)
	}

	if restored.Balance.Cmp(acct.Balance) != 0 {
		t.Errorf("balance: got %s, want %s", restored.Balance, acct.Balance)
	}
	if restored.Nonce != acct.Nonce {
		t.Errorf("nonce: got %d, want %d", restored.Nonce, acct.Nonce)
	}
	if restored.Alive != acct.Alive {
		t.Errorf("alive: got %v, want %v", restored.Alive, acct.Alive)
	}
	if restored.StorageRoot != acct.StorageRoot {
		t.Error("storage root mismatch")
	}
}

func TestDeserializeInvalidLength(t *testing.T) {
	_, err := deserializeAccount([]byte{1, 2, 3})
	if err == nil {
		t.Error("expected error for invalid data length")
	}
}

func TestPersistenceAcrossReopen(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "testdb")

	// Write data.
	{
		store, err := OpenStore(dbPath)
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		addr := TreeKey{31: 0x01}
		acct := NewAccount()
		acct.Balance = big.NewInt(12345)
		store.PutAccount(addr, acct)

		var root fr.Element
		root.SetUint64(9999)
		store.PutAccountRoot(root)

		store.Close()
	}

	// Reopen and verify.
	{
		store, err := OpenStore(dbPath)
		if err != nil {
			t.Fatalf("reopen: %v", err)
		}
		defer store.Close()

		addr := TreeKey{31: 0x01}
		loaded, err := store.GetAccount(addr)
		if err != nil {
			t.Fatalf("get: %v", err)
		}
		if loaded == nil {
			t.Fatal("account lost after reopen")
		}
		if loaded.Balance.Cmp(big.NewInt(12345)) != 0 {
			t.Errorf("balance after reopen: got %s, want 12345", loaded.Balance)
		}

		root, err := store.GetAccountRoot()
		if err != nil {
			t.Fatalf("get root: %v", err)
		}
		var expected fr.Element
		expected.SetUint64(9999)
		if root != expected {
			t.Error("root lost after reopen")
		}
	}
}
