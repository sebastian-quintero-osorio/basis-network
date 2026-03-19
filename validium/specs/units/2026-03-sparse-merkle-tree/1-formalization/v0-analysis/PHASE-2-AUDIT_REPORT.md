# Phase 2: Audit Report -- Sparse Merkle Tree (RU-V1)

## Unit Information

- **Research Unit**: RU-V1 (Sparse Merkle Tree with Poseidon Hash)
- **Target**: validium
- **Date**: 2026-03-18
- **Phase**: 2 (Verify Formalization Integrity)
- **Verdict**: PASS -- Formalization is faithful to source materials.

---

## 1. Structural Mapping

Side-by-side comparison of source materials (0-input/) and TLA+ specification.

### 1.1 State Representation

| Source (smt-implementation.ts) | TLA+ (SparseMerkleTree.tla) | Faithful? |
|---|---|---|
| `nodes: Map<string, FieldElement>` (line 71) | `entries: [Keys -> Values \cup {EMPTY}]` | YES -- entries captures the logical content; concrete node hashes are derived via ComputeNode |
| `_entryCount: number` (line 74) | Not modeled | ACCEPTABLE -- entry count is metadata, not state-affecting |
| `defaultHashes: FieldElement[]` (line 65) | `DefaultHash(level)` recursive operator | YES -- same recursive construction |
| `root` getter (line 138) | `root` variable | YES -- both represent `getNode(depth, 0)` |

### 1.2 Operations

| Source Operation | TLA+ Action/Operator | Faithful? |
|---|---|---|
| `insert(key, value)` (lines 168-208) | `Insert(k, v)` action | YES |
| `update(key, value)` (lines 215-217) | Subsumed by Insert (same semantics) | YES |
| `delete(key)` (lines 222-224) | `Delete(k)` action | YES |
| `getProof(key)` (lines 239-260) | `ProofSiblings(e, k)` + `PathBitsForKey(k)` | YES |
| `verifyProof(root, key, leafHash, proof)` (lines 271-283) | `VerifyProofOp(r, lh, siblings, pathBits)` | YES |

### 1.3 Hash Function

| Source | TLA+ | Faithful? |
|---|---|---|
| `hash2(left, right)` using circomlibjs Poseidon (lines 102-105) | `Hash(a, b)` prime-field linear function | ACCEPTABLE -- models algebraic structure (determinism, non-zero output) not cryptographic security |
| `value === 0n ? 0n : this.hash2(key, value)` (line 172) | `LeafHash(key, value) == IF value = EMPTY THEN EMPTY ELSE Hash(key, value)` | YES -- exact match |

### 1.4 Path Navigation

| Source | TLA+ | Faithful? |
|---|---|---|
| `getBit(index, pos)` = `(index >> pos) & 1` (line 159) | `PathBit(key, level) == (key \div Pow2(level)) % 2` | YES -- equivalent bit extraction |
| `currentIndex ^ 1n` for sibling (line 249) | `SiblingIndex(key, level)` using even/odd check | YES -- equivalent to XOR with 1 |
| `pathBits[level] === 1 ? hash2(sibling, current) : hash2(current, sibling)` (lines 276-279) | `IF bit = 0 THEN Hash(currentHash, sibling) ELSE Hash(sibling, currentHash)` | YES -- same left/right ordering |

### 1.5 Invariants

| Source (README.md) | TLA+ | Faithful? |
|---|---|---|
| "root always reflects actual tree content" | `ConsistencyInvariant == root = ComputeRoot(entries)` | YES |
| "invalid proof NEVER accepted" | `SoundnessInvariant` -- quantifies over all positions and all wrong values | YES -- strengthened to check ALL 16 leaf positions |
| "existing entry always has valid proof" | `CompletenessInvariant` -- quantifies over all positions | YES -- strengthened to include non-membership proofs |

---

## 2. Hallucination Detection

Checking whether the specification assumes mechanisms NOT present in the source.

| TLA+ Element | Present in Source? | Assessment |
|---|---|---|
| `Pow2(n)` operator | Implicit in bit operations | OK -- utility, not an assumption |
| `EntryValue(e, idx)` | Implicit in `getNode` (returns default for absent) | OK -- faithful to sparse storage model |
| `WalkUp` operator | Explicit in insert (lines 186-206) | OK -- direct translation of path recomputation loop |
| `ComputeNode` (full rebuild) | NOT explicitly in source | OK -- this is the reference truth for verification, not a source feature. The source computes roots incrementally; the full rebuild is the mathematical definition of "correct root". |
| `HASH_MOD` constant | NOT in source (Poseidon has no modulus) | ACCEPTABLE -- model-checking artifact. Documented in Phase 1 notes with proof that invariant semantics are preserved. |

**No hallucinations detected.** All TLA+ elements trace to source materials or are
justified as model-checking infrastructure (documented as such).

---

## 3. Omission Detection

Checking whether the specification MISSES critical side-effects or state transitions.

### 3.1 Omitted Implementation Details

| Source Feature | Omitted? | Impact |
|---|---|---|
| Sparse storage optimization (Map, delete defaults) | YES | None -- performance optimization, not state-affecting |
| Entry count tracking (`_entryCount`) | YES | None -- metadata, not used in tree operations |
| `keyToIndex` bit masking (line 152) | YES | None -- model assumes keys ARE indices (valid for keys < 2^DEPTH) |
| `toField` modular reduction (line 117) | YES | None -- model values are already in valid range |
| `getLeafHash` accessor (line 231) | YES | None -- convenience accessor, not a state transition |
| `verifyProofStatic` (lines 290-313) | YES | None -- stateless variant, identical logic to `verifyProof` |
| `getStats` (lines 318-329) | YES | None -- observability, not state-affecting |

### 3.2 Potentially Omitted State Transitions

| Scenario | Covered? | Assessment |
|---|---|---|
| Insert to empty position | YES | Insert action with entries[k] = EMPTY, v in Values |
| Update existing entry | YES | Insert action with entries[k] != EMPTY, v != entries[k] |
| Delete existing entry | YES | Delete action |
| Delete non-existent entry | N/A | Guard prevents (entries[k] # EMPTY). Source behavior: insert(key, 0n) when already 0n is a no-op. Correct omission. |
| Insert same value | N/A | Guard prevents (v # entries[k]). Source behavior: no-op. Correct omission. |
| Key collision (two keys map to same index) | N/A | Model uses keys as direct indices. In production, key derivation via Poseidon hash could theoretically collide, but probability is negligible (2^-128 for BN128). Outside scope. |

### 3.3 Missing Invariants

| Potential Invariant | Included? | Assessment |
|---|---|---|
| Root uniqueness (different entries => different roots) | NO | Follows from hash collision resistance. Not checkable in finite model with modular hash (pigeonhole). Acceptable omission. |
| Proof uniqueness (only one valid proof per key) | NO | Follows from tree structure determinism. Implicit in Completeness + Soundness. |
| Deletion correctness (after delete, non-membership proof works) | YES | Covered by CompletenessInvariant when entries[k] = EMPTY |

**No critical omissions detected.** All omitted features are either performance optimizations,
metadata, or properties that follow from the verified invariants combined with cryptographic
assumptions.

---

## 4. Source Fidelity Assessment

### 4.1 Insert Path Recomputation

The most critical algorithm to verify is the incremental path recomputation in Insert.
The source implementation (smt-implementation.ts, lines 186-206):

```typescript
let currentIndex = index;
for (let level = 0; level < this.depth; level++) {
    const isRight = this.getBit(currentIndex, 0);
    const parentIndex = currentIndex >> 1n;
    let left, right;
    if (isRight) {
        left = this.getNode(level, currentIndex ^ 1n);
        right = this.getNode(level, currentIndex);
    } else {
        left = this.getNode(level, currentIndex);
        right = this.getNode(level, currentIndex ^ 1n);
    }
    const parentHash = this.hash2(left, right);
    this.setNode(level + 1, parentIndex, parentHash);
    currentIndex = parentIndex;
}
```

The TLA+ WalkUp operator:

```tla+
WalkUp(oldEntries, currentHash, key, level) ==
    IF level = DEPTH THEN currentHash
    ELSE LET bit     == PathBit(key, level)
             sibling == SiblingHash(oldEntries, key, level)
             parent  == IF bit = 0
                        THEN Hash(currentHash, sibling)
                        ELSE Hash(sibling, currentHash)
         IN WalkUp(oldEntries, parent, key, level + 1)
```

**Verification**: Bit extraction (`getBit` vs `PathBit`), sibling lookup (`currentIndex ^ 1n`
vs `SiblingIndex`), and left/right hash ordering all correspond exactly. The key difference
is that the source mutates `nodes` in-place during the loop, while TLA+ computes the
result functionally. Since only the path from leaf to root is affected, and siblings are
read (not written) during the walk, this difference is immaterial. The ConsistencyInvariant
confirms equivalence across all 65,536 states.

### 4.2 Proof Verification

The source verifyProof (lines 271-283) and TLA+ VerifyWalkUp use identical logic:
walk from leaf hash to root, combining with siblings according to path bits.
CompletenessInvariant confirms this produces the correct root for all entries.

---

## 5. Verdict

**PASS.** The TLA+ specification faithfully represents the Sparse Merkle Tree as
described in the Scientist's research materials and reference implementation.

- No hallucinated mechanisms
- No critical omissions
- All state transitions mapped
- Hash function modeling is sound for invariant verification
- All 65,536 reachable states verified

The specification is ready for downstream consumption by the Architect (implementation)
and Prover (Coq certification).
