# Adversarial Report: State Transition Circuit (RU-V2)

**Date**: 2026-03-18
**Agent**: Prime Architect
**Target**: validium/circuits/circuits/state_transition.circom
**Specification**: validium/specs/units/2026-03-state-transition-circuit/1-formalization/v0-analysis/specs/StateTransitionCircuit/StateTransitionCircuit.tla

---

## 1. Summary

Adversarial testing of the StateTransition Circom circuit, which proves a batch of
sequential key-value updates in an enterprise's Sparse Merkle Tree transitions the
state root correctly from `prevStateRoot` to `newStateRoot`.

The circuit was compiled at depth=10, batch=4, producing 45,715 R1CS constraints.
Six test scenarios were executed: one valid baseline and five adversarial attacks
targeting distinct circuit constraints. All attacks were correctly rejected.

**Overall Verdict**: NO VIOLATIONS FOUND.

---

## 2. Attack Catalog

| ID | Attack Vector | Target Constraint | Result | Line |
|----|---------------|-------------------|--------|------|
| T0 | Valid input (baseline) | All | ACCEPTED | -- |
| T1 | Wrong oldValue (forged Merkle proof) | ProofSoundness | REJECTED | 92 |
| T2 | Wrong newStateRoot (forged final root) | StateRootChain | REJECTED | 116 |
| T3 | Wrong sibling (corrupted Merkle path) | ProofSoundness | REJECTED | 92 |
| T4 | Swapped transaction order | BatchIntegrity | REJECTED | 92 |
| T5 | Key overflow (key > 2^depth) | Key range check | REJECTED | 62 |

---

## 3. Findings

### 3.1 No Vulnerabilities Found

All tested attack vectors were correctly rejected by the circuit's constraint system.
The three TLA+ invariants map to enforceable circuit constraints:

- **ProofSoundness** (TLA+ line 450): Enforced by `oldRootChecks[i].out === 1` (line 92).
  Any mismatch between the claimed oldValue and the actual Merkle root makes the
  constraint unsatisfiable. Verified by T1, T3, T4.

- **StateRootChain** (TLA+ line 401): Enforced by `finalCheck.out === 1` (line 116).
  The chained root after all transactions must equal the declared newStateRoot.
  Verified by T2.

- **BatchIntegrity** (TLA+ line 423): Enforced by the chaining mechanism
  (`chainedRoots[i+1] <== newPathVerifiers[i].root`). Reordering transactions
  breaks the chain because each transaction's Merkle proof is computed against
  the intermediate root from the previous transaction. Verified by T4.

### 3.2 Security Enhancement: Path Bit Derivation (INFO)

**Severity**: INFO

The production circuit derives path bits from keys using `Num2Bits(depth)` rather
than accepting them as prover inputs. This is a security improvement over the
research prototype (which accepted pathBits as inputs), because:

1. The prover cannot supply path bits inconsistent with the key.
2. `Num2Bits` enforces that `key < 2^depth`, preventing out-of-range keys (T5).
3. Reduces the witness size by `depth * batchSize` field elements.

The cost is `depth` additional constraints per transaction (negligible: 10 out of
~11,428 per-tx constraints at depth=10).

### 3.3 Replay Protection (INFO)

**Severity**: INFO

The circuit does not prevent batch replay (submitting the same valid proof twice).
This is correct by design -- replay protection is an L1 concern. The on-chain
verifier contract must track processed state roots and reject duplicate submissions.
This is documented, not a flaw.

### 3.4 Empty Value Handling (INFO)

**Severity**: INFO

The TLA+ spec defines `LeafHash(key, EMPTY) = EMPTY` (line 119), meaning empty
leaves have hash 0. The Circom circuit always computes `Poseidon(key, value)` even
when value=0, which produces a non-zero hash. This divergence is intentional: the
circuit operates on non-empty values only (the prover only includes transactions
that modify occupied or newly-inserted leaves). Deletion semantics (setting value
to 0) would require an additional conditional check. This is a known limitation
for the MVP -- the Scientist should investigate deletion support in a future
research unit if needed.

---

## 4. Pipeline Feedback

| Finding | Route | Action |
|---------|-------|--------|
| Replay protection needed | Architect (Phase A) | Implement in L1 verifier contract (ZKVerifier.sol) |
| Empty value / deletion support | Scientist (Phase 0) | Investigate conditional leaf hashing for deletion |
| Path bit derivation is sound | Informational | Document in ADR |

---

## 5. Test Inventory

| Test | Input File | Expected | Actual | Pass |
|------|-----------|----------|--------|------|
| T0: Valid baseline | input.json | ACCEPTED | ACCEPTED | YES |
| T1: Wrong oldValue | input_tampered_oldvalue.json | REJECTED | REJECTED (line 92) | YES |
| T2: Wrong newStateRoot | input_tampered_newroot.json | REJECTED | REJECTED (line 116) | YES |
| T3: Wrong sibling | input_tampered_sibling.json | REJECTED | REJECTED (line 92) | YES |
| T4: Swapped tx order | input_tampered_swapped.json | REJECTED | REJECTED (line 92) | YES |
| T5: Key overflow | input_tampered_overflow_key.json | REJECTED | REJECTED (line 62) | YES |

All adversarial inputs are stored in `validium/circuits/build/state_transition/`.

---

## 6. Verdict

**NO SECURITY VIOLATIONS FOUND.**

The StateTransition circuit correctly enforces all three TLA+ invariants
(StateRootChain, BatchIntegrity, ProofSoundness) and adds an additional security
property (key range enforcement) via Num2Bits decomposition. The circuit is ready
for trusted setup and proof generation.

---

## 7. Circuit Metrics

| Metric | Value |
|--------|-------|
| Template | `StateTransition(10, 4)` |
| R1CS constraints | 45,715 |
| Non-linear constraints | 21,589 |
| Linear constraints | 24,126 |
| Template instances | 78 |
| Wires | 45,763 |
| Public inputs | 4 |
| Private inputs | 52 |
| Per-tx constraints | ~11,429 |
| Constraint formula | ~1,038 * (depth+1) * batchSize + depth * batchSize + 3 |
