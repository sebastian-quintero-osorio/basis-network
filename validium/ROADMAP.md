# Validium MVP -- Research and Development Roadmap

## Overview

The Enterprise ZK Validium Node is the MVP target for Basis Network. It is an application-specific
execution environment that allows each enterprise to process transactions privately, generate
zero-knowledge proofs of correctness, and submit those proofs to the Basis Network L1 (Avalanche
Subnet-EVM) for on-chain verification.

This roadmap defines 7 Research Units (RUs) that flow through the 4-agent R&D pipeline
(Scientist, Logicist, Architect, Prover) to build every missing component.

## Current State

| Component | Status | Location |
|-----------|--------|----------|
| L1 Contracts (5) | Deployed on Fuji, 72 tests passing | `l1/contracts/` |
| batch_verifier.circom | Working (742 constraints, batch 4) | `validium/circuits/` |
| Groth16 trusted setup | Complete (Powers of Tau + keys) | `validium/circuits/build/` |
| Groth16Verifier.sol | Generated, ready for deployment | `validium/circuits/build/` |
| PLASMA Adapter | Complete (4 methods) | `validium/adapters/src/plasma-adapter/` |
| Trace Adapter | Complete (4 methods) | `validium/adapters/src/trace-adapter/` |
| TransactionQueue | Complete (retry + backoff) | `validium/adapters/src/common/queue.ts` |
| Dashboard | Live (4 pages, 10s polling) | `l1/dashboard/` |
| Enterprise Node Service | Placeholder only (README) | `validium/node/` |

## Target State (MVP Complete)

The MVP is complete when:

1. An enterprise can submit transactions to the node, which generates ZK proofs and verifies them on the L1.
2. State roots form a verifiable chain on the L1 -- no gaps, no reversals.
3. No private data is exposed at any point in the process.
4. The system handles at least 64-transaction batches with proof generation under 60 seconds.
5. Adversarial tests confirm that invalid proofs are rejected and replayed batches are detected.

## Research Units

### RU-V1: Sparse Merkle Tree with Poseidon Hash

**Criticality:** MAXIMUM -- foundational data structure for all state management.

**Hypothesis:**
A Sparse Merkle Tree of depth 32 with Poseidon hash can support 100,000+ entries with insert
latency < 10ms, Merkle proof generation < 5ms, and verification < 2ms in TypeScript, maintaining
BN128 field compatibility for in-circuit verification with Circom.

**Scientist:**
- Research existing SMT implementations (Iden3 SMT, Polygon Hermez, Semaphore).
- Benchmark: optimal depth, memory usage, insert/update/prove/verify latency.
- Compare hash functions: Poseidon vs MiMC vs Rescue (constraint cost, security, performance).
- Measure in-circuit constraint cost of Poseidon Merkle proof verification.
- Experiment with tree compaction and caching strategies.
- Produce working TypeScript code with circomlibjs.

**Logicist:**
- Formalize in TLA+: Insert, Update, Delete, GetProof, VerifyProof operations.
- Invariants:
  - ConsistencyInvariant: root always reflects actual tree content.
  - SoundnessInvariant: invalid proof is never accepted.
  - CompletenessInvariant: existing entry always has a valid proof.
- Model check with tree depth 4 and 8 entries (finite but sufficient to expose bugs).

**Architect:**
- Implement TypeScript class `SparseMerkleTree` using circomlibjs Poseidon.
- Serialization/deserialization for persistence.
- Standalone Merkle proof generation and verification.
- Unit tests + adversarial tests (forged proofs, duplicate entries, empty tree, overflow).
- Target: `validium/node/src/state/`

**Prover:**
- Spec.v: faithful translation of TLA+ specification.
- Impl.v: abstract model of TypeScript implementation.
- Refinement.v: prove that insert/update/prove preserve ConsistencyInvariant.

**Output:** Production-grade `SparseMerkleTree` module in TypeScript, ZK-compatible.

---

### RU-V2: State Transition Circuit

**Criticality:** MAXIMUM -- the heart of the ZK proving system.

**Hypothesis:**
A Circom circuit that proves state transitions (prevStateRoot -> newStateRoot) for batches of 64
transactions can be generated in < 60 seconds with < 100,000 constraints using Groth16, verifying
both individual Merkle proof integrity and state root chain consistency.

**Scientist:**
- Start from existing `batch_verifier.circom` (742 constraints, batch 4).
- Research: constraint cost of in-circuit Merkle proof verification (Poseidon path, depth 32).
- Benchmark proof generation time vs batch size (4, 16, 32, 64, 128).
- Analyze tradeoff: constraint count vs proving time.
- Investigate Circom optimization: signal reuse, template parameterization, lookup patterns.
- Compare with circuits from Semaphore, Tornado Cash, Hermez.

**Logicist:**
- Formalize: StateTransition(prevRoot, newRoot, txBatch) as TLA+ action.
- Invariants:
  - StateRootChain: newRoot = f(prevRoot, txBatch).
  - BatchIntegrity: each tx in batch has valid Merkle proof against intermediate state.
  - ProofSoundness: invalid proof always rejected.
- Model check with 3 enterprises, batch size 4, 3 state roots of depth 3.

**Architect:**
- Implement Circom circuit: `state_transition.circom` with templates for Merkle proof verification,
  state root computation, and batch validation.
- Updated scripts: setup, prove, verify for the new circuit.
- Export new Groth16Verifier.sol.
- Tests: edge cases (empty batch, duplicate tx, incorrect root, max batch size).
- Target: `validium/circuits/circuits/`

**Prover:**
- Spec.v: constraint system model as equations over finite field.
- Impl.v: circuit model.
- Refinement.v: prove each constraint is necessary and sufficient for safety properties.

**Output:** `state_transition.circom` (batch 64), updated scripts, new Groth16Verifier.sol.

**Depends on:** RU-V1 (Merkle tree structure determines the circuit design).

---

### RU-V3: L1 State Commitment Protocol

**Criticality:** MAXIMUM -- the on-chain trust anchor.

**Hypothesis:**
A StateCommitment.sol contract that maintains per-enterprise state root chains with integrated ZK
proof verification can process batch submissions at < 300K gas, detect gaps and reversals in the
root chain, and maintain complete batch history with < 500 bytes of storage per batch.

**Scientist:**
- Research state commitment patterns: zkSync Era (commit-prove-execute), Polygon zkEVM
  (sequenceBatches + verifyBatches), Scroll (commitBatch + finalizeBatch).
- Measure gas costs of different storage layouts on Subnet-EVM.
- Analyze tradeoff: on-chain history depth vs gas cost.
- Benchmark against existing ZKVerifier.sol as baseline.

**Logicist:**
- Formalize: SubmitBatch(enterprise, prevRoot, newRoot, proof) as TLA+ action.
- Invariants:
  - ChainContinuity: newBatch.prevRoot == currentRoot[enterprise].
  - NoGap: batch IDs are consecutive per enterprise.
  - NoReversal: state root never reverts to a previous value without explicit rollback.
  - ProofBeforeState: state only changes if proof is valid.
- Model check with 2 enterprises, 5 batches. Simulate gap attack and replay attack.

**Architect:**
- Implement `StateCommitment.sol`: mapping enterprise -> EnterpriseState
  (currentRoot, previousRoot, batchCount, lastBatchTimestamp, isActive).
- Integration with existing ZKVerifier.sol (or enhanced version).
- Integration with EnterpriseRegistry.sol for permissions.
- Hardhat unit tests + adversarial (gap attack, replay, wrong enterprise, invalid proof).
- Target: `l1/contracts/contracts/core/`

**Prover:**
- Spec.v: on-chain state as mapping.
- Impl.v: Solidity contract model.
- Refinement.v: prove ChainContinuity and ProofBeforeState hold under all transitions.

**Output:** `StateCommitment.sol` deployed, tests > 85% coverage, updated deploy script.

**Depends on:** RU-V2 (needs proof format and public signals from the new circuit).

---

### RU-V4: Transaction Queue and Batch Aggregation Engine

**Criticality:** HIGH -- determines throughput and reliability.

**Hypothesis:**
A transaction queue with chronological ordering and configurable batch aggregation can sustain
100+ tx/min throughput with batch formation latency < 5s, guaranteeing zero transaction loss
under crash recovery, and producing deterministic batches (same transactions -> same batch).

**Scientist:**
- Research queue patterns: persistent queues, write-ahead logs, crash recovery strategies.
- Study batch formation strategies: time-based, size-based, hybrid.
- Analyze ordering guarantees: causal, total, FIFO.
- Benchmark: throughput under load, behavior under simulated crash.
- Build experimental code extending the existing `TransactionQueue` from adapters.

**Logicist:**
- Formalize: Enqueue(tx), FormBatch(), ProcessBatch() as TLA+ actions.
- Invariants:
  - NoLoss: every enqueued tx eventually appears in a batch.
  - Determinism: same set of txs produces same batch.
  - Ordering: txs within a batch respect arrival order.
  - Completeness: batch formation triggers when threshold is reached.
- Model check with 10 txs, batch size 4. Simulate crash after enqueue but before batch formation.

**Architect:**
- Implement: `TransactionQueue` (persistent, crash-safe), `BatchAggregator` (configurable
  thresholds: size, time, hybrid), `BatchBuilder` (constructs ZK circuit input from batch).
- Integrate with SMT from RU-V1 (each tx updates the tree).
- Tests: concurrent enqueue, crash recovery, boundary conditions (0, 1, max, max+1).
- Target: `validium/node/src/queue/` and `validium/node/src/batch/`

**Prover:**
- Spec.v: queue as sequence, batch as subsequence.
- Impl.v: implementation model.
- Refinement.v: prove NoLoss and Determinism are maintained.

**Output:** Production-grade `TransactionQueue` and `BatchAggregator` modules in TypeScript.

**Depends on:** RU-V1 (batch formation requires updating the SMT per transaction).

---

### RU-V5: Enterprise Node Orchestrator

**Criticality:** MAXIMUM -- integrates all components into a running service.

**Hypothesis:**
A Node.js event-driven service that orchestrates the complete cycle (receive -> state update ->
batch -> prove -> submit) can process end-to-end a batch of 64 transactions in < 90 seconds
(60s proving + 30s overhead), with zero data leakage, crash recovery without state loss, and
REST/WebSocket API for PLASMA/Trace integration.

**Scientist:**
- Research blockchain node patterns: event loops, state machine design, graceful shutdown.
- Study: Polygon Hermez node proving orchestration, zkSync Era sequencer lifecycle.
- Define API contract for PLASMA/Trace integration.
- Benchmark end-to-end: total latency, memory footprint, CPU utilization during proving.

**Logicist:**
- Formalize the COMPLETE node state machine: states (Idle, Receiving, Batching, Proving,
  Submitting, Error), transitions, and recovery paths.
- Invariants:
  - Liveness: if pending txs exist, a batch is eventually proved.
  - Safety: proof is never submitted without correct state root.
  - Privacy: no private data leaves the node except proof + public signals.
- Model check: happy path, crash during proving, L1 tx failure, concurrent submissions.

**Architect:**
- Implement complete service: entry point (`validium/node/src/index.ts`), integrated modules
  (SMT, Queue, BatchAggregator, Prover wrapper, L1 Submitter).
- REST API for receiving events from PLASMA/Trace.
- Configuration management (.env).
- Health checks and monitoring endpoints.
- Graceful shutdown and crash recovery.
- Structured logging.
- E2E tests: full cycle from PLASMA event to L1 verification.
- Target: `validium/node/`

**Prover:**
- Spec.v: node state machine.
- Impl.v: orchestrator model.
- Refinement.v: prove Safety and Liveness under all transitions including crash recovery.

**Output:** Complete `validium/node/` -- the functional MVP.

**Depends on:** RU-V1, RU-V2, RU-V3, RU-V4 (integrates all prior components).

---

### RU-V6: Data Availability Committee (DAC)

**Criticality:** HIGH -- enterprise-grade privacy guarantee.

**Hypothesis:**
A Data Availability Committee of 3 nodes (2-of-3 honest minority) can attest batch data
availability in < 2 seconds, with enterprise-managed storage, without exposing data to any
individual node, and with recovery mechanism if one node fails.

**Scientist:**
- Research: Polygon Avail DAC, EigenDA, Celestia (compare models).
- Study: secret sharing (Shamir), erasure coding, attestation protocols.
- Analyze: honest minority vs honest majority assumptions for enterprise context.
- Benchmark: attestation latency, storage overhead, recovery time.

**Logicist:**
- Formalize: DAC as set of nodes with attestation protocol.
- Invariants:
  - DataAvailability: if 2/3 nodes attest, data is recoverable.
  - Privacy: no individual node can reconstruct complete data.
  - Liveness: attestation completes if >= 2 nodes are online.
- Model check with 3 nodes. Simulate 1 node down, 1 node malicious.

**Architect:**
- Implement: DACNode (stores shares), DACProtocol (attestation and recovery),
  integration with Enterprise Node (node sends data shares to DAC after proving).
- Smart contract `DACAttestation.sol` for on-chain attestation records.
- Tests: node failure, malicious node, recovery.
- Target: `validium/node/src/da/`

**Prover:**
- Spec.v/Impl.v/Refinement.v for the DAC protocol.

**Output:** DAC module integrated with Enterprise Node, attestation contract.

**Depends on:** RU-V1 (data structure to distribute). Can execute in parallel with RU-V2/V3/V4.

---

### RU-V7: Cross-Enterprise Verification (Hub-and-Spoke)

**Criticality:** MEDIUM -- post-MVP but valuable for the vision.

**Hypothesis:**
A hub-and-spoke model where the L1 aggregates proofs from multiple enterprises can verify
cross-enterprise interactions (e.g., enterprise A sells to enterprise B) without revealing
data from either, using proof aggregation with < 2x overhead over individual verification.

**Scientist:**
- Research: recursive SNARKs (SnarkPack), proof aggregation techniques, Rayls cross-privacy.
- Analyze feasibility with Groth16 (limited) vs PLONK (more flexible).
- Benchmark: aggregation cost vs individual verification.

**Logicist:**
- Formalize: CrossEnterpriseVerification as action taking proofs from 2+ enterprises.
- Invariants:
  - Isolation: proof from A reveals nothing about B.
  - Consistency: cross-reference is valid only if both proofs are valid.

**Architect:**
- Implement: proof aggregation module, `CrossEnterpriseVerifier.sol`.
- Adversarial tests: falsify cross-reference, use proof from wrong enterprise.
- Target: `validium/node/src/cross-enterprise/` and `l1/contracts/contracts/verification/`

**Prover:**
- Proof of Isolation and Consistency properties.

**Output:** Cross-enterprise verification module.

**Depends on:** RU-V5 (functional node), RU-V6 (DA layer).

---

## Dependency Graph

```
RU-V1 (Sparse Merkle Tree)
  |
  +---> RU-V2 (State Transition Circuit) ---> RU-V3 (L1 State Commitment) ---+
  |                                                                           |
  +---> RU-V4 (Batch Aggregation) ----------------------------------------+  |
  |                                                                        |  |
  +---> RU-V6 (Data Availability) ------+                                  v  v
                                        +---> RU-V7 -----------> RU-V5 (Enterprise Node)
                                              (Cross-Ent.)        (Orchestrator)
```

Critical path: RU-V1 -> RU-V2 -> RU-V3 -> RU-V5
Parallel track A: RU-V4 (after RU-V1, parallel with RU-V2 and RU-V3)
Parallel track B: RU-V6 (after RU-V1, parallel with everything)
Final: RU-V7 (after RU-V5 and RU-V6)

## Execution Timeline (Pipelined)

```
Week    Scientist          Logicist           Architect          Prover
----    ---------          --------           ---------          ------
 1      RU-V1              --                 --                 --
 2      RU-V2              RU-V1              --                 --
 3      RU-V4              RU-V2              RU-V1              --
 4      RU-V6              RU-V4              RU-V2              RU-V1
 5      RU-V3              RU-V6              RU-V4              RU-V2
 6      RU-V5              RU-V3              RU-V6              RU-V4
 7      RU-V7              RU-V5              RU-V3              RU-V6
 8      --                 RU-V7              RU-V5              RU-V3
 9      --                 --                 RU-V7              RU-V5
10      --                 --                 --                 RU-V7
```

Estimated total: 8-10 weeks for Validium MVP 100% complete with formal proofs.

## Reuse From Existing Codebase

| Existing Artifact | Used By | How |
|-------------------|---------|-----|
| `batch_verifier.circom` | RU-V2 | Starting point and benchmark baseline |
| `TransactionQueue` (adapters) | RU-V4 | Design reference, extended with persistence |
| `ZKVerifier.sol` | RU-V3 | Integration target or replacement basis |
| `PLASMAAdapter` / `TraceAdapter` | RU-V5 | API contract reference for node REST API |
| `demo.ts` | RU-V5 | E2E test scenario template |
| Groth16 trusted setup artifacts | RU-V2 | Reuse Powers of Tau, regenerate circuit keys |

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Batch-64 circuit exceeds 60s proving time | MVP performance target missed | Scientist benchmarks incrementally (16, 32, 64). If 64 is not viable, MVP operates at batch 32. |
| Poseidon in-circuit cost too high at depth 32 | Circuit constraints explode | Investigate shallower tree (depth 20) or hash function alternatives (MiMC). |
| Crash recovery adds too much complexity | Node service becomes fragile | Start with checkpoint-based recovery (simpler), defer WAL to post-MVP. |
| Coq proofs take longer than implementation | Pipeline bottleneck at Prover | Prioritize Safety proofs (state integrity) over Liveness proofs. |
| TLA+ model checking state explosion | Logicist blocked | Reduce model size (fewer enterprises, smaller batches) while preserving property coverage. |
