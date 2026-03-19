# Validium MVP -- Post-Roadmap Integration Plan

## What Was Accomplished

The R&D pipeline executed 28 agent sessions across 7 Research Units, producing:

- **7 TypeScript/Circom/Solidity modules**, each individually tested
- **7 TLA+ specifications**, all model-checked (TLC PASS)
- **7 Coq verification units**, 125+ theorems, 0 Admitted
- **~860 unit tests** passing across all modules
- **~100 adversarial attack scenarios** tested
- **1 critical bug** found by formal verification and fixed (NoLoss in batch aggregation)
- **1 innovation** discovered (Shamir SSS for DAC privacy -- no production validium has this)

## What We Have (Module Inventory)

| Module | Location | Tests | TLC | Coq | Status |
|--------|----------|-------|-----|-----|--------|
| SparseMerkleTree | `validium/node/src/state/` | 52 | PASS | VERIFIED | Standalone OK |
| TransactionQueue + WAL | `validium/node/src/queue/` | 66 | PASS | VERIFIED | Standalone OK |
| BatchAggregator + Builder | `validium/node/src/batch/` | 45 | (same) | (same) | Standalone OK |
| DACProtocol + Shamir | `validium/node/src/da/` | 67 | PASS | VERIFIED | Standalone OK |
| ZK Prover wrapper | `validium/node/src/prover/` | (in E2E) | -- | -- | Depends on circuit setup |
| L1 Submitter | `validium/node/src/submitter/` | (in E2E) | -- | -- | Depends on deployment |
| REST API (Fastify) | `validium/node/src/api/` | (in E2E) | -- | -- | Standalone OK |
| Orchestrator | `validium/node/src/orchestrator.ts` | 19 | PASS | VERIFIED | **Mock-based tests** |
| state_transition.circom | `validium/circuits/circuits/` | 6 adversarial | PASS | VERIFIED | Compiled (d10 only) |
| StateCommitment.sol | `l1/contracts/contracts/core/` | 38 | PASS | VERIFIED | **Not deployed** |
| DACAttestation.sol | `l1/contracts/contracts/verification/` | 28 | PASS | VERIFIED | **Not deployed** |
| CrossEnterpriseVerifier.sol | `l1/contracts/contracts/verification/` | 25 | PASS | VERIFIED | **Not deployed** |

## What Is Missing (Integration Gaps)

### Critical Path: Making the Node Run End-to-End

Each module was built and tested in isolation by separate agent sessions. The following
integration work is required to make the system function as a single running service.

#### 1. Cross-Module Integration Testing

The orchestrator imports all modules but was tested with mocks. Required:

- [ ] Verify all TypeScript modules compile together (`npx tsc --noEmit` from `validium/node/`)
- [ ] Resolve any type mismatches between modules (each agent defined its own types)
- [ ] Create shared type definitions if needed (`src/common/types.ts`)
- [ ] Run the full test suite together and fix any cross-module failures
- [ ] Write at least 1 real integration test: enqueue tx -> form batch -> update SMT -> build witness

#### 2. Circuit Production Setup

The state_transition circuit was benchmarked at multiple depths but needs production setup:

- [ ] Compile `state_transition.circom` at depth 32, batch 8 (production config)
- [ ] Run Powers of Tau ceremony (or reuse existing `pot19` from benchmarks)
- [ ] Generate circuit-specific proving and verification keys
- [ ] Generate the production `Groth16Verifier.sol` from the final keys
- [ ] Verify proof generation works with real SMT data (not synthetic inputs)
- [ ] Measure actual proving time on target hardware

#### 3. L1 Contract Deployment

Three new contracts need deployment on Basis Network (Fuji):

- [ ] Deploy `StateCommitment.sol` (integrate with existing EnterpriseRegistry)
- [ ] Deploy `DACAttestation.sol` (configure committee members)
- [ ] Deploy `CrossEnterpriseVerifier.sol` (integrate with StateCommitment)
- [ ] Update `StateCommitment.sol` with the production Groth16 verifying key
- [ ] Test batch submission on actual L1 (not Hardhat local network)
- [ ] Update deploy script (`l1/contracts/scripts/deploy.ts`)

#### 4. End-to-End Pipeline Test

The complete cycle has never been executed:

- [ ] Start the node (`validium/node/`)
- [ ] Send a transaction via REST API (POST /v1/transactions)
- [ ] Verify the SMT is updated
- [ ] Verify batch formation triggers (size or time threshold)
- [ ] Verify ZK proof is generated (snarkjs or rapidsnark)
- [ ] Verify proof is submitted to StateCommitment.sol on L1
- [ ] Verify state root is updated on-chain
- [ ] Verify DAC attestation is recorded
- [ ] Query the batch via REST API (GET /v1/batches/:id)

#### 5. Dashboard Update

The existing dashboard (`l1/dashboard/`) shows the old architecture:

- [ ] Add StateCommitment batch history view (per enterprise)
- [ ] Add state root chain visualization
- [ ] Add DAC attestation status
- [ ] Add node health status (connected to GET /v1/status)
- [ ] Remove or update references to the old ZKVerifier-only flow

### Non-Critical but Important

#### 6. Configuration and Operations

- [ ] Populate `.env.example` with all required variables
- [ ] Document node startup procedure
- [ ] Add Docker/docker-compose for reproducible deployment
- [ ] Configure structured logging output (JSON to file or stdout)
- [ ] Set up health check monitoring

#### 7. Known Technical Debt

From the R&D pipeline (documented in Open Questions OQ-1 through OQ-22):

- **OQ-1**: In-memory SMT exceeds 2GB at >1M entries. Production needs LevelDB/RocksDB backing.
- **OQ-2**: Proof verification margin is tight (P95 = 1.869ms vs 2ms). WebAssembly Poseidon recommended.
- **OQ-3**: snarkjs cannot prove batch 64 at depth 32 in <60s. Rapidsnark (C++) or GPU prover needed.
- **OQ-6**: WAL benchmarks ran on Windows NTFS. Production Linux (ext4) may show different fsync behavior.
- **OQ-9**: Shamir recovery at 500KB takes ~9.7s in JavaScript. Native implementation needed for interactive use.
- **OQ-15**: Pipelined SMT writes during proving create rollback risk if L1 submission fails.

#### 8. Security Hardening

- [ ] Rate limiting on REST API endpoints
- [ ] Authentication for transaction submission (enterprise API keys)
- [ ] WAL integrity verification on startup (SHA-256 checksums)
- [ ] Checkpoint file integrity hash
- [ ] Transaction deduplication by txHash (ATK-BA4)

## Recommended Execution Order

The fastest path to a functional system:

```
Step 1: Cross-module compilation check (30 min)
    |
Step 2: Circuit production setup (2-4 hours, mostly waiting for compilation)
    |
Step 3: Contract deployment on Fuji (1 hour)
    |
Step 4: E2E pipeline test with real proof (2-4 hours)
    |
Step 5: Dashboard update (4-8 hours)
```

Steps 1-4 can be accomplished in a single focused session. Step 5 is independent.

## Architecture Decisions Made During R&D

These decisions emerged from the pipeline and should be preserved:

1. **Integrated ZK verification** in StateCommitment.sol (not delegated to ZKVerifier.sol).
   Reason: 72% of gas is pairing verification. Delegation adds 56K gas overhead, exceeding 300K budget.

2. **Deferred WAL checkpoint** (checkpoint after batch processing, not formation).
   Reason: NoLoss bug found by TLA+ model checking. Checkpoint during formation creates
   a 1.9-12.8s crash-loss window during proving.

3. **Shamir (2,3)-SS for DAC** instead of raw data distribution.
   Reason: Information-theoretic privacy. No production validium has this. Genuine differentiator.

4. **Depth 32, batch 8-16** for production circuit.
   Reason: d32_b8 = 274K constraints, 12.8s proving. d32_b16 extrapolates to ~26s.
   Batch 64 exceeds 60s target with snarkjs.

5. **Pipelined state machine** (accept transactions during proving/submission).
   Reason: 1.29x throughput improvement. CheckQueue transition required for liveness
   (discovered by Logicist, missing from original design).

6. **Fastify over Express** for REST API.
   Reason: 2-4x throughput advantage in benchmarks. Enterprise workload benefits from
   the performance headroom.
