# Adversarial Report: Enterprise Node Orchestrator

**Unit**: RU-V5 Enterprise Node
**Date**: 2026-03-18
**Target**: validium/node/src/orchestrator.ts
**Spec**: validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/specs/EnterpriseNode/EnterpriseNode.tla
**Agent**: Prime Architect (lab/3-architect)

---

## 1. Summary

Adversarial testing of the Enterprise Node Orchestrator -- the pipelined state machine that integrates all verified components (SMT, Queue, BatchAggregator, ZKProver, L1Submitter, DACProtocol) into a functional enterprise validium node.

19 tests executed across 9 test categories. All tests pass. Adversarial scenarios cover state machine violations, crash recovery, privacy boundaries, state root integrity, and boundary conditions.

**Overall Verdict**: NO VIOLATIONS FOUND

---

## 2. Attack Catalog

| ID | Attack Vector | Category | Result |
|----|---------------|----------|--------|
| ADV-ENO-01 | Submit transaction in Error state | State violation | PASS (rejected) |
| ADV-ENO-02 | Submit transaction in Batching state | State violation | PASS (rejected) |
| ADV-ENO-03 | L1 submission failure mid-batch | Crash recovery | PASS (recovered) |
| ADV-ENO-04 | WAL crash recovery after enqueue | Data durability | PASS (all txs recovered) |
| ADV-ENO-05 | State root gap between batches | Chain integrity | PASS (no gaps) |
| ADV-ENO-06 | Batch exceeding maxBatchSize | Boundary | PASS (bounded) |
| ADV-ENO-07 | Raw data in L1 submission | Privacy | PASS (not exposed) |
| ADV-ENO-08 | SMT root inconsistency after batch | State continuity | PASS (consistent) |
| ADV-ENO-09 | Pipelined tx during Proving state | Concurrent access | PASS (accepted) |
| ADV-ENO-10 | Partial batch via time trigger | Boundary | PASS (correct) |
| ADV-ENO-11 | Multiple sequential batch cycles | Integration | PASS (chained) |
| ADV-ENO-12 | Unknown batch ID query | API boundary | PASS (404) |

---

## 3. Findings

### 3.1 Severity Classification

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| MODERATE | 0 |
| LOW | 0 |
| INFO | 3 |

### 3.2 Informational Findings

**INFO-1: SMT Checkpoint Not Verified Against L1**

The SMT checkpoint is saved locally after L1 confirmation. On recovery, the checkpoint is loaded without verifying its root matches the on-chain state. In a production deployment, the node should query `getEnterpriseState()` on startup and validate the local checkpoint root matches the L1 `currentRoot`.

- **Risk**: If the local checkpoint file is corrupted or tampered with, the node could operate with an incorrect state root. The L1 contract would reject subsequent batches (INV-NO2 enforcement), so this is a liveness issue, not a safety issue.
- **Mitigation**: Add L1 state verification to the startup/recovery path. The `L1Submitter.queryEnterpriseState()` method already exists for this purpose.
- **Classification**: Informational. L1 contract provides the safety backstop.

**INFO-2: DAC Distribution is Best-Effort**

DAC share distribution and attestation collection are synchronous but non-blocking for the batch cycle. If DAC operations fail, the batch is still confirmed on L1 without a DAC certificate.

- **Risk**: If DAC consistently fails, data availability is not guaranteed off-chain. Recovery would require replaying from the WAL.
- **Mitigation**: For production, DAC attestation should be a prerequisite for L1 submission, or a monitoring alert should fire when DAC attestation fails.
- **Classification**: Informational. Acceptable for MVP; documented for production hardening.

**INFO-3: No Rate Limiting on Transaction Ingestion**

The API endpoint `POST /v1/transactions` accepts transactions without rate limiting. A malicious or misconfigured adapter could flood the queue.

- **Risk**: Memory exhaustion from unbounded queue growth. WAL disk usage would also grow unboundedly.
- **Mitigation**: Add Fastify rate limiting plugin (`@fastify/rate-limit`) and queue depth bounds. Consider backpressure signaling (HTTP 429) when queue exceeds a configurable threshold.
- **Classification**: Informational. In a permissioned enterprise context, the risk is low.

---

## 4. Pipeline Feedback

| Finding | Route | Target |
|---------|-------|--------|
| INFO-1: L1 state verification on startup | Implementation Hardening | Phase 3 (Architect) |
| INFO-2: DAC as prerequisite for submission | Spec Refinement | Phase 2 (Logicist) |
| INFO-3: Rate limiting | Implementation Hardening | Phase 3 (Architect) |

No findings require new research threads or specification corrections.

---

## 5. Test Inventory

| Test | Status |
|------|--------|
| Init: start in Idle state | PASS |
| Init: zero queue depth and batches | PASS |
| ReceiveTx: accept tx, Idle -> Receiving | PASS |
| ReceiveTx: multiple txs in Receiving | PASS |
| ReceiveTx: reject in Error state | PASS |
| ReceiveTx: reject in Batching state | PASS |
| Full cycle: complete batch (2 txs) | PASS |
| Full cycle: multiple sequential batches | PASS |
| Full cycle: partial batch on time trigger | PASS |
| INV-NO2: chain state roots without gaps | PASS |
| INV-NO3: no raw data in L1 submission | PASS |
| INV-NO4: WAL crash recovery | PASS |
| INV-NO4: recover and continue after error | PASS |
| INV-NO5: SMT root consistency through cycle | PASS |
| BatchSizeBound: never exceed maxBatchSize | PASS |
| Pipelined: accept txs during Proving | PASS |
| Status: accurate status report | PASS |
| Queries: batch record after processing | PASS |
| Queries: undefined for unknown batch ID | PASS |

**Total: 19 passed, 0 failed**

---

## 6. Invariant Coverage Matrix

| TLA+ Invariant | Test Coverage | Enforcement Mechanism |
|----------------|---------------|----------------------|
| TypeOK | Init tests | TypeScript type system (compile-time) |
| INV-NO1 EventualConfirmation | Full cycle tests | Batch loop + retry on error |
| INV-NO2 ProofStateIntegrity | ADV-ENO-05 | L1 contract check + state root chaining |
| INV-NO3 NoDataLeakage | ADV-ENO-07 | Architecture (adapter layer hashing) |
| INV-NO4 NoTransactionLoss | ADV-ENO-03, ADV-ENO-04 | WAL + deferred checkpoint |
| INV-NO4 NoDuplication | Full cycle tests | WAL checkpoint + FIFO ordering |
| INV-NO5 StateRootContinuity | ADV-ENO-08 | SMT checkpoint/restore on error |
| QueueWalConsistency | ADV-ENO-04 | TransactionQueue (verified in RU-V4) |
| BatchSizeBound | ADV-ENO-06 | BatchAggregator.config.maxBatchSize |

---

## 7. Verdict

**NO VIOLATIONS FOUND**

All 8 TLA+ safety invariants are enforced. The liveness property (EventualConfirmation) is demonstrated by successful batch cycle completion including error recovery.

Three informational findings documented for production hardening. None affect safety in the MVP context.
