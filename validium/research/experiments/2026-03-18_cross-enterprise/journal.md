# Journal -- Cross-Enterprise Verification (RU-V7)

## 2026-03-18 -- Session 1: Literature Review + Implementation

### Pre-Experiment Predictions

1. Cross-reference proof will require ~2x the constraints of a single enterprise proof
   (two Merkle path verifications instead of one).
2. Sequential verification (3 Groth16 proofs) will achieve ~1.35x overhead.
3. Batched pairing verification will reduce to ~1.19x overhead.
4. Privacy is preserved because the cross-reference circuit uses private Merkle proofs
   from both enterprises -- only the state roots (already public) are exposed.

### What Would Change My Mind?

- If the cross-reference circuit requires exposing intermediate state values (not just roots),
  privacy is broken and the approach must be redesigned.
- If aggregation for small batch sizes (2-5 proofs) has overhead > 50% per proof,
  the < 2x target may be unachievable with current Groth16.
- If recursive proof composition for Groth16 is not feasible without switching to PLONK,
  the MVP approach needs re-evaluation.

### Literature Review Summary

Conducted search across 15+ sources including IACR ePrint, FC proceedings, Springer,
production systems (Polygon, zkSync, Nebra, Rayls). Key findings documented in findings.md.

### Design Decision: Three Verification Approaches

After literature review, identified three viable approaches for cross-enterprise verification:

1. **Sequential**: Verify each enterprise proof + cross-reference proof independently.
   Simplest. Gas = sum of individual verifications + cross-reference.

2. **Batched Pairing**: Use Groth16 batch verification (shared random linear combination
   of pairing equations). Saves repeated pairing computations.

3. **Aggregated (Hub Model)**: Use inner product argument (SnarkPack-style) to aggregate
   all proofs into single verification. Only efficient at scale (32+ proofs).

For MVP with 2-10 enterprises, Approach 1 (Sequential) or Approach 2 (Batched) is optimal.
Approach 3 reserved for scale-out phase.

### Cross-Reference Circuit Design

The cross-reference circuit proves: "There exists a leaf in Enterprise A's SMT and a leaf
in Enterprise B's SMT such that the values satisfy an interaction predicate, without
revealing the values themselves."

Public inputs: stateRootA, stateRootB, interactionCommitment
Private inputs: keyA, valueA, siblingsA, pathBitsA, keyB, valueB, siblingsB, pathBitsB

Constraints:
- 2 * MerklePathVerifier(depth=32) = 2 * 1,038 * 33 = 68,508
- Interaction predicate (Poseidon hash match) = ~500
- Total estimate: ~69,008 constraints

Proving time estimate (from RU-V2 pattern: ~65 us/constraint):
- 69,008 * 65 us = ~4.49 seconds (snarkjs)
- With rapidsnark: ~0.45 seconds (10x speedup from RU-V5)
