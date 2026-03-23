package statedb

import (
	"math/big"

	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/state"
	"github.com/ethereum/go-ethereum/core/stateless"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
	"github.com/ethereum/go-ethereum/trie/utils"
	"github.com/holiman/uint256"
)

// Adapter implements go-ethereum's vm.StateDB interface backed by the Poseidon SMT.
// This is the bridge between EVM execution (which requires go-ethereum types) and
// ZK-friendly state management (which uses BN254 field elements and Poseidon hashing).
//
// The adapter maintains in-memory maps for code, access lists, transient storage,
// self-destruct tracking, logs, and a snapshot journal for REVERT support.
type Adapter struct {
	db    *StateDB
	hooks *tracing.Hooks // Tracing hooks for OnBalanceChange, OnStorageChange, etc.

	// Per-transaction state (reset between transactions).
	code       map[TreeKey][]byte     // Contract bytecode (not stored in SMT)
	codeHash   map[TreeKey]common.Hash // Keccak256 of bytecode
	suicided   map[TreeKey]bool       // Self-destructed contracts in this tx
	refund     uint64                 // Gas refund accumulator
	logs       []*types.Log           // Transaction event logs
	preimages  map[common.Hash][]byte // Preimage cache

	// EIP-2929 access lists.
	accessListAddresses map[common.Address]struct{}
	accessListSlots     map[common.Address]map[common.Hash]struct{}

	// EIP-1153 transient storage (per-transaction, cleared after each tx).
	transientStorage map[common.Address]map[common.Hash]common.Hash

	// Snapshot journal for REVERT support.
	snapshots []snapshot
	snapID    int
}

// snapshot captures the state delta at a specific point for revert.
// Uses first-write-wins journaling: only the first mutation to a given key
// within a snapshot is recorded (that's the value to restore on revert).
type snapshot struct {
	id             int
	accountChanges map[TreeKey]accountSnapshot
	storageChanges map[TreeKey]map[TreeKey]storageSnapshot
	codeChanges    map[TreeKey]codeSnapshot
	suicideChanges map[TreeKey]bool // previous suicided state
	logLength      int              // len(logs) at snapshot time
	refundValue    uint64           // refund counter at snapshot time
}

type accountSnapshot struct {
	existed bool
	balance *big.Int
	nonce   uint64
}

type storageSnapshot struct {
	value fr.Element
}

type codeSnapshot struct {
	code     []byte
	codeHash common.Hash
}

// Compile-time check that Adapter implements vm.StateDB.
var _ vm.StateDB = (*Adapter)(nil)

// NewAdapter creates a new StateDB adapter wrapping the Poseidon SMT state.
func NewAdapter(db *StateDB) *Adapter {
	return &Adapter{
		db:                  db,
		code:                make(map[TreeKey][]byte),
		codeHash:            make(map[TreeKey]common.Hash),
		suicided:            make(map[TreeKey]bool),
		logs:                nil,
		preimages:           make(map[common.Hash][]byte),
		accessListAddresses: make(map[common.Address]struct{}),
		accessListSlots:     make(map[common.Address]map[common.Hash]struct{}),
		transientStorage:    make(map[common.Address]map[common.Hash]common.Hash),
	}
}

// SetHooks sets the tracing hooks for state-change callbacks.
// The executor calls this before EVM execution so the tracer receives
// OnBalanceChange, OnStorageChange, and OnNonceChange events.
func (a *Adapter) SetHooks(hooks *tracing.Hooks) {
	a.hooks = hooks
}

// key converts a common.Address to a TreeKey for SMT lookup.
func key(addr common.Address) TreeKey {
	return AddressToKey(addr)
}

// ---------------------------------------------------------------------------
// Account management
// ---------------------------------------------------------------------------

func (a *Adapter) CreateAccount(addr common.Address) {
	k := key(addr)
	if !a.db.IsAlive(k) {
		a.journalAccount(k) // journal: account did not exist
		a.db.CreateAccount(k)
	}
}

func (a *Adapter) CreateContract(addr common.Address) {
	k := key(addr)
	if a.db.IsAlive(k) {
		// Address already exists (e.g., pre-funded or post-SELFDESTRUCT re-creation).
		// Clear old code and code hash so the new contract starts clean.
		a.journalCode(k) // journal old code before clearing
		delete(a.code, k)
		delete(a.codeHash, k)
	} else {
		a.journalAccount(k) // journal: account did not exist
		a.db.CreateAccount(k)
	}
}

// ---------------------------------------------------------------------------
// Balance
// ---------------------------------------------------------------------------

func (a *Adapter) GetBalance(addr common.Address) *uint256.Int {
	bal := a.db.GetBalance(key(addr))
	result, _ := uint256.FromBig(bal)
	return result
}

func (a *Adapter) AddBalance(addr common.Address, amount *uint256.Int, reason tracing.BalanceChangeReason) uint256.Int {
	k := key(addr)
	if !a.db.IsAlive(k) {
		a.journalAccount(k)
		a.db.CreateAccount(k)
	}
	a.journalAccount(k)
	prev := a.db.GetBalance(k)
	newBal := new(big.Int).Add(prev, amount.ToBig())
	a.db.SetBalance(k, newBal)
	if a.hooks != nil && a.hooks.OnBalanceChange != nil && !amount.IsZero() {
		a.hooks.OnBalanceChange(addr, prev, newBal, reason)
	}
	prevU, _ := uint256.FromBig(prev)
	return *prevU
}

func (a *Adapter) SubBalance(addr common.Address, amount *uint256.Int, reason tracing.BalanceChangeReason) uint256.Int {
	k := key(addr)
	a.journalAccount(k)
	prev := a.db.GetBalance(k)
	newBal := new(big.Int).Sub(prev, amount.ToBig())
	if newBal.Sign() < 0 {
		newBal.SetUint64(0)
	}
	a.db.SetBalance(k, newBal)
	if a.hooks != nil && a.hooks.OnBalanceChange != nil && !amount.IsZero() {
		a.hooks.OnBalanceChange(addr, prev, newBal, reason)
	}
	prevU, _ := uint256.FromBig(prev)
	return *prevU
}

// ---------------------------------------------------------------------------
// Nonce
// ---------------------------------------------------------------------------

func (a *Adapter) GetNonce(addr common.Address) uint64 {
	return a.db.GetNonce(key(addr))
}

func (a *Adapter) SetNonce(addr common.Address, nonce uint64, _ tracing.NonceChangeReason) {
	k := key(addr)
	if !a.db.IsAlive(k) {
		a.journalAccount(k)
		a.db.CreateAccount(k)
	}
	a.journalAccount(k)
	prev := a.db.GetNonce(k)
	a.db.SetNonce(k, nonce)
	if a.hooks != nil && a.hooks.OnNonceChange != nil {
		a.hooks.OnNonceChange(addr, prev, nonce)
	}
}

// ---------------------------------------------------------------------------
// Code
// ---------------------------------------------------------------------------

func (a *Adapter) GetCodeHash(addr common.Address) common.Hash {
	k := key(addr)
	if h, ok := a.codeHash[k]; ok {
		return h
	}
	// Defensive: if code exists in the code map but hash was not cached, compute it.
	if code, ok := a.code[k]; ok && len(code) > 0 {
		h := crypto.Keccak256Hash(code)
		a.codeHash[k] = h
		return h
	}
	if !a.db.IsAlive(k) {
		return common.Hash{}
	}
	// Account exists but has no code = empty code hash (types.EmptyCodeHash).
	// This value passes go-ethereum's collision check: contractHash == emptyCodeHash.
	return crypto.Keccak256Hash(nil)
}

func (a *Adapter) GetCode(addr common.Address) []byte {
	return a.code[key(addr)]
}

func (a *Adapter) SetCode(addr common.Address, code []byte) []byte {
	k := key(addr)
	a.journalCode(k)
	prev := a.code[k]
	a.code[k] = code
	h := crypto.Keccak256Hash(code)
	a.codeHash[k] = h
	// Sync the underlying Account.CodeHash for persistence consistency.
	var codeHashFr fr.Element
	codeHashFr.SetBytes(h[:])
	a.db.SetCodeHash(k, codeHashFr)
	return prev
}

func (a *Adapter) GetCodeSize(addr common.Address) int {
	return len(a.code[key(addr)])
}

// ---------------------------------------------------------------------------
// Refund
// ---------------------------------------------------------------------------

func (a *Adapter) AddRefund(gas uint64) { a.refund += gas }
func (a *Adapter) SubRefund(gas uint64) {
	if gas > a.refund {
		a.refund = 0
		return
	}
	a.refund -= gas
}
func (a *Adapter) GetRefund() uint64 { return a.refund }

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

func (a *Adapter) GetState(addr common.Address, slot common.Hash) common.Hash {
	k := key(addr)
	slotKey := SlotToKey(slot)
	elem := a.db.GetStorage(k, slotKey)
	return common.Hash(FieldElementToHash(elem))
}

func (a *Adapter) SetState(addr common.Address, slot common.Hash, value common.Hash) common.Hash {
	k := key(addr)
	slotKey := SlotToKey(slot)
	a.journalStorage(k, slotKey)
	prev := a.db.GetStorage(k, slotKey)
	prevHash := common.Hash(FieldElementToHash(prev))
	newElem := HashToFieldElement(value)
	a.db.SetStorage(k, slotKey, newElem)
	if a.hooks != nil && a.hooks.OnStorageChange != nil {
		a.hooks.OnStorageChange(addr, slot, prevHash, value)
	}
	return prevHash
}

func (a *Adapter) GetCommittedState(addr common.Address, slot common.Hash) common.Hash {
	// In a journaled system, committed state is the state before the tx.
	// For simplicity, return current state (correct for single-tx batches).
	return a.GetState(addr, slot)
}

func (a *Adapter) GetStorageRoot(addr common.Address) common.Hash {
	k := key(addr)
	if !a.db.IsAlive(k) {
		// Non-existent accounts must return zero hash.
		// go-ethereum's collision check treats non-zero, non-EmptyRootHash storage roots
		// as evidence of an existing contract (triggers ErrContractAddressCollision).
		return common.Hash{}
	}
	root := a.db.StorageRoot(k)
	// If storage root equals the empty Poseidon SMT root, return go-ethereum's
	// EmptyRootHash so the collision check recognizes this as empty storage.
	if root == a.db.EmptyStorageRoot() {
		return types.EmptyRootHash
	}
	return common.Hash(FieldElementToHash(root))
}

// ---------------------------------------------------------------------------
// Transient storage (EIP-1153)
// ---------------------------------------------------------------------------

func (a *Adapter) GetTransientState(addr common.Address, k common.Hash) common.Hash {
	if m, ok := a.transientStorage[addr]; ok {
		return m[k]
	}
	return common.Hash{}
}

func (a *Adapter) SetTransientState(addr common.Address, k, v common.Hash) {
	if _, ok := a.transientStorage[addr]; !ok {
		a.transientStorage[addr] = make(map[common.Hash]common.Hash)
	}
	a.transientStorage[addr][k] = v
}

// ---------------------------------------------------------------------------
// Self-destruct
// ---------------------------------------------------------------------------

func (a *Adapter) SelfDestruct(addr common.Address) uint256.Int {
	k := key(addr)
	a.journalAccount(k)
	a.journalSuicide(k)
	bal := a.db.GetBalance(k)
	a.suicided[k] = true
	a.db.SetBalance(k, new(big.Int))
	result, _ := uint256.FromBig(bal)
	return *result
}

func (a *Adapter) HasSelfDestructed(addr common.Address) bool {
	return a.suicided[key(addr)]
}

func (a *Adapter) SelfDestruct6780(addr common.Address) (uint256.Int, bool) {
	return a.SelfDestruct(addr), true
}

// ---------------------------------------------------------------------------
// Existence
// ---------------------------------------------------------------------------

func (a *Adapter) Exist(addr common.Address) bool {
	return a.db.IsAlive(key(addr))
}

func (a *Adapter) Empty(addr common.Address) bool {
	k := key(addr)
	if !a.db.IsAlive(k) {
		return true
	}
	bal := a.db.GetBalance(k)
	nonce := a.db.GetNonce(k)
	codeSize := len(a.code[k])
	return bal.Sign() == 0 && nonce == 0 && codeSize == 0
}

// ---------------------------------------------------------------------------
// Access lists (EIP-2929)
// ---------------------------------------------------------------------------

func (a *Adapter) AddressInAccessList(addr common.Address) bool {
	_, ok := a.accessListAddresses[addr]
	return ok
}

func (a *Adapter) SlotInAccessList(addr common.Address, slot common.Hash) (bool, bool) {
	_, addrOk := a.accessListAddresses[addr]
	if slots, ok := a.accessListSlots[addr]; ok {
		_, slotOk := slots[slot]
		return addrOk, slotOk
	}
	return addrOk, false
}

func (a *Adapter) AddAddressToAccessList(addr common.Address) {
	a.accessListAddresses[addr] = struct{}{}
}

func (a *Adapter) AddSlotToAccessList(addr common.Address, slot common.Hash) {
	a.accessListAddresses[addr] = struct{}{}
	if _, ok := a.accessListSlots[addr]; !ok {
		a.accessListSlots[addr] = make(map[common.Hash]struct{})
	}
	a.accessListSlots[addr][slot] = struct{}{}
}

// ---------------------------------------------------------------------------
// Snapshots (REVERT support)
// ---------------------------------------------------------------------------

// currentSnapshot returns the top snapshot on the stack, or nil if empty.
func (a *Adapter) currentSnapshot() *snapshot {
	if len(a.snapshots) == 0 {
		return nil
	}
	return &a.snapshots[len(a.snapshots)-1]
}

// journalAccount records the old account state in the current snapshot (first-write-wins).
func (a *Adapter) journalAccount(k TreeKey) {
	snap := a.currentSnapshot()
	if snap == nil {
		return
	}
	if _, exists := snap.accountChanges[k]; exists {
		return // first-write-wins: already journaled in this snapshot
	}
	snap.accountChanges[k] = accountSnapshot{
		existed: a.db.IsAlive(k),
		balance: a.db.GetBalance(k),
		nonce:   a.db.GetNonce(k),
	}
}

// journalStorage records the old storage value in the current snapshot (first-write-wins).
func (a *Adapter) journalStorage(contract, slot TreeKey) {
	snap := a.currentSnapshot()
	if snap == nil {
		return
	}
	if _, exists := snap.storageChanges[contract]; !exists {
		snap.storageChanges[contract] = make(map[TreeKey]storageSnapshot)
	}
	if _, exists := snap.storageChanges[contract][slot]; exists {
		return // first-write-wins
	}
	snap.storageChanges[contract][slot] = storageSnapshot{
		value: a.db.GetStorage(contract, slot),
	}
}

// journalCode records the old code in the current snapshot (first-write-wins).
func (a *Adapter) journalCode(k TreeKey) {
	snap := a.currentSnapshot()
	if snap == nil {
		return
	}
	if _, exists := snap.codeChanges[k]; exists {
		return // first-write-wins
	}
	// Copy the old code to prevent aliasing
	oldCode := a.code[k]
	codeCopy := make([]byte, len(oldCode))
	copy(codeCopy, oldCode)
	snap.codeChanges[k] = codeSnapshot{
		code:     codeCopy,
		codeHash: a.codeHash[k],
	}
}

// journalSuicide records the old suicided state in the current snapshot (first-write-wins).
func (a *Adapter) journalSuicide(k TreeKey) {
	snap := a.currentSnapshot()
	if snap == nil {
		return
	}
	if _, exists := snap.suicideChanges[k]; exists {
		return
	}
	snap.suicideChanges[k] = a.suicided[k]
}

func (a *Adapter) Snapshot() int {
	a.snapID++
	a.snapshots = append(a.snapshots, snapshot{
		id:             a.snapID,
		accountChanges: make(map[TreeKey]accountSnapshot),
		storageChanges: make(map[TreeKey]map[TreeKey]storageSnapshot),
		codeChanges:    make(map[TreeKey]codeSnapshot),
		suicideChanges: make(map[TreeKey]bool),
		logLength:      len(a.logs),
		refundValue:    a.refund,
	})
	return a.snapID
}

func (a *Adapter) RevertToSnapshot(id int) {
	// Find the snapshot with the matching id.
	idx := -1
	for i := len(a.snapshots) - 1; i >= 0; i-- {
		if a.snapshots[i].id == id {
			idx = i
			break
		}
	}
	if idx < 0 {
		return
	}

	// Walk snapshots from newest to target (inclusive), restoring old values.
	for i := len(a.snapshots) - 1; i >= idx; i-- {
		snap := a.snapshots[i]

		// Restore account state (balance, nonce, existence).
		for k, as := range snap.accountChanges {
			if !as.existed {
				// Account did not exist before this snapshot -- kill it.
				a.db.KillAccount(k)
			} else {
				// Restore old balance and nonce.
				a.db.SetBalance(k, as.balance)
				a.db.SetNonce(k, as.nonce)
			}
		}

		// Restore storage values.
		for contract, slots := range snap.storageChanges {
			for slot, ss := range slots {
				a.db.SetStorage(contract, slot, ss.value)
			}
		}

		// Restore code.
		for k, cs := range snap.codeChanges {
			if len(cs.code) == 0 {
				delete(a.code, k)
				delete(a.codeHash, k)
			} else {
				a.code[k] = cs.code
				a.codeHash[k] = cs.codeHash
			}
		}

		// Restore suicide flags.
		for k, wasSuicided := range snap.suicideChanges {
			if wasSuicided {
				a.suicided[k] = true
			} else {
				delete(a.suicided, k)
			}
		}
	}

	// Restore logs and refund from the target snapshot.
	targetSnap := a.snapshots[idx]
	a.logs = a.logs[:targetSnap.logLength]
	a.refund = targetSnap.refundValue

	// Truncate snapshots at the target.
	a.snapshots = a.snapshots[:idx]
}

// ---------------------------------------------------------------------------
// Logs and preimages
// ---------------------------------------------------------------------------

func (a *Adapter) AddLog(log *types.Log) {
	a.logs = append(a.logs, log)
}

func (a *Adapter) AddPreimage(hash common.Hash, preimage []byte) {
	a.preimages[hash] = preimage
}

// GetLogs returns all logs collected during execution.
func (a *Adapter) GetLogs() []*types.Log {
	return a.logs
}

// ---------------------------------------------------------------------------
// Advanced features (safe no-ops for enterprise L2)
// ---------------------------------------------------------------------------

func (a *Adapter) PointCache() *utils.PointCache { return nil }

func (a *Adapter) Prepare(rules params.Rules, sender, coinbase common.Address, dest *common.Address, precompiles []common.Address, txAccesses types.AccessList) {
	// Reset per-transaction state.
	a.accessListAddresses = make(map[common.Address]struct{})
	a.accessListSlots = make(map[common.Address]map[common.Hash]struct{})
	a.transientStorage = make(map[common.Address]map[common.Hash]common.Hash)

	// Add sender and precompiles to access list (EIP-2929).
	a.AddAddressToAccessList(sender)
	a.AddAddressToAccessList(coinbase)
	if dest != nil {
		a.AddAddressToAccessList(*dest)
	}
	for _, addr := range precompiles {
		a.AddAddressToAccessList(addr)
	}
	for _, entry := range txAccesses {
		a.AddAddressToAccessList(entry.Address)
		for _, slot := range entry.StorageKeys {
			a.AddSlotToAccessList(entry.Address, slot)
		}
	}
}

func (a *Adapter) Witness() *stateless.Witness { return nil }

func (a *Adapter) AccessEvents() *state.AccessEvents { return nil }

func (a *Adapter) Finalise(deleteEmptyObjects bool) {
	// Clear per-transaction state.
	a.suicided = make(map[TreeKey]bool)
	a.refund = 0
	a.logs = nil
	a.snapshots = nil
	a.snapID = 0
}

// ---------------------------------------------------------------------------
// Public helpers
// ---------------------------------------------------------------------------

// ResetTransaction prepares the adapter for a new transaction.
func (a *Adapter) ResetTransaction() {
	a.Finalise(true)
	a.transientStorage = make(map[common.Address]map[common.Hash]common.Hash)
}

// DB returns the underlying Poseidon SMT StateDB.
func (a *Adapter) DB() *StateDB {
	return a.db
}
