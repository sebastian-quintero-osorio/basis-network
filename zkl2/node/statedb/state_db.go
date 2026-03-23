package statedb

import (
	"math/big"

	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
)

// StateDB implements the EVM state database as a two-level Sparse Merkle Tree.
//
// Level 1 (Account Trie): Maps addresses to account hashes.
//
//	key = address, value = Poseidon(balance, storageRoot)
//
// Level 2 (Storage Tries): One SMT per contract, mapping slots to values.
//
//	key = slot, value = storage value (BN254 field element)
//
// All mutations update roots incrementally via O(depth) WalkUp operations.
// The two-level structure ensures account isolation (operations on account A
// do not affect account B) and storage isolation (contract A's storage is
// independent of contract B's storage).
//
// [Spec: StateDatabase.tla -- full two-level trie specification]
type StateDB struct {
	accountTrie      *SparseMerkleTree            // Level 1: address -> account hash
	storageTries     map[TreeKey]*SparseMerkleTree // Level 2: one SMT per contract
	accounts         map[TreeKey]*Account          // Account data (balance, nonce, etc.)
	storageDepth     int                           // Depth for new storage tries
	emptyStorageRoot fr.Element                    // DefaultHash(storageDepth) -- cached
}

// NewStateDB creates a new empty StateDB with the given configuration.
//
// [Spec: Init -- genesis state with empty tries]
func NewStateDB(cfg Config) *StateDB {
	// Compute the empty storage root: DefaultHash(storageDepth).
	// This is the root of an all-empty storage trie.
	tmpStorage := NewSparseMerkleTree(cfg.StorageDepth)
	emptyStorageRoot := tmpStorage.Root()

	return &StateDB{
		accountTrie:      NewSparseMerkleTree(cfg.AccountDepth),
		storageTries:     make(map[TreeKey]*SparseMerkleTree),
		accounts:         make(map[TreeKey]*Account),
		storageDepth:     cfg.StorageDepth,
		emptyStorageRoot: emptyStorageRoot,
	}
}

// getOrCreateStorageTrie returns the storage trie for an address, creating one if needed.
func (db *StateDB) getOrCreateStorageTrie(addr TreeKey) *SparseMerkleTree {
	if trie, ok := db.storageTries[addr]; ok {
		return trie
	}
	trie := NewSparseMerkleTree(db.storageDepth)
	db.storageTries[addr] = trie
	return trie
}

// accountValue computes the trie value for an account.
// Dead or nonexistent accounts return zero (EMPTY).
// Live accounts: Poseidon(balance, storageRoot).
//
// [Spec: AccountValue(addr) == IF ~alive[addr] THEN EMPTY ELSE Hash(balances[addr], storageRoot)]
func (db *StateDB) accountValue(addr TreeKey) fr.Element {
	acct, ok := db.accounts[addr]
	if !ok || !acct.Alive {
		return fr.Element{} // EMPTY
	}
	var balElem fr.Element
	balElem.SetBigInt(acct.Balance)
	return db.accountTrie.Hash(&balElem, &acct.StorageRoot)
}

// CreateAccount activates a dormant account at the given address.
// The account is created with zero balance, zero nonce, and empty storage.
//
// Returns ErrAccountAlreadyAlive if the account is already alive.
//
// Single-step incremental account root update via WalkUp.
//
// [Spec: CreateAccount(addr)]
// [Spec: Guard: ~alive[addr]]
func (db *StateDB) CreateAccount(addr TreeKey) error {
	if acct, ok := db.accounts[addr]; ok && acct.Alive {
		return ErrAccountAlreadyAlive
	}

	acct := NewAccount()
	acct.StorageRoot = db.emptyStorageRoot
	db.accounts[addr] = acct

	// Update account trie with the new account value.
	// [Spec: accountRoot' = WalkUp(AccountEntries, newLeaf, addr, 0, ACCOUNT_DEPTH)]
	val := db.accountValue(addr)
	db.accountTrie.Insert(addr, val)

	return nil
}

// Transfer moves balance from one alive account to another.
// Both accounts must be alive. Amount must be positive.
// Sender must have sufficient balance.
//
// Two-step incremental account root update:
//   - Step 1: Update sender leaf using current tree siblings.
//   - Step 2: Update receiver leaf using intermediate tree siblings.
//
// [Spec: Transfer(from, to, amount)]
// [Spec: Guards: alive[from], alive[to], from # to, amount > 0, balances[from] >= amount]
func (db *StateDB) Transfer(from, to TreeKey, amount *big.Int) error {
	if from == to {
		return ErrSelfTransfer
	}
	if amount.Sign() <= 0 {
		return ErrZeroAmount
	}

	fromAcct, ok := db.accounts[from]
	if !ok || !fromAcct.Alive {
		return ErrAccountNotAlive
	}
	toAcct, ok := db.accounts[to]
	if !ok || !toAcct.Alive {
		return ErrAccountNotAlive
	}
	if fromAcct.Balance.Cmp(amount) < 0 {
		return ErrInsufficientBalance
	}

	// Step 1: Debit sender, update account trie.
	// [Spec: interEntries == [AccountEntries EXCEPT ![from] = newFromVal]]
	fromAcct.Balance.Sub(fromAcct.Balance, amount)
	val := db.accountValue(from)
	db.accountTrie.Insert(from, val)

	// Step 2: Credit receiver, update account trie with intermediate siblings.
	// [Spec: finalRoot == WalkUp(interEntries, newToLeaf, to, 0, ACCOUNT_DEPTH)]
	toAcct.Balance.Add(toAcct.Balance, amount)
	val = db.accountValue(to)
	db.accountTrie.Insert(to, val)

	return nil
}

// SetStorage writes a value to an account's storage slot.
// The account must be alive. Setting value to zero deletes the slot.
//
// Two-level incremental update:
//   - Level 2: Update storage trie -> new storageRoot.
//   - Level 1: Update account trie (account hash changed due to new storageRoot).
//
// [Spec: SetStorage(contract, slot, value)]
// [Spec: Guards: contract \in Contracts, alive[contract], slot \in Slots]
func (db *StateDB) SetStorage(contract, slot TreeKey, value fr.Element) error {
	acct, ok := db.accounts[contract]
	if !ok || !acct.Alive {
		return ErrAccountNotAlive
	}

	// Level 2: Update storage trie.
	// [Spec: newSR == WalkUp(oldSE, newSLeaf, slot, 0, STORAGE_DEPTH)]
	storageTrie := db.getOrCreateStorageTrie(contract)
	storageTrie.Insert(slot, value)

	// Update account's cached storage root.
	// [Spec: storageRoots' = [storageRoots EXCEPT ![contract] = newSR]]
	acct.StorageRoot = storageTrie.Root()

	// Level 1: Update account trie (account hash changed).
	// [Spec: accountRoot' = WalkUp(AccountEntries, newAccLeaf, contract, 0, ACCOUNT_DEPTH)]
	val := db.accountValue(contract)
	db.accountTrie.Insert(contract, val)

	return nil
}

// SelfDestruct destroys a contract, transferring its remaining balance to a beneficiary.
// Both the contract and beneficiary must be alive. They must be different addresses.
//
// Effects:
//   - Contract: alive=false, balance=0, all storage cleared, storageRoot reset.
//   - Beneficiary: balance increased by contract's former balance.
//
// Two-step account trie update:
//   - Step 1: Kill contract (leaf -> EMPTY).
//   - Step 2: Credit beneficiary using intermediate tree.
//
// [Spec: SelfDestruct(contract, beneficiary)]
// [Spec: Guards: contract \in Contracts, alive[contract], alive[beneficiary], contract # beneficiary]
func (db *StateDB) SelfDestruct(contract, beneficiary TreeKey) error {
	if contract == beneficiary {
		return ErrSelfDestructToSelf
	}

	contractAcct, ok := db.accounts[contract]
	if !ok || !contractAcct.Alive {
		return ErrAccountNotAlive
	}
	benAcct, ok := db.accounts[beneficiary]
	if !ok || !benAcct.Alive {
		return ErrAccountNotAlive
	}

	contractBalance := new(big.Int).Set(contractAcct.Balance)

	// Step 1: Kill the contract.
	// [Spec: alive' = [alive EXCEPT ![contract] = FALSE]]
	// [Spec: balances' = [balances EXCEPT ![contract] = 0, ...]]
	// [Spec: storageData' = [storageData EXCEPT ![contract] = [s \in Slots |-> EMPTY]]]
	// [Spec: storageRoots' = [storageRoots EXCEPT ![contract] = DefaultHash(STORAGE_DEPTH)]]
	contractAcct.Alive = false
	contractAcct.Balance.SetUint64(0)
	contractAcct.StorageRoot = db.emptyStorageRoot

	// Clear all storage by replacing with empty trie.
	if _, ok := db.storageTries[contract]; ok {
		delete(db.storageTries, contract)
	}

	// Update account trie: contract becomes EMPTY (dead account).
	// [Spec: interRoot == WalkUp(AccountEntries, deadLeaf, contract, 0, ACCOUNT_DEPTH)]
	val := db.accountValue(contract) // returns EMPTY since not alive
	db.accountTrie.Insert(contract, val)

	// Step 2: Credit beneficiary.
	// [Spec: balances' = [balances EXCEPT ![beneficiary] = @ + balances[contract]]]
	// [Spec: finalRoot == WalkUp(interEntries, newBenLeaf, beneficiary, 0, ACCOUNT_DEPTH)]
	benAcct.Balance.Add(benAcct.Balance, contractBalance)
	val = db.accountValue(beneficiary)
	db.accountTrie.Insert(beneficiary, val)

	return nil
}

// GetBalance returns the balance of an account.
// Returns zero for nonexistent or dead accounts.
//
// [Spec: balances[addr] -- read-only access]
func (db *StateDB) GetBalance(addr TreeKey) *big.Int {
	acct, ok := db.accounts[addr]
	if !ok || !acct.Alive {
		return new(big.Int)
	}
	return new(big.Int).Set(acct.Balance)
}

// SetBalance sets the balance of an alive account directly.
// Returns ErrAccountNotAlive if the account does not exist or is dead.
func (db *StateDB) SetBalance(addr TreeKey, balance *big.Int) error {
	acct, ok := db.accounts[addr]
	if !ok || !acct.Alive {
		return ErrAccountNotAlive
	}

	acct.Balance.Set(balance)
	val := db.accountValue(addr)
	db.accountTrie.Insert(addr, val)

	return nil
}

// GetNonce returns the nonce of an account. Returns 0 for nonexistent accounts.
func (db *StateDB) GetNonce(addr TreeKey) uint64 {
	acct, ok := db.accounts[addr]
	if !ok || !acct.Alive {
		return 0
	}
	return acct.Nonce
}

// SetNonce sets the nonce of an alive account.
func (db *StateDB) SetNonce(addr TreeKey, nonce uint64) error {
	acct, ok := db.accounts[addr]
	if !ok || !acct.Alive {
		return ErrAccountNotAlive
	}
	acct.Nonce = nonce
	val := db.accountValue(addr)
	db.accountTrie.Insert(addr, val)
	return nil
}

// SetCodeHash updates the code hash field on an alive account.
// This is called by the adapter when SetCode is invoked so the underlying
// Account struct stays consistent with the adapter's in-memory code map.
func (db *StateDB) SetCodeHash(addr TreeKey, hash fr.Element) {
	acct, ok := db.accounts[addr]
	if !ok || !acct.Alive {
		return
	}
	acct.CodeHash = hash
}

// KillAccount marks an account as dead and removes it from the trie.
// Used by the adapter's RevertToSnapshot to undo account creation.
func (db *StateDB) KillAccount(addr TreeKey) {
	acct, ok := db.accounts[addr]
	if !ok {
		return
	}
	acct.Alive = false
	acct.Balance.SetUint64(0)
	acct.Nonce = 0
	// Update account trie (dead account = EMPTY leaf).
	val := db.accountValue(addr)
	db.accountTrie.Insert(addr, val)
}

// EmptyStorageRoot returns the root hash of an empty storage trie.
// This is the DefaultHash(storageDepth) from the Poseidon SMT.
func (db *StateDB) EmptyStorageRoot() fr.Element {
	return db.emptyStorageRoot
}

// GetStorage returns the value at an account's storage slot.
// Returns zero for nonexistent accounts, dead accounts, or empty slots.
//
// GetStorage is a read-only operation. Its correctness is verified by the
// StorageIsolation invariant: every storage slot has a valid Merkle proof
// against the contract's storage root.
//
// [Spec: StorageIsolation invariant verifies GetStorage semantics]
func (db *StateDB) GetStorage(contract, slot TreeKey) fr.Element {
	storageTrie, ok := db.storageTries[contract]
	if !ok {
		return fr.Element{}
	}
	val, _ := storageTrie.Get(slot)
	return val
}

// GetAccount returns a copy of the account at the given address.
// Returns nil if the account has never been created.
func (db *StateDB) GetAccount(addr TreeKey) *Account {
	acct, ok := db.accounts[addr]
	if !ok {
		return nil
	}
	return &Account{
		Nonce:       acct.Nonce,
		Balance:     new(big.Int).Set(acct.Balance),
		StorageRoot: acct.StorageRoot,
		CodeHash:    acct.CodeHash,
		Alive:       acct.Alive,
	}
}

// IsAlive returns whether the account at the given address exists and is alive.
//
// [Spec: alive[addr]]
func (db *StateDB) IsAlive(addr TreeKey) bool {
	acct, ok := db.accounts[addr]
	return ok && acct.Alive
}

// StateRoot returns the current state root (account trie root hash).
//
// [Spec: accountRoot]
func (db *StateDB) StateRoot() fr.Element {
	return db.accountTrie.Root()
}

// StorageRoot returns the storage trie root for an address.
// Returns the empty storage root for addresses without storage.
//
// [Spec: storageRoots[contract] for contracts; DefaultHash(STORAGE_DEPTH) for EOAs]
func (db *StateDB) StorageRoot(addr TreeKey) fr.Element {
	if trie, ok := db.storageTries[addr]; ok {
		return trie.Root()
	}
	return db.emptyStorageRoot
}

// GetAccountProof generates a Merkle proof for an account in the account trie.
func (db *StateDB) GetAccountProof(addr TreeKey) MerkleProof {
	return db.accountTrie.GetProof(addr)
}

// GetStorageProof generates a Merkle proof for a storage slot in a contract's storage trie.
func (db *StateDB) GetStorageProof(contract, slot TreeKey) MerkleProof {
	storageTrie, ok := db.storageTries[contract]
	if !ok {
		storageTrie = NewSparseMerkleTree(db.storageDepth)
	}
	return storageTrie.GetProof(slot)
}

// VerifyAccountProof verifies a Merkle proof against the current state root.
func (db *StateDB) VerifyAccountProof(proof MerkleProof) bool {
	return db.accountTrie.VerifyProof(db.StateRoot(), proof)
}

// VerifyStorageProof verifies a storage proof against a contract's storage root.
func (db *StateDB) VerifyStorageProof(contract TreeKey, proof MerkleProof) bool {
	sr := db.StorageRoot(contract)
	storageTrie, ok := db.storageTries[contract]
	if !ok {
		storageTrie = NewSparseMerkleTree(db.storageDepth)
	}
	return storageTrie.VerifyProof(sr, proof)
}

// TotalBalance returns the sum of all account balances.
// Used to verify the BalanceConservation invariant.
//
// [Spec: TotalBalance == SumOver(balances, Addresses)]
func (db *StateDB) TotalBalance() *big.Int {
	total := new(big.Int)
	for _, acct := range db.accounts {
		total.Add(total, acct.Balance)
	}
	return total
}

// AccountCount returns the number of accounts (alive or dead) that have been created.
func (db *StateDB) AccountCount() int {
	return len(db.accounts)
}

// AliveAccountCount returns the number of currently alive accounts.
func (db *StateDB) AliveAccountCount() int {
	count := 0
	for _, acct := range db.accounts {
		if acct.Alive {
			count++
		}
	}
	return count
}
