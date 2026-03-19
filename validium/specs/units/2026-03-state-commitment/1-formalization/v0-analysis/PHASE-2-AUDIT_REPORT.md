# Phase 2: Audit Report -- State Commitment Protocol (RU-V3)

**Unit**: state-commitment
**Target**: validium
**Date**: 2026-03-18
**Phase**: 2 -- Verify Formalization Integrity
**Role**: The Auditor

---

## 1. Audit Scope

This audit verifies that the TLA+ specification `StateCommitment.tla` (v0-analysis)
faithfully represents the source materials in `0-input/`. The audit covers:

- **State variable mapping**: every source variable has a TLA+ counterpart (or justified omission)
- **State transition mapping**: every source function has a TLA+ action (or justified omission)
- **Hallucination detection**: the spec introduces no mechanisms absent from the source
- **Omission detection**: the spec omits no critical behavior
- **Semantic drift detection**: no subtle differences in meaning between source and spec

### Source Materials Examined

| Artifact | Path | Role |
|----------|------|------|
| Research findings | `0-input/REPORT.md` | Primary protocol description |
| Hypothesis definition | `0-input/hypothesis.json` | Scope and predictions |
| Reference implementation (V1) | `0-input/code/StateCommitmentV1.sol` | Minimal layout -- primary formalization target |
| Reference implementation (V2) | `0-input/code/StateCommitmentV2.sol` | Rich layout -- secondary reference |
| Benchmark harness | `0-input/code/StateCommitmentBenchmark.sol` | Gas measurement contracts |
| Benchmark tests | `0-input/code/benchmark.test.ts` | Test methodology |
| Gas benchmark results | `0-input/results/gas-benchmark.md` | Experimental data |

### Formalization Artifacts Examined

| Artifact | Path |
|----------|------|
| TLA+ specification | `v0-analysis/specs/StateCommitment/StateCommitment.tla` |
| Model instance | `v0-analysis/experiments/StateCommitment/MC_StateCommitment.tla` |
| TLC configuration | `v0-analysis/experiments/StateCommitment/MC_StateCommitment.cfg` |
| TLC log (Certificate of Truth) | `v0-analysis/experiments/StateCommitment/MC_StateCommitment.log` |
| Phase 1 notes | `v0-analysis/PHASE-1-FORMALIZATION_NOTES.md` |

---

## 2. Structural Mapping Analysis

### 2.1 State Variable Mapping

| Source (StateCommitmentV1.sol) | Solidity Type | TLA+ Variable | TLA+ Type | Match? |
|--------------------------------|---------------|---------------|-----------|--------|
| `enterprises[e].currentRoot` | bytes32 | `currentRoot[e]` | Roots \cup {None} | YES |
| `enterprises[e].batchCount` | uint64 | `batchCount[e]` | 0..MaxBatches | YES |
| `enterprises[e].lastTimestamp` | uint64 | -- | Not modeled | JUSTIFIED OMISSION |
| `enterprises[e].initialized` | bool | `initialized[e]` | BOOLEAN | YES |
| `batchRoots[e][id]` | mapping(uint256 => bytes32) | `batchHistory[e][id]` | [0..MaxBatches-1 -> Roots \cup {None}] | YES |
| `totalBatchesCommitted` | uint256 | `totalCommitted` | 0..(Cardinality(Enterprises) * MaxBatches) | YES |
| `admin` | address | -- | Not modeled | JUSTIFIED OMISSION |
| `enterpriseRegistry` | address | -- | Not modeled | JUSTIFIED OMISSION |
| `vk` (VerifyingKey) | struct | -- | Not modeled | JUSTIFIED OMISSION |
| `verifyingKeySet` | bool | -- | Not modeled | JUSTIFIED OMISSION |

**Coverage**: 6/10 state variables modeled. 4 omitted with justification.

**Assessment**: All protocol-critical state is modeled. The four omitted variables
(`lastTimestamp`, `admin`, `enterpriseRegistry`, `vk`/`verifyingKeySet`) participate
in no safety invariant of the state commitment protocol. They serve access control,
configuration, or metadata purposes.

### 2.2 State Transition Mapping

| Source Function | Source Guards | TLA+ Action | TLA+ Guards | Match? |
|-----------------|-------------|-------------|-------------|--------|
| `constructor(registry)` | -- | `Init` | -- | YES |
| `setVerifyingKey(...)` | onlyAdmin | Not modeled | -- | JUSTIFIED OMISSION |
| `initializeEnterprise(e, root)` | onlyAdmin, !initialized[e] | `InitializeEnterprise(e, root)` | ~initialized[e], genesisRoot \in Roots | PARTIAL |
| `submitBatch(prev, new, size, a, b, c, signals)` | vkSet, authorized, initialized, chainContinuity, proofValid | `SubmitBatch(e, prev, new, valid)` | initialized, batchCount < MaxBatches, prevRoot = currentRoot[e], proofIsValid = TRUE, newRoot \in Roots | PARTIAL |

**Coverage**: 3/4 state-changing functions modeled. 1 omitted with justification.

**Guard mapping for initializeEnterprise**:

| Solidity Guard | TLA+ Guard | Modeled? |
|----------------|-----------|----------|
| `msg.sender != admin` (onlyAdmin) | -- | NO (access control) |
| `enterprises[enterprise].initialized` | `~initialized[e]` | YES |

**Guard mapping for submitBatch**:

| Solidity Guard | TLA+ Guard | Modeled? |
|----------------|-----------|----------|
| `!verifyingKeySet` (line 141) | -- | NO (deployment lifecycle) |
| `_checkAuthorized(msg.sender)` (line 145) | -- | NO (access control) |
| `!es.initialized` (line 148) | `initialized[e]` | YES |
| `es.currentRoot != prevStateRoot` (line 151) | `prevRoot = currentRoot[e]` | YES |
| `!_verifyProof(a,b,c,publicSignals)` (line 156) | `proofIsValid = TRUE` | YES (oracle abstraction) |
| batchId = es.batchCount (line 160, structural) | `LET bid == batchCount[e]` | YES |

**Effect mapping for submitBatch**:

| Solidity Effect | TLA+ Effect | Modeled? |
|-----------------|-------------|----------|
| `es.currentRoot = newStateRoot` (line 163) | `currentRoot' EXCEPT ![e] = newRoot` | YES |
| `es.batchCount = uint64(batchId + 1)` (line 164) | `batchCount' EXCEPT ![e] = bid + 1` | YES |
| `es.lastTimestamp = uint64(block.timestamp)` (line 165) | -- | NO (metadata) |
| `batchRoots[msg.sender][batchId] = newStateRoot` (line 168) | `batchHistory' EXCEPT ![e][bid] = newRoot` | YES |
| `totalBatchesCommitted++` (line 170) | `totalCommitted' = totalCommitted + 1` | YES |
| `emit BatchCommitted(...)` (line 173) | -- | NO (observation, no state change) |

### 2.3 Invariant-to-Source Mapping

| TLA+ Invariant | Source Anchor | Correspondence |
|----------------|---------------|----------------|
| `TypeOK` | Implicit in Solidity type system | Ensures modeling correctness |
| `ChainContinuity` | INV-S1, V1.sol line 151 (`es.currentRoot != prevStateRoot` check) | `currentRoot[e] = batchHistory[e][batchCount[e]-1]` -- verifies the chain head always reflects the last committed root |
| `NoGap` | V1.sol line 160 (`batchId = es.batchCount` auto-increment) | Slots [0..batchCount-1] filled, [batchCount..MaxBatches-1] empty |
| `NoReversal` | REPORT.md "NoReversal" invariant | `initialized[e] => currentRoot[e] \in Roots` -- chain head never reverts to sentinel |
| `InitBeforeBatch` | V1.sol line 148 (`!es.initialized` revert) | `batchCount[e] > 0 => initialized[e]` |
| `GlobalCountIntegrity` | V1.sol line 170 (`totalBatchesCommitted++`) | `totalCommitted = SUM(batchCount)` across all enterprises |

All 6 invariants trace to explicit source mechanisms. No orphan invariants.

---

## 3. Discrepancy Detection

### 3.1 Hallucination Check

The spec was examined element-by-element for mechanisms absent from the source.

| TLA+ Element | Source Basis | Hallucinated? |
|-------------|-------------|---------------|
| `InitializeEnterprise` action | `initializeEnterprise()` in V1.sol | NO |
| `SubmitBatch` action | `submitBatch()` in V1.sol | NO |
| `proofIsValid` parameter | `_verifyProof()` return value | NO (oracle abstraction) |
| `MaxBatches` bound | -- | NO (finite model artifact, not protocol mechanism) |
| `None` sentinel | bytes32(0) default in Solidity mappings | NO (standard encoding) |
| `ChainContinuity` invariant | INV-S1 in REPORT.md, V1.sol line 151 | NO |
| `NoGap` invariant | REPORT.md, V1.sol line 160 | NO |
| `NoReversal` invariant | REPORT.md | NO |
| `InitBeforeBatch` invariant | V1.sol line 148 | NO |
| `GlobalCountIntegrity` invariant | V1.sol line 170 | NO |
| `SumBatchesHelper` recursive helper | -- | NO (utility for GlobalCountIntegrity, not a protocol mechanism) |

**Result: No hallucinations detected.** Every element in the TLA+ specification maps
to an explicit construct in the source materials. The `MaxBatches` bound and `None`
sentinel are standard finite model abstractions, not protocol mechanisms.

### 3.2 Omission Check

| Omitted Element | Source Location | Severity | Justification |
|-----------------|----------------|----------|---------------|
| `lastTimestamp` variable | V1.sol:24, lines 114, 165 | NEGLIGIBLE | Metadata field. Participates in no guard, no invariant, no conditional branch. Purely informational. |
| `setVerifyingKey()` action | V1.sol:89-105 | LOW | Deployment configuration. VK does not participate in any state commitment invariant. |
| `verifyingKeySet` guard | V1.sol:141 | LOW | Deployment lifecycle. Once VK is set, this guard always passes. Model assumes operational state. Documented in Phase 1 notes (6.3). |
| `admin` role / `onlyAdmin` modifier | V1.sol:74-77, 109 | LOW | Access control concern. The `~initialized[e]` guard prevents double-initialization regardless of caller identity. Safety properties hold under the more permissive TLA+ model. |
| `_checkAuthorized(msg.sender)` | V1.sol:145, 207-215 | LOW | Access control via EnterpriseRegistry. Enterprise isolation is guaranteed by EXCEPT semantics in TLA+, not by authorization. |
| `msg.sender` binding | V1.sol:147 (enterprises[msg.sender]) | LOW | In Solidity, the caller IS the enterprise. In TLA+, enterprise identity is a parameter. The TLA+ model is more permissive (any actor can trigger any enterprise's action) but safety properties hold under this relaxation. |
| `batchSize` parameter | V1.sol:132, 173 (event only in V1) | NEGLIGIBLE | Metadata. In V1 (the formalization target), batchSize appears only in the event. No guard, no state update, no invariant. |
| `publicSignals` content | V1.sol:139, 156 | LOW-MEDIUM | The public signals [prevStateRoot, newStateRoot, batchNum, enterpriseId] bind the ZK proof to specific transition parameters. This binding is abstracted away by the `proofIsValid` oracle. See Section 3.2.1. |
| Events (BatchCommitted, EnterpriseInitialized) | V1.sol:47-60 | NEGLIGIBLE | Events do not modify state. They are observation mechanisms. |
| View functions | V1.sol:186-203 | NEGLIGIBLE | Read-only functions. No state transitions. |
| V2 (Rich layout) | StateCommitmentV2.sol | N/A | V2 is not the formalization target. REPORT.md recommends V1 (Minimal) as the production layout. The TLA+ spec correctly targets V1. |
| Benchmark contracts | StateCommitmentBenchmark.sol | N/A | Testing infrastructure. Not protocol logic. |

#### 3.2.1 Note on publicSignals Abstraction

The `proofIsValid` oracle abstracts both the ZK proof verification AND the binding
between proof public inputs and the function parameters. In the actual contract:

```
publicSignals = [prevStateRoot, newStateRoot, batchNum, enterpriseId]
```

The ZK circuit enforces that the proof is valid FOR these specific parameters.
The TLA+ model decouples this: `proofIsValid` says "a valid proof exists" but does
not verify "the proof is for THIS specific (prevRoot, newRoot) transition."

This is a sound abstraction because:
1. The ChainContinuity guard independently enforces `prevRoot = currentRoot[e]`
2. The proof binding is a property of the ZK circuit, not the commitment protocol
3. The TLA+ model is strictly more permissive (it accepts valid proofs for any
   transition), so any safety violation found under this model would also exist
   in the actual system

No safety properties are weakened by this abstraction. However, the binding is
essential for the overall system's security and should be verified at the ZK
circuit level (outside the scope of this specification).

**Result: No critical omissions.** All omissions are justified and affect only
access control, deployment lifecycle, or metadata -- none affect the protocol-level
safety properties being verified.

### 3.3 Semantic Drift Check

| Property | Solidity Behavior | TLA+ Behavior | Drift? |
|----------|-------------------|---------------|--------|
| Genesis root | `currentRoot = genesisRoot` on init | `currentRoot[e] = genesisRoot` on init | NO |
| batchCount start value | 0 (Solidity default) | 0 (explicit in Init) | NO |
| First batchId | 0 (batchId = es.batchCount before increment) | 0 (LET bid == batchCount[e] before increment) | NO |
| batchCount increment | `uint64(batchId + 1)` | `bid + 1` | NO |
| Root update atomicity | Single EVM transaction | Single TLA+ step | NO |
| totalCommitted increment | Unconditional after state update | Unconditional in SubmitBatch | NO |
| History stores newRoot | `batchRoots[msg.sender][batchId] = newStateRoot` | `batchHistory[e][bid] = newRoot` | NO |
| No-op transition (newRoot = prevRoot) | Permitted (no explicit check) | Permitted (newRoot \in Roots, no exclusion) | NO |
| Double initialization | Reverts with EnterpriseAlreadyInitialized | Blocked by ~initialized[e] guard | NO |
| Re-initialization after use | Impossible (initialized flag never reset) | Impossible (no action sets initialized to FALSE) | NO |
| Root domain | bytes32 (2^256 values) | Finite set {r1, r2, r3, r4} | NO (standard finite abstraction) |
| Uninitialized default | bytes32(0) for currentRoot | None for currentRoot | NO (equivalent sentinels) |
| UNCHANGED semantics | Solidity: only touched fields change | TLA+: explicit UNCHANGED clauses | NO (verified correct) |

**Result: No semantic drift detected.** Every behavioral property matches between
source and specification. The finite root domain is a standard model-checking
abstraction that preserves equivalence classes relevant to the protocol.

---

## 4. Model Configuration Assessment

### 4.1 Finite Parameter Adequacy

| Parameter | Value | Justification | Adequate? |
|-----------|-------|---------------|-----------|
| Enterprises | {"e1", "e2"} | Minimum for cross-enterprise isolation testing | YES |
| MaxBatches | 5 | Sufficient for chain continuity, gap, and replay testing across multiple transitions | YES |
| Roots | {"r1", "r2", "r3", "r4"} | 4 roots for 5 transitions enables root cycling (hash collision in abstract domain), testing NoReversal under pressure | YES |
| None | "none" | Sentinel value, distinct from all roots (ASSUME enforced) | YES |

### 4.2 Attack Vector Coverage

| Attack | Modeled? | Mechanism |
|--------|----------|-----------|
| Gap attack (skip batch ID) | YES | batchId is structural (auto-increment), not parameterized. TLC explores all 3.78M interleavings. |
| Replay attack (resubmit old batch) | YES | ChainContinuity guard blocks stale prevRoot. TLC generates all (prev, new, valid) combinations. |
| Cross-enterprise interference | YES | EXCEPT ![e] semantics + 2 enterprises. TLC verifies isolation across all interleavings. |
| Invalid proof acceptance | YES | proofIsValid \in BOOLEAN in Next relation. Guard blocks FALSE. |
| Double initialization | YES | ~initialized[e] guard. TLC explores initialization before and after batches. |
| Root chain corruption | YES | ChainContinuity invariant verified across all reachable states. |
| Counter manipulation | YES | GlobalCountIntegrity invariant verified across all reachable states. |

### 4.3 State Space

- 3,778,441 states generated
- 1,874,161 distinct states explored
- Search depth: 13
- Duration: 21 seconds
- Collision probability: 1.4E-7 (negligible)

The state space is exhaustively explored. Zero states left on queue.

---

## 5. Observations (Non-Blocking)

These observations do not constitute discrepancies but are recorded for downstream
awareness.

### 5.1 No-Op Transition Permitted

Both the Solidity contract and TLA+ spec permit `newRoot == prevRoot`. The Phase 1
notes (Section 6.1) correctly identify this and recommend verifying at the ZK circuit
level. This is a design question, not a formalization error.

### 5.2 Genesis Root Uniqueness Not Enforced

Multiple enterprises can share the same genesis root. Phase 1 notes (Section 6.2)
correctly identify this as expected behavior (independent Sparse Merkle Trees with
identical initial states).

### 5.3 More Permissive Access Model

The TLA+ model does not enforce admin-only initialization or enterprise-self-only
submission. This makes the model strictly more permissive than the Solidity contract.
Since all safety properties pass under this relaxed model, they necessarily hold under
the stricter Solidity access control.

### 5.4 Formalization Targets V1 (Minimal Layout)

The specification models StateCommitmentV1.sol (Layout A: Minimal), which is the
recommended production layout per REPORT.md Section "Recommendation for Downstream
Pipeline." StateCommitmentV2.sol (Layout B: Rich) and the events-only layout (Layout C)
are intentionally excluded. This is correct: V1 is the protocol design to be implemented.

---

## 6. Phase 1 Notes Cross-Check

The Phase 1 notes (PHASE-1-FORMALIZATION_NOTES.md) document all abstraction decisions
and open issues. This audit verifies their accuracy:

| Phase 1 Claim | Audit Finding | Accurate? |
|---------------|---------------|-----------|
| ZK proof abstracted as oracle | proofIsValid parameter, confirmed | YES |
| State roots as abstract hash domain | Roots set with 4 elements, confirmed | YES |
| Enterprise authorization not modeled | _checkAuthorized omitted, confirmed | YES |
| Events and view functions not modeled | No events or views in spec, confirmed | YES |
| Gap attack impossible by construction | batchId structural, NoGap holds across 1.87M states | YES |
| Replay attack blocked for non-trivial transitions | ChainContinuity verified, no-op edge case documented | YES |
| Cross-enterprise attack impossible | EXCEPT semantics verified across all interleavings | YES |
| No-op transition permitted (Section 6.1) | Confirmed: neither contract nor spec prevents newRoot = prevRoot | YES |
| Genesis root uniqueness not enforced (Section 6.2) | Confirmed: no guard in either contract or spec | YES |
| Verifying key lifecycle not modeled (Section 6.3) | Confirmed: setVerifyingKey and verifyingKeySet omitted | YES |

All Phase 1 claims are accurate. No corrections required.

---

## 7. Verdict

### TRUE TO SOURCE

The TLA+ specification `StateCommitment.tla` is a faithful formalization of the
L1 State Commitment Protocol as described in `0-input/REPORT.md` and implemented
in `0-input/code/StateCommitmentV1.sol`.

**Basis for verdict**:

1. **State mapping**: 6/6 protocol-critical state variables modeled with correct types
   and domains. 4 non-critical variables (access control, configuration, metadata)
   omitted with documented justification.

2. **Transition mapping**: 3/3 protocol-critical actions modeled (Init,
   InitializeEnterprise, SubmitBatch). 5/7 guards modeled; the 2 omitted guards
   (verifyingKeySet, authorization) are access-control concerns that do not affect
   the safety properties under verification.

3. **No hallucinations**: Every element in the specification traces to an explicit
   construct in the source materials. No invented mechanisms.

4. **No critical omissions**: All omissions affect access control, deployment lifecycle,
   or metadata. No protocol-level behavior is missing.

5. **No semantic drift**: Behavioral properties match exactly between source and
   specification across all 13 properties checked.

6. **Model adequacy**: 2 enterprises, 5 batches, 4 roots provide sufficient diversity
   for exhaustive verification. 1,874,161 distinct states explored with zero violations.

### Disposition

- **Phase 3 (Diagnose)**: NOT TRIGGERED. No protocol flaws detected.
- **Downstream handoff**: The specification is ready for the Prime Architect (Phase 3
  of the pipeline is skipped; proceed to implementation). The Prover can begin Coq
  certification against the verified TLA+ specification.

---

*Audited by The Logicist, 2026-03-18.*
