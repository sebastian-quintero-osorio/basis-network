# zkEVM L2 -- Production Implementation Plan -- ALL GAPS CLOSED

**Status: COMPLETED (2026-03-23)**

All 5 gaps identified in this document have been resolved. The full E2E pipeline
has been verified on Basis Network L1 (Fuji): tx -> EVM execute -> witness (9ms) ->
PLONK-KZG prove (86ms) -> L1 commit -> L1 prove -> L1 execute -> batch finalized
(291K total gas, 5.8s). See POST_ROADMAP_TODO.md for current project status.

## Original State (preserved for reference)

The R&D pipeline and infrastructure work were complete: 719+ tests passing, 6 contracts
deployed on Fuji. The 5 gaps below have all been closed.

## Architecture of the Gap

```
Client (MetaMask/ethers.js)
    |
    | eth_sendRawTransaction("0xf86c...")
    v
[GAP 1] RPC: Decode RLP, verify ECDSA signature, extract fields
    |
    | sequencer.Transaction{From, To, Value, ...}
    v
[GAP 2] Type Adapter: Convert Ethereum types to internal types
    |
    v
Sequencer: Add to mempool, produce L2 block
    |
    | block.Transactions[]
    v
[GAP 3] StateDB Adapter: Implement vm.StateDB over Poseidon SMT
    |
    v
EVM Executor: Execute txs, produce traces
    |
    | ExecutionTrace (JSON)
    v
[GAP 4] Rust CLI: Witness generator + prover as stdin/stdout binaries
    |
    | ProofResultJSON
    v
[GAP 5] L1 Submit: Send commitBatch + proveBatch + executeBatch via ethclient
    |
    v
BasisRollup.sol on Fuji (already deployed)
```

Each gap is a discrete, testable unit. No gap depends on a later gap.
They MUST be implemented in order 2 -> 3 -> 1 -> 5 -> 4.

Rationale for this order:
- Gap 2 (types) is a prerequisite for all other integration
- Gap 3 (StateDB adapter) enables real EVM execution
- Gap 1 (RPC decode) enables real client interaction
- Gap 5 (L1 submit) enables on-chain finalization
- Gap 4 (Rust CLI) enables real ZK proof generation (most complex, least blocking for E2E)

---

## Gap 1: RPC Transaction Decoding

### Problem
`ethSendRawTransaction` receives hex-encoded RLP bytes from clients but passes them
as raw string bytes to the backend. No RLP decoding, no ECDSA signature verification,
no field extraction.

### Files to Modify

**1.1 `zkl2/node/rpc/server.go`** -- Fix ethSendRawTransaction handler

Current (broken):
```go
txHash, err := s.backend.SendRawTransaction([]byte(rawTxHex))
```

Required:
```go
// 1. Strip "0x" prefix and hex-decode to binary
rawBytes, err := hex.DecodeString(strings.TrimPrefix(rawTxHex, "0x"))

// 2. RLP-decode to *types.Transaction
var tx types.Transaction
err = rlp.DecodeBytes(rawBytes, &tx)

// 3. Extract sender via ECDSA recovery (Cancun signer)
signer := types.LatestSignerForChainID(big.NewInt(int64(s.backend.ChainID())))
from, err := types.Sender(signer, &tx)

// 4. Compute tx hash
txHash := tx.Hash()

// 5. Forward decoded tx to backend
err = s.backend.SubmitTransaction(from, &tx)
```

**1.2 `zkl2/node/rpc/server.go`** -- Update Backend interface

```go
type Backend interface {
    ChainID() uint64
    BlockNumber() uint64
    GetBalance(address string) (*big.Int, error)
    SubmitTransaction(from common.Address, tx *types.Transaction) error  // CHANGED
    GetTransactionReceipt(txHash string) (*TransactionReceipt, error)
    GetBatchStatus(batchID uint64) (*BatchStatus, error)
}
```

**1.3 `zkl2/node/rpc/server_test.go`** -- Update mock backend and add tests

- TestSendRawTransaction_ValidEthereumTx: Construct a real signed tx with go-ethereum, RLP-encode, send via RPC, verify backend receives decoded fields
- TestSendRawTransaction_InvalidRLP: Send garbage hex, verify parse error
- TestSendRawTransaction_InvalidSignature: Send tx with wrong chain ID, verify rejection

### New Imports (all already in go.mod)
```go
"encoding/hex"
"strings"
"github.com/ethereum/go-ethereum/core/types"
"github.com/ethereum/go-ethereum/rlp"
```

### Tests: 3 new + update 1 existing
### Effort: ~80 lines changed

---

## Gap 2: Sequencer Type Alignment

### Problem
The sequencer uses custom types (`sequencer.Address = [20]byte`, `Value uint64`) that are
incompatible with Ethereum transaction types (`common.Address`, `*big.Int`).

### Files to Modify

**2.1 `zkl2/node/sequencer/types.go`** -- Change Value type

```go
// BEFORE:
Value     uint64    // Transfer value (wei)

// AFTER:
Value     *big.Int  // Transfer value (wei) -- must support full 256-bit range
```

**2.2 `zkl2/node/sequencer/types.go`** -- Add To pointer semantics

```go
// BEFORE:
To        Address   // Recipient address

// AFTER:
To        *Address  // Recipient address (nil for contract creation)
```

**2.3 `zkl2/node/sequencer/mempool.go`** -- Update gas accounting

The `Drain` method uses `tx.GasLimit` for gas accounting. After adding `*big.Int` Value,
verify no code treats Value as uint64 (grep for `.Value` usage across the package).

**2.4 `zkl2/node/sequencer/sequencer_test.go`** -- Fix all test constructors

Every test that constructs a `Transaction{}` literal must change:
- `Value: 1000` -> `Value: big.NewInt(1000)`
- `To: Address{...}` -> `To: &Address{...}` (or nil for create)

**2.5 NEW `zkl2/node/sequencer/convert.go`** -- Adapter functions

```go
// FromEthTransaction converts a go-ethereum signed transaction to a sequencer Transaction.
func FromEthTransaction(from common.Address, ethTx *types.Transaction) Transaction {
    var to *Address
    if ethTx.To() != nil {
        addr := Address(*ethTx.To())
        to = &addr
    }
    return Transaction{
        Hash:     TxHash(ethTx.Hash()),
        From:     Address(from),
        To:       to,
        Nonce:    ethTx.Nonce(),
        Data:     ethTx.Data(),
        GasLimit: ethTx.Gas(),
        Value:    new(big.Int).Set(ethTx.Value()),
    }
}

// ToExecutorMessage converts a sequencer Transaction to an executor Message.
func (tx Transaction) ToExecutorMessage() executor.Message {
    var to *common.Address
    if tx.To != nil {
        addr := common.Address(*tx.To)
        to = &addr
    }
    return executor.Message{
        From:     common.Address(tx.From),
        To:       to,
        Value:    tx.Value,
        Gas:      tx.GasLimit,
        GasPrice: new(big.Int), // Zero-fee L2
        Data:     tx.Data,
        Nonce:    tx.Nonce,
    }
}
```

### Cascading Changes
Every file that references `sequencer.Transaction.Value` as uint64 must be updated:
- `sequencer/block_builder.go`
- `sequencer/mempool.go`
- `sequencer/sequencer_test.go`
- `node/integration_test.go`
- `cmd/basis-l2/main.go`

### Tests: Fix ~15 existing tests + 4 new conversion tests
### Effort: ~150 lines changed across 8 files

---

## Gap 3: StateDB Adapter (vm.StateDB Interface)

### Problem
The EVM executor requires `*state.StateDB` (go-ethereum), but the L2 state lives in
our Poseidon SMT `statedb.StateDB`. A bridge adapter must implement the `vm.StateDB`
interface (26+ methods) backed by the Poseidon SMT.

### Files to Create

**3.1 NEW `zkl2/node/statedb/adapter.go`** -- The StateDB adapter

```go
// Adapter implements go-ethereum's vm.StateDB interface backed by the Poseidon SMT.
// This is the bridge between EVM execution and ZK-friendly state management.
type Adapter struct {
    db       *StateDB          // Poseidon SMT state
    logs     []*types.Log      // Transaction logs
    refund   uint64            // Gas refund counter
    code     map[TreeKey][]byte // Contract bytecode (not in SMT)
    suicided map[TreeKey]bool  // Self-destructed contracts
}
```

Methods to implement (26 total, grouped by complexity):

**Trivial (direct delegation, ~1 line each):**
- `GetBalance(addr) *uint256.Int` -- delegate to `db.GetBalance(AddressToKey(addr))`
- `GetNonce(addr) uint64` -- need to add Nonce to SMT Account or track separately
- `Exist(addr) bool` -- delegate to `db.IsAlive(AddressToKey(addr))`
- `Empty(addr) bool` -- check balance=0, nonce=0, codeSize=0
- `AddRefund(gas)` / `SubRefund(gas)` / `GetRefund()` -- in-memory counter

**Simple (conversion + delegation, ~5 lines each):**
- `GetState(addr, slot) common.Hash` -- convert fr.Element to [32]byte
- `SetState(addr, slot, value)` -- convert [32]byte to fr.Element
- `GetCommittedState(addr, slot) common.Hash` -- same as GetState for non-journaled
- `CreateAccount(addr)` -- delegate to `db.CreateAccount(AddressToKey(addr))`
- `CreateContract(addr)` -- same as CreateAccount + mark as contract

**Medium (arithmetic + conversion):**
- `AddBalance(addr, amount, reason)` -- get current + add + set
- `SubBalance(addr, amount, reason)` -- get current - sub + set
- `SetBalance(addr, amount)` -- convert + delegate

**Complex (require new storage in Adapter):**
- `GetCode(addr) []byte` -- stored in adapter.code map (not in SMT)
- `SetCode(addr, code)` -- stored in adapter.code map + update code hash
- `GetCodeHash(addr) common.Hash` -- keccak256 of code
- `GetCodeSize(addr) int` -- len(code)
- `HasSuicided(addr) bool` -- adapter.suicided map
- `AddLog(log)` -- append to adapter.logs
- `Snapshot() int` / `RevertToSnapshot(id)` -- journal for EVM revert semantics

**Snapshot/Journal System:**
The most complex part. The EVM needs to revert state changes on REVERT opcode.
Requires a journal that records every mutation and can undo them.

Approach: Copy the journal pattern from go-ethereum's state package, but operating
on our Poseidon SMT. Each Snapshot() saves the current account/storage state, and
RevertToSnapshot() restores it.

Simpler approach for MVP: Keep a copy of modified keys before each snapshot, restore
on revert. Only a few accounts change per transaction.

**3.2 NEW `zkl2/node/statedb/adapter_test.go`** -- Comprehensive tests

- TestAdapter_GetSetBalance: Create account, set balance, verify via adapter
- TestAdapter_GetSetState: Set storage slot via adapter, verify via SMT
- TestAdapter_Snapshot_Revert: Take snapshot, modify state, revert, verify original
- TestAdapter_AddSubBalance: Arithmetic correctness
- TestAdapter_CreateAccount: Via adapter creates in SMT
- TestAdapter_Code: Store and retrieve contract bytecode
- TestAdapter_Logs: Add and retrieve logs
- TestAdapter_Exist_Empty: Existence and emptiness checks

**3.3 Modify `zkl2/node/statedb/state_db.go`** -- Add missing methods

The current StateDB is missing:
- `GetNonce(addr TreeKey) uint64` -- Account struct has Nonce but no getter
- `SetNonce(addr TreeKey, nonce uint64) error` -- No setter

These are simple additions to the Account struct methods.

**3.4 Modify `zkl2/node/executor/executor.go`** -- Accept adapter

Change the executor to accept a `vm.StateDB` interface (which the Adapter implements)
instead of the concrete `*state.StateDB`:

```go
// BEFORE:
func (e *Executor) ExecuteTransaction(ctx context.Context, stateDB *state.StateDB, ...)

// AFTER:
func (e *Executor) ExecuteTransaction(ctx context.Context, stateDB vm.StateDB, ...)
```

This also means removing the `NewHookedState` wrapping (the adapter itself handles hooks).

### Tests: 10+ new tests for the adapter
### Effort: ~400 lines new (adapter.go) + ~200 lines tests + ~50 lines modifications
### This is the largest single gap.

---

## Gap 4: Rust Prover CLI Binaries

### Problem
The Rust prover workspace produces only libraries. The Go pipeline calls
`exec.Command("basis-prover", "witness")` which does not exist.

### Files to Create

**4.1 NEW `zkl2/prover/cli/Cargo.toml`** -- New binary crate

```toml
[package]
name = "basis-prover-cli"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "basis-prover"
path = "src/main.rs"

[dependencies]
basis-witness = { path = "../witness" }
basis-circuit = { path = "../circuit" }
basis-aggregator = { path = "../aggregator" }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

**4.2 NEW `zkl2/prover/cli/src/main.rs`** -- CLI entry point

```rust
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let subcommand = args.get(1).map(|s| s.as_str()).unwrap_or("help");

    match subcommand {
        "witness" => run_witness(),
        "prove" => run_prove(),
        "verify" => run_verify(),
        "version" => println!("basis-prover v0.1.0"),
        _ => print_usage(),
    }
}
```

**4.3 NEW `zkl2/prover/cli/src/witness_cmd.rs`** -- Witness subcommand

- Read BatchTraceJSON from stdin
- Call basis_witness::WitnessGenerator::generate()
- Serialize WitnessResultJSON to stdout
- Log timing metrics to stderr

**4.4 NEW `zkl2/prover/cli/src/prove_cmd.rs`** -- Prove subcommand

- Read WitnessResultJSON from stdin
- Call basis_circuit::Prover::prove()
- Serialize ProofResultJSON to stdout
- Log timing metrics to stderr

**4.5 Modify `zkl2/prover/Cargo.toml`** -- Add cli crate to workspace

```toml
members = [
    "witness",
    "circuit",
    "aggregator",
    "cli",
]
```

**4.6 NEW `zkl2/prover/cli/src/types.rs`** -- JSON types matching Go protocol

Must exactly match the Go types in `pipeline/types.go`:
- `BatchTraceJSON` (input to witness)
- `ExecutionTraceJSON` (per-tx trace)
- `TraceEntryJSON` (per-op entry)
- `WitnessResultJSON` (output of witness, input to prover)
- `ProofResultJSON` (output of prover)

### Integration Test

**4.7 NEW `zkl2/prover/cli/tests/integration.rs`**

```rust
#[test]
fn test_witness_stdin_stdout() {
    let input = serde_json::json!({
        "block_number": 1,
        "pre_state_root": "0x00",
        "post_state_root": "0x01",
        "traces": [{ "tx_hash": "0xabc", "from": "0x01", ... }]
    });

    let output = Command::new("cargo")
        .args(["run", "--bin", "basis-prover", "--", "witness"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn();
    // Write input, read output, verify JSON structure
}
```

### Tests: 3 integration tests (witness, prove, version)
### Effort: ~300 lines Rust + Cargo config

---

## Gap 5: L1 Submit via ethclient

### Problem
`stages_production.go` Submit() is a placeholder that logs and returns zeros.

### Files to Modify

**5.1 NEW `zkl2/node/pipeline/l1_submitter.go`** -- L1 submission logic

```go
type L1Submitter struct {
    client     *ethclient.Client
    privateKey *ecdsa.PrivateKey
    rollupAddr common.Address
    rollupABI  abi.ABI
    chainID    *big.Int
    logger     *slog.Logger
}

func NewL1Submitter(rpcURL, privateKeyHex, rollupAddress string, logger *slog.Logger) (*L1Submitter, error) {
    client, err := ethclient.Dial(rpcURL)
    // Parse private key, ABI, address
    // Return submitter
}

func (s *L1Submitter) SubmitBatch(ctx context.Context, batch *BatchState) error {
    // 1. commitBatch(CommitBatchData)
    // 2. Wait for receipt
    // 3. proveBatch(batchId, a, b, c, publicSignals)
    // 4. Wait for receipt
    // 5. executeBatch(batchId)
    // 6. Wait for receipt
    // 7. Return total gas used and L1 tx hashes
}
```

**5.2 Modify `zkl2/node/pipeline/stages_production.go`** -- Wire L1Submitter

Replace the TODO in Submit() with actual L1Submitter call.

**5.3 NEW `zkl2/node/pipeline/l1_submitter_test.go`** -- Tests with simulated backend

Use go-ethereum's `simulated.Backend` for testing:
- Deploy BasisRollupHarness on simulated chain
- Call SubmitBatch with test data
- Verify all 3 transactions succeed
- Verify state root updated on-chain

### New Imports
```go
"github.com/ethereum/go-ethereum/ethclient"
"github.com/ethereum/go-ethereum/accounts/abi"
"github.com/ethereum/go-ethereum/accounts/abi/bind"
"github.com/ethereum/go-ethereum/crypto"
```

### Tests: 4 tests (submit success, commit fail, prove fail, execute fail)
### Effort: ~250 lines new

---

## Gap 6: Node Wiring (connects all gaps)

### Problem
`cmd/basis-l2/main.go` initializes components but doesn't wire them together:
- RPC server is not started
- EVM executor is not connected to sequencer
- Pipeline uses simulated stages

### Files to Modify

**6.1 Modify `zkl2/node/cmd/basis-l2/main.go`** -- Full wiring

```go
func initNode(cfg *config.Config, logger *slog.Logger) (*Node, error) {
    // 1. StateDB (Poseidon SMT) + LevelDB persistence
    store, _ := statedb.OpenStore(cfg.L2.DataDir + "/state")
    sdb := statedb.NewStateDB(cfg)

    // 2. StateDB Adapter (implements vm.StateDB over Poseidon SMT)
    adapter := statedb.NewAdapter(sdb)

    // 3. EVM Executor (uses adapter)
    exec := executor.New(executorCfg, logger)

    // 4. Sequencer
    seq, _ := sequencer.New(seqCfg, logger)

    // 5. L1 Submitter (real ethclient connection)
    submitter, _ := pipeline.NewL1Submitter(cfg.L1.RPCURL, cfg.L1.PrivateKey, ...)

    // 6. Production Pipeline Stages
    stages := &pipeline.ProductionStages{
        Executor:  exec,
        Adapter:   adapter,
        Submitter: submitter,
        ...
    }
    orch := pipeline.NewOrchestrator(pipelineCfg, logger, stages)

    // 7. RPC Server with real backend
    backend := NewNodeBackend(sdb, seq, orch)
    rpcServer := rpc.NewServer(rpcCfg, backend, logger)

    return &Node{..., rpcServer: rpcServer}, nil
}
```

**6.2 NEW `zkl2/node/cmd/basis-l2/backend.go`** -- Backend implementation

Implements `rpc.Backend` interface by delegating to real node components:
```go
type NodeBackend struct {
    stateDB   *statedb.StateDB
    sequencer *sequencer.Sequencer
    pipeline  *pipeline.Orchestrator
}

func (b *NodeBackend) SubmitTransaction(from common.Address, tx *types.Transaction) error {
    seqTx := sequencer.FromEthTransaction(from, tx)
    return b.sequencer.Mempool().Add(seqTx)
}

func (b *NodeBackend) GetBalance(address string) (*big.Int, error) {
    key := statedb.AddressToKey(common.HexToAddress(address))
    return b.stateDB.GetBalance(key), nil
}
```

### Tests: Integration test that starts full node, sends tx via RPC, verifies execution
### Effort: ~200 lines new

---

## Implementation Order

```
Phase 1: Type Foundation
  [GAP 2] Sequencer type alignment (Value *big.Int, To *Address)
  [GAP 2] Conversion functions (FromEthTransaction, ToExecutorMessage)
  -> Commit: "refactor(zkl2): align sequencer types with Ethereum transaction model"

Phase 2: State Bridge
  [GAP 3] StateDB Adapter (vm.StateDB over Poseidon SMT)
  [GAP 3] Add GetNonce/SetNonce to statedb.StateDB
  [GAP 3] Executor accepts vm.StateDB instead of *state.StateDB
  -> Commit: "feat(zkl2): implement StateDB adapter bridging EVM execution to Poseidon SMT"

Phase 3: Client Interface
  [GAP 1] RPC SendRawTransaction with RLP decode + ECDSA verify
  [GAP 1] Updated Backend interface
  -> Commit: "feat(zkl2): add Ethereum transaction decoding to JSON-RPC server"

Phase 4: L1 Finalization
  [GAP 5] L1Submitter with ethclient
  [GAP 5] Wire into ProductionStages.Submit()
  -> Commit: "feat(zkl2): implement real L1 batch submission via ethclient"

Phase 5: ZK Proving
  [GAP 4] Rust CLI binary (basis-prover)
  [GAP 4] witness and prove subcommands
  -> Commit: "feat(zkl2): add basis-prover CLI binary for witness/prove via stdin/stdout"

Phase 6: Full Integration
  [GAP 6] Node wiring (main.go)
  [GAP 6] NodeBackend implementing rpc.Backend
  -> Commit: "feat(zkl2): wire all components into production node binary"

Phase 7: Production E2E Test
  Full E2E: client sends signed tx -> RPC -> sequencer -> executor -> witness -> proof -> L1
  -> Commit: "test(zkl2): production E2E test with real Ethereum transactions on live chain"
```

---

## Estimated Effort per Phase

| Phase | Gap | New Lines | Modified Lines | New Tests | Sessions |
|-------|-----|-----------|----------------|-----------|----------|
| 1 | Types | ~100 | ~150 | 4 | 1 |
| 2 | StateDB Adapter | ~400 | ~100 | 10 | 1-2 |
| 3 | RPC Decode | ~80 | ~50 | 3 | 1 |
| 4 | L1 Submit | ~250 | ~50 | 4 | 1 |
| 5 | Rust CLI | ~300 | ~20 | 3 | 1 |
| 6 | Node Wiring | ~200 | ~100 | 2 | 1 |
| 7 | E2E | ~150 | ~0 | 1 | 1 |
| **Total** | | **~1,480** | **~470** | **27** | **~5-7** |

---

## Definition of Done

The system is production-ready when:

1. A client can send a **signed Ethereum transaction** via `eth_sendRawTransaction`
2. The transaction is **decoded, signature-verified**, and added to the mempool
3. The sequencer **includes it in an L2 block**
4. The EVM executor **executes it against the Poseidon SMT state**
5. The witness generator **produces a witness from the execution trace**
6. The ZK prover **generates a validity proof**
7. The L1 submitter **commits, proves, and executes the batch** on BasisRollup.sol
8. The **state root is updated on-chain** and verifiable
9. The client can **query the receipt** via `eth_getTransactionReceipt`
10. The entire pipeline completes **without manual intervention**

Each step must have automated tests. The full pipeline must be verified on the
live Fuji chain with a real signed transaction.
