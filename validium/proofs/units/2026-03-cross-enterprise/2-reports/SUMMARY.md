# Cross-Enterprise Verification Unit -- Summary

**Date**: 2026-03-18
**Target**: validium
**Unit**: 2026-03-cross-enterprise
**Status**: VERIFIED -- 13 theorems Qed, 0 Admitted

---

## Scope

Proves that the cross-enterprise verification protocol preserves three safety
invariants across all 6 state transitions. Focus areas: **Isolation** (enterprise
data sovereignty) and **Consistency** (cross-reference validity).

## Input Artifacts

- **TLA+ Specification**: `CrossEnterprise.tla` (251 lines)
  - 6 actions: SubmitBatch, VerifyBatch, FailBatch, RequestCrossRef, VerifyCrossRef, RejectCrossRef
  - 3 safety properties: Isolation, Consistency, NoCrossRefSelfLoop
  - TLC model-checked with 2 enterprises, 2 batches, 2 state roots
- **TypeScript Implementation**: `cross-reference-builder.ts` (443 lines)
  - buildCrossReferenceEvidence, verifyCrossReferenceLocally
- **Solidity Implementation**: `CrossEnterpriseVerifier.sol` (451 lines)
  - verifyCrossReference with inline Groth16 verification

## Proof Artifacts

| File | Lines | Purpose |
|------|-------|---------|
| Common.v | 207 | Types, CrossRefId equality, functional update lemmas, tactics |
| Spec.v | 193 | Faithful TLA+ translation: state, actions, Step, properties |
| Impl.v | 135 | Implementation correspondence (TypeScript + Solidity) |
| Refinement.v | 332 | 13 theorems: initialization, preservation, corollaries |

## Theorem Inventory

### Invariant Initialization (3)

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 1 | isolation_init | Init satisfies Isolation | Qed |
| 2 | consistency_init | Init satisfies Consistency | Qed |
| 3 | no_self_loop_init | Init satisfies NoCrossRefSelfLoop | Qed |

### Invariant Preservation (3, each covering all 6 actions)

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 4 | isolation_preserved | Isolation preserved by Step | Qed |
| 5 | consistency_preserved | Consistency preserved by Step | Qed |
| 6 | no_self_loop_preserved | NoCrossRefSelfLoop preserved by Step | Qed |

### Combined Invariant (3)

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 7 | all_invariants_init | All hold at Init | Qed |
| 8 | all_invariants_preserved | All preserved by Step | Qed |
| 9 | invariants_reachable | All reachable states satisfy all | Qed |

### Corollaries (4)

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 10 | cross_ref_preserves_roots | VerifyCrossRef does not modify state roots | Qed |
| 11 | verified_crossref_both_verified | Verified cross-ref implies both batches verified | Qed |
| 12 | enterprise_root_has_witness | Non-genesis root has verified batch witness | Qed |
| 13 | active_crossref_distinct | Active cross-refs have distinct endpoints | Qed |

## Key Proof Strategies

### Isolation

- **VerifyBatch** is the only action that advances `currentRoot`. It simultaneously
  sets the batch to `Verified` with a matching root, providing the existential witness.
- **SubmitBatch/FailBatch** modify batches at `Idle`/`Submitted` status. The witness
  batch from the induction hypothesis has `Verified` status, creating a status
  contradiction if the positions coincide (`Verified <> Idle`, `Verified <> Submitted`).
  Proved via `fupdate2_neq_pair` with pair inequality derived from `congruence`.
- **Cross-ref actions** (Request/Verify/Reject) leave `currentRoot`, `batchStatus`,
  and `batchNewRoot` unchanged, making Isolation trivially preserved.

### Consistency

- **VerifyCrossRef** is the only action that sets `crossRefStatus` to `CRVerified`.
  Its guard requires both batch statuses to be `Verified`, directly satisfying the
  Consistency consequent.
- **Batch monotonicity**: once a batch reaches `Verified`, no action downgrades it.
  `SubmitBatch` requires `Idle`, `FailBatch` requires `Submitted` -- neither can fire
  on a `Verified` batch. For `VerifyBatch`, updating to `Verified` preserves any
  position already at `Verified` (via `fupdate2_to_same`).
- **Request/Reject**: set `crossRefStatus` to `CRPending`/`CRRejected`, neither of
  which equals `CRVerified`, so the Consistency hypothesis is vacuously false.

### NoCrossRefSelfLoop

- Structural: all cross-ref actions require `valid_ref ref` (src <> dst) in their guards.
- Batch actions leave `crossRefStatus` unchanged, so the invariant hypothesis propagates directly.

## Axiom Trust Base

- `GenesisRoot : StateRoot` -- a parameter with no axioms on its value.
  Represents the initial state root for all enterprises at system genesis.
  Enforced by implementation: genesis block configuration.

No additional axioms were introduced. The trust base is minimal.

## Compilation

```
Rocq Prover 9.0.1 (OCaml 4.14.2)
coqc -Q . CE Common.v      PASS
coqc -Q . CE Spec.v         PASS
coqc -Q . CE Impl.v         PASS
coqc -Q . CE Refinement.v   PASS
```

0 errors. 0 warnings. 0 Admitted. 13 theorems Qed.
