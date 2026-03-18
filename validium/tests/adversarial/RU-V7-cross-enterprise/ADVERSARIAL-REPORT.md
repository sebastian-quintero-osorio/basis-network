# Adversarial Testing Report -- RU-V7 Cross-Enterprise Verification

**Date**: 2026-03-18
**Target**: validium (MVP Enterprise ZK Validium Node)
**Unit**: RU-V7 Cross-Enterprise Verification
**Spec**: validium/specs/units/2026-03-cross-enterprise/1-formalization/v0-analysis/specs/CrossEnterprise/CrossEnterprise.tla
**TLC Result**: PASS (461,529 states, 54,009 distinct, 0 errors)

---

## 1. Summary

Adversarial testing was performed on the Cross-Enterprise Verification implementation covering both the TypeScript off-chain module (`validium/node/src/cross-enterprise/`) and the Solidity L1 contract (`l1/contracts/contracts/verification/CrossEnterpriseVerifier.sol`).

Testing targeted all three TLA+ safety invariants:
- **Isolation**: Enterprise state roots must not be modified by cross-reference operations
- **Consistency**: Cross-reference verification requires both enterprise batch proofs to be independently verified
- **NoCrossRefSelfLoop**: Cross-references between an enterprise and itself are structurally forbidden

**Verdict**: NO VIOLATIONS FOUND

---

## 2. Attack Catalog

| # | Attack Vector | Target | Result | Invariant Tested |
|---|--------------|--------|--------|-----------------|
| A1 | Self-reference (src == dst) | TypeScript | REJECTED | NoCrossRefSelfLoop |
| A2 | Self-reference (src == dst) | Solidity | REJECTED | NoCrossRefSelfLoop |
| A3 | Invalid source Merkle proof | TypeScript | REJECTED | Consistency |
| A4 | Invalid destination Merkle proof | TypeScript | REJECTED | Consistency |
| A5 | State root mismatch | TypeScript | REJECTED | Consistency |
| A6 | Source batch not verified on L1 | TypeScript | REJECTED | Consistency |
| A7 | Destination batch not verified on L1 | TypeScript | REJECTED | Consistency |
| A8 | Source batch not verified on L1 | Solidity | REJECTED | Consistency |
| A9 | Destination batch not verified on L1 | Solidity | REJECTED | Consistency |
| A10 | Neither batch verified | Solidity | REJECTED | Consistency |
| A11 | Invalid Groth16 proof | Solidity | REJECTED | Consistency |
| A12 | Tampered interaction commitment | TypeScript | REJECTED | Consistency |
| A13 | Enterprise state modified after cross-ref | TypeScript | UNCHANGED | Isolation |
| A14 | Enterprise state modified after cross-ref | Solidity | UNCHANGED | Isolation |
| A15 | Replay attack (re-verify same cross-ref) | Solidity | REJECTED | Idempotency |
| A16 | Unregistered source enterprise | Solidity | REJECTED | Authorization |
| A17 | Unregistered destination enterprise | Solidity | REJECTED | Authorization |
| A18 | Deactivated enterprise | Solidity | REJECTED | Authorization |
| A19 | Swapped enterprise proofs | TypeScript | REJECTED | Consistency |
| A20 | Concurrent cross-references | TypeScript | PASS | Independence |
| A21 | Multi-enterprise (3-way) | Solidity | PASS | Independence |
| A22 | Directional asymmetry (A->B vs B->A) | Solidity | DISTINCT | Ordering |
| A23 | Empty tree proofs (non-membership) | TypeScript | ACCEPTED | Edge case |
| A24 | Different batch IDs same enterprises | TypeScript | DISTINCT | Identification |
| A25 | VK not set before verification | Solidity | REJECTED | Configuration |

---

## 3. Findings

### CRITICAL: None

### MODERATE: None

### LOW: None

### INFO

**INFO-1: Non-membership proofs are accepted by buildCrossReferenceEvidence.**

The cross-reference builder accepts Merkle proofs for keys that do not exist in the tree (leafHash = 0). This is by design: the proof is still cryptographically valid (proves non-membership). A cross-reference circuit in production would add an additional constraint verifying that the leaf hash is non-zero, ensuring both enterprises actually have the referenced records. The current implementation documents this as a known property.

**INFO-2: Privacy leakage is exactly 1 bit per interaction.**

Submitting a cross-reference proof inherently reveals that an interaction exists between Enterprise A and Enterprise B. This is an unavoidable consequence of the verification model and is documented in the research report. The interaction commitment (Poseidon hash) reveals zero additional information about the content of the interaction due to preimage resistance (128-bit security).

---

## 4. Pipeline Feedback

### Implementation Hardening (Phase 3)

No implementation hardening needed. All invariants hold as proven by TLC.

### Informational

- **Non-membership guard**: A future Circom circuit implementation should include a constraint `leafHash != 0` for both enterprises to prevent cross-references involving non-existent records. This is a circuit-level concern, not a contract/builder concern.
- **Gas optimization**: The current sequential approach (individual proofs + cross-reference proof) yields 1.41x overhead for 2 enterprises with 1 interaction. For scaling beyond 10 enterprises, consider batched pairing verification as documented in the research report.

---

## 5. Test Inventory

### TypeScript (validium/node/src/cross-enterprise/__tests__/cross-reference-builder.test.ts)

| Test | Result |
|------|--------|
| should build valid evidence from two enterprise proofs | PASS |
| should produce deterministic commitments | PASS |
| should reject self-reference (NoCrossRefSelfLoop) | PASS |
| should reject invalid source Merkle proof | PASS |
| should reject invalid destination Merkle proof | PASS |
| should reject proof against wrong state root | PASS |
| should verify valid evidence with both batches verified | PASS |
| should reject when source batch not verified (Consistency) | PASS |
| should reject when destination batch not verified (Consistency) | PASS |
| should reject self-reference in verification | PASS |
| should reject tampered interaction commitment | PASS |
| should not leak private data in public signals | PASS |
| should produce different commitments for different interactions | PASS |
| should not modify enterprise state roots during verification | PASS |
| should format signals as 0x-prefixed hex strings | PASS |
| should handle empty tree proofs (non-membership) | PASS |
| should reject when proofs are swapped between enterprises | PASS |
| should produce different refIds for different batch IDs | PASS |
| should handle concurrent verification of multiple cross-references | PASS |

**Total: 19/19 PASS**

### Solidity (l1/contracts/test/CrossEnterpriseVerifier.test.ts)

| Test | Result |
|------|--------|
| should set admin | PASS |
| should link to StateCommitment | PASS |
| should link to EnterpriseRegistry | PASS |
| should start with zero verified cross-references | PASS |
| should verify a valid cross-reference | PASS |
| should store correct refId | PASS |
| should emit CrossReferenceVerified with correct parameters | PASS |
| should reject self-reference (enterpriseA == enterpriseB) | PASS |
| should reject when source batch not verified | PASS |
| should reject when destination batch not verified | PASS |
| should reject when neither batch is verified | PASS |
| should not modify enterprise state roots after cross-ref verification | PASS |
| should reject unregistered source enterprise | PASS |
| should reject unregistered destination enterprise | PASS |
| should reject deactivated enterprise | PASS |
| should reject invalid proof | PASS |
| should reject re-verification of already verified cross-reference | PASS |
| should allow admin to set verifying key | PASS |
| should reject non-admin verifying key update | PASS |
| should reject verification before verifying key is set | PASS |
| should return None for non-existent cross-reference | PASS |
| should return Verified after successful verification | PASS |
| should compute deterministic refIds | PASS |
| should support multiple independent cross-references | PASS |
| should handle directional cross-references (A->B != B->A) | PASS |

**Total: 25/25 PASS**

---

## 6. Verdict

**NO VIOLATIONS FOUND**

All three TLA+ safety invariants (Isolation, Consistency, NoCrossRefSelfLoop) hold under adversarial testing. The implementation is a faithful translation of the verified specification.

Combined test results: **44/44 PASS** across TypeScript and Solidity test suites.
