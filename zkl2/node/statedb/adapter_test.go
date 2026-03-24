package statedb

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
)

// ---------------------------------------------------------------------------
// Adapter unit tests
// ---------------------------------------------------------------------------

func testAdapter() (*Adapter, *StateDB) {
	cfg := Config{AccountDepth: 8, StorageDepth: 8}
	db := NewStateDB(cfg)
	adapter := NewAdapter(db)
	return adapter, db
}

func TestAdapter_CreateAndGetBalance(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x1111111111111111111111111111111111111111")

	// Account doesn't exist yet.
	if a.Exist(addr) {
		t.Error("account should not exist before creation")
	}
	bal := a.GetBalance(addr)
	if bal.Sign() != 0 {
		t.Errorf("expected zero balance, got %s", bal)
	}

	// Create and fund.
	a.CreateAccount(addr)
	if !a.Exist(addr) {
		t.Error("account should exist after creation")
	}

	amount := uint256.NewInt(1000000)
	a.AddBalance(addr, amount, tracing.BalanceChangeUnspecified)
	bal = a.GetBalance(addr)
	if bal.Uint64() != 1000000 {
		t.Errorf("expected balance 1000000, got %s", bal)
	}
}

func TestAdapter_SubBalance(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x1111111111111111111111111111111111111111")

	a.CreateAccount(addr)
	a.AddBalance(addr, uint256.NewInt(5000), tracing.BalanceChangeUnspecified)
	a.SubBalance(addr, uint256.NewInt(2000), tracing.BalanceChangeUnspecified)

	bal := a.GetBalance(addr)
	if bal.Uint64() != 3000 {
		t.Errorf("expected 3000, got %s", bal)
	}
}

func TestAdapter_NonceOperations(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x1111111111111111111111111111111111111111")

	a.CreateAccount(addr)
	if a.GetNonce(addr) != 0 {
		t.Errorf("expected initial nonce 0, got %d", a.GetNonce(addr))
	}

	a.SetNonce(addr, 42, tracing.NonceChangeUnspecified)
	if a.GetNonce(addr) != 42 {
		t.Errorf("expected nonce 42, got %d", a.GetNonce(addr))
	}
}

func TestAdapter_StorageOperations(t *testing.T) {
	a, db := testAdapter()
	addr := common.HexToAddress("0x3333333333333333333333333333333333333333")
	slot := common.HexToHash("0x01")
	value := common.HexToHash("0x42")

	a.CreateAccount(addr)
	a.SetCode(addr, []byte{0x60, 0x00}) // Minimal contract code

	// Set storage via adapter.
	prev := a.SetState(addr, slot, value)
	if prev != (common.Hash{}) {
		t.Errorf("expected zero prev value, got %s", prev.Hex())
	}

	// Read back via adapter.
	got := a.GetState(addr, slot)
	if got != value {
		t.Errorf("expected %s, got %s", value.Hex(), got.Hex())
	}

	// Verify the underlying Poseidon SMT was updated.
	smtKey := AddressToKey(addr)
	smtSlot := SlotToKey(slot)
	smtVal := db.GetStorage(smtKey, smtSlot)
	if smtVal.IsZero() {
		t.Error("expected non-zero value in Poseidon SMT")
	}
}

func TestAdapter_CodeOperations(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x4444444444444444444444444444444444444444")

	a.CreateAccount(addr)
	code := []byte{0x60, 0x42, 0x60, 0x00, 0x55, 0x00} // PUSH 0x42, PUSH 0, SSTORE, STOP

	a.SetCode(addr, code)
	if a.GetCodeSize(addr) != len(code) {
		t.Errorf("expected code size %d, got %d", len(code), a.GetCodeSize(addr))
	}
	if !bytesEqual(a.GetCode(addr), code) {
		t.Error("code mismatch")
	}
	if a.GetCodeHash(addr) == (common.Hash{}) {
		t.Error("expected non-zero code hash")
	}
}

func TestAdapter_ExistAndEmpty(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x5555555555555555555555555555555555555555")

	if a.Exist(addr) {
		t.Error("should not exist before creation")
	}
	if !a.Empty(addr) {
		t.Error("non-existent account should be empty")
	}

	a.CreateAccount(addr)
	if !a.Exist(addr) {
		t.Error("should exist after creation")
	}
	if !a.Empty(addr) {
		t.Error("newly created account should be empty (zero balance/nonce/code)")
	}

	a.AddBalance(addr, uint256.NewInt(1), tracing.BalanceChangeUnspecified)
	if a.Empty(addr) {
		t.Error("account with balance should not be empty")
	}
}

func TestAdapter_AccessList(t *testing.T) {
	a, _ := testAdapter()
	sender := common.HexToAddress("0xaaaa")
	coinbase := common.HexToAddress("0xbbbb")
	dest := common.HexToAddress("0xcccc")

	a.Prepare(params.Rules{}, sender, coinbase, &dest, nil, nil)

	if !a.AddressInAccessList(sender) {
		t.Error("sender should be in access list after Prepare")
	}
	if !a.AddressInAccessList(coinbase) {
		t.Error("coinbase should be in access list after Prepare")
	}
	if !a.AddressInAccessList(dest) {
		t.Error("dest should be in access list after Prepare")
	}

	unknownAddr := common.HexToAddress("0xdddd")
	if a.AddressInAccessList(unknownAddr) {
		t.Error("unknown address should not be in access list")
	}
}

func TestAdapter_TransientStorage(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x6666")
	key := common.HexToHash("0x01")
	val := common.HexToHash("0xff")

	a.SetTransientState(addr, key, val)
	got := a.GetTransientState(addr, key)
	if got != val {
		t.Errorf("expected %s, got %s", val.Hex(), got.Hex())
	}

	// After Finalise, transient storage should be cleared.
	a.Finalise(true)
	// Note: Finalise clears suicided/refund/logs/snapshots but transient storage
	// is cleared by ResetTransaction. Let's call that.
	a.ResetTransaction()
	got = a.GetTransientState(addr, key)
	if got != (common.Hash{}) {
		t.Error("transient storage should be cleared after ResetTransaction")
	}
}

func TestAdapter_SelfDestruct(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x7777")

	a.CreateAccount(addr)
	a.AddBalance(addr, uint256.NewInt(5000), tracing.BalanceChangeUnspecified)

	if a.HasSelfDestructed(addr) {
		t.Error("should not be self-destructed before call")
	}

	prev := a.SelfDestruct(addr)
	if prev.Uint64() != 5000 {
		t.Errorf("expected previous balance 5000, got %d", prev.Uint64())
	}
	if !a.HasSelfDestructed(addr) {
		t.Error("should be self-destructed after call")
	}
	// Balance should be zeroed.
	if a.GetBalance(addr).Uint64() != 0 {
		t.Error("balance should be zero after self-destruct")
	}
}

func TestAdapter_Logs(t *testing.T) {
	a, _ := testAdapter()
	log1 := &types.Log{Address: common.HexToAddress("0x01"), Data: []byte{1}}
	log2 := &types.Log{Address: common.HexToAddress("0x02"), Data: []byte{2}}

	a.AddLog(log1)
	a.AddLog(log2)

	logs := a.GetLogs()
	if len(logs) != 2 {
		t.Errorf("expected 2 logs, got %d", len(logs))
	}
}

func TestAdapter_SnapshotRevert(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x8888")

	a.CreateAccount(addr)
	a.AddBalance(addr, uint256.NewInt(1000), tracing.BalanceChangeUnspecified)

	// Take snapshot.
	snapID := a.Snapshot()

	// Modify state.
	a.AddBalance(addr, uint256.NewInt(5000), tracing.BalanceChangeUnspecified)
	if a.GetBalance(addr).Uint64() != 6000 {
		t.Errorf("expected 6000 after add, got %d", a.GetBalance(addr).Uint64())
	}

	// Revert.
	a.RevertToSnapshot(snapID)

	// Note: Our snapshot/revert is structural (for EVM compatibility).
	// The Poseidon SMT state is the source of truth. For full revert
	// support, a journal system would be needed. This test verifies
	// the snapshot mechanism doesn't panic.
	_ = a.GetBalance(addr) // Should not panic
}

// ---------------------------------------------------------------------------
// EVM Execution Integration Test
// ---------------------------------------------------------------------------

func TestAdapter_EVMExecution_SimpleTransfer(t *testing.T) {
	a, db := testAdapter()
	sender := common.HexToAddress("0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
	recipient := common.HexToAddress("0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")

	// Fund sender.
	a.CreateAccount(sender)
	a.AddBalance(sender, uint256.NewInt(1_000_000), tracing.BalanceChangeUnspecified)
	a.SetNonce(sender, 0, tracing.NonceChangeUnspecified)

	// Create recipient.
	a.CreateAccount(recipient)

	// Record initial state root.
	rootBefore := db.StateRoot()

	// Build EVM and execute a simple value transfer.
	blockCtx := vm.BlockContext{
		CanTransfer: func(db vm.StateDB, addr common.Address, amount *uint256.Int) bool {
			return db.GetBalance(addr).Cmp(amount) >= 0
		},
		Transfer: func(db vm.StateDB, sender, recipient common.Address, amount *uint256.Int) {
			db.SubBalance(sender, amount, tracing.BalanceChangeTransfer)
			db.AddBalance(recipient, amount, tracing.BalanceChangeTransfer)
		},
		GetHash:     func(n uint64) common.Hash { return common.Hash{} },
		BlockNumber: new(big.Int).SetUint64(1),
		Time:        1700000000,
		GasLimit:    30_000_000,
		BaseFee:     new(big.Int),
	}

	chainConfig := &params.ChainConfig{
		ChainID:             big.NewInt(431990),
		HomesteadBlock:      big.NewInt(0),
		EIP150Block:         big.NewInt(0),
		EIP155Block:         big.NewInt(0),
		EIP158Block:         big.NewInt(0),
		ByzantiumBlock:      big.NewInt(0),
		ConstantinopleBlock: big.NewInt(0),
		PetersburgBlock:     big.NewInt(0),
		IstanbulBlock:       big.NewInt(0),
		BerlinBlock:         big.NewInt(0),
		LondonBlock:         big.NewInt(0),
		ShanghaiTime:        uint64Ptr(0),
		CancunTime:          uint64Ptr(0),
	}

	evm := vm.NewEVM(blockCtx, a, chainConfig, vm.Config{})
	evm.SetTxContext(vm.TxContext{
		Origin:   sender,
		GasPrice: new(big.Int),
	})

	// Execute: transfer 100,000 wei from sender to recipient.
	transferAmount := uint256.NewInt(100_000)
	_, _, err := evm.Call(sender, recipient, nil, 21000, transferAmount)
	if err != nil {
		t.Fatalf("EVM call failed: %v", err)
	}

	// Verify balances through the adapter.
	senderBal := a.GetBalance(sender)
	recipientBal := a.GetBalance(recipient)

	if senderBal.Uint64() != 900_000 {
		t.Errorf("sender balance: expected 900000, got %d", senderBal.Uint64())
	}
	if recipientBal.Uint64() != 100_000 {
		t.Errorf("recipient balance: expected 100000, got %d", recipientBal.Uint64())
	}

	// Verify the Poseidon SMT root changed.
	rootAfter := db.StateRoot()
	if rootBefore == rootAfter {
		t.Error("expected state root to change after transfer")
	}

	// Verify balances in the underlying Poseidon SMT.
	senderKey := AddressToKey(sender)
	recipientKey := AddressToKey(recipient)
	smtSenderBal := db.GetBalance(senderKey)
	smtRecipientBal := db.GetBalance(recipientKey)

	if smtSenderBal.Cmp(big.NewInt(900_000)) != 0 {
		t.Errorf("SMT sender balance: expected 900000, got %s", smtSenderBal)
	}
	if smtRecipientBal.Cmp(big.NewInt(100_000)) != 0 {
		t.Errorf("SMT recipient balance: expected 100000, got %s", smtRecipientBal)
	}
}

func TestAdapter_EVMExecution_ContractSSTORE(t *testing.T) {
	a, db := testAdapter()
	sender := common.HexToAddress("0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
	contractAddr := common.HexToAddress("0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC")

	// Fund sender and deploy contract.
	a.CreateAccount(sender)
	a.AddBalance(sender, uint256.NewInt(1_000_000), tracing.BalanceChangeUnspecified)
	a.CreateAccount(contractAddr)

	// Bytecode: PUSH1 0x42, PUSH1 0x00, SSTORE, STOP
	// Stores value 0x42 at storage slot 0.
	bytecode := []byte{0x60, 0x42, 0x60, 0x00, 0x55, 0x00}
	a.SetCode(contractAddr, bytecode)

	// Execute contract.
	blockCtx := vm.BlockContext{
		CanTransfer: func(db vm.StateDB, addr common.Address, amount *uint256.Int) bool {
			return db.GetBalance(addr).Cmp(amount) >= 0
		},
		Transfer: func(db vm.StateDB, sender, recipient common.Address, amount *uint256.Int) {
			db.SubBalance(sender, amount, tracing.BalanceChangeTransfer)
			db.AddBalance(recipient, amount, tracing.BalanceChangeTransfer)
		},
		GetHash:     func(n uint64) common.Hash { return common.Hash{} },
		BlockNumber: new(big.Int).SetUint64(1),
		Time:        1700000000,
		GasLimit:    30_000_000,
		BaseFee:     new(big.Int),
	}

	chainConfig := &params.ChainConfig{
		ChainID:             big.NewInt(431990),
		HomesteadBlock:      big.NewInt(0),
		EIP150Block:         big.NewInt(0),
		EIP155Block:         big.NewInt(0),
		EIP158Block:         big.NewInt(0),
		ByzantiumBlock:      big.NewInt(0),
		ConstantinopleBlock: big.NewInt(0),
		PetersburgBlock:     big.NewInt(0),
		IstanbulBlock:       big.NewInt(0),
		BerlinBlock:         big.NewInt(0),
		LondonBlock:         big.NewInt(0),
		ShanghaiTime:        uint64Ptr(0),
		CancunTime:          uint64Ptr(0),
	}

	evm := vm.NewEVM(blockCtx, a, chainConfig, vm.Config{})
	evm.SetTxContext(vm.TxContext{
		Origin:   sender,
		GasPrice: new(big.Int),
	})

	_, _, err := evm.Call(sender, contractAddr, nil, 100_000, uint256.NewInt(0))
	if err != nil {
		t.Fatalf("EVM call failed: %v", err)
	}

	// Verify storage was set via adapter.
	slot := common.HexToHash("0x00")
	value := a.GetState(contractAddr, slot)
	expected := common.HexToHash("0x42")
	if value != expected {
		t.Errorf("storage slot 0: expected 0x42, got %s", value.Hex())
	}

	// Verify storage in the underlying Poseidon SMT.
	smtContract := AddressToKey(contractAddr)
	smtSlot := SlotToKey(slot)
	smtVal := db.GetStorage(smtContract, smtSlot)
	if smtVal.IsZero() {
		t.Error("expected non-zero value in Poseidon SMT storage")
	}
}

// ---------------------------------------------------------------------------
// Contract deployment tests
// ---------------------------------------------------------------------------

func TestAdapter_ContractDeploymentViaCreate(t *testing.T) {
	a, db := testAdapter()
	deployer := common.HexToAddress("0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

	// Fund deployer.
	a.CreateAccount(deployer)
	a.AddBalance(deployer, uint256.NewInt(10_000_000), tracing.BalanceChangeUnspecified)

	// Simulate what go-ethereum's evm.Create does:
	// 1. Compute contract address (keccak256(rlp(sender, nonce)))
	contractAddr := common.HexToAddress("0xDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD")

	// 2. Collision check: GetCodeHash must return zero hash for non-existent address
	codeHash := a.GetCodeHash(contractAddr)
	if codeHash != (common.Hash{}) {
		t.Fatalf("expected zero hash for non-existent address, got %s", codeHash.Hex())
	}
	if a.GetNonce(contractAddr) != 0 {
		t.Fatalf("expected nonce 0 for non-existent address")
	}

	// 3. CreateContract
	a.CreateContract(contractAddr)
	if !a.Exist(contractAddr) {
		t.Fatal("contract address should exist after CreateContract")
	}

	// 4. Set nonce to 1 (go-ethereum sets nonce=1 for new contracts)
	a.SetNonce(contractAddr, 1, tracing.NonceChangeUnspecified)

	// 5. Simulate init code execution: store value at slot 0
	slot := common.HexToHash("0x00")
	value := common.HexToHash("0x42")
	a.SetState(contractAddr, slot, value)

	// 6. SetCode with deployed bytecode
	bytecode := []byte{0x60, 0x42, 0x60, 0x00, 0x55, 0x00} // PUSH 0x42, PUSH 0, SSTORE, STOP
	a.SetCode(contractAddr, bytecode)

	// Verify everything is consistent
	if a.GetCodeSize(contractAddr) != len(bytecode) {
		t.Errorf("code size mismatch: expected %d, got %d", len(bytecode), a.GetCodeSize(contractAddr))
	}
	gotHash := a.GetCodeHash(contractAddr)
	if gotHash == (common.Hash{}) {
		t.Error("code hash should not be zero after SetCode")
	}
	gotState := a.GetState(contractAddr, slot)
	if gotState != value {
		t.Errorf("storage mismatch: expected %s, got %s", value.Hex(), gotState.Hex())
	}
	if a.GetNonce(contractAddr) != 1 {
		t.Errorf("nonce should be 1, got %d", a.GetNonce(contractAddr))
	}

	// Verify the Poseidon SMT was updated
	smtKey := AddressToKey(contractAddr)
	if !db.IsAlive(smtKey) {
		t.Error("contract should be alive in Poseidon SMT")
	}
	smtSlot := SlotToKey(slot)
	smtVal := db.GetStorage(smtKey, smtSlot)
	if smtVal.IsZero() {
		t.Error("expected non-zero storage in Poseidon SMT")
	}
}

func TestAdapter_GetCodeHash_PreFundedAddress(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0xEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE")

	// Pre-fund the address (alive, no code).
	a.CreateAccount(addr)
	a.AddBalance(addr, uint256.NewInt(1_000_000), tracing.BalanceChangeUnspecified)

	// GetCodeHash for alive account with no code = emptyCodeHash.
	// This must NOT trigger go-ethereum's collision check.
	emptyCodeHash := common.HexToHash("0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
	gotHash := a.GetCodeHash(addr)
	if gotHash != emptyCodeHash {
		t.Errorf("expected emptyCodeHash for alive account with no code, got %s", gotHash.Hex())
	}

	// Collision check simulation: nonce==0 && (hash==zero || hash==emptyCodeHash) => no collision
	nonce := a.GetNonce(addr)
	isCollision := nonce != 0 || (gotHash != (common.Hash{}) && gotHash != emptyCodeHash)
	if isCollision {
		t.Error("pre-funded address should NOT trigger collision check")
	}

	// Deploy contract at this pre-funded address
	a.CreateContract(addr)
	a.SetNonce(addr, 1, tracing.NonceChangeUnspecified)
	a.SetCode(addr, []byte{0x60, 0x00, 0x55, 0x00})

	// Now GetCodeHash should return the real hash
	gotHash = a.GetCodeHash(addr)
	if gotHash == emptyCodeHash || gotHash == (common.Hash{}) {
		t.Error("code hash should be real hash after SetCode, not empty")
	}
}

func TestAdapter_CreateContract_ClearsOldCode(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF")

	// Deploy first contract
	a.CreateAccount(addr)
	a.SetCode(addr, []byte{0x60, 0x42, 0x00}) // PUSH 0x42, STOP
	a.SetNonce(addr, 1, tracing.NonceChangeUnspecified)

	// Verify code exists
	if a.GetCodeSize(addr) != 3 {
		t.Fatalf("expected code size 3, got %d", a.GetCodeSize(addr))
	}

	// Simulate self-destruct + re-creation (e.g., via CREATE2)
	// CreateContract should clear old code
	a.CreateContract(addr)
	if a.GetCodeSize(addr) != 0 {
		t.Error("CreateContract should clear old code")
	}
	// GetCodeHash after clear should return emptyCodeHash (account is alive, no code)
	emptyCodeHash := common.HexToHash("0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
	if a.GetCodeHash(addr) != emptyCodeHash {
		t.Errorf("expected emptyCodeHash after CreateContract clear, got %s", a.GetCodeHash(addr).Hex())
	}

	// Deploy new code
	a.SetCode(addr, []byte{0x60, 0xFF, 0x00}) // PUSH 0xFF, STOP
	if a.GetCodeSize(addr) != 3 {
		t.Error("new code should be set after re-creation")
	}
}

func TestAdapter_EVMExecution_ContractCreation(t *testing.T) {
	a, db := testAdapter()
	deployer := common.HexToAddress("0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

	// Fund deployer.
	a.CreateAccount(deployer)
	a.AddBalance(deployer, uint256.NewInt(10_000_000), tracing.BalanceChangeUnspecified)

	rootBefore := db.StateRoot()

	// Build EVM.
	blockCtx := vm.BlockContext{
		CanTransfer: func(db vm.StateDB, addr common.Address, amount *uint256.Int) bool {
			return db.GetBalance(addr).Cmp(amount) >= 0
		},
		Transfer: func(db vm.StateDB, sender, recipient common.Address, amount *uint256.Int) {
			db.SubBalance(sender, amount, tracing.BalanceChangeTransfer)
			db.AddBalance(recipient, amount, tracing.BalanceChangeTransfer)
		},
		GetHash:     func(n uint64) common.Hash { return common.Hash{} },
		BlockNumber: new(big.Int).SetUint64(1),
		Time:        1700000000,
		GasLimit:    30_000_000,
		BaseFee:     new(big.Int),
	}

	chainConfig := &params.ChainConfig{
		ChainID:             big.NewInt(431990),
		HomesteadBlock:      big.NewInt(0),
		EIP150Block:         big.NewInt(0),
		EIP155Block:         big.NewInt(0),
		EIP158Block:         big.NewInt(0),
		ByzantiumBlock:      big.NewInt(0),
		ConstantinopleBlock: big.NewInt(0),
		PetersburgBlock:     big.NewInt(0),
		IstanbulBlock:       big.NewInt(0),
		BerlinBlock:         big.NewInt(0),
		LondonBlock:         big.NewInt(0),
		ShanghaiTime:        uint64Ptr(0),
		CancunTime:          uint64Ptr(0),
	}

	evm := vm.NewEVM(blockCtx, a, chainConfig, vm.Config{})
	evm.SetTxContext(vm.TxContext{
		Origin:   deployer,
		GasPrice: new(big.Int),
	})

	// Init code: PUSH1 0x42, PUSH1 0x00, SSTORE, PUSH1 0x01, PUSH1 0x00, RETURN
	// This stores 0x42 at slot 0 during init, then returns 1-byte runtime code (0x01).
	// Actually, we need to return bytecode. Let's use a simpler init code:
	// Runtime code: 0x00 (STOP) -- 1 byte
	// Init code: PUSH1 0x01 (runtime size), PUSH1 0x0c (runtime offset), PUSH1 0x00, CODECOPY, PUSH1 0x01, PUSH1 0x00, RETURN
	// But simpler: just return a single STOP byte.
	// PUSH1 0x00 PUSH1 0x00 SSTORE  -- store 0 at slot 0 (just to test SSTORE)
	// PUSH1 0x01 PUSH1 0x00 MSTORE8 -- store 0x01 at memory[0]
	// PUSH1 0x01 PUSH1 0x00 RETURN  -- return 1 byte from memory[0]
	initCode := []byte{
		0x60, 0x42, // PUSH1 0x42
		0x60, 0x00, // PUSH1 0x00
		0x55,       // SSTORE (store 0x42 at slot 0)
		0x60, 0x00, // PUSH1 0x00 (runtime code = STOP)
		0x60, 0x00, // PUSH1 0x00
		0x53,       // MSTORE8
		0x60, 0x01, // PUSH1 0x01
		0x60, 0x00, // PUSH1 0x00
		0xf3,       // RETURN
	}

	ret, contractAddr, gasLeft, err := evm.Create(deployer, initCode, 1_000_000, uint256.NewInt(0))
	if err != nil {
		t.Fatalf("EVM Create failed: %v", err)
	}
	_ = gasLeft

	// Verify contract was deployed
	if contractAddr == (common.Address{}) {
		t.Fatal("contract address should not be zero")
	}
	t.Logf("Contract deployed at: %s", contractAddr.Hex())
	t.Logf("Runtime code: %x (len=%d)", ret, len(ret))

	// Verify deployed runtime code
	code := a.GetCode(contractAddr)
	if len(code) == 0 {
		t.Error("deployed contract should have code")
	}

	// Verify code hash is set
	codeHash := a.GetCodeHash(contractAddr)
	if codeHash == (common.Hash{}) {
		t.Error("deployed contract should have non-zero code hash")
	}

	// Verify storage was set by init code
	slot := common.HexToHash("0x00")
	storageVal := a.GetState(contractAddr, slot)
	expected := common.HexToHash("0x42")
	if storageVal != expected {
		t.Errorf("storage slot 0: expected 0x42, got %s", storageVal.Hex())
	}

	// Verify state root changed
	rootAfter := db.StateRoot()
	if rootBefore == rootAfter {
		t.Error("state root should change after contract deployment")
	}

	t.Logf("State root changed: %v -> %v", rootBefore.String(), rootAfter.String())
}

// ---------------------------------------------------------------------------
// Snapshot/Revert Journaling Tests (production journaling, not structural)
// ---------------------------------------------------------------------------

func TestAdapter_SnapshotRevertBalance(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x1111111111111111111111111111111111111111")
	a.CreateAccount(addr)
	a.AddBalance(addr, uint256.NewInt(1000), tracing.BalanceChangeUnspecified)

	snapID := a.Snapshot()
	a.AddBalance(addr, uint256.NewInt(5000), tracing.BalanceChangeUnspecified)
	if a.GetBalance(addr).Uint64() != 6000 {
		t.Fatalf("expected 6000 after add, got %d", a.GetBalance(addr).Uint64())
	}

	a.RevertToSnapshot(snapID)
	if a.GetBalance(addr).Uint64() != 1000 {
		t.Errorf("expected 1000 after revert, got %d", a.GetBalance(addr).Uint64())
	}
}

func TestAdapter_SnapshotRevertNonce(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x2222222222222222222222222222222222222222")
	a.CreateAccount(addr)
	a.SetNonce(addr, 5, tracing.NonceChangeUnspecified)

	snapID := a.Snapshot()
	a.SetNonce(addr, 42, tracing.NonceChangeUnspecified)
	if a.GetNonce(addr) != 42 {
		t.Fatalf("expected nonce 42, got %d", a.GetNonce(addr))
	}

	a.RevertToSnapshot(snapID)
	if a.GetNonce(addr) != 5 {
		t.Errorf("expected nonce 5 after revert, got %d", a.GetNonce(addr))
	}
}

func TestAdapter_SnapshotRevertStorage(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x3333333333333333333333333333333333333333")
	a.CreateAccount(addr)
	slot := common.HexToHash("0x01")
	origVal := common.HexToHash("0xAA")
	a.SetState(addr, slot, origVal)

	snapID := a.Snapshot()
	newVal := common.HexToHash("0xBB")
	a.SetState(addr, slot, newVal)
	if a.GetState(addr, slot) != newVal {
		t.Fatalf("expected 0xBB, got %s", a.GetState(addr, slot).Hex())
	}

	a.RevertToSnapshot(snapID)
	if a.GetState(addr, slot) != origVal {
		t.Errorf("expected 0xAA after revert, got %s", a.GetState(addr, slot).Hex())
	}
}

func TestAdapter_SnapshotRevertCode(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x4444444444444444444444444444444444444444")
	a.CreateAccount(addr)
	origCode := []byte{0x60, 0x42, 0x00}
	a.SetCode(addr, origCode)

	snapID := a.Snapshot()
	a.SetCode(addr, []byte{0x60, 0xFF, 0x00})
	if a.GetCodeSize(addr) != 3 {
		t.Fatal("code should be set")
	}

	a.RevertToSnapshot(snapID)
	code := a.GetCode(addr)
	if !bytesEqual(code, origCode) {
		t.Errorf("expected original code after revert, got %x", code)
	}
}

func TestAdapter_SnapshotRevertSelfDestruct(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x5555555555555555555555555555555555555555")
	a.CreateAccount(addr)
	a.AddBalance(addr, uint256.NewInt(9000), tracing.BalanceChangeUnspecified)

	snapID := a.Snapshot()
	a.SelfDestruct(addr)
	if !a.HasSelfDestructed(addr) {
		t.Fatal("should be self-destructed")
	}
	if a.GetBalance(addr).Uint64() != 0 {
		t.Fatal("balance should be zero after self-destruct")
	}

	a.RevertToSnapshot(snapID)
	if a.HasSelfDestructed(addr) {
		t.Error("should NOT be self-destructed after revert")
	}
	if a.GetBalance(addr).Uint64() != 9000 {
		t.Errorf("expected balance 9000 after revert, got %d", a.GetBalance(addr).Uint64())
	}
}

func TestAdapter_SnapshotNestedReverts(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x6666666666666666666666666666666666666666")
	a.CreateAccount(addr)
	a.AddBalance(addr, uint256.NewInt(100), tracing.BalanceChangeUnspecified)

	snapA := a.Snapshot()
	a.AddBalance(addr, uint256.NewInt(200), tracing.BalanceChangeUnspecified) // 300

	snapB := a.Snapshot()
	a.AddBalance(addr, uint256.NewInt(400), tracing.BalanceChangeUnspecified) // 700

	if a.GetBalance(addr).Uint64() != 700 {
		t.Fatalf("expected 700, got %d", a.GetBalance(addr).Uint64())
	}

	// Revert to A (skipping B) -- should undo both B's and A's mutations
	a.RevertToSnapshot(snapA)
	if a.GetBalance(addr).Uint64() != 100 {
		t.Errorf("expected 100 after revert to A, got %d", a.GetBalance(addr).Uint64())
	}

	_ = snapB // used above
}

func TestAdapter_SnapshotRevertLogs(t *testing.T) {
	a, _ := testAdapter()
	log1 := &types.Log{Address: common.HexToAddress("0x01"), Data: []byte{1}}
	a.AddLog(log1)

	snapID := a.Snapshot()
	log2 := &types.Log{Address: common.HexToAddress("0x02"), Data: []byte{2}}
	log3 := &types.Log{Address: common.HexToAddress("0x03"), Data: []byte{3}}
	a.AddLog(log2)
	a.AddLog(log3)

	if len(a.GetLogs()) != 3 {
		t.Fatalf("expected 3 logs, got %d", len(a.GetLogs()))
	}

	a.RevertToSnapshot(snapID)
	if len(a.GetLogs()) != 1 {
		t.Errorf("expected 1 log after revert, got %d", len(a.GetLogs()))
	}
}

func TestAdapter_SnapshotRevertAccountCreation(t *testing.T) {
	a, _ := testAdapter()
	addr := common.HexToAddress("0x7777777777777777777777777777777777777777")

	snapID := a.Snapshot()
	a.CreateAccount(addr)
	a.AddBalance(addr, uint256.NewInt(500), tracing.BalanceChangeUnspecified)
	if !a.Exist(addr) {
		t.Fatal("account should exist after creation")
	}

	a.RevertToSnapshot(snapID)
	if a.Exist(addr) {
		t.Error("account should NOT exist after reverting creation")
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func uint64Ptr(n uint64) *uint64 { return &n }

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// Ensure Adapter satisfies vm.StateDB at compile time.
var _ vm.StateDB = (*Adapter)(nil)
