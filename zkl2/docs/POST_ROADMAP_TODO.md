# zkEVM L2 -- Post-Roadmap Integration Plan

## What Was Accomplished

The R&D pipeline executed 44 agent sessions across 11 Research Units (5 phases), producing:

- **11 Go/Rust/Solidity modules**, each individually tested
- **11 TLA+ specifications**, all model-checked (TLC PASS)
- **11 Coq verification units**, 107 .v files, 0 Admitted
- **~463 unit tests** passing across all modules (321 Solidity, 142 Rust)
- **~174 Go test cases** written (compilation unverified -- Go not installed on dev machine)
- **11 adversarial attack reports**, 0 violations found
- **18,138+ lines of production code** (Go, Rust, Solidity)

## What We Have (Module Inventory)

| Module | Location | Tests | TLC | Coq | Status |
|--------|----------|-------|-----|-----|--------|
| EVM Executor | `zkl2/node/executor/` | 13 Go | PASS | VERIFIED | Standalone library |
| Sequencer + Mempool | `zkl2/node/sequencer/` | 35 Go | PASS | VERIFIED | Standalone library |
| StateDB (Poseidon SMT) | `zkl2/node/statedb/` | 24 Go | PASS | VERIFIED | Standalone library |
| Pipeline Orchestrator | `zkl2/node/pipeline/` | 17 Go | PASS | VERIFIED | **Simulated stages only** |
| DAC (Reed-Solomon + Shamir) | `zkl2/node/da/` | 28 Go | PASS | VERIFIED | Standalone library |
| Cross-Enterprise Hub | `zkl2/node/cross/` | 24 Go | PASS | VERIFIED | Standalone library |
| Witness Generator | `zkl2/prover/witness/` | 62 Rust | PASS | VERIFIED | Standalone library |
| PLONK Circuit | `zkl2/prover/circuit/` | 46 Rust | PASS | VERIFIED | Standalone library |
| Proof Aggregator | `zkl2/prover/aggregator/` | 34 Rust | PASS | VERIFIED | Standalone library |
| Bridge Relayer | `zkl2/bridge/relayer/` | 33 Go | PASS | VERIFIED | Standalone library |
| BasisRollup.sol | `zkl2/contracts/` | 88 TS | PASS | VERIFIED | Not deployed |
| BasisBridge.sol | `zkl2/contracts/` | 40 TS | PASS | VERIFIED | Not deployed |
| BasisDAC.sol | `zkl2/contracts/` | 68 TS | PASS | VERIFIED | Not deployed |
| BasisHub.sol | `zkl2/contracts/` | 51 TS | PASS | VERIFIED | Not deployed |
| BasisAggregator.sol | `zkl2/contracts/` | 27 TS | PASS | VERIFIED | Not deployed |
| BasisVerifier.sol | `zkl2/contracts/` | 48 TS | PASS | VERIFIED | Not deployed |

**Test totals:** 321 Solidity passing (1 timing flake), 142 Rust passing, ~174 Go written.

## Critical Assessment: What is Missing

The R&D pipeline produced **isolated, individually-tested libraries**. Unlike the Validium MVP
(which runs end-to-end on the live Fuji chain), the zkl2 components have **never been connected**.
There is no runnable binary, no cross-language bridge, no deployment, and no E2E verification.

The following sections detail every gap between the current state and 100% production completion.

---

## Section 1: Cross-Module Integration

### 1.1 Go Test Compilation Verification -- NOT STARTED

**Priority:** CRITICAL
**Effort:** Small
**Blocker:** Go is not installed on the development machine.

- [ ] Install Go 1.25+ on the development machine (or WSL)
- [ ] Run `go test ./...` from `zkl2/node/` and verify all 174 Go tests pass
- [ ] Run `go test ./...` from `zkl2/bridge/` and verify all 33 bridge tests pass
- [ ] Run `go vet ./...` to verify no static analysis issues
- [ ] Run `go build ./...` to verify all packages compile together
- [ ] Fix any compilation or test failures found
- [ ] Document Go version and test results

**Why this is critical:** The Go tests were written by AI agents in isolation. Without
running them, we have zero assurance the code compiles, let alone passes tests. The Rust
tests (142 passing) and Solidity tests (321 passing) have been verified. The Go tests
have NOT.

### 1.2 Cross-Package Type Consistency -- NOT STARTED

**Priority:** HIGH
**Effort:** Medium

- [ ] Verify `executor.TransactionResult` is compatible with `pipeline.BatchState.Traces`
- [ ] Verify `statedb.StateDB` interface matches what `executor.Executor` expects
- [ ] Verify `sequencer.Block` output feeds correctly into `executor.Execute` input
- [ ] Verify `pipeline.ExecutionTraceJSON` matches `prover/witness` expected input format
- [ ] Verify `da.Certificate` serialization matches `BasisDAC.sol` expected calldata
- [ ] Verify `cross.SettlementProof` matches `BasisHub.sol` expected calldata
- [ ] Create shared types package if needed, or document type mapping

### 1.3 BasisVerifier Test Timing Flake -- NOT FIXED

**Priority:** MEDIUM
**Effort:** Small

- [ ] Fix timestamp race condition in `BasisVerifier.test.ts:360`
  - Test uses `await getTimestamp()` which reads `block.timestamp` AFTER the transaction
  - The emitted event has `block.timestamp` at execution time, which can be 1 second earlier
  - Fix: use `await time.latest()` from Hardhat helpers, or remove timestamp assertion
- [ ] Verify 322/322 tests pass after fix

---

## Section 2: Node Binary and Runnable System

### 2.1 Node Binary (cmd/basis-l2) -- NOT STARTED

**Priority:** CRITICAL
**Effort:** Large

There is no `main()` function anywhere in the Go codebase. All modules are libraries.
The node cannot be started.

- [ ] Create `zkl2/node/cmd/basis-l2/main.go` with:
  - CLI argument parsing (config file path, log level, etc.)
  - Configuration loading from YAML/TOML file
  - Component initialization in correct order:
    1. Logger setup
    2. StateDB initialization (with persistence backend)
    3. Sequencer initialization (with mempool config)
    4. EVM Executor initialization (with StateDB)
    5. Pipeline Orchestrator initialization (with real stages)
    6. DAC Node initialization (if DAC mode enabled)
    7. JSON-RPC server startup
    8. L1 Synchronizer startup
    9. Bridge Relayer startup (if bridge enabled)
  - Graceful shutdown handler (SIGINT/SIGTERM)
  - Health check endpoint
- [ ] Create `zkl2/node/config/` package with configuration structs
- [ ] Create `Makefile` with build targets:
  - `make build` -- compile the binary
  - `make test` -- run all Go tests
  - `make lint` -- run staticcheck/golangci-lint
- [ ] Verify the binary compiles and starts (even if it does nothing useful yet)

### 2.2 Production Pipeline Stages -- NOT STARTED

**Priority:** CRITICAL
**Effort:** Large

`zkl2/node/pipeline/stages.go` defines a `Stages` interface, but ONLY `SimulatedStages`
(stages_sim.go) implements it. The `SimulatedStages` generates random data and sleeps.
There are NO real stages connecting the actual components.

- [ ] Create `zkl2/node/pipeline/stages_production.go` implementing `Stages`:
  - `Execute()`: call `executor.Execute()` with real transactions from the sequencer,
    collect execution traces, update StateDB
  - `WitnessGen()`: serialize traces to JSON, invoke Rust witness generator binary
    via stdin/stdout IPC (as documented in types.go comments), parse result
  - `Prove()`: invoke Rust prover binary with witness, collect proof bytes
  - `Submit()`: call BasisRollup.sol on L1 via ethers/Go-Ethereum client
    (commitBatch + proveBatch + executeBatch)
- [ ] Write integration tests for each real stage (mocking external dependencies)
- [ ] Write E2E test that runs all 4 real stages in sequence

### 2.3 Go-Rust IPC Bridge -- NOT STARTED

**Priority:** CRITICAL
**Effort:** Medium

The witness generator and prover are Rust binaries. The orchestrator is Go. They need
to communicate. The types document "JSON over stdin/stdout" but no code implements it.

- [ ] Create Rust CLI binary in `zkl2/prover/` that accepts:
  - `basis-prover witness --input <trace.json> --output <witness.json>`
  - `basis-prover prove --witness <witness.json> --output <proof.json>`
  - `basis-prover verify --proof <proof.json> --public-inputs <inputs.json>`
- [ ] Create Go wrapper in `zkl2/node/pipeline/` that:
  - Spawns Rust binary as child process
  - Pipes JSON to stdin, reads JSON from stdout
  - Handles timeouts and error codes
  - Logs timing metrics
- [ ] Write integration tests with real Rust binary
- [ ] Benchmark IPC overhead (target: <5ms for 100 tx batch)

### 2.4 JSON-RPC API Server -- NOT STARTED

**Priority:** CRITICAL
**Effort:** Large

The architecture documents describe "eth_sendTransaction (JSON-RPC)" but there is no
JSON-RPC server in the codebase. Enterprises cannot submit transactions.

- [ ] Create `zkl2/node/rpc/` package with:
  - Standard Ethereum JSON-RPC server (net/http or fasthttp)
  - `eth_sendRawTransaction` -- submit signed transaction to mempool
  - `eth_getTransactionReceipt` -- query transaction status
  - `eth_getBlockByNumber` / `eth_getBlockByHash` -- query L2 blocks
  - `eth_getBalance` / `eth_getCode` / `eth_getStorageAt` -- state queries
  - `eth_call` -- read-only EVM execution
  - `eth_chainId` -- return L2 chain ID
  - `eth_blockNumber` -- return latest L2 block number
  - `eth_getLogs` -- event log queries
  - `basis_getBatchStatus` -- custom endpoint for batch/proof status
  - `basis_getProofStatus` -- custom endpoint for proving pipeline status
- [ ] Rate limiting per IP (enterprise-grade, not public)
- [ ] Authentication (API key or JWT, enterprise-specific)
- [ ] Write comprehensive tests for each endpoint
- [ ] Verify compatibility with ethers.js v6, Hardhat, and MetaMask

### 2.5 L1 Synchronizer -- NOT STARTED

**Priority:** HIGH
**Effort:** Medium

The node needs to read L1 state for:
- Forced inclusion transactions (deposited to BasisRollup.sol)
- Bridge deposit events (from BasisBridge.sol)
- DAC attestation events (from BasisDAC.sol)
- Enterprise registration changes (from EnterpriseRegistry.sol)

- [ ] Create `zkl2/node/sync/` package with:
  - L1 block scanner (poll or WebSocket subscription)
  - Event parser for BasisRollup, BasisBridge, BasisDAC, EnterpriseRegistry
  - Forced inclusion queue (feeds into Sequencer)
  - Deposit processing (feeds into Bridge Relayer)
  - State persistence for last-scanned block number
- [ ] Write tests with mocked L1 events
- [ ] Integration test with local Hardhat node emitting real events

---

## Section 3: Contract Deployment and L1 Integration

### 3.1 Contract Deployment to Fuji -- NOT STARTED

**Priority:** CRITICAL
**Effort:** Medium

The 6 zkl2 contracts have NEVER been deployed. They only run in the Hardhat test environment.

- [ ] Create deployment script `zkl2/contracts/scripts/deploy.ts`:
  - Deploy BasisVerifier.sol (proof verification)
  - Deploy BasisRollup.sol (state root management) -- link to BasisVerifier
  - Deploy BasisBridge.sol (asset transfers) -- link to EnterpriseRegistry on L1
  - Deploy BasisDAC.sol (data availability committee)
  - Deploy BasisAggregator.sol (proof aggregation)
  - Deploy BasisHub.sol (cross-enterprise settlement)
- [ ] Configure Hardhat for Fuji testnet:
  - Add Fuji RPC endpoint to `hardhat.config.ts`
  - Configure deployer account (same as L1 deployer: 0xA5Ee...)
  - Set gas price to 1 wei (near-zero fee model)
- [ ] Execute deployment to live Fuji chain
- [ ] Verify all 6 contracts on Snowtrace/explorer
- [ ] Record deployed addresses in documentation
- [ ] Create `.env.example` with all required variables

### 3.2 Contract Integration with L1 -- NOT STARTED

**Priority:** HIGH
**Effort:** Medium

The zkl2 contracts need to interact with the existing L1 contracts.

- [ ] Register zkl2 BasisRollup as a recognized contract in L1 EnterpriseRegistry
- [ ] Configure BasisBridge to read from L1 EnterpriseRegistry (IEnterpriseRegistry interface)
- [ ] Verify BasisRollup can commit/prove/execute batches on the live chain
- [ ] Verify BasisBridge deposit/withdrawal flows work on live chain
- [ ] Test forced inclusion: submit tx to BasisRollup on L1, verify it appears in L2

### 3.3 BasisGovernance.sol -- NOT IMPLEMENTED

**Priority:** LOW
**Effort:** Medium

The README references `BasisGovernance.sol` for protocol parameter updates, but this
contract does not exist in the codebase.

- [ ] Determine if governance is needed for MVP or can be deferred
- [ ] If needed: implement BasisGovernance.sol with:
  - Protocol parameter updates (batch size, proof timeout, etc.)
  - Admin-only access control (timelock optional for future)
  - Event emission for parameter changes
- [ ] If deferred: remove reference from README.md

---

## Section 4: End-to-End Pipeline Verification

### 4.1 E2E Test Script -- NOT STARTED

**Priority:** CRITICAL
**Effort:** Large

Unlike the Validium MVP (which has `validium/node/scripts/e2e-test.ts` running the
full pipeline on the live Fuji chain), zkl2 has NO end-to-end test.

- [ ] Create `zkl2/node/scripts/e2e-test.sh` (or equivalent):
  1. Start the L2 node binary
  2. Submit a transaction via JSON-RPC (`eth_sendRawTransaction`)
  3. Wait for sequencer to include it in a block
  4. Wait for EVM executor to produce execution trace
  5. Wait for witness generator to produce witness
  6. Wait for ZK prover to generate proof
  7. Wait for L1 submitter to call BasisRollup.sol
  8. Verify state root updated on L1
  9. Verify transaction receipt available via JSON-RPC
  10. Verify batch status is "finalized"
- [ ] Run on local Hardhat network first
- [ ] Run on live Fuji chain with deployed contracts
- [ ] Document results: timing, gas usage, proof size
- [ ] Zero crashes during E2E execution

### 4.2 Bridge E2E Test -- NOT STARTED

**Priority:** HIGH
**Effort:** Medium

- [ ] Deposit test: lock tokens on L1, verify minted on L2
- [ ] Withdrawal test: burn on L2, verify released on L1
- [ ] Escape hatch test: simulate offline sequencer, withdraw via Merkle proof
- [ ] Double-spend test: attempt to withdraw same deposit twice (must fail)

### 4.3 Cross-Enterprise E2E Test -- NOT STARTED

**Priority:** MEDIUM
**Effort:** Medium

- [ ] Register 2 enterprises (A and B) on L1
- [ ] Submit cross-enterprise transaction from A to B
- [ ] Verify settlement on L1 BasisHub.sol
- [ ] Verify isolation: B cannot read A's private data
- [ ] Verify atomicity: partial settlement reverts completely

### 4.4 DAC E2E Test -- NOT STARTED

**Priority:** MEDIUM
**Effort:** Medium

- [ ] Start 7 DAC nodes
- [ ] Submit batch data to DAC
- [ ] Collect attestations from >= 5 nodes
- [ ] Submit certificate to BasisDAC.sol on L1
- [ ] Simulate 2 nodes offline, verify recovery from remaining 5
- [ ] Simulate malicious node, verify data integrity

---

## Section 5: Configuration and Operations

### 5.1 Environment Configuration -- NOT STARTED

**Priority:** HIGH
**Effort:** Small

- [ ] Create `zkl2/node/.env.example` with all required variables:
  ```
  # L1 Connection
  L1_RPC_URL=https://rpc.basisnetwork.com.co
  L1_CHAIN_ID=43199
  L1_DEPLOYER_KEY=

  # L2 Configuration
  L2_CHAIN_ID=
  L2_BLOCK_INTERVAL_MS=1000
  L2_BATCH_SIZE=100

  # Contract Addresses (deployed)
  BASIS_ROLLUP_ADDRESS=
  BASIS_BRIDGE_ADDRESS=
  BASIS_DAC_ADDRESS=
  BASIS_HUB_ADDRESS=
  BASIS_AGGREGATOR_ADDRESS=
  BASIS_VERIFIER_ADDRESS=
  ENTERPRISE_REGISTRY_ADDRESS=0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5

  # Prover Configuration
  PROVER_BINARY_PATH=./target/release/basis-prover
  PROOF_TIMEOUT_SECONDS=300

  # DAC Configuration
  DAC_THRESHOLD=5
  DAC_COMMITTEE_SIZE=7
  DAC_NODE_URLS=

  # API Configuration
  RPC_PORT=8545
  RPC_RATE_LIMIT_PER_SEC=100
  API_KEY_HASH=
  ```
- [ ] Create `zkl2/prover/.env.example` for Rust prover configuration
- [ ] Ensure `.env` is in `.gitignore`

### 5.2 Docker and Containerization -- NOT STARTED

**Priority:** HIGH
**Effort:** Medium

- [ ] Create `zkl2/node/Dockerfile`:
  - Multi-stage build (Go builder + minimal runtime)
  - Include Rust prover binary
  - Health check endpoint
  - Non-root user
- [ ] Create `zkl2/docker-compose.yml`:
  - L2 node service
  - DAC nodes (7 instances)
  - Local L1 (Hardhat node for testing)
- [ ] Create `zkl2/Makefile` with:
  - `make docker-build`
  - `make docker-up`
  - `make docker-test` (E2E in containers)
- [ ] Test containerized deployment

### 5.3 Startup Documentation -- NOT STARTED

**Priority:** HIGH
**Effort:** Small

- [ ] Create `zkl2/node/STARTUP.md` documenting:
  - Prerequisites (Go, Rust, Node.js versions)
  - Installation steps
  - Configuration
  - Starting the node
  - Verifying the node is running
  - Submitting a test transaction
  - Monitoring and logs
  - Stopping the node
- [ ] Create `zkl2/QUICKSTART.md` with minimal 5-minute setup

### 5.4 Structured Logging and Monitoring -- NOT STARTED

**Priority:** MEDIUM
**Effort:** Small

- [ ] Add structured logging (slog) to all Go packages with consistent fields:
  - `component` (executor, sequencer, pipeline, etc.)
  - `batch_id`, `block_number`, `tx_hash` where applicable
  - `duration_ms` for performance-critical operations
- [ ] Add Prometheus-compatible metrics:
  - `basis_l2_blocks_produced_total`
  - `basis_l2_batches_proved_total`
  - `basis_l2_proof_duration_seconds`
  - `basis_l2_l1_submission_duration_seconds`
  - `basis_l2_mempool_size`
  - `basis_l2_state_root_height`

---

## Section 6: Security Hardening

### 6.1 JSON-RPC Security -- NOT STARTED

**Priority:** HIGH
**Effort:** Medium

- [ ] Rate limiting per IP (token bucket, configurable burst/rate)
- [ ] Authentication for transaction submission (API key or JWT)
- [ ] Input validation on all RPC parameters
- [ ] Request size limits
- [ ] CORS configuration
- [ ] TLS termination (or reverse proxy via Nginx)

### 6.2 Transaction Validation -- NOT STARTED

**Priority:** HIGH
**Effort:** Small

- [ ] Signature verification before mempool admission
- [ ] Nonce validation
- [ ] Gas limit validation
- [ ] Balance check (sufficient for value + gas)
- [ ] Deduplication by tx hash

### 6.3 State Persistence and Recovery -- NOT STARTED

**Priority:** HIGH
**Effort:** Medium

The current StateDB is entirely in-memory.

- [ ] Add LevelDB or RocksDB backend for StateDB persistence
- [ ] Write-ahead log (WAL) for crash recovery
- [ ] Checkpoint mechanism (periodic state snapshots)
- [ ] Startup recovery: reload state from last checkpoint + replay WAL
- [ ] Test: kill node mid-batch, restart, verify state consistency

### 6.4 Pipeline Failure Recovery -- NOT STARTED

**Priority:** MEDIUM
**Effort:** Medium

- [ ] WAL for pipeline state (which batches are in-flight, at which stage)
- [ ] On restart: resume in-flight batches from last known stage
- [ ] Idempotent L1 submissions (check if batch already committed before re-submitting)
- [ ] Configurable retry policies per stage
- [ ] Dead letter queue for permanently failed batches

---

## Section 7: Testing Completeness

### 7.1 Go Integration Tests -- NOT STARTED

**Priority:** HIGH
**Effort:** Large

The Go tests are all unit-level within individual packages. There are no tests
that verify multiple packages working together.

- [ ] Create `zkl2/node/integration_test.go`:
  - Sequencer produces block -> Executor processes block -> StateDB updated
  - Pipeline orchestrator drives full cycle (with simulated stages initially)
  - DAC receives batch data -> produces certificate
  - Cross-enterprise hub routes message between two enterprise modules
- [ ] Create `zkl2/node/pipeline/integration_test.go`:
  - Real executor + real StateDB + simulated prover
  - Verify execution traces are correct format for witness generator
- [ ] Create `zkl2/bridge/integration_test.go`:
  - Relayer processes deposit event -> produces Merkle proof
  - Relayer processes withdrawal -> verifies nullifier

### 7.2 Contract Coverage Report -- NOT VERIFIED

**Priority:** MEDIUM
**Effort:** Small

- [ ] Run `npx hardhat coverage` and verify >85% line coverage for all contracts
- [ ] Identify and fill coverage gaps
- [ ] Add coverage report to CI

### 7.3 Rust Integration Tests -- NOT STARTED

**Priority:** MEDIUM
**Effort:** Medium

- [ ] Create `zkl2/prover/tests/integration.rs`:
  - Witness generator produces witness -> Circuit accepts witness -> Proof generated
  - Aggregator combines multiple proofs -> Aggregated proof verifiable
- [ ] Benchmark: proof generation time for realistic batch sizes (10, 50, 100 tx)
- [ ] Memory profiling under sustained load

### 7.4 Adversarial E2E Tests -- NOT STARTED

**Priority:** MEDIUM
**Effort:** Medium

- [ ] Invalid proof submission to BasisRollup.sol (must revert)
- [ ] Replay attack: re-submit same batch (must revert)
- [ ] State root manipulation: submit incorrect state root (must revert)
- [ ] Bridge double-spend attempt
- [ ] Sequencer censorship: verify forced inclusion mechanism works
- [ ] DAC withholding: verify data recovery from threshold nodes
- [ ] Cross-enterprise isolation breach attempt

---

## Section 8: Documentation

### 8.1 README Update -- NOT STARTED

**Priority:** MEDIUM
**Effort:** Small

- [ ] Update `zkl2/README.md`:
  - Change "80% complete" to accurate status
  - Add "Getting Started" section
  - Add deployed contract addresses (after deployment)
  - Update component status table (remove "Planned", "In development")
  - Remove `BasisGovernance.sol` reference (or mark as future)
  - Add test run instructions for each language (Go, Rust, Solidity)

### 8.2 API Documentation -- NOT STARTED

**Priority:** MEDIUM
**Effort:** Medium

- [ ] Document all JSON-RPC endpoints with request/response examples
- [ ] Document custom `basis_*` endpoints
- [ ] Document authentication mechanism
- [ ] Create Postman/Insomnia collection for manual testing

### 8.3 Deployment Guide -- NOT STARTED

**Priority:** MEDIUM
**Effort:** Medium

- [ ] Step-by-step deployment guide for:
  - Local development (Hardhat network)
  - Fuji testnet
  - Production (future)
- [ ] Contract deployment procedure
- [ ] Node binary deployment procedure
- [ ] DAC node deployment procedure
- [ ] Bridge relayer deployment procedure

---

## Section 9: Dashboard Integration

### 9.1 zkEVM L2 Dashboard Page -- NOT STARTED

**Priority:** LOW
**Effort:** Medium

The Validium has a dedicated dashboard page. The zkl2 does not.

- [ ] Add "zkEVM L2" page to `l1/dashboard/`:
  - L2 block production stats
  - Batch/proof pipeline status (pending, proving, submitted, finalized)
  - BasisRollup state root history (per enterprise)
  - Bridge deposit/withdrawal activity
  - DAC attestation status
  - Cross-enterprise settlement activity
  - Proof aggregation statistics
- [ ] Update dashboard sidebar navigation
- [ ] Update Overview page with L2 stats

---

## Section 10: CI/CD

### 10.1 GitHub Actions Workflow -- NOT STARTED

**Priority:** MEDIUM
**Effort:** Small

- [ ] Create `.github/workflows/zkl2-test.yml`:
  - Go tests: `go test ./...` for node/ and bridge/
  - Go lint: `golangci-lint run`
  - Rust tests: `cargo test` for prover/
  - Rust lint: `cargo clippy -- -D warnings`
  - Solidity tests: `npx hardhat test` for contracts/
  - Solidity coverage: `npx hardhat coverage`
- [ ] Add to PR checks (must pass before merge)

---

## Priority Matrix

| Priority | Section | Effort | Description |
|----------|---------|--------|-------------|
| **P0** | 1.1 | Small | Install Go, verify Go tests compile and pass |
| **P0** | 2.1 | Large | Node binary (cmd/basis-l2) -- the system cannot start without this |
| **P0** | 2.2 | Large | Production pipeline stages -- components never connected |
| **P0** | 2.3 | Medium | Go-Rust IPC bridge -- prover cannot be invoked |
| **P0** | 2.4 | Large | JSON-RPC API -- enterprises cannot submit transactions |
| **P0** | 3.1 | Medium | Deploy contracts to Fuji -- nothing on-chain |
| **P0** | 4.1 | Large | E2E test on live chain -- the single most important validation |
| **P1** | 1.2 | Medium | Cross-package type consistency |
| **P1** | 2.5 | Medium | L1 synchronizer (forced inclusion, deposits) |
| **P1** | 3.2 | Medium | Contract integration with L1 |
| **P1** | 5.1 | Small | Environment configuration (.env.example) |
| **P1** | 5.2 | Medium | Docker containerization |
| **P1** | 5.3 | Small | Startup documentation |
| **P1** | 6.1 | Medium | JSON-RPC security hardening |
| **P1** | 6.2 | Small | Transaction validation |
| **P1** | 6.3 | Medium | State persistence (LevelDB/RocksDB) |
| **P1** | 7.1 | Large | Go integration tests |
| **P2** | 1.3 | Small | BasisVerifier test timing flake |
| **P2** | 4.2 | Medium | Bridge E2E test |
| **P2** | 4.3 | Medium | Cross-enterprise E2E test |
| **P2** | 4.4 | Medium | DAC E2E test |
| **P2** | 5.4 | Small | Structured logging and monitoring |
| **P2** | 6.4 | Medium | Pipeline failure recovery |
| **P2** | 7.2 | Small | Contract coverage report |
| **P2** | 7.3 | Medium | Rust integration tests |
| **P2** | 7.4 | Medium | Adversarial E2E tests |
| **P2** | 8.1 | Small | README update |
| **P2** | 8.2 | Medium | API documentation |
| **P2** | 8.3 | Medium | Deployment guide |
| **P3** | 3.3 | Medium | BasisGovernance.sol (optional) |
| **P3** | 9.1 | Medium | Dashboard integration |
| **P3** | 10.1 | Small | CI/CD pipeline |

---

## Comparison: Validium (100%) vs zkl2 (Current)

| Capability | Validium MVP | zkl2 |
|------------|-------------|------|
| Runnable binary | Yes (TypeScript node) | **NO** -- no main() |
| Component integration | All modules connected | **NO** -- isolated libraries |
| Cross-language bridge | snarkjs in-process | **NO** -- Go-Rust IPC not implemented |
| API server | Fastify REST (14 endpoints) | **NO** -- no JSON-RPC server |
| Deployed contracts | 7 contracts on Fuji | **NO** -- nothing deployed |
| E2E test on live chain | Yes (REST -> WAL -> Batch -> Proof -> L1) | **NO** -- no E2E test |
| State persistence | WAL + checkpoints | **NO** -- in-memory only |
| Docker | Dockerfile + docker-compose | **NO** |
| .env.example | Yes | **NO** |
| STARTUP.md | Yes | **NO** |
| Security hardening | Rate limiting, auth, WAL integrity | **NO** |
| Dashboard page | Yes (Validium page) | **NO** |
| CI/CD | N/A | **NO** |
| Unit tests verified | 275/275 TS passing | 321/322 TS, 142/142 Rust. **Go: UNVERIFIED** |
| TLA+ specs | 7 verified | 11 verified |
| Coq proofs | 7 units, 125+ theorems | 11 units, 107 files |

---

## Recommended Execution Order

### Phase A: Foundation (can be parallelized)
1. Install Go, verify Go tests (1.1)
2. Fix BasisVerifier test flake (1.3)
3. Create .env.example (5.1)

### Phase B: Node Skeleton
4. Create node binary with config loading (2.1)
5. Create JSON-RPC API server skeleton (2.4)
6. Add state persistence to StateDB (6.3)

### Phase C: Component Connection
7. Verify cross-package types (1.2)
8. Build Go-Rust IPC bridge (2.3)
9. Implement production pipeline stages (2.2)
10. Build L1 synchronizer (2.5)

### Phase D: Deployment
11. Deploy contracts to Fuji (3.1)
12. Integrate with L1 contracts (3.2)

### Phase E: End-to-End Verification
13. Run E2E test on local Hardhat (4.1)
14. Run E2E test on live Fuji chain (4.1)
15. Run Bridge E2E test (4.2)
16. Run DAC E2E test (4.4)
17. Run Cross-Enterprise E2E test (4.3)

### Phase F: Hardening
18. Security hardening (6.1, 6.2, 6.4)
19. Docker containerization (5.2)
20. Go integration tests (7.1)
21. Rust integration tests (7.3)
22. Adversarial E2E tests (7.4)

### Phase G: Documentation and Polish
23. Startup documentation (5.3)
24. README update (8.1)
25. API documentation (8.2)
26. Deployment guide (8.3)
27. Dashboard integration (9.1)
28. CI/CD pipeline (10.1)

---

## Known Technical Debt (from R&D Pipeline)

These open questions were identified during R&D and remain unresolved:

- **OQ-L1**: EVM executor uses in-memory state. Production needs persistent backend (LevelDB/RocksDB).
- **OQ-L2**: Sequencer has no P2P layer. Single-operator is acceptable for enterprise, but
  limits decentralization options.
- **OQ-L3**: Witness generator has not been tested with real Geth execution traces. The test
  traces are synthetic (generated by the test harness, not by the actual EVM executor).
- **OQ-L4**: PLONK circuit is architecturally designed but uses mock field operations. A
  production PLONK circuit for real EVM opcodes requires substantial additional work
  (likely months of engineering for full EVM coverage).
- **OQ-L5**: Proof aggregation uses simulated proofs. Real recursive proof aggregation
  requires the individual proofs to be from a compatible proof system.
- **OQ-L6**: The DAC nodes have never communicated over a real network. All tests use
  in-memory channels.
- **OQ-L7**: Bridge relayer has no event subscription to L1. It is a library with no
  event loop or connection management.

## Architecture Decisions Made During R&D

These decisions emerged from the pipeline and should be preserved:

1. **Go for L2 node** (TD-001): Geth heritage, goroutine concurrency, blockchain ecosystem maturity.
2. **Rust for ZK prover** (TD-002): Memory safety, zero-cost abstractions, native ZK libraries (gnark-crypto, halo2).
3. **PLONK as target proof system** (TD-003): Universal setup, custom gates for EVM opcodes, ~300K gas verification.
4. **Validium mode** (TD-004): Enterprise data privacy via DAC, only proofs on L1.
5. **Per-enterprise chains** (TD-005): Maximum data sovereignty and operational independence.
6. **Hub-and-spoke cross-enterprise** (TD-006): L1 as security hub, enterprises as spokes.
7. **Geth fork for EVM** (TD-007): 10+ years battle-tested, complete opcode support.
8. **Poseidon for state tree** (TD-008): 500x constraint reduction vs Keccak in ZK circuits.
9. **Solidity 0.8.24 with Cancun** (TD-009): Avalanche Subnet-EVM does not support Pectra.
