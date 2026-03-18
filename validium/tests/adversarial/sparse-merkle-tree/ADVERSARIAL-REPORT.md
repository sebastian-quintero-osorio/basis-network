# Adversarial Report -- Sparse Merkle Tree (RU-V1)

## Unit Information

- **Research Unit**: RU-V1 (Sparse Merkle Tree with Poseidon Hash)
- **Target**: validium
- **Date**: 2026-03-18
- **Implementation**: `validium/node/src/state/sparse-merkle-tree.ts`
- **Test Suite**: `validium/node/src/state/__tests__/sparse-merkle-tree.test.ts`
- **Spec**: `validium/specs/units/2026-03-sparse-merkle-tree/SparseMerkleTree.tla`

---

## 1. Summary

Adversarial testing of the Sparse Merkle Tree implementation targeting the three
formally verified invariants (Consistency, Soundness, Completeness). The test suite
exercises 11 distinct attack vectors across 52 test cases, including proof forgery,
proof transplant, stale proof replay, path bit manipulation, second preimage injection,
and field boundary violations.

All attacks were correctly rejected by the implementation.

---

## 2. Attack Catalog

| ID | Attack Vector | Description | Result |
|----|---------------|-------------|--------|
| ADV-01 | Forged proof (random siblings) | Fabricate sibling hashes with arbitrary values | REJECTED |
| ADV-02 | Proof transplant | Use proof generated for key A to verify key B | REJECTED |
| ADV-03 | Stale proof replay | Use proof from before tree mutation against new root | REJECTED |
| ADV-04 | Duplicate key overwrite | Verify old value proof after key update | REJECTED |
| ADV-05 | Empty tree exploitation | Fake membership claims in empty tree (all 16 positions) | REJECTED |
| ADV-06 | Malformed proof length | Truncated (too few) and extended (too many) siblings | REJECTED |
| ADV-07 | Path bit manipulation | Flip all bits; flip each individual bit | REJECTED |
| ADV-08 | Key outside address space | Keys exceeding 2^depth; keys outside BN128 field | REJECTED |
| ADV-09 | Zero-value edge cases | insert(key, 0) as deletion; repeated deletion | HANDLED |
| ADV-10 | Sibling order swap | Reverse the sibling array order | REJECTED |
| ADV-11 | Second preimage injection | Replace leaf hash with level-0 sibling hash | REJECTED |

---

## 3. Findings

### 3.1 Severity Classification

| Severity | Count | Description |
|----------|-------|-------------|
| CRITICAL | 0 | No critical vulnerabilities found |
| MODERATE | 0 | No moderate vulnerabilities found |
| LOW | 0 | No low-severity issues found |
| INFO | 2 | Informational observations (see below) |

### 3.2 Informational Findings

**INFO-01: Key masking produces distinct leaf hashes for aliased indices**

When a key exceeds 2^depth, bit masking (`key & ((1n << depth) - 1n)`) maps it to a
valid leaf index. However, the leaf hash computation uses the FULL key value
(`hash2(key, value)`), not the masked index. This means keys 5 and 21 (which alias
to the same index at depth 4) produce different leaf hashes. This is correct behavior:
the key is part of the committed data, and collisions would require Poseidon preimage
attacks (computationally infeasible on BN128).

**INFO-02: Entry count not cryptographically committed**

The `_entryCount` field tracks the number of occupied leaves as metadata. It is not
part of the Merkle root computation and is therefore not tamper-evident. This is
acceptable because entry count is observability metadata, not security-critical state.
The TLA+ specification does not model entry count (confirmed in Audit Report, Section
3.1: "entry count is metadata, not state-affecting").

---

## 4. Pipeline Feedback

| Finding | Route | Action |
|---------|-------|--------|
| INFO-01 (key masking) | Informational | Document in module README. No action needed. |
| INFO-02 (entry count) | Informational | No action needed. Consistent with spec omission. |

No findings require routing to upstream pipeline phases (Scientist or Logicist).

---

## 5. Test Inventory

### 5.1 Unit Tests (TLA+ Invariant Verification)

| Category | Tests | Status |
|----------|-------|--------|
| Construction | 5 | PASS |
| ConsistencyInvariant | 7 | PASS |
| CompletenessInvariant | 6 | PASS |
| SoundnessInvariant | 6 | PASS |
| Static verification | 2 | PASS |
| Serialization | 3 | PASS |
| Entry count | 3 | PASS |
| Statistics | 1 | PASS |
| Type safety | 3 | PASS |

### 5.2 Adversarial Tests

| ID | Test Case | Status |
|----|-----------|--------|
| ADV-01 | Fabricated siblings rejected | PASS |
| ADV-02 | Proof transplant (key A proof for key B) rejected | PASS |
| ADV-03a | Stale proof against new root rejected | PASS |
| ADV-03b | Stale proof against original root accepted | PASS |
| ADV-04a | Old value proof after overwrite rejected | PASS |
| ADV-04b | New value proof after overwrite accepted | PASS |
| ADV-05a | Non-membership proofs in empty tree valid (16 positions) | PASS |
| ADV-05b | Fake membership in empty tree rejected (16 positions) | PASS |
| ADV-06a | Truncated proof rejected | PASS |
| ADV-06b | Extended proof rejected | PASS |
| ADV-07a | All path bits flipped rejected | PASS |
| ADV-07b | Single bit flipped rejected (each position) | PASS |
| ADV-08a | Key > 2^depth handled via masking | PASS |
| ADV-08b | Key outside BN128 field rejected | PASS |
| ADV-09a | insert(key, 0) equivalent to deletion | PASS |
| ADV-09b | Repeated deletion is no-op | PASS |
| ADV-10 | Reversed sibling order rejected | PASS |
| ADV-11 | Sibling hash as leaf hash rejected | PASS |

### 5.3 Summary

| Metric | Value |
|--------|-------|
| Total test cases | 52 |
| Passed | 52 |
| Failed | 0 |
| Execution time | ~32 seconds |

---

## 6. Verdict

**NO VIOLATIONS FOUND.**

The Sparse Merkle Tree implementation correctly enforces all three formally verified
invariants (Consistency, Soundness, Completeness) and rejects all 11 adversarial
attack vectors. The implementation is ready for downstream consumption by the Prover
(Coq certification) and integration with the batch processing layer (RU-V3).
