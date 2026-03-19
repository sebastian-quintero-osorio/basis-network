# Adversarial Report: State Commitment Protocol (RU-V3)

Date: 2026-03-18
Target: validium (MVP)
Contract: `l1/contracts/contracts/core/StateCommitment.sol`
Spec: `validium/specs/units/2026-03-state-commitment/1-formalization/v0-analysis/specs/StateCommitment/StateCommitment.tla`
Test file: `l1/contracts/test/StateCommitment.test.ts`

---

## 1. Summary

Adversarial testing of the StateCommitment L1 contract against the formally verified TLA+ specification. The contract implements per-enterprise state root chains with integrated Groth16 ZK proof verification. All 10 adversarial scenarios were tested. Zero security violations found.

---

## 2. Attack Catalog

| # | Attack Vector | TLA+ Invariant Targeted | Result | Severity |
|---|---------------|------------------------|--------|----------|
| 1 | Gap attack (skip batch ID) | NoGap | BLOCKED | N/A |
| 2 | Replay attack (stale prevRoot) | ChainContinuity (INV-S1) | BLOCKED | N/A |
| 3 | Cross-enterprise state corruption | Enterprise isolation | BLOCKED | N/A |
| 4 | Deactivated enterprise submission | Authorization | BLOCKED | N/A |
| 5 | Double initialization (overwrite genesis) | InitializeEnterprise guard | BLOCKED | N/A |
| 6 | Invalid proof acceptance | ProofBeforeState (INV-S2) | BLOCKED | N/A |
| 7 | State mutation on failed proof | ProofBeforeState (INV-S2) | BLOCKED | N/A |
| 8 | Global counter desync | GlobalCountIntegrity | BLOCKED | N/A |
| 9 | Root reversal to zero | NoReversal | BLOCKED | N/A |
| 10 | Cross-enterprise chain spoofing | ChainContinuity + isolation | BLOCKED | N/A |

---

## 3. Findings

### CRITICAL: None

### MODERATE: None

### LOW: None

### INFO

**INFO-1: No-op transitions permitted**

Description: The contract allows `newStateRoot == prevStateRoot` (submitting a batch that does not change the state root). This is consistent with the TLA+ specification which permits it. The behavior is harmless: batchCount still increments, totalBatchesCommitted increments, and the event log records the submission. The ZK circuit should prevent no-op proofs from being generated in practice.

Disposition: By design. The TLA+ model explicitly permits this and TLC verified it is harmless.

**INFO-2: Genesis root is not uniqueness-enforced**

Description: Two enterprises can be initialized with the same genesis root. This is correct behavior (enterprises may use the same SMT initialization) but could confuse external auditing tools that assume unique genesis roots.

Disposition: Informational. The formalization notes acknowledge this. No code change required.

**INFO-3: Verifying key can be overwritten**

Description: The admin can call `setVerifyingKey` multiple times, overwriting the previous key. This is intentional (key rotation for circuit upgrades) but could invalidate in-progress proofs if called between proof generation and submission.

Disposition: Operational concern. Key rotation should be coordinated with enterprise node operators. No code change required for MVP.

---

## 4. Pipeline Feedback

| Finding | Route | Target Phase |
|---------|-------|--------------|
| INFO-1 (no-op transitions) | Informational | Document only |
| INFO-2 (genesis uniqueness) | Informational | Document only |
| INFO-3 (key rotation) | Spec refinement | Phase 2 (Logicist) for v2 |

No findings require immediate action. All security-critical invariants from the TLA+ specification are correctly enforced.

---

## 5. Test Inventory

| Test | Category | Result |
|------|----------|--------|
| Batch IDs are structural, not caller-supplied | Gap attack | PASS |
| Stale prevRoot rejected after chain advances | Replay attack | PASS |
| Enterprise 2 state unchanged by Enterprise 1 submission | Cross-enterprise | PASS |
| Deactivated enterprise cannot submit | Authorization | PASS |
| Double initialization reverts | Double init | PASS |
| GlobalCountIntegrity across multiple enterprises | Counter integrity | PASS |
| currentRoot never reverts to zero | NoReversal | PASS |
| Cross-enterprise chain spoofing rejected | ChainContinuity | PASS |
| State unchanged when proof is invalid | ProofBeforeState | PASS |
| Invalid proof reverts with InvalidProof | Proof rejection | PASS |

Additional unit tests (28 total) cover deployment, admin functions, initialization, happy-path batch submission, sequential batch chains, error paths, and all view functions.

---

## 6. Verdict

**NO VIOLATIONS FOUND**

All 6 TLA+ safety invariants (TypeOK, ChainContinuity, NoGap, NoReversal, InitBeforeBatch, GlobalCountIntegrity) are correctly enforced by the Solidity implementation. The contract is structurally immune to gap attacks (batch IDs are not parameters), replay attacks (ChainContinuity check), and cross-enterprise interference (per-enterprise state isolation via msg.sender).

38 tests passing. 0 failures. 0 security violations.
