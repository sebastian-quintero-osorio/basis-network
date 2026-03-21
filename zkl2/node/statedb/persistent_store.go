package statedb

import (
	"encoding/binary"
	"fmt"
	"math/big"

	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
	"github.com/syndtr/goleveldb/leveldb"
	"github.com/syndtr/goleveldb/leveldb/opt"
	"github.com/syndtr/goleveldb/leveldb/util"
)

// Key prefixes for LevelDB entries.
var (
	prefixAccount     = []byte("a/") // a/<TreeKey> -> serialized Account
	prefixAccountNode = []byte("n/") // n/<level>/<path> -> fr.Element (account trie node)
	prefixStorageNode = []byte("s/") // s/<contract>/<level>/<path> -> fr.Element (storage trie node)
	prefixStorageLeaf = []byte("l/") // l/<contract>/<slot> -> fr.Element (storage leaf)
	prefixMeta        = []byte("m/") // m/<key> -> metadata (root hash, config)
)

// Metadata keys.
var (
	metaAccountRoot = []byte("m/account_root")
	metaConfig      = []byte("m/config")
)

// PersistentStore provides LevelDB-backed persistence for the StateDB.
//
// Writes are batched for atomicity: a single LevelDB WriteBatch contains
// all modifications from one state transition, ensuring crash consistency.
//
// Key encoding:
//   - Account data:  a/<32-byte TreeKey> -> 73 bytes (balance:32 + nonce:8 + alive:1 + storageRoot:32)
//   - Trie nodes:    n/<2-byte level><32-byte path> -> 32 bytes (fr.Element)
//   - Storage nodes: s/<32-byte contract><2-byte level><32-byte path> -> 32 bytes
//   - Storage leaves: l/<32-byte contract><32-byte slot> -> 32 bytes
//   - Metadata:      m/<key> -> variable
type PersistentStore struct {
	db *leveldb.DB
}

// OpenStore opens or creates a LevelDB database at the given path.
func OpenStore(path string) (*PersistentStore, error) {
	db, err := leveldb.OpenFile(path, &opt.Options{
		WriteBuffer:        64 * opt.MiB,
		CompactionTableSize: 8 * opt.MiB,
	})
	if err != nil {
		return nil, fmt.Errorf("statedb: open leveldb %s: %w", path, err)
	}
	return &PersistentStore{db: db}, nil
}

// Close closes the LevelDB database.
func (s *PersistentStore) Close() error {
	return s.db.Close()
}

// ---------------------------------------------------------------------------
// Account Operations
// ---------------------------------------------------------------------------

// GetAccount retrieves a serialized account from LevelDB.
func (s *PersistentStore) GetAccount(addr TreeKey) (*Account, error) {
	key := append(prefixAccount, addr[:]...)
	data, err := s.db.Get(key, nil)
	if err == leveldb.ErrNotFound {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("statedb: get account %x: %w", addr[:4], err)
	}
	return deserializeAccount(data)
}

// PutAccount stores a serialized account to LevelDB.
func (s *PersistentStore) PutAccount(addr TreeKey, acct *Account) error {
	key := append(prefixAccount, addr[:]...)
	data := serializeAccount(acct)
	return s.db.Put(key, data, nil)
}

// ---------------------------------------------------------------------------
// Trie Node Operations (Account Trie)
// ---------------------------------------------------------------------------

// GetAccountNode retrieves an account trie node hash.
func (s *PersistentStore) GetAccountNode(level uint16, path TreeKey) (fr.Element, error) {
	key := makeNodeKey(prefixAccountNode, level, path)
	data, err := s.db.Get(key, nil)
	if err == leveldb.ErrNotFound {
		return fr.Element{}, nil
	}
	if err != nil {
		return fr.Element{}, err
	}
	var elem fr.Element
	elem.SetBytes(data)
	return elem, nil
}

// ---------------------------------------------------------------------------
// Storage Operations
// ---------------------------------------------------------------------------

// GetStorageLeaf retrieves a storage slot value.
func (s *PersistentStore) GetStorageLeaf(contract, slot TreeKey) (fr.Element, error) {
	key := make([]byte, 0, len(prefixStorageLeaf)+64)
	key = append(key, prefixStorageLeaf...)
	key = append(key, contract[:]...)
	key = append(key, slot[:]...)
	data, err := s.db.Get(key, nil)
	if err == leveldb.ErrNotFound {
		return fr.Element{}, nil
	}
	if err != nil {
		return fr.Element{}, err
	}
	var elem fr.Element
	elem.SetBytes(data)
	return elem, nil
}

// ---------------------------------------------------------------------------
// Metadata Operations
// ---------------------------------------------------------------------------

// GetAccountRoot retrieves the persisted account trie root hash.
func (s *PersistentStore) GetAccountRoot() (fr.Element, error) {
	data, err := s.db.Get(metaAccountRoot, nil)
	if err == leveldb.ErrNotFound {
		return fr.Element{}, nil
	}
	if err != nil {
		return fr.Element{}, err
	}
	var elem fr.Element
	elem.SetBytes(data)
	return elem, nil
}

// PutAccountRoot persists the account trie root hash.
func (s *PersistentStore) PutAccountRoot(root fr.Element) error {
	return s.db.Put(metaAccountRoot, root.Marshal(), nil)
}

// ---------------------------------------------------------------------------
// Batch Operations (Atomic Writes)
// ---------------------------------------------------------------------------

// WriteBatch wraps a LevelDB write batch for atomic multi-key updates.
type WriteBatch struct {
	batch *leveldb.Batch
	store *PersistentStore
}

// NewBatch creates a new atomic write batch.
func (s *PersistentStore) NewBatch() *WriteBatch {
	return &WriteBatch{
		batch: new(leveldb.Batch),
		store: s,
	}
}

// PutAccount adds an account write to the batch.
func (wb *WriteBatch) PutAccount(addr TreeKey, acct *Account) {
	key := append([]byte(nil), prefixAccount...)
	key = append(key, addr[:]...)
	wb.batch.Put(key, serializeAccount(acct))
}

// PutAccountNode adds an account trie node write to the batch.
func (wb *WriteBatch) PutAccountNode(level uint16, path TreeKey, val fr.Element) {
	key := makeNodeKey(prefixAccountNode, level, path)
	wb.batch.Put(key, val.Marshal())
}

// DeleteAccountNode removes an account trie node from the batch.
func (wb *WriteBatch) DeleteAccountNode(level uint16, path TreeKey) {
	key := makeNodeKey(prefixAccountNode, level, path)
	wb.batch.Delete(key)
}

// PutStorageLeaf adds a storage slot write to the batch.
func (wb *WriteBatch) PutStorageLeaf(contract, slot TreeKey, val fr.Element) {
	key := make([]byte, 0, len(prefixStorageLeaf)+64)
	key = append(key, prefixStorageLeaf...)
	key = append(key, contract[:]...)
	key = append(key, slot[:]...)
	wb.batch.Put(key, val.Marshal())
}

// PutStorageNode adds a storage trie node write to the batch.
func (wb *WriteBatch) PutStorageNode(contract TreeKey, level uint16, path TreeKey, val fr.Element) {
	key := make([]byte, 0, len(prefixStorageNode)+66)
	key = append(key, prefixStorageNode...)
	key = append(key, contract[:]...)
	key = append(key, encodeLevel(level)...)
	key = append(key, path[:]...)
	wb.batch.Put(key, val.Marshal())
}

// PutAccountRoot adds the account root write to the batch.
func (wb *WriteBatch) PutAccountRoot(root fr.Element) {
	wb.batch.Put(metaAccountRoot, root.Marshal())
}

// Commit atomically writes all batched operations to LevelDB.
func (wb *WriteBatch) Commit() error {
	return wb.store.db.Write(wb.batch, nil)
}

// Size returns the number of operations in the batch.
func (wb *WriteBatch) Size() int {
	return wb.batch.Len()
}

// ---------------------------------------------------------------------------
// Snapshot and Recovery
// ---------------------------------------------------------------------------

// AccountCount returns the number of account entries in the database.
func (s *PersistentStore) AccountCount() (int, error) {
	iter := s.db.NewIterator(util.BytesPrefix(prefixAccount), nil)
	defer iter.Release()
	count := 0
	for iter.Next() {
		count++
	}
	return count, iter.Error()
}

// ---------------------------------------------------------------------------
// Serialization Helpers
// ---------------------------------------------------------------------------

// Account binary format: balance(32) + nonce(8) + alive(1) + storageRoot(32) = 73 bytes.
func serializeAccount(acct *Account) []byte {
	buf := make([]byte, 73)
	balBytes := acct.Balance.Bytes()
	copy(buf[32-len(balBytes):32], balBytes) // big-endian, left-padded
	binary.BigEndian.PutUint64(buf[32:40], acct.Nonce)
	if acct.Alive {
		buf[40] = 1
	}
	copy(buf[41:73], acct.StorageRoot.Marshal())
	return buf
}

func deserializeAccount(data []byte) (*Account, error) {
	if len(data) != 73 {
		return nil, fmt.Errorf("statedb: invalid account data length %d (expected 73)", len(data))
	}
	acct := &Account{
		Balance: new(big.Int).SetBytes(data[0:32]),
		Nonce:   binary.BigEndian.Uint64(data[32:40]),
		Alive:   data[40] == 1,
	}
	acct.StorageRoot.SetBytes(data[41:73])
	return acct, nil
}

func makeNodeKey(prefix []byte, level uint16, path TreeKey) []byte {
	key := make([]byte, 0, len(prefix)+2+32)
	key = append(key, prefix...)
	key = append(key, encodeLevel(level)...)
	key = append(key, path[:]...)
	return key
}

func encodeLevel(level uint16) []byte {
	buf := make([]byte, 2)
	binary.BigEndian.PutUint16(buf, level)
	return buf
}
