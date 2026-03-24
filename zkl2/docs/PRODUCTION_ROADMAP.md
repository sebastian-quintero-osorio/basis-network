# zkL2: Complete Production Roadmap

## Current State: ~75% (Updated 2026-03-23)

The full E2E pipeline has been **verified on Basis Network L1 (Fuji)** on 2026-03-23:
tx -> EVM execute -> witness (9ms, 2 rows) -> PLONK-KZG prove (86ms, 1376 bytes) ->
L1 commit (149K gas) -> L1 prove (71K gas) -> L1 execute -> batch finalized
(291K total gas, 5.8s). Real KZG proofs are generated and verified on-chain via
PlonkVerifier.sol. LevelDB state persistence, L1 synchronizer, and ProtoGalaxy
aggregation are all operational. Contract deployment E2E also verified.

Remaining work: complete EVM circuit coverage, distributed DAC, bridge E2E,
cross-enterprise E2E, security audit, production deployment.

This document defines every step to reach 100%.

---

## Phase 1: Real KZG Proof Generation -- COMPLETED (2026-03-23)

All items in this phase have been implemented and verified on-chain.

### 1.1 Wire Real create_proof() into CLI -- COMPLETED

**Problem (resolved):** `zkl2/prover/cli/src/main.rs` previously called `MockProver::run()`
and output `vec![0u8; 192]`. Now calls real `create_proof()` with KZG SRS parameters.

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

**Result:** `basis-prover prove` outputs real KZG proof bytes (1376 bytes).
`basis-prover verify` (commit 673fd65) validates proofs offline. SRS persisted to disk
(commit d179fab) for reuse across invocations.

### 1.2 Proof Serialization for On-Chain Verification -- COMPLETED

**Solution implemented: Path A (PlonkVerifier.sol)**

1. PlonkVerifier.sol deployed with commitment-based verification + challenge period
   (commit 8bda53d)
2. BasisRollupV2.sol deployed with REAL PlonkVerifier on-chain verification
   (commit 2e75922)
3. BasisVerifier.sol routes to PlonkVerifier in PLONK mode via migration state machine
4. Full proof serialization: Rust KZG proof -> base64 -> Go -> ABI encoding -> L1

**Verification:** Proof generated in Rust, serialized, passed to PlonkVerifier.sol,
verified on Basis Network L1 (Fuji). 71K gas for proveBatch.

### 1.3 L1 Submitter Real Proof Data -- COMPLETED

**Problem (resolved):** `l1_submitter.go` previously sent dummy proof data (all zeros).
Now sends real proof bytes parsed from Rust prover output.

**Result:** L1Submitter wired into production pipeline (commit 184c64d). Real proof
data flows through: Rust prover -> base64 JSON -> Go parser -> ABI encoding ->
BasisRollup.proveBatch() on L1. Pre-flight check (commit d5891e3) prevents duplicate
submissions.

### 1.4 End-to-End Proof Verification on L1 -- COMPLETED

**Verified on 2026-03-23 (commit 89f764e):**
1. Start zkl2 node -- DONE
2. Send signed transaction via RPC -- DONE
3. Block production -> EVM execution -> trace collection -- DONE
4. Witness generation (9ms, 2 rows) -- DONE
5. Real KZG proof generation (86ms, 1376 bytes) -- DONE
6. L1 submission with real proof -- DONE
7. BasisRollup.sol verifies proof via PlonkVerifier -- DONE
8. State root updated on-chain -- DONE

**On-chain result:** committedBatches=1, provenBatches=1, executedBatches=1,
state root advanced from Poseidon genesis to post-batch root.
BasisRollupHarness: 0x79279EDe17c8026412cD093876e8871352f18546.
Total gas: 291K, total time: 5.8s.

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

## Phase 3: Real Proof Aggregation -- PARTIALLY COMPLETED

### 3.1 Replace SHA256 Simulation with ProtoGalaxy -- COMPLETED

**Problem (resolved):** `aggregator/src/verifier_circuit.rs` previously used SHA256
hashing instead of real ProtoGalaxy folding.

**Result:** Real ProtoGalaxy folding implemented (commit 92083d1). Challenge-based
linear combination: `C' = sum(alpha^i * C_i)`. CommittedInstance and FoldedInstance
types for proper aggregation. Wired into production pipeline (commit 144bdb5).
Main node triggers aggregation after 4 finalized batches (main.go lines 668-686).

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

## Phase 5: L1 Synchronizer -- COMPLETED (2026-03-23)

### 5.1 Real eth_getLogs Implementation -- COMPLETED

**Problem (resolved):** `sync/synchronizer.go` `scanNewBlocks()` previously just
incremented a counter.

**Result:** L1 Synchronizer fully wired into main.go (lines 311-423). Polls L1 via
eth_getLogs with topic filters for ForcedInclusion, Deposit, DACAttestation, and
EnterpriseRegistered events. Event data parsed into typed structs and dispatched to
registered handlers. Commit 23bc8df fixed deposit event topic and default contract
addresses.

### 5.2 Forced Inclusion Integration -- COMPLETED

- [x] L1 ForcedInclusion events detected and forwarded to sequencer (main.go lines 385-398)
- [ ] E2E test: submit forced inclusion on L1, verify it appears in next L2 block (not tested)

### 5.3 Bridge Deposit Detection -- COMPLETED

- [x] L1 Deposit events detected and forwarded to bridge relayer (main.go lines 399-418)
- [x] Bridge relayer has deposit/withdrawal handlers that credit/debit L2 StateDB
- [x] L1 bridge client wired for withdraw root submission (commit eb0edf2)
- [ ] E2E test: deposit on L1, verify balance on L2 (not tested)

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

| Phase | Duration | Status |
|-------|----------|--------|
| 1. Real KZG Proofs | 1-2 weeks | **COMPLETED** (2026-03-23) |
| 2. Complete EVM Circuit | 2-6 months (or 2-6 weeks with PSE adoption) | Open (20+ opcodes done, full coverage pending) |
| 3. Real Proof Aggregation | 3-4 weeks | **ProtoGalaxy COMPLETED**, aggregated on-chain verification open |
| 4. Distributed DAC | 2-3 weeks | Open |
| 5. L1 Synchronizer | 1-2 weeks | **COMPLETED** (wired into main loop) |
| 6. Bridge Implementation | 2-3 weeks | **PARTIALLY COMPLETED** (relayer + L1 client wired, E2E untested) |
| 7. Cross-Enterprise Hub | 2-3 weeks | Open (module exists, L1 integration untested) |
| 8. Security Audit | 3-4 weeks | Open |
| 9. Production Deployment | 2-4 weeks | Open |
| 10. Scale/Optimization | Ongoing | Open |

**Critical path:** Phase 2 -> Phase 8 -> Phase 9 (Phase 1 completed)
**Parallel tracks:** Phases 4, 6, 7 can run alongside Phase 2

**Total remaining to production: 4-8 months** (accelerated with PSE circuit adoption)
