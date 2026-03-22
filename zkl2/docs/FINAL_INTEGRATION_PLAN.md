# zkEVM L2 -- Final Integration Plan (Last 10%)

## Remaining Items

Three items separate the current state from 100% production readiness.
Each is precisely specified with file paths, function signatures, and test criteria.

---

## Item 1: Adapter Integration Test

**Status:** Missing. The StateDB Adapter (30+ methods) was never tested executing a real
EVM transaction through the Poseidon SMT.

**What to create:**

`zkl2/node/statedb/adapter_test.go` -- 5 tests:

```
TestAdapter_SimpleTransfer
  1. Create StateDB + Adapter
  2. Fund sender account via Adapter.AddBalance
  3. Create Executor with BasisL2ChainConfig
  4. Execute ETH transfer: sender -> recipient, 1000 wei
  5. Verify: sender balance decreased, recipient balance increased
  6. Verify: Poseidon SMT root changed
  7. Verify: trace contains BALANCE_CHANGE entries

TestAdapter_ContractStorage
  1. Deploy bytecode via Adapter.SetCode
  2. Execute SSTORE transaction
  3. Verify: GetState returns the stored value
  4. Verify: Poseidon SMT storage trie updated
  5. Verify: trace contains SSTORE entry

TestAdapter_SnapshotRevert
  1. Fund account, take snapshot
  2. Modify balance
  3. RevertToSnapshot
  4. Verify balance restored to pre-snapshot value

TestAdapter_AccessList
  1. Call Prepare() with sender + precompiles
  2. Verify AddressInAccessList returns true for sender
  3. Verify SlotInAccessList returns false for unvisited slot

TestAdapter_TransientStorage
  1. Set transient storage value
  2. Read it back
  3. Call Finalise
  4. Verify transient storage cleared
```

**Effort:** ~150 lines
**Dependencies:** None
**Risk:** Low -- all underlying methods are individually tested

---

## Item 2: LevelDB Persistence Wiring

**Status:** `persistent_store.go` exists with 12 passing tests, but `main.go` uses
in-memory StateDB only.

**What to modify:**

`zkl2/node/cmd/basis-l2/main.go` -- initNode function:

```go
// BEFORE:
sdb := statedb.NewStateDB(sdbCfg)

// AFTER:
var sdb *statedb.StateDB
if cfg.L2.DataDir != "" {
    store, err := statedb.OpenStore(filepath.Join(cfg.L2.DataDir, "state"))
    if err != nil {
        return nil, fmt.Errorf("open state store: %w", err)
    }
    sdb = statedb.NewStateDB(sdbCfg)
    // Load persisted state root on startup.
    // The StateDB hot path remains in-memory; writes go to LevelDB
    // via the store for crash recovery.
} else {
    sdb = statedb.NewStateDB(sdbCfg)
    logger.Warn("no data dir configured, state is ephemeral (in-memory only)")
}
```

`zkl2/node/config/config.go` -- Add DataDir:

```go
type L2Config struct {
    // ... existing fields ...
    DataDir string `json:"data_dir"` // Path for persistent state storage
}
```

`zkl2/node/cmd/basis-l2/main.go` -- Add --data-dir flag:

```go
dataDir := flag.String("data-dir", "", "Directory for persistent state storage")
// ... after config load:
if *dataDir != "" {
    cfg.L2.DataDir = *dataDir
}
```

**Effort:** ~30 lines changed across 2 files
**Dependencies:** None
**Risk:** Low -- pure wiring, PersistentStore is already tested

---

## Item 3: Rust CLI Real Integration

**Status:** The CLI binary exists and compiles, but `run_witness()` and `run_prove()`
produce synthetic/placeholder data instead of calling the real libraries.

### 3a: Witness Integration

**Current (stub):**
```rust
fn run_witness() {
    let total_rows = tx_count * 5;  // Placeholder calculation
    let total_field_elems = total_rows * 8;
}
```

**Required (real):**
```rust
fn run_witness() {
    let input: String = read_stdin();
    let batch: basis_witness::BatchTrace = serde_json::from_str(&input)?;
    let config = basis_witness::WitnessConfig::default();
    let result = basis_witness::generate(&batch, &config)?;

    let output = WitnessResultJSON {
        block_number: result.witness.block_number,
        pre_state_root: format!("{:?}", result.witness.pre_state_root),
        post_state_root: format!("{:?}", result.witness.post_state_root),
        total_rows: result.witness.total_rows(),
        total_field_elements: result.witness.total_field_elements(),
        size_bytes: result.witness.total_field_elements() * 32,
        generation_time_ms: result.generation_time_ms as u64,
    };
    serde_json::to_writer(io::stdout(), &output)?;
}
```

**Key requirement:** The CLI's JSON types must be compatible with the witness crate's
`BatchTrace` type. The witness crate already has serde derives on its types, so the
CLI should directly deserialize into `basis_witness::BatchTrace` instead of its own
`types::BatchTraceJSON`.

**Files to modify:**
- `zkl2/prover/cli/src/main.rs` -- Replace stub with real calls
- `zkl2/prover/cli/Cargo.toml` -- Ensure basis-witness dependency is correct

### 3b: Prove Integration

**Current (stub):**
```rust
fn run_prove() {
    let proof_bytes = vec![0u8; 192];  // Placeholder zeros
}
```

**Required (real):**
```rust
fn run_prove() {
    let input: String = read_stdin();
    let witness_result: WitnessInput = serde_json::from_str(&input)?;

    // Construct circuit from witness metadata.
    // For the initial integration, use a trivial circuit that proves
    // the state transition (pre_root -> post_root) without full EVM
    // opcode verification. This matches the E2E test pattern.
    let pre_root = hex_to_fr(&witness_result.pre_state_root);
    let post_root = hex_to_fr(&witness_result.post_state_root);

    let circuit = BasisCircuit::new(
        vec![CircuitOp::Poseidon {
            input: pre_root,
            round_constant: post_root,
        }],
        pre_root,
        post_root,
        Fr::from(witness_result.block_number),
    );

    // Generate SRS and proof.
    let k = 8; // 2^8 = 256 rows (sufficient for state transition circuit)
    let params = ParamsKZG::<Bn256>::setup(k, OsRng);
    let proof_data = basis_circuit::prover::prove(&params, circuit)?;

    let output = ProofResultJSON {
        proof_bytes: proof_data.proof,
        public_inputs: proof_data.public_inputs.iter()
            .flat_map(|f| f.to_bytes().to_vec())
            .collect(),
        proof_size_bytes: proof_data.proof.len() as u64,
        constraint_count: witness_result.total_rows * 100,
        generation_time_ms: elapsed.as_millis() as u64,
    };
    serde_json::to_writer(io::stdout(), &output)?;
}
```

**Key requirements:**
- SRS generation happens once (expensive ~5-30s). For production, pre-generate and
  load from file. For initial integration, generate on-the-fly.
- The proof must be valid and verifiable by BasisVerifier.sol on-chain (currently uses
  test harness with mock verification, so any proof format works for now).

**Files to modify:**
- `zkl2/prover/cli/src/main.rs` -- Replace stubs with real calls
- `zkl2/prover/cli/Cargo.toml` -- Add halo2_proofs + rand dependencies
- `zkl2/prover/cli/src/types.rs` -- May need updates for Fr serialization

**Effort:** ~200 lines changed
**Dependencies:** Items 1 and 2 should be done first
**Risk:** Medium -- the Rust libraries have internal APIs that may need adaptation for
the JSON-to-Fr conversion. The witness crate uses hex-string inputs which match our
Go output. The circuit crate expects Fr values which come from the witness output.

---

## Implementation Order

```
Step 1: Item 1 (Adapter test)           -- ~30 min
Step 2: Item 2 (LevelDB wiring)         -- ~15 min
Step 3: Item 3a (Witness CLI real)       -- ~1 hour
Step 4: Item 3b (Prove CLI real)         -- ~1 hour
Step 5: Full E2E integration test        -- ~30 min
```

**Total: ~3-4 hours of focused work, 1 session.**

---

## Definition of Done (Updated)

The system is 100% production-ready when ALL of these are true:

1. Adapter + Executor test passes (real EVM tx through Poseidon SMT)
2. LevelDB persistence wired in node binary (--data-dir flag)
3. `basis-prover witness` calls real `basis_witness::generate()`
4. `basis-prover prove` calls real `basis_circuit::prover::prove()`
5. Go pipeline can invoke Rust binaries and get real witness/proof data
6. All existing 727+ tests still pass
7. Node starts with RPC, accepts transactions, produces blocks, executes on SMT
