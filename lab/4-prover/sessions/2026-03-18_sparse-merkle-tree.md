# Session Log: Sparse Merkle Tree Verification

**Date**: 2026-03-18
**Target**: validium (MVP)
**Unit**: 2026-03-sparse-merkle-tree
**Agent**: The Prover (lab/4-prover)

---

## Status: VERIFIED

All 10 core theorems proved. Zero Admitted. Full compilation on Rocq 9.0.1.

## Artifacts Produced

| Artifact | Path |
|----------|------|
| TLA+ snapshot (read-only) | `validium/proofs/units/2026-03-sparse-merkle-tree/0-input-spec/SparseMerkleTree.tla` |
| Impl snapshot (read-only) | `validium/proofs/units/2026-03-sparse-merkle-tree/0-input-impl/sparse-merkle-tree.ts` |
| Impl snapshot (read-only) | `validium/proofs/units/2026-03-sparse-merkle-tree/0-input-impl/types.ts` |
| Common.v | `validium/proofs/units/2026-03-sparse-merkle-tree/1-proofs/Common.v` |
| Spec.v | `validium/proofs/units/2026-03-sparse-merkle-tree/1-proofs/Spec.v` |
| Impl.v | `validium/proofs/units/2026-03-sparse-merkle-tree/1-proofs/Impl.v` |
| Refinement.v | `validium/proofs/units/2026-03-sparse-merkle-tree/1-proofs/Refinement.v` |
| Verification log | `validium/proofs/units/2026-03-sparse-merkle-tree/2-reports/verification.log` |
| Summary | `validium/proofs/units/2026-03-sparse-merkle-tree/2-reports/SUMMARY.md` |

## What Was Done

1. **Input Validation**: Created verification unit directory structure at
   `validium/proofs/units/2026-03-sparse-merkle-tree/`. Populated read-only snapshots
   of the TLA+ specification and TypeScript implementation.

2. **Common.v**: Defined the shared type infrastructure:
   - FieldElement as Z, EMPTY = 0
   - Hash axiomatized as positive and injective (modeling Poseidon over BN128)
   - pow2 using Z.pow for clean arithmetic
   - Entries as total functions Z -> FieldElement
   - LeafHash, PathBit, SiblingIndex with supporting lemmas

3. **Spec.v**: Faithful translation of SparseMerkleTree.tla:
   - State = (entries, root) record
   - DefaultHash, ComputeNode, WalkUp as recursive functions
   - Init, Insert, Delete as state transitions
   - ValidKey predicate (k >= 0 and k / pow2(d) = 0)
   - ConsistencyInvariant, SoundnessInvariant, CompletenessInvariant

4. **Impl.v**: Abstract model of sparse-merkle-tree.ts:
   - NodeStore as function (level, index) -> FieldElement
   - State with depth and node store
   - insert via walkUpLoop, delete as insert with EMPTY
   - getProof, verifyProof structurally matching the spec

5. **Refinement.v**: 10 core theorems + 20 helper lemmas:
   - Part 1: Arithmetic helpers (ancestor_step, pathbit_0/1_ancestor, sibling_index)
   - Part 2: Initial state refinement
   - Part 3: VerifyWalkUp structural equivalence (Impl = Spec)
   - Part 4: ComputeNode independence and empty tree
   - Part 5: Completeness kernel (verify_reconstructs_node)
   - Part 6: Completeness from Consistency
   - Part 7: Soundness from Hash Injectivity
   - Part 8: Consistency preservation (the hard part)
   - Part 9: All-invariants induction

## Key Decisions and Rationale

1. **Hash axiomatization**: Modeled Hash as abstract with positivity and injectivity.
   Positivity without preconditions (matches Poseidon over finite field).
   Injectivity models collision resistance (256-bit security).

2. **pow2 via Z.pow**: Used `Z.pow 2 (Z.of_nat n)` instead of a Fixpoint to get
   clean integration with Stdlib lemmas (Z.pow_succ_r, Z.pow_pos_nonneg, Z.div_div).

3. **ValidKey predicate**: Added `k >= 0 /\ k / pow2 d = 0` to Completeness and
   Soundness invariants. This faithfully models the TLA+ assumption
   `Keys \subseteq LeafIndices == 0..(Pow2(DEPTH) - 1)`.

4. **Sibling subtree independence**: Proved via `compute_node_update_outside` and
   `sibling_outside_key`. The key insight: a single-leaf update at k cannot affect
   any subtree that does not contain k.

5. **Controlled reduction**: Used `cbn [Spec.WalkUp]` and `cbn [Spec.ComputeNode]`
   instead of `simpl` to prevent over-reduction of arithmetic in Z (which caused
   match-on-positive/negative patterns that broke nia).

## Challenges Encountered

- Rocq 9.0 renamed `From Coq` to `From Stdlib` and removed Nia module (available
  via `From Stdlib Require Import micromega.Psatz`).
- `simpl` aggressively reduces `2 * index` to binary match expressions, breaking
  nonlinear arithmetic tactics. Solved by using `cbn` selectively.
- `lia` cannot handle products of variables (nonlinear). Required `nia` from Psatz.
- Let-bound variables in proofs are opaque to `rewrite`. Solved with `subst`.

## Next Steps

- This verification unit covers RU-V1 (Sparse Merkle Tree).
- The next pipeline step for the Prover is RU-V2 (Batch Verification) once
  the Architect completes the batch processing implementation.
