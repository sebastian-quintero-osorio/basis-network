# Verification Summary: State Commitment Protocol

**Unit:** 2026-03-state-commitment
**Target:** validium
**Date:** 2026-03-18
**Prover:** Rocq Prover 9.0.1 (OCaml 4.14.2)
**Verdict:** PASS -- All theorems proved, zero Admitted, zero custom axioms.

---

## Inputs

| Artifact | Path |
|----------|------|
| TLA+ Spec | `0-input-spec/StateCommitment.tla` (207 lines) |
| Solidity Impl | `0-input-impl/StateCommitment.sol` (410 lines) |

## Proof Files

| File | Lines | Purpose |
|------|-------|---------|
| `Common.v` | 99 | Domain types, function update primitives, lemmas |
| `Spec.v` | 139 | Faithful TLA+ translation: State, Init, actions, invariants |
| `Impl.v` | 128 | Solidity model: State, Init, actions, step relation |
| `Refinement.v` | 414 | Refinement + all invariant proofs |

## Theorems Proved

### Refinement (Simulation)

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 1 | `init_refinement` | `map_state(Impl.Init) = Spec.Init` | Qed |
| 2 | `step_refinement` | Every Impl step maps to Spec step or stutter | Qed |

### Invariant Base Cases

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 3 | `all_invariants_init` | All 4 invariants hold in Init | Qed |

### Invariant Preservation (Under ALL Transitions)

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 4 | `init_before_batch_preserved` | InitBeforeBatch inductive | Qed |
| 5 | `no_reversal_preserved` | NoReversal inductive | Qed |
| 6 | `no_gap_preserved` | NoGap inductive | Qed |
| 7 | `chain_continuity_preserved` | ChainContinuity inductive (needs InitBeforeBatch) | Qed |
| 8 | `all_invariants_preserved` | Combined: AllInvariants is inductive | Qed |

### Implementation-Level Correctness

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 9 | `impl_invariants_init` | AllInvariants holds for Impl initial state | Qed |
| 10 | `impl_invariants_preserved` | AllInvariants preserved by every Impl step | Qed |

### ProofBeforeState (INV-S2)

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 11 | `proof_before_state` | Preconditions suffice to construct valid step | Qed |

## Axiom Trust Base

**NONE.** All proofs from first principles. No `Axiom`, no `Parameter`, no `Admitted`.

## Safety Properties Verified

### INV-S1: ChainContinuity
- **Definition:** `initialized[e] /\ batchCount[e] > 0 => currentRoot[e] = batchHistory[e][batchCount[e] - 1]`
- **Verified for:** InitializeEnterprise (vacuous: batchCount = 0), SubmitBatch (direct equality: newRoot = newRoot)
- **Co-invariant:** Requires InitBeforeBatch (to derive batchCount = 0 for uninitialized enterprises)

### INV-S2: ProofBeforeState
- **Enforcement:** Structural -- the step_submit_batch constructor requires proof validity as a precondition
- **Solidity mapping:** Lines 233-234 (`_verifyProof` check) execute before lines 240-248 (state mutation)
- **Guarantee:** By Curry-Howard, existence of a step term implies all preconditions were met

### NoGap
- **Definition:** `i < batchCount[e] => batchHistory[e][i] <> NONE` and `i >= batchCount[e] => batchHistory[e][i] = NONE`
- **Verified for:** InitializeEnterprise (UNCHANGED), SubmitBatch (fills slot batchCount with newRoot > 0)

### NoReversal
- **Definition:** `initialized[e] => currentRoot[e] <> NONE`
- **Verified for:** InitializeEnterprise (genesisRoot > 0), SubmitBatch (newRoot > 0)

### InitBeforeBatch
- **Definition:** `batchCount[e] > 0 => initialized[e] = true`
- **Verified for:** InitializeEnterprise (sets initialized = true), SubmitBatch (increments batchCount only for initialized e)

## Modeling Decisions

1. **Enterprise type:** `nat` with decidable equality (abstracts Solidity `address`)
2. **Root type:** `nat` with `NONE = 0` (abstracts Solidity `bytes32(0)`)
3. **Proof validity:** Boolean abstraction (matches TLA+ `proofIsValid` parameter)
4. **Solidity batchCount = 0 in initializeEnterprise:** Modeled as UNCHANGED (semantically equivalent under InitBeforeBatch invariant; avoids functional extensionality axiom)
5. **SetVerifyingKey:** Modeled as stutter step (no TLA+ counterpart; does not affect safety invariants)
6. **Authorization (isAuthorized):** Abstracted -- step relation assumes caller is authorized

## Cross-Consistency Assessment

The TLA+ specification and Solidity implementation are **isomorphic** on the state commitment protocol:
- Same state variables (currentRoot, batchCount, initialized, batchHistory, totalCommitted)
- Same guards (initialized check, chain continuity check, proof validity)
- Same effects (atomic state update after proof verification)
- Same invariants preserved by same mechanisms

Solidity adds: lastTimestamp (not security-critical), verifyingKeySet (admin gating), EnterpriseRegistry authorization (access control). These are correctly abstracted in the Coq model.
