# zkL2: Complete Production Roadmap

## Current State: ~40%

The Go node (EVM executor, sequencer, statedb) works. Rust prover libraries exist with real halo2 circuit. Solidity contracts are deployed. Go-Rust IPC is verified. But the ZK proof pipeline outputs dummy bytes and no proof has ever been verified on-chain against BasisRollup.sol. This document defines every step to reach 100%.

---

## Phase 1: Real KZG Proof Generation (1-2 weeks)

This is the single most critical phase. Without real proofs, nothing else matters.

### 1.1 Wire Real create_proof() into CLI

**Problem:** `zkl2/prover/cli/src/main.rs` calls `MockProver::run()` and outputs `vec![0u8; 192]`. The real `create_proof()` function EXISTS in `prover.rs` but is never called.

**Solution:**
- File: `zkl2/prover/cli/src/main.rs` -- `run_prove()` function
- Steps:
  1. Generate KZG SRS parameters: `ParamsKZG::<Bn256>::setup(k, OsRng)` where k = circuit degree (currently 10, may need 14-16 for production)
  2. Build the circuit from witness result
  3. Generate verification key: `keygen_vk(&params, &circuit)`
  4. Generate proving key: `keygen_pk(&params, vk, &circuit)`
  5. Call `create_proof::<_, ProverSHPLONK<Bn256>, _, _, _, _>()` -- the function already exists in `circuit/src/prover.rs`
  6. Serialize proof bytes to JSON output
  7. Cache params/keys to disk (SRS generation is expensive, do it once)

**Key insight:** halo2-KZG does NOT require a multi-party trusted setup ceremony like Groth16. `ParamsKZG::setup(k, OsRng)` generates parameters deterministically. This is fundamentally simpler.

**Files to modify:**
- `zkl2/prover/cli/src/main.rs` -- Replace MockProver with real prover
- `zkl2/prover/circuit/src/prover.rs` -- May need adjustments for serialization format
- `zkl2/prover/cli/src/types.rs` -- ProofResult must carry real proof bytes

**Verification:** `basis-prover prove` outputs non-zero proof bytes. `basis-prover verify` (new command) verifies the proof offline.

### 1.2 Proof Serialization for On-Chain Verification

**Problem:** BasisRollup.sol expects Groth16 format (a: G1, b: G2, c: G1). halo2-KZG produces PLONK proofs with different structure (commitments + evaluations + opening proof).

**Two paths:**
- **Path A (recommended):** Deploy a PLONK-KZG verifier contract on L1. The halo2 ecosystem has Solidity verifier generators (`snark-verifier` crate from PSE).
- **Path B:** Convert PLONK proof to Groth16 format. This is mathematically impossible directly -- would need a wrapper SNARK (Groth16 proof of PLONK verification). Complex but proven approach (used by Scroll).

**Solution (Path A):**
1. Use `snark-verifier` crate to generate a Solidity PLONK verifier
2. Deploy as `PlonkVerifier.sol` on Basis Network L1
3. Update BasisVerifier.sol to route to PlonkVerifier when in PLONK mode (migration state machine already exists)
4. BasisRollup.sol calls BasisVerifier.sol which delegates to PlonkVerifier

**Files to create:**
- `zkl2/contracts/contracts/PlonkVerifier.sol` -- generated from snark-verifier
- Deploy script for PlonkVerifier

**Verification:** Generate proof in Rust, serialize, pass to PlonkVerifier.sol, verify returns true.

### 1.3 L1 Submitter Real Proof Data

**Problem:** `l1_submitter.go` sends `dummyA`, `dummyB`, `dummyC` (all zeros).

**Solution:**
- Parse `ProofResultJSON.ProofBytes` from the Rust prover output
- Format according to the on-chain verifier's expected ABI encoding
- For PLONK-KZG: encode commitments and evaluation proofs per PlonkVerifier ABI
- Send real proof data in `proveBatch()` transaction

**Files to modify:**
- `zkl2/node/pipeline/l1_submitter.go` -- Replace dummy data with parsed proof
- `zkl2/node/pipeline/types.go` -- ProofResultJSON may need additional fields

**Verification:** `proveBatch()` transaction succeeds on L1 with real BasisRollup (not harness).

### 1.4 End-to-End Proof Verification on L1

**Test:**
1. Start zkl2 node
2. Send signed transaction via RPC
3. Block production -> EVM execution -> trace collection
4. Witness generation (Rust)
5. Real KZG proof generation (Rust)
6. L1 submission with real proof
7. BasisRollup.sol verifies proof via PlonkVerifier
8. State root updated on-chain

---

## Phase 2: Complete EVM Circuit (2-6 months)

### 2.1 Current Gate Inventory

The circuit has 5 gates: Add, Mul, Poseidon, Memory, Stack. A complete zkEVM needs gates for every EVM opcode category.

### 2.2 Arithmetic Gates (2 weeks)
- ADD, SUB, MUL, DIV, SDIV, MOD, SMOD, ADDMOD, MULMOD, EXP
- Comparison: LT, GT, SLT, SGT, EQ, ISZERO
- Bitwise: AND, OR, XOR, NOT, BYTE, SHL, SHR, SAR
- Each gate: constraint definition + witness assignment + tests

### 2.3 Memory and Storage Gates (3 weeks)
- MLOAD, MSTORE, MSTORE8, MSIZE
- SLOAD, SSTORE (Poseidon SMT proof verification within circuit)
- CALLDATALOAD, CALLDATACOPY, CALLDATASIZE
- CODECOPY, CODESIZE, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH
- RETURNDATASIZE, RETURNDATACOPY

### 2.4 Control Flow Gates (3 weeks)
- JUMP, JUMPI, JUMPDEST, PC
- PUSH1-PUSH32
- DUP1-DUP16, SWAP1-SWAP16
- POP
- Bytecode commitment (hash of deployed code)

### 2.5 System Operations Gates (2 weeks)
- CALL, CALLCODE, DELEGATECALL, STATICCALL
- CREATE, CREATE2
- RETURN, REVERT, SELFDESTRUCT (deprecated but needed)
- LOG0-LOG4

### 2.6 Environment Gates (1 week)
- ADDRESS, BALANCE, ORIGIN, CALLER, CALLVALUE
- GASPRICE, COINBASE, TIMESTAMP, NUMBER, DIFFICULTY, GASLIMIT
- CHAINID, SELFBALANCE, BASEFEE
- BLOCKHASH

### 2.7 Lookup Tables (2 weeks)
- Bytecode lookup table (verify opcode at PC is correct)
- Memory access consistency (read-after-write ordering)
- Storage state consistency (Poseidon SMT operations)
- Call stack consistency

### 2.8 Circuit Testing Framework
- Per-opcode test vectors (correct execution + malicious witness rejection)
- Cross-opcode interaction tests
- Gas metering verification
- Benchmark: proof generation time vs circuit size

### 2.9 Alternative: Adopt Existing zkEVM Circuit

Instead of building from scratch, evaluate adopting:
- **PSE zkEVM** (Privacy and Scaling Explorations) -- most mature open-source halo2 zkEVM
- **Scroll's zkevm-circuits** -- production-grade, also halo2
- **Taiko's raiko** -- newer, modular approach

**Evaluation criteria:**
- License compatibility with BSL 1.1
- halo2 version compatibility (PSE fork v0.3.0 matches our dependency)
- Customizability for enterprise features (per-enterprise isolation, zero-fee)
- Community support and maintenance

**Recommendation:** Start with PSE zkEVM circuits as a base, customize for Basis Network enterprise requirements. This reduces the 2-6 month timeline to 2-6 weeks for initial integration + ongoing customization.

---

## Phase 3: Real Proof Aggregation (3-4 weeks)

### 3.1 Replace SHA256 Simulation with ProtoGalaxy

**Problem:** `aggregator/src/verifier_circuit.rs` uses SHA256 hashing instead of real ProtoGalaxy folding.

**Solution:**
- Integrate Sonobe library (Rust implementation of ProtoGalaxy + CycleFold)
- `fold_pair()`: Replace SHA256 with `ProtoGalaxy::fold(instance_a, instance_b)`
- `decide()`: Replace SHA256 with real Groth16 decider proof over folded instance
- Maintain the same TLA+ safety properties (already verified)

**Files to modify:**
- `zkl2/prover/aggregator/src/verifier_circuit.rs` -- real ProtoGalaxy
- `zkl2/prover/aggregator/Cargo.toml` -- add sonobe dependency
- `zkl2/prover/aggregator/src/aggregator.rs` -- adjust types for real folded instances

**Dependencies:** Sonobe library (https://github.com/privacy-scaling-explorations/sonobe)

### 3.2 Aggregated Proof On-Chain Verification

- Generate single Groth16 decider proof from N folded enterprise proofs
- Deploy aggregation verifier contract
- BasisAggregator.sol calls verifier for aggregated proofs
- Gas savings: 220K per aggregated batch vs 420K per individual

### 3.3 Multi-Enterprise Aggregation E2E

- Run 3 enterprise nodes producing independent proofs
- Aggregate into single proof
- Verify aggregated proof on L1
- Verify per-enterprise state roots updated correctly

---

## Phase 4: Distributed DAC (2-3 weeks)

### 4.1 DAC Node as Standalone Go Service

**Solution:**
- Create `zkl2/dac-node/` -- standalone Go service
- gRPC transport with protobuf definitions
- Reed-Solomon erasure coding (already implemented in `da/erasure.go`)
- Shamir secret sharing for share generation
- LevelDB share storage
- ECDSA attestation signing
- Health and metrics endpoints

### 4.2 BasisDAC.sol Integration

- After collecting threshold attestations, submit to BasisDAC.sol on L1
- Wire into pipeline Submit stage (after proof submission)

### 4.3 DAC Recovery Testing

- Docker Compose: 5 DAC nodes + zkl2 node
- Kill 2 nodes (threshold 3-of-5), verify recovery
- Corrupted share detection and rejection

---

## Phase 5: L1 Synchronizer (1-2 weeks)

### 5.1 Real eth_getLogs Implementation

**Problem:** `sync/synchronizer.go` `scanNewBlocks()` just increments a counter.

**Solution:**
- Use `ethclient.FilterLogs()` with topic filters for:
  - ForcedInclusion events from BasisRollup
  - Deposit events from BasisBridge
  - DACAttestation events from BasisDAC
  - EnterpriseRegistered events from EnterpriseRegistry
- Parse event data into typed structs
- Dispatch to registered handlers

### 5.2 Forced Inclusion Integration

- When L1 emits ForcedInclusion, add transaction to sequencer forced queue
- Sequencer includes forced transactions within deadline
- Test: submit forced inclusion on L1, verify it appears in next L2 block

### 5.3 Bridge Deposit Detection

- When L1 emits Deposit, credit balance on L2 statedb
- Mint equivalent tokens on L2
- Test: deposit on L1, verify balance on L2

---

## Phase 6: Bridge Full Implementation (2-3 weeks)

### 6.1 Deposit Flow (L1 -> L2)

- User deposits ETH/tokens to BasisBridge.sol on L1
- L1 Synchronizer detects Deposit event
- L2 node mints equivalent on L2 statedb
- User sees balance on L2

### 6.2 Withdrawal Flow (L2 -> L1)

- User initiates withdrawal on L2
- Withdrawal included in batch
- After batch proven and executed on L1, user claims on L1
- BasisBridge.sol verifies Merkle proof against executed state root
- Funds released to user on L1

### 6.3 Escape Hatch

- If sequencer offline > 24 hours, users can withdraw via state proof
- BasisBridge.sol `escapeWithdraw()` verifies Merkle proof against last executed root
- Test: stop sequencer for 24h, verify escape withdrawal works

### 6.4 Bridge Relayer

- `zkl2/bridge/relayer/` -- standalone Go service
- Monitors L1 for deposits, L2 for withdrawals
- Submits withdrawal roots to L1 after batch execution
- Merkle tree management for withdrawal proofs

---

## Phase 7: Cross-Enterprise Hub (2-3 weeks)

### 7.1 Hub-and-Spoke Protocol

- Enterprise A proves state on L1 via BasisRollup
- Enterprise B proves state on L1 via BasisRollup
- Hub verifies both proofs and records cross-reference via BasisHub.sol
- No direct L2-to-L2 communication (L1 is the trust anchor)

### 7.2 Cross-Enterprise Gateway

- Go service in `zkl2/node/cross/` (already has routing logic)
- Wire to BasisHub.sol on L1
- 4-phase protocol: Prepare -> Verify -> Respond -> Settle

### 7.3 Atomic Settlement

- Both enterprises verified or neither (no partial success)
- Timeout mechanism for unilateral withdrawal
- Test with 3 enterprises in hub topology

---

## Phase 8: Security and Audit (3-4 weeks)

### 8.1 Smart Contract Audit

- BasisRollup.sol, BasisBridge.sol, BasisDAC.sol, BasisHub.sol, BasisAggregator.sol, BasisVerifier.sol
- PlonkVerifier.sol (generated, but verify no vulnerabilities)
- Third-party audit firm

### 8.2 Prover Security

- Circuit soundness review (no under-constrained witnesses)
- Side-channel analysis on proof generation
- Malicious witness rejection for all opcode gates

### 8.3 Node Security

- RPC input fuzzing (invalid RLP, oversized transactions, malformed signatures)
- Mempool DoS resistance
- State corruption recovery

### 8.4 Bridge Security

- Withdrawal proof forgery resistance
- Double-spend prevention (nullifier completeness)
- Escape hatch timing attack analysis

---

## Phase 9: Production Deployment (2-4 weeks)

### 9.1 Mainnet Contract Deployment

- Deploy all 6 contracts to Avalanche mainnet
- Set verifying keys from production circuit
- Initialize enterprises

### 9.2 Multi-Validator L1

- 3+ validators for Basis Network L1
- Validator failover testing
- Monitoring and alerting

### 9.3 Enterprise Node Packaging

- Docker image for zkl2 node (Go binary + Rust prover)
- Helm chart for Kubernetes deployment
- Configuration management (enterprise-specific settings)
- Automated certificate and key provisioning

### 9.4 Monitoring and Observability

- Prometheus metrics from Go node and Rust prover
- Grafana dashboards: block production, batch pipeline, proof generation, L1 submission
- PagerDuty/Slack alerting integration

---

## Phase 10: Scale and Optimization (ongoing)

### 10.1 GPU Proof Acceleration

- CUDA/OpenCL acceleration for halo2 proof generation
- Target: 10x speedup (from minutes to seconds for full EVM proofs)
- Hardware: NVIDIA A100 or similar

### 10.2 Proof Parallelization

- Multiple enterprise proofs in parallel
- Pipeline: while proving batch N, execute batch N+1
- Worker pool with job queue

### 10.3 State Compression

- State diff compression for L1 submission
- Reduce calldata cost (even with zero-fee, reduces chain bloat)

### 10.4 PLONK to Halo2 Recursion

- Recursive proof composition: prove batch of batches
- Amortize L1 verification cost across many batches
- Target: 1 L1 tx per hour regardless of throughput

---

## Success Criteria

The zkL2 is 100% production-ready when:
1. Full EVM circuit covers all Cancun opcodes (or adopted from PSE/Scroll)
2. Real KZG proofs generated and verified on-chain (BasisRollup, not harness)
3. PLONK verifier deployed and functional on L1
4. Proof aggregation with real ProtoGalaxy folding
5. Distributed DAC with 3+ nodes on separate machines
6. L1 Synchronizer processes forced inclusion and deposits
7. Bridge deposit/withdrawal/escape fully functional
8. Cross-enterprise hub operational with 2+ enterprises
9. Security audit completed with zero high-severity findings
10. GPU-accelerated proving under 60 seconds for full EVM blocks
11. Load tested at target throughput (100-500 TPS per enterprise)
12. 3+ validators on mainnet
13. First enterprise onboarded and running production workload

---

## Timeline Estimate

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| 1. Real KZG Proofs | 1-2 weeks | None |
| 2. Complete EVM Circuit | 2-6 months (or 2-6 weeks with PSE adoption) | Phase 1 |
| 3. Real Proof Aggregation | 3-4 weeks | Phase 1 |
| 4. Distributed DAC | 2-3 weeks | None (parallel) |
| 5. L1 Synchronizer | 1-2 weeks | None (parallel) |
| 6. Bridge Implementation | 2-3 weeks | Phase 5 |
| 7. Cross-Enterprise Hub | 2-3 weeks | Phase 1 |
| 8. Security Audit | 3-4 weeks | Phases 1-7 |
| 9. Production Deployment | 2-4 weeks | Phase 8 |
| 10. Scale/Optimization | Ongoing | Phase 9 |

**Critical path:** Phase 1 -> Phase 2 -> Phase 8 -> Phase 9
**Parallel tracks:** Phases 3, 4, 5, 6, 7 can run alongside Phase 2

**Total to production: 6-12 months** (accelerated with PSE circuit adoption)
