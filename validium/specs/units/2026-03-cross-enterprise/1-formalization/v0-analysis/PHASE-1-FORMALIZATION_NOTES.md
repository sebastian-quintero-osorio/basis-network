# Phase 1: Formalization Notes -- Cross-Enterprise Verification (RU-V7)

**Date**: 2026-03-18
**Target**: validium
**Unit**: `validium/specs/units/2026-03-cross-enterprise/`
**Result**: PASS

---

## 1. Research-to-Specification Mapping

| Research Concept | Source | TLA+ Element | Notes |
|---|---|---|---|
| Enterprise state root | REPORT.md, "Groth16 Individual Verification Cost" | `currentRoot : [Enterprises -> StateRoots]` | Verified root per enterprise |
| Batch submission | REPORT.md, "Sequential Verification" baseline | `SubmitBatch(e, b, r)` action | idle -> submitted |
| Groth16 proof verification | REPORT.md, "Groth16 Individual Verification Cost" (205,600 gas) | `VerifyBatch(e, b)` action | submitted -> verified, updates currentRoot |
| Proof failure | Derived from adversarial model | `FailBatch(e, b)` action | submitted -> idle |
| Cross-reference request | REPORT.md, "Cross-Reference Circuit Design" | `RequestCrossRef(s, d, sb, db)` action | Requires active batches from both enterprises |
| Cross-reference verification | REPORT.md, "Cross-Reference Circuit Design" + "Privacy Analysis" | `VerifyCrossRef(s, d, sb, db)` action | Consistency gate: both batches must be verified |
| Cross-reference rejection | Derived from failure path | `RejectCrossRef(s, d, sb, db)` action | At least one batch not verified |
| Enterprise isolation | REPORT.md, "Privacy Analysis" -- ZK guarantees, 128-bit security | `Isolation` invariant | Enterprise state determined solely by own batches |
| Cross-reference consistency | REPORT.md, Recommendations -- "valid only if both proofs valid" | `Consistency` invariant | Verified cross-ref implies both batches verified |
| No self-referencing | Structural, derived from protocol semantics | `NoCrossRefSelfLoop` invariant | Enforced by CrossRefIds construction |
| Public signals | REPORT.md, "Cross-Reference Circuit Design" (3 field elements) | Comment on `VerifyCrossRef` | stateRootA, stateRootB, interactionCommitment |
| Private inputs | REPORT.md, "Privacy Analysis" | Comment on `VerifyCrossRef` | keys, values, Merkle siblings, path bits |

## 2. Specification Summary

### Module: CrossEnterprise

**Constants**: `Enterprises`, `BatchIds`, `StateRoots`, `GenesisRoot`

**Variables** (4):
- `currentRoot` -- verified state root per enterprise
- `batchStatus` -- batch lifecycle (idle/submitted/verified)
- `batchNewRoot` -- state root claimed by each batch
- `crossRefStatus` -- cross-reference lifecycle (none/pending/verified/rejected)

**Actions** (6):
1. `SubmitBatch` -- enterprise submits batch with new state root
2. `VerifyBatch` -- batch ZK proof verified on L1, state root advances
3. `FailBatch` -- batch ZK proof fails, batch reverts to idle
4. `RequestCrossRef` -- request cross-enterprise verification
5. `VerifyCrossRef` -- verify cross-reference proof (consistency gate)
6. `RejectCrossRef` -- reject cross-reference (batch not verified)

**Safety Invariants** (4):
1. `TypeOK` -- type invariant
2. `Isolation` -- enterprise state determined solely by own verified batches
3. `Consistency` -- verified cross-ref requires both batches verified
4. `NoCrossRefSelfLoop` -- structural: no self-referencing cross-refs

**Liveness Property** (1):
- `CrossRefTermination` -- pending cross-refs eventually resolve (requires LiveSpec)

## 3. Assumptions Made During Formalization

1. **State root abstraction**: State roots are modeled as opaque values from a finite domain. The cryptographic properties of Poseidon hashing and Merkle tree construction are abstracted away. The specification verifies protocol-level correctness, not cryptographic soundness.

2. **Proof abstraction**: ZK proof generation and verification are modeled as non-deterministic actions (VerifyBatch can succeed or fail). The actual Groth16 pairing check is not modeled -- its correctness is assumed from the cryptographic literature (128-bit security).

3. **Batch slot reuse**: Batch identifiers are modeled as reusable slots (a batch can fail and be resubmitted). In the production system, batch IDs would be unique monotonic counters. The finite model uses reusable slots for state space tractability.

4. **Single cross-reference constraint**: The model check limits exploration to at most 1 active cross-reference at a time (`MC_Constraint`). This matches the user requirement and keeps the state space manageable. The specification itself supports arbitrary numbers of concurrent cross-references.

5. **No gas modeling**: Gas costs documented in the research (205,600 gas for Groth16, 806,737 for sequential cross-ref) are not modeled in TLA+. The specification verifies correctness properties, not resource consumption.

6. **Isolation modeling**: The `Isolation` invariant captures state independence (no cross-contamination of enterprise state roots). The information-theoretic isolation (no private data leakage via ZK proofs) is a structural property of the specification verified by inspection: `VerifyCrossRef` accesses only `crossRefStatus` and `batchStatus`, never `batchNewRoot` of the other enterprise.

## 4. Verification Results

### Safety Check (TLC)

```
TLC2 Version 2.16 of 31 December 2020
Specification: Spec (Init /\ [][Next]_vars)
Workers: 4
Constraint: MC_Constraint (at most 1 active cross-reference)

Constants:
  Enterprises = {E1, E2}
  BatchIds    = {B1, B2}
  StateRoots  = {R0, R1, R2}
  GenesisRoot = R0

Result: Model checking completed. No error has been found.
States generated:  461,529
Distinct states:   54,009
Queue remaining:   0 (complete exploration)
Search depth:      11
Time:              2 seconds

Invariants verified:
  [PASS] TypeOK
  [PASS] Isolation
  [PASS] Consistency
  [PASS] NoCrossRefSelfLoop

Fingerprint collision probability: < 1.2E-9 (negligible)
```

### Reproduction Instructions

```bash
cd validium/specs/units/2026-03-cross-enterprise/1-formalization/v0-analysis/experiments/CrossEnterprise/_build/
java -cp ../../../../../../../lab/2-logicist/tools/tla2tools.jar \
    tlc2.TLC -workers 4 -config MC_CrossEnterprise.cfg MC_CrossEnterprise
```

### Liveness Check (not yet executed)

Liveness checking (`CrossRefTermination`) requires `LiveSpec` (with fairness). To run:

1. Change `SPECIFICATION Spec` to `SPECIFICATION LiveSpec` in `.cfg`
2. Add `PROPERTIES CrossRefTermination`
3. Re-run TLC (liveness checking is significantly slower due to cycle detection)

## 5. Open Issues

1. **Batch resubmission and stale cross-references**: If a batch slot is resubmitted after a cross-reference was requested against it, the cross-reference may reference stale state. The current model does not track the state root at request time. In the production system, unique batch IDs prevent this. The model is correct under the assumption that batch slots represent unique submissions within a single protocol epoch.

2. **Liveness not yet model-checked**: The `CrossRefTermination` liveness property is defined but not yet verified by TLC. Under the specified fairness conditions (WF on VerifyBatch, FailBatch, VerifyCrossRef, RejectCrossRef), the property should hold because: (a) every submitted batch either gets verified or fails, and (b) every pending cross-ref can either be verified (if both batches verified) or rejected (if at least one batch not verified).

3. **Dense interaction graphs**: The research report identifies that sequential verification exceeds 2x overhead when interactions >> enterprises. The TLA+ specification does not model gas costs but the Consistency invariant holds regardless of interaction density. The Architect must implement batched pairing verification for dense scenarios.

4. **Information-theoretic isolation**: The `Isolation` invariant captures state independence but not the full information-theoretic guarantee of the ZK proof system. Full isolation depends on the soundness and zero-knowledge properties of Groth16, which are beyond the scope of TLA+ model checking. The Prover (lab/4-prover) should formalize this in Coq.
