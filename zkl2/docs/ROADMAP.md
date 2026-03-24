# zkEVM L2 -- Research and Development Roadmap

## Overview

The Enterprise zkEVM L2 is the long-term target for Basis Network. It is a full zkEVM Layer 2
where each enterprise deploys their own chain with a sequencer, EVM executor, ZK prover, and
data availability committee. Settlement and verification happen on the Basis Network L1.

This roadmap defines 11 Research Units (RUs) that flow through the 4-agent R&D pipeline
(Scientist, Logicist, Architect, Prover) to build every component.

## Current State

| Component | Status | Location |
|-----------|--------|----------|
| Vision document | Complete (327 lines) | `zkl2/VISION.md` |
| Architecture document | Complete (97 lines) | `zkl2/docs/ARCHITECTURE.md` |
| Technical decisions (9 ADRs) | Complete (157 lines) | `zkl2/docs/TECHNICAL_DECISIONS.md` |
| Go code (L2 node) | 100% -- E2E verified on L1 | `zkl2/node/` (246 Go tests, 7 CLI commands) |
| Rust code (ZK prover) | 100% -- real KZG proofs | `zkl2/prover/` (142 Rust tests, SRS cached) |
| Solidity contracts (L1) | 100% -- deployed on Fuji | `zkl2/contracts/` (322 TS tests, 6+1 contracts) |
| Bridge infrastructure | 90% -- wired, E2E untested | `zkl2/bridge/` (33 Go tests) |

## Prerequisite

The Validium MVP (see `validium/ROADMAP.md`) should be substantially complete before starting
the zkL2 pipeline. Knowledge from Validium RUs (especially RU-V1, RU-V2, RU-V3) directly
informs zkL2 research and implementation.

## Target State (zkEVM L2 Complete)

1. An enterprise can deploy their own L2 chain with sequencer, EVM executor, and prover.
2. Arbitrary Solidity contracts can execute on L2 with full EVM compatibility (Cancun opcodes).
3. ZK validity proofs verify on the Basis Network L1 via BasisRollup.sol.
4. Bridge enables L1 <-> L2 asset transfers with escape hatch for censorship resistance.
5. Enterprise DAC provides data availability without public data exposure.
6. Cross-enterprise hub-and-spoke model enables inter-enterprise verification.

## Technology Assignments

| Component | Language | Justification |
|-----------|----------|---------------|
| L2 Node | Go | Geth fork heritage, goroutine concurrency, blockchain ecosystem |
| ZK Prover | Rust | Memory safety, zero-cost abstractions, native ZK libraries |
| L1 Contracts | Solidity 0.8.24 | EVM native, existing L1 infrastructure, evmVersion: cancun |
| Bridge Relayer | Go | Same runtime as L2 node, shared libraries |

## Research Units

### Phase 1: L2 Foundation

#### RU-L1: EVM Execution Engine (Geth Fork)

**Criticality:** MAXIMUM -- the core execution environment.

**Hypothesis:**
A minimal fork of go-ethereum can execute EVM transactions with its own state management,
producing execution traces (storage reads/writes, opcodes executed) necessary for witness
generation, while maintaining 100% compatibility with Cancun opcodes and processing
1000+ simple transactions per second.

**Scientist:**
- Research how Polygon CDK, Scroll, and zkSync fork Geth.
- Identify minimal Geth modules needed: core/vm, core/state, ethdb.
- Measure overhead of trace generation vs vanilla Geth.
- Map Cancun opcodes that require special ZK treatment (KECCAK256, BLOCKHASH, etc.).
- Benchmark: tx/s, trace size per tx, memory usage.

**Logicist:**
- Formalize: EVM as state machine with SLOAD/SSTORE/CALL/CREATE operations.
- Invariants:
  - Determinism: same tx + same state -> same result and same trace.
  - TraceCompleteness: trace captures ALL state-modifying operations.
  - OpcodeCorrectness: each opcode produces correct output per EVM specification.
- Model check with 3 accounts, 5 opcodes, 2 transactions.

**Architect:**
- Implement in Go: minimal Geth fork with trace collector and state manager.
- Tests: execute simple Solidity contracts and verify traces match expected behavior.
- Target: `zkl2/node/executor/`

**Prover:**
- Prove Determinism and TraceCompleteness properties.

**Output:** Minimal Go EVM executor with execution trace generation.

---

#### RU-L2: Sequencer and Block Production

**Criticality:** HIGH -- transaction ordering and block lifecycle.

**Hypothesis:**
A single-operator sequencer can produce L2 blocks every 1-2 seconds with FIFO ordering,
maintaining a forced inclusion mechanism via L1 that guarantees censorship resistance with
maximum latency of 24 hours for forced transactions.

**Scientist:**
- Research sequencer designs: zkSync, Polygon CDK, Arbitrum, Scroll.
- Study forced inclusion mechanisms and their L1 gas costs.
- Analyze MEV considerations in enterprise context (likely minimal).
- Benchmark: block production latency, tx ordering fairness, mempool management.

**Logicist:**
- Formalize: Sequencer as block producer with mempool and forced inclusion queue.
- Invariants:
  - Inclusion: every valid tx is eventually included in a block.
  - ForcedInclusion: tx submitted to L1 is included in L2 within T blocks.
  - Ordering: transactions within a block respect a deterministic ordering rule.
- Model check with 5 txs, 2 forced txs, 3 blocks.

**Architect:**
- Implement in Go: sequencer module, mempool, block builder, forced inclusion queue (reads from L1).
- Target: `zkl2/node/sequencer/`

**Prover:**
- Prove Inclusion and ForcedInclusion properties.

**Output:** Go sequencer module with forced inclusion support.

---

#### RU-L4: State Database (L2)

**Criticality:** HIGH -- L2 state persistence and root computation.

**Hypothesis:**
A state database based on Sparse Merkle Tree with Poseidon hash (reusing findings from
Validium RU-V1) implemented in Go can support 10,000+ accounts with state root computation
< 50ms, compatible with witness generation for the ZK prover.

**Scientist:**
- Reuse research from Validium RU-V1 (SMT with Poseidon).
- Research Go implementations: gnark SMT, iden3-go, Hermez state DB.
- Analyze MPT vs SMT tradeoffs for EVM state (account model).
- Benchmark Go implementation vs TypeScript (RU-V1): insert, prove, verify latency.

**Logicist:**
- Reuse and extend formalization from RU-V1, adapted to EVM account model
  (accounts, storage slots, contract code).
- Add invariants for EVM-specific operations (account creation, self-destruct, storage layout).

**Architect:**
- Implement in Go: SMT with Poseidon, compatible with EVM state model.
- Account trie + storage trie per contract.
- Target: `zkl2/node/statedb/`

**Prover:**
- Extend RU-V1 proofs for the Go model and EVM account structure.

**Output:** Go state database module with Poseidon SMT, EVM-compatible.

**Depends on:** Validium RU-V1 (reuses research and design).

---

### Phase 2: ZK Proving

#### RU-L3: Witness Generation from EVM Execution

**Criticality:** MAXIMUM -- bridge between execution and proving.

**Hypothesis:**
A witness generator in Rust can extract from an EVM execution trace the private inputs
necessary for a ZK validity circuit, processing traces of 1000 transactions in < 30 seconds
with deterministic output (same trace -> same witness).

**Scientist:**
- Research how Polygon Hermez, Scroll, and zkSync generate witnesses from EVM traces.
- Study algebraic intermediate representations (AIR) and their role in witness generation.
- Analyze which EVM operations produce the most witness data (storage, memory, stack).
- Benchmark: witness generation time vs trace size, memory usage during generation.

**Logicist:**
- Formalize: WitnessExtract(trace) -> witness as function.
- Invariants:
  - Completeness: witness contains all information necessary for proof generation.
  - Soundness: invalid witness produces invalid proof (not false positive).
  - Determinism: same trace always produces same witness.

**Architect:**
- Implement in Rust: witness generator that consumes execution traces from RU-L1.
- Modular design: one witness module per EVM operation category (arithmetic, memory, storage, control).
- Target: `zkl2/prover/witness/`

**Prover:**
- Prove Completeness and Soundness properties.

**Output:** Rust witness generator module.

**Depends on:** RU-L1 (needs trace format from EVM executor).

---

#### RU-L5: BasisRollup.sol (L1 Settlement Contract)

**Criticality:** MAXIMUM -- L1 verification and state commitment for L2.

**Hypothesis:**
A rollup contract on Solidity can verify validity proofs of L2 batches, maintain state root
chain per enterprise, and process batch submissions at < 500K gas, extending the patterns
from Validium RU-V3 to the full zkEVM model with block-level (not just batch-level) tracking.

**Scientist:**
- Research rollup contracts: zkSync Era, Polygon zkEVM, Scroll.
- Study gas optimization: calldata compression, batch commitment schemes.
- Analyze: commit-prove-execute pattern vs direct verification.
- Benchmark gas costs for different batch sizes and proof systems.

**Logicist:**
- Extend formalization from Validium RU-V3 for L2 block model.
- Add invariants for block-level state tracking, finality, and reorg protection.

**Architect:**
- Implement: `BasisRollup.sol` with batch commitment, proof verification, state root chain.
- Integration with enhanced verifier contract.
- Hardhat tests + adversarial testing.
- Target: `zkl2/contracts/`

**Prover:**
- Prove state commitment integrity for L2 block model.

**Output:** `BasisRollup.sol` deployed, tests > 85% coverage.

**Depends on:** Validium RU-V3 (reuses L1 state commitment patterns).

---

#### RU-L6: End-to-End L2-to-L1 Proving Pipeline

**Criticality:** MAXIMUM -- integration of all Phase 1 and Phase 2 components.

**Hypothesis:**
An end-to-end pipeline (L2 transaction -> EVM execution -> trace -> witness -> proof -> L1
verification) can process a batch of 100 L2 transactions with total latency < 5 minutes,
with zero manual intervention and automatic retry on failure.

**Scientist:**
- Research pipeline architectures: Polygon CDK pipeline, Scroll proving pipeline.
- Study: parallelism opportunities (multiple batches proving concurrently).
- Benchmark: end-to-end latency breakdown (execution, witness gen, proving, submission).
- Identify bottlenecks and optimization opportunities.

**Logicist:**
- Formalize complete pipeline state machine: stages (Execute, Witness, Prove, Submit, Finalize).
- Invariants:
  - PipelineIntegrity: every committed batch has valid proof on L1.
  - Liveness: pending batches are eventually proved and submitted.
  - Atomicity: partial pipeline failure does not corrupt state.

**Architect:**
- Implement: pipeline orchestrator in Go, connecting executor (RU-L1), sequencer (RU-L2),
  state DB (RU-L4), witness gen (RU-L3), and L1 submitter (RU-L5).
- Retry logic, monitoring, metrics.
- E2E tests with real Solidity contracts on L2.
- Target: `zkl2/node/pipeline/`

**Prover:**
- Prove PipelineIntegrity and Atomicity properties.

**Output:** Working E2E pipeline -- the core of the L2 node.

**Depends on:** RU-L1, RU-L2, RU-L3, RU-L4, RU-L5.

---

### Phase 3: Bridge and Data Availability

#### RU-L7: BasisBridge.sol (L1 <-> L2 Asset Transfer)

**Criticality:** HIGH -- enables value transfer between layers.

**Hypothesis:**
A bridge contract can process deposits (L1 -> L2) in < 5 minutes and withdrawals (L2 -> L1)
in < 30 minutes, with an escape hatch that allows withdrawal via Merkle proof directly on L1
if the sequencer is offline for > 24 hours.

**Scientist:**
- Research bridge designs: zkSync Era bridge, Polygon zkEVM bridge, Scroll bridge.
- Study escape hatch mechanisms and their security assumptions.
- Analyze double-spend prevention strategies.
- Benchmark: deposit/withdrawal latency, gas costs.

**Logicist:**
- Formalize: Deposit(L1->L2), Withdrawal(L2->L1), ForcedWithdrawal(escape hatch).
- Invariants:
  - NoDoubleSpend: asset cannot be withdrawn twice.
  - EscapeHatchLiveness: if sequencer offline > T, user can withdraw via L1.
  - BalanceConservation: total L1 locked == total L2 minted.

**Architect:**
- Implement: `BasisBridge.sol` (L1 side), bridge module in L2 node (L2 side), Go relayer.
- Tests: deposit flow, withdrawal flow, escape hatch, double-spend attempt.
- Target: `zkl2/contracts/` and `zkl2/bridge/`

**Prover:**
- Prove NoDoubleSpend, EscapeHatchLiveness, and BalanceConservation.

**Output:** Bridge contract + relayer, fully tested.

**Depends on:** RU-L5 (bridge integrates with rollup contract), RU-L6 (bridge uses pipeline for proof).

---

#### RU-L8: Enterprise Data Availability Committee (Production)

**Criticality:** HIGH -- production-grade data availability for enterprise privacy.

**Hypothesis:**
A production DAC extending the Validium RU-V6 design with erasure coding can achieve 99.9%
data availability with 5-of-7 honest minority assumption, < 1 second attestation latency,
and verifiable data recovery from any 5 nodes.

**Scientist:**
- Reuse research from Validium RU-V6.
- Research: erasure coding (Reed-Solomon), KZG commitments for DA.
- Study: EigenDA, Celestia DA, Polygon Avail production deployments.
- Benchmark: attestation latency, storage overhead, recovery time at scale.

**Logicist:**
- Extend RU-V6 formalization for larger committee (7 nodes) with erasure coding.
- Add invariants for data reconstruction from k-of-n shares.

**Architect:**
- Implement: production DACNode, erasure coding module, `BasisDAC.sol` on-chain attestation.
- Target: `zkl2/node/da/` and `zkl2/contracts/`

**Prover:**
- Prove DataRecoverability and AttestationLiveness properties.

**Output:** Production DAC with erasure coding.

**Depends on:** Validium RU-V6 (reuses design), RU-L6 (integrates with pipeline).

---

### Phase 4: Production Hardening

#### RU-L9: PLONK Migration

**Criticality:** HIGH -- eliminates per-circuit trusted setup.

**Hypothesis:**
Migrating from Groth16 to PLONK (via halo2 or plonky2 in Rust) eliminates the need for
per-circuit trusted setup, allows custom gates for EVM operations, and maintains on-chain
verification < 500K gas with proof size < 1KB.

**Scientist:**
- Research: halo2 (Zcash/Scroll), plonky2 (Polygon), PLONK arithmetization.
- Study custom gates for EVM opcodes (addition, multiplication, memory access).
- Benchmark: Groth16 vs PLONK proving time, proof size, verification gas, setup complexity.
- Evaluate maturity and production readiness of each library.

**Logicist:**
- Formalize proof system properties as axioms.
- Verify that changing proof system does not break system invariants.
- Model check: system with PLONK verifier instead of Groth16.

**Architect:**
- Implement in Rust: PLONK prover circuit with custom gates.
- Updated verifier contract on L1.
- Migration path from Groth16 to PLONK (dual verification period).
- Target: `zkl2/prover/circuit/` and `zkl2/contracts/`

**Prover:**
- Prove that migration preserves Soundness property.

**Output:** PLONK-based prover, updated L1 verifier.

**Depends on:** RU-L6 (needs working pipeline to migrate).

---

#### RU-L10: Proof Aggregation and Recursive Composition

**Criticality:** MEDIUM -- efficiency optimization for multi-enterprise deployment.

**Hypothesis:**
Recursive proof composition can aggregate proofs from N enterprise batches into a single
proof verifiable on L1, reducing per-enterprise verification gas by N-fold while maintaining
soundness guarantees.

**Scientist:**
- Research: recursive SNARKs, SnarkPack, Nova folding schemes.
- Study: aggregation strategies (tree, sequential, parallel).
- Benchmark: aggregation overhead, gas savings vs number of proofs aggregated.

**Logicist:**
- Formalize: AggregateProof(proof1, ..., proofN) -> aggregatedProof.
- Invariants:
  - AggregationSoundness: aggregated proof valid iff all component proofs valid.
  - IndependencePreservation: failure of one enterprise proof does not invalidate others.

**Architect:**
- Implement: aggregation pipeline in Rust, updated L1 verifier for aggregated proofs.
- Target: `zkl2/prover/aggregator/`

**Prover:**
- Prove AggregationSoundness property.

**Output:** Proof aggregation pipeline.

**Depends on:** RU-L9 (PLONK is more suitable for recursive composition than Groth16).

---

### Phase 5: Enterprise Features

#### RU-L11: Cross-Enterprise Hub-and-Spoke

**Criticality:** MEDIUM -- multi-enterprise interaction.

**Hypothesis:**
A hub-and-spoke model using the L1 as hub can verify cross-enterprise interactions with
recursive proofs, maintaining complete data isolation between enterprises while enabling
verifiable inter-enterprise transactions (e.g., supply chain across companies).

**Scientist:**
- Extend research from Validium RU-V7 with recursive proof capabilities.
- Research: Rayls cross-privacy model, Project EPIC (BIS).
- Study: inter-chain messaging, asset transfer between enterprise L2s.

**Logicist:**
- Formalize: CrossEnterpriseTransaction(enterpriseA, enterpriseB, proof).
- Invariants:
  - Isolation: enterprise A data is never visible to enterprise B.
  - CrossConsistency: cross-enterprise state is consistent on L1.
  - AtomicSettlement: cross-enterprise tx either completes fully or reverts fully.

**Architect:**
- Implement: cross-enterprise protocol in Go (L2 side) and Solidity (L1 side).
- Hub contract on L1 for routing and verification.
- Target: `zkl2/node/cross-enterprise/` and `zkl2/contracts/`

**Prover:**
- Prove Isolation and AtomicSettlement properties.

**Output:** Cross-enterprise verification protocol.

**Depends on:** RU-L10 (uses recursive proofs), RU-L7 (uses bridge patterns).

---

## Dependency Graph

```
Phase 1: Foundation
  RU-L1 (EVM Executor) ---+
  RU-L2 (Sequencer) ------+---> Phase 2
  RU-L4 (State DB) -------+

Phase 2: ZK Proving
  RU-L3 (Witness Gen) ----+
  RU-L5 (BasisRollup) ----+---> RU-L6 (E2E Pipeline)

Phase 3: Bridge & DA
  RU-L7 (Bridge) ------------- depends on RU-L5, RU-L6
  RU-L8 (Prod DAC) ----------- depends on RU-L6, Validium RU-V6

Phase 4: Production Hardening
  RU-L9 (PLONK) -------------- depends on RU-L6
  RU-L10 (Aggregation) ------- depends on RU-L9

Phase 5: Enterprise Features
  RU-L11 (Hub-and-Spoke) ----- depends on RU-L10, RU-L7
```

## Execution Timeline (Pipelined)

```
Month   Scientist          Logicist           Architect          Prover
-----   ---------          --------           ---------          ------
 1      RU-L1 (EVM)        --                 --                 --
 1-2    RU-L2 (Seq)        RU-L1              --                 --
 2      RU-L4 (StateDB)    RU-L2              RU-L1              --
 2-3    RU-L3 (Witness)    RU-L4              RU-L2              RU-L1
 3      RU-L5 (Rollup)     RU-L3              RU-L4              RU-L2
 3-4    RU-L6 (E2E)        RU-L5              RU-L3              RU-L4
 4      RU-L7 (Bridge)     RU-L6              RU-L5              RU-L3
 4-5    RU-L8 (DAC)        RU-L7              RU-L6              RU-L5
 5      RU-L9 (PLONK)      RU-L8              RU-L7              RU-L6
 5-6    RU-L10 (Aggreg)    RU-L9              RU-L8              RU-L7
 6      RU-L11 (Hub)       RU-L10             RU-L9              RU-L8
 6+     --                 RU-L11             RU-L10             RU-L9
 7      --                 --                 RU-L11             RU-L10
 7+     --                 --                 --                 RU-L11
```

Estimated total: 6-7 months for zkEVM L2 100% complete with formal proofs.

## Reuse from Validium MVP

| Validium Component | zkL2 Component | Reuse Type |
|--------------------|----------------|-----------|
| RU-V1: SMT TypeScript | RU-L4: SMT Go | Knowledge + algorithms, reimplemented in Go |
| RU-V2: Circom circuit | RU-L3/L9: Rust prover | Constraint design informs circuit architecture |
| RU-V3: StateCommitment.sol | RU-L5: BasisRollup.sol | Direct extension of the contract |
| RU-V4: Batch aggregation | RU-L2: Sequencer | Queue and ordering patterns |
| RU-V5: Node orchestrator | RU-L6: E2E pipeline | Lifecycle management patterns |
| RU-V6: DAC basic | RU-L8: DAC production | Extension with erasure coding |
| RU-V7: Cross-enterprise | RU-L11: Hub-and-spoke | Extension with recursive proofs |

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Geth fork too complex | Phase 1 delayed | Start with minimal EVM (essential opcodes only), expand incrementally. |
| Rust ZK libraries immature | Phase 2 delayed | Groth16 in Rust as fallback. PLONK only if halo2/plonky2 are mature enough. |
| Witness generation too slow | Pipeline bottleneck | Parallelize witness gen across trace segments. |
| PLONK verification gas too high | L1 costs increase | Stay on Groth16 if PLONK gas exceeds 2x Groth16. |
| Bridge security vulnerability | Asset loss risk | Extensive formal verification (Prover), time-locked withdrawals, audit. |
| Cross-enterprise model too ambitious | Phase 5 delayed | Ship L2 without cross-enterprise; add it as a post-launch upgrade. |
