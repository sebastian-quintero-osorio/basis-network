# Adversarial Report: BasisRollup (RU-L5 Architect)

**Unit**: basis-rollup
**Target**: zkl2
**Date**: 2026-03-19
**Agent**: Prime Architect
**Spec**: zkl2/specs/units/2026-03-basis-rollup/1-formalization/v0-analysis/specs/BasisRollup/BasisRollup.tla
**Contract**: zkl2/contracts/contracts/BasisRollup.sol

---

## 1. Summary

Adversarial testing of the BasisRollup.sol contract covering the three-phase commit-prove-execute lifecycle. 23 adversarial test vectors across 5 attack categories were executed against the BasisRollupHarness (mock Groth16 verification) on Hardhat's local EVM (cancun target).

**Overall Verdict**: NO VIOLATIONS FOUND

All 88 tests pass (65 functional + 23 adversarial). Every TLA+ invariant is enforced at the Solidity level. No state corruption, authorization bypass, or lifecycle violation was achievable through the tested attack vectors.

---

## 2. Attack Catalog

| ID | Attack Vector | Target Invariant | Result |
|----|--------------|------------------|--------|
| ADV-01 | Execute uncommitted batch | INV-03 ProveBeforeExecute | BLOCKED |
| ADV-02 | Skip prove phase entirely | INV-03 ProveBeforeExecute | BLOCKED |
| ADV-03 | Submit invalid proof | INV-S2 ProofBeforeState | BLOCKED (no state mutation) |
| ADV-04 | Prove batch 1 before batch 0 | INV-06 CommitBeforeProve | BLOCKED |
| ADV-05 | Execute batch 1 before batch 0 | INV-04 ExecuteInOrder | BLOCKED |
| ADV-06 | Skip batch ID in execution | INV-04 ExecuteInOrder | BLOCKED |
| ADV-07 | Revert executed batch | INV-05 RevertSafety | BLOCKED |
| ADV-08 | Revert-recommit state corruption | INV-02 BatchChainContinuity | BLOCKED |
| ADV-09 | Revert proven batch counter misalignment | INV-07 CounterMonotonicity | BLOCKED |
| ADV-10 | Sequential reverts to corrupt counters | INV-11 GlobalCountIntegrity | BLOCKED |
| ADV-11 | Enterprise proves another's batch | Enterprise Isolation | BLOCKED |
| ADV-12 | Enterprise executes another's batch | Enterprise Isolation | BLOCKED |
| ADV-13 | Cross-enterprise revert side effects | Enterprise Isolation | BLOCKED |
| ADV-14 | Unauthorized commit | Access Control | BLOCKED |
| ADV-15 | Unauthorized prove | Access Control | BLOCKED |
| ADV-16 | Unauthorized execute | Access Control | BLOCKED |
| ADV-17 | Deauthorization mid-lifecycle | Access Control | BLOCKED |
| ADV-18 | Non-admin revert | Access Control | BLOCKED |
| ADV-19 | Non-admin initialize | Access Control | BLOCKED |
| ADV-20 | Non-admin set verifying key | Access Control | BLOCKED |
| ADV-21 | Overlapping block ranges | INV-R4 MonotonicBlockRange | BLOCKED |
| ADV-22 | Block range gap | INV-R4 MonotonicBlockRange | BLOCKED |
| ADV-23 | Single-block batch edge case | INV-R4 MonotonicBlockRange | VALID (accepted correctly) |

---

## 3. Findings

### 3.1 Severity Classification

| Severity | Count | Details |
|----------|-------|---------|
| CRITICAL | 0 | None |
| MODERATE | 0 | None |
| LOW | 0 | None |
| INFO | 2 | See below |

### 3.2 Informational Findings

**INFO-01: Admin key is a single EOA**

The `admin` address controls initialization, revert, and verifying key configuration. No multisig or timelock is implemented. For production deployment, admin operations should be behind a multisig (e.g., Gnosis Safe) or governance contract.

- **Severity**: INFO
- **Recommendation**: Implement admin transfer functionality and require multisig for production deployment.
- **Pipeline feedback**: Implementation Hardening (Phase 3)

**INFO-02: No batch expiry or forced inclusion deadline**

The `priorityOpsHash` field is stored but not enforced. A committed batch can remain unproven indefinitely. In a production rollup, this would require a forced inclusion mechanism with a deadline after which users can exit via the L1.

- **Severity**: INFO
- **Recommendation**: Future research unit to model forced inclusion liveness properties in TLA+.
- **Pipeline feedback**: New Research Thread (Phase 1)

---

## 4. Pipeline Feedback

| Finding | Route | Description |
|---------|-------|-------------|
| INFO-01 | Implementation Hardening | Add admin transfer + recommend multisig for deployment |
| INFO-02 | New Research Thread | Model forced inclusion deadlines (liveness property) |

---

## 5. Test Inventory

### 5.1 Functional Tests (65)

| Category | Count | Status |
|----------|-------|--------|
| Deployment | 3 | ALL PASS |
| InitializeEnterprise | 5 | ALL PASS |
| CommitBatch | 10 | ALL PASS |
| ProveBatch | 8 | ALL PASS |
| ExecuteBatch | 8 | ALL PASS |
| RevertBatch | 10 | ALL PASS |
| Full Lifecycle | 3 | ALL PASS |
| Enterprise Isolation | 4 | ALL PASS |
| Counter Invariants | 2 | ALL PASS |
| View Functions | 5 | ALL PASS |
| Edge Cases | 3 | ALL PASS |
| **Total** | **65** | **ALL PASS** |

### 5.2 Adversarial Tests (23)

| Category | Count | Status |
|----------|-------|--------|
| Proof Bypass | 3 | ALL PASS |
| Out-of-Order Operations | 3 | ALL PASS |
| Revert Exploits | 4 | ALL PASS |
| Cross-Enterprise Attacks | 3 | ALL PASS |
| Authorization Bypass | 7 | ALL PASS |
| Block Range Manipulation | 3 | ALL PASS |
| **Total** | **23** | **ALL PASS** |

### 5.3 TLA+ Invariant Coverage Map

| # | TLA+ Invariant | Test Coverage |
|---|---------------|---------------|
| 1 | TypeOK | Solidity type system (structural) |
| 2 | BatchChainContinuity | ExecuteBatch functional tests + ADV-08 |
| 3 | ProveBeforeExecute | ProveBatch/ExecuteBatch tests + ADV-01, ADV-02, ADV-03 |
| 4 | ExecuteInOrder | ExecuteBatch tests + ADV-05, ADV-06 |
| 5 | RevertSafety | RevertBatch tests + ADV-07 |
| 6 | CommitBeforeProve | ProveBatch tests + ADV-04 |
| 7 | CounterMonotonicity | Counter Invariants tests + ADV-09 |
| 8 | NoReversal | InitializeEnterprise tests |
| 9 | InitBeforeBatch | CommitBatch tests |
| 10 | StatusConsistency | Full Lifecycle tests + View Functions |
| 11 | GlobalCountIntegrity | Counter Invariants + ADV-10, ADV-13 |
| 12 | BatchRootIntegrity | CommitBatch + RevertBatch tests |

---

## 6. Verdict

**NO VIOLATIONS FOUND**

The BasisRollup.sol implementation faithfully enforces all 12 TLA+-verified invariants. The three-phase commit-prove-execute lifecycle is secure against the tested attack vectors. No state corruption, authorization bypass, or lifecycle violation was achievable.

Two informational findings (admin centralization, missing forced inclusion deadline) are noted for future hardening but do not represent security vulnerabilities in the current design scope.

---

## 7. Reproduction

```bash
cd zkl2/contracts
npm install
npx hardhat test
```

Expected output: 88 passing, 0 failing.
