# Verification Summary: Sparse Merkle Tree

**Unit**: 2026-03-sparse-merkle-tree
**Target**: validium (MVP)
**Date**: 2026-03-18
**Prover**: Rocq 9.0.1
**Verdict**: VERIFIED

---

## Scope

Formal verification of the Sparse Merkle Tree (SMT) implementation against
its TLA+ specification. The SMT is the foundational data structure for
enterprise state management in the Basis Network ZK Validium system.

**Specification**: SparseMerkleTree.tla (TLC: 1,572,865 states, 65,536 distinct, PASS)
**Implementation**: sparse-merkle-tree.ts (TypeScript, Poseidon hash over BN128)

## What Was Proved

### Core Theorems (all Qed, zero Admitted)

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 1 | `init_refinement` | Impl.Init maps to Spec.Init | PROVED |
| 2 | `verify_walkup_equiv` | Impl.verifyWalkUp = Spec.VerifyWalkUp | PROVED |
| 3 | `completeness_from_consistency` | ConsistencyInvariant => CompletenessInvariant | PROVED |
| 4 | `soundness_from_consistency` | ConsistencyInvariant + hash_injective => SoundnessInvariant | PROVED |
| 5 | `consistency_init` | ConsistencyInvariant holds at initialization | PROVED |
| 6 | `consistency_preserved_insert` | ConsistencyInvariant preserved by Insert | PROVED |
| 7 | `consistency_preserved_delete` | ConsistencyInvariant preserved by Delete | PROVED |
| 8 | `all_invariants_init` | All 3 invariants hold at Init | PROVED |
| 9 | `all_invariants_preserved_insert` | All 3 invariants preserved by Insert | PROVED |
| 10 | `all_invariants_preserved_delete` | All 3 invariants preserved by Delete | PROVED |

### Key Helper Lemmas (all Qed)

| Lemma | Purpose |
|-------|---------|
| `compute_node_ext` | ComputeNode depends only on entries in its subtree |
| `compute_node_update_outside` | Single-leaf update does not affect disjoint subtrees |
| `compute_node_empty` | Empty tree produces DefaultHash at every level |
| `verify_reconstructs_node` | VerifyWalkUp with correct siblings reconstructs ancestor |
| `verify_walkup_injective` | VerifyWalkUp is injective in the leaf hash |
| `walkup_computes_new_root` | Incremental WalkUp computes correct new root |
| `sibling_hash_update_invariant` | Sibling subtree unchanged under single-leaf update |
| `parent_from_left` / `parent_from_right` | Hash of child + sibling = ComputeNode at parent |
| `pathbit_0_ancestor` / `pathbit_1_ancestor` | Key index arithmetic across levels |

## Invariants Verified

### ConsistencyInvariant
`root = ComputeNode(entries, depth, 0)`

The root hash is a deterministic function of the tree contents.
Incremental path recomputation (WalkUp) always produces the same
result as full tree rebuild (ComputeRoot). **Proved inductively**:
holds at Init, preserved by Insert and Delete.

### CompletenessInvariant
`forall k (valid), VerifyProof(root, LeafHash(k, entries[k]), siblings, pathBits) = true`

Every valid leaf position has a valid Merkle proof.
**Derived from ConsistencyInvariant** via `verify_reconstructs_node`.

### SoundnessInvariant
`forall k v (valid), v <> entries[k] -> not VerifyProof(root, LeafHash(k, v), siblings, pathBits)`

No invalid proof is accepted. **Derived from ConsistencyInvariant**
via `verify_walkup_injective` and the hash injectivity axiom.

## Axiom Trust Base

| Axiom | Justification |
|-------|---------------|
| `hash_positive` | Poseidon outputs are in (0, p) for the BN128 field |
| `hash_injective` | Poseidon collision resistance over BN128 (256-bit security) |
| `depth_positive` | Tree depth > 0 (implementation validates at construction) |

## Preconditions

- `k >= 0`: Keys are non-negative (BN128 field elements in [0, p))
- `k / pow2(depth) = 0`: Key is in valid range [0, 2^depth)
  This models the TLA+ assumption `Keys \subseteq LeafIndices`

## Proof Architecture

```
ConsistencyInvariant (root = ComputeRoot)
  |-- consistency_init            (base case)
  |-- consistency_preserved_insert (inductive step via walkup_computes_new_root)
  |-- consistency_preserved_delete (reduces to insert)
  |
  +---> CompletenessInvariant     (derived via verify_reconstructs_node)
  +---> SoundnessInvariant        (derived via verify_walkup_injective + hash_injective)
```

The proof structure mirrors the TLA+ model checking result: Consistency is the
fundamental invariant; Completeness and Soundness are consequences.

## Files

| File | Lines | Purpose |
|------|-------|---------|
| Common.v | ~220 | Type mappings, hash axioms, shared tactics |
| Spec.v | ~265 | Faithful TLA+ to Coq translation |
| Impl.v | ~240 | Abstract model of TypeScript implementation |
| Refinement.v | ~630 | Refinement proof with 10 core theorems |
