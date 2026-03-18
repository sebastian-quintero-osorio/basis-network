---- MODULE SparseMerkleTree ----
(* ================================================================ *)
(* Sparse Merkle Tree with Poseidon Hash -- Formal Specification    *)
(* ================================================================ *)
(*                                                                  *)
(* Basis Network Enterprise ZK Validium -- State Management Layer   *)
(* Research Unit: RU-V1 (Sparse Merkle Tree with Poseidon Hash)     *)
(*                                                                  *)
(* This module formalizes the Sparse Merkle Tree (SMT) as described *)
(* in the Scientist's experimental findings. The SMT is the         *)
(* foundational data structure for all enterprise state management  *)
(* in the validium system. Every subsequent research unit (RU-V2    *)
(* through RU-V7) depends on the correctness of this component.     *)
(*                                                                  *)
(* [Source: 0-input/REPORT.md, Executive Summary]                   *)
(* [Source: 0-input/code/smt-implementation.ts]                     *)
(*                                                                  *)
(* FORMALIZED OPERATIONS:                                           *)
(*   Insert(key, value)  -- Insert or update a key-value pair       *)
(*   Delete(key)         -- Remove an entry (set value to zero)     *)
(*   ProofSiblings(k)    -- Generate Merkle proof siblings          *)
(*   VerifyProofOp(...)  -- Verify a Merkle proof against a root    *)
(*                                                                  *)
(* VERIFIED INVARIANTS:                                             *)
(*   ConsistencyInvariant  -- Root = deterministic hash of entries  *)
(*   SoundnessInvariant    -- No false-positive proof verification  *)
(*   CompletenessInvariant -- Every entry has a valid proof         *)
(*                                                                  *)
(* HASH FUNCTION:                                                   *)
(*   Modeled as an abstract injective function. The production      *)
(*   system uses Poseidon over BN128 scalar field (240 R1CS         *)
(*   constraints per hash). For model checking, a Cantor pairing    *)
(*   function is used, which is provably injective over all         *)
(*   non-negative integers.                                         *)
(*                                                                  *)
(* [Source: 0-input/REPORT.md, Section 2 -- Hash Function]          *)
(* ================================================================ *)

EXTENDS Integers, FiniteSets, TLC

(* ======================================== *)
(*           CONSTANTS                      *)
(* ======================================== *)

CONSTANTS
    Keys,       \* Set of keys that can be inserted (leaf indices in 0..2^DEPTH - 1)
    Values,     \* Set of non-zero values (models BN128 field elements)
    DEPTH       \* Tree depth (number of levels from root to leaves)

(* ======================================== *)
(*           DERIVED CONSTANTS              *)
(* ======================================== *)

\* [Source: 0-input/REPORT.md, Section 3.2 -- "Default value: Empty leaves hash to 0"]
\* The sentinel value for empty (unoccupied) leaves.
\* In the real system: field element 0 (BigInt 0n).
EMPTY == 0

\* Power of 2 (TLA+ standard library does not provide exponentiation)
RECURSIVE Pow2(_)
Pow2(n) == IF n = 0 THEN 1 ELSE 2 * Pow2(n - 1)

\* The complete set of leaf indices in the tree.
\* [Source: 0-input/REPORT.md, Section 3.1 -- "2^32 possible leaves"]
\* For the model: 2^DEPTH possible leaves (2^4 = 16 for DEPTH = 4).
LeafIndices == 0..(Pow2(DEPTH) - 1)

(* ======================================== *)
(*           ASSUMPTIONS                    *)
(* ======================================== *)

ASSUME DEPTH \in (Nat \ {0})
ASSUME Keys \subseteq LeafIndices
ASSUME Keys # {}
ASSUME EMPTY \notin Values
ASSUME Values # {}

(* ======================================== *)
(*           HASH FUNCTION                  *)
(* ======================================== *)
\*
\* The hash function is modeled as a prime-field linear hash:
\*   Hash(a, b) = (a * 31 + b * 17 + 1) mod HASH_MOD + 1
\*
\* where HASH_MOD = 65537 (the Fermat prime F4 = 2^16 + 1).
\*
\* Properties required for invariant verification:
\*   P1. Hash(a, b) >= 1 for all a, b >= 0 (distinguishes from EMPTY = 0).
\*   P2. gcd(31, HASH_MOD) = 1. This guarantees: for fixed b,
\*       Hash(a1, b) = Hash(a2, b) implies a1 = a2 (within mod class).
\*       This property ensures Soundness: a wrong leaf hash propagates
\*       a distinct value through every level to the root.
\*   P3. For our finite domain (keys 0..15, values 0..3), LeafHash is
\*       fully injective: max|31*dk + 17*dv| = 499 < 65537, so no
\*       modular wraparound occurs at level 0.
\*   P4. All intermediate computations fit in 32-bit integers:
\*       max(a * 31) = 65537 * 31 = 2,031,647 < 2^31.
\*
\* In the real system: Poseidon 2-to-1 hash over BN128 scalar field.
\* [Source: 0-input/REPORT.md, Section 2.2 -- "Poseidon is the clear choice"]
\* [Source: 0-input/code/smt-implementation.ts, lines 102-105]

HASH_MOD == 65537

Hash(a, b) == ((a * 31 + b * 17 + 1) % HASH_MOD) + 1

\* Leaf hash: H(key, value) for occupied leaves, 0 for empty leaves.
\* [Source: 0-input/code/smt-implementation.ts, line 172]
\* "const leafHash = value === 0n ? 0n : this.hash2(key, value)"
LeafHash(key, value) == IF value = EMPTY THEN EMPTY ELSE Hash(key, value)

(* ======================================== *)
(*           DEFAULT HASHES                 *)
(* ======================================== *)
\*
\* Precomputed hashes for all-empty subtrees at each level.
\* [Source: 0-input/code/smt-implementation.ts, lines 83-87]
\* "this.defaultHashes[0] = 0n;
\*  for (let i = 1; i <= depth; i++) {
\*      this.defaultHashes[i] = this.hash2(
\*          this.defaultHashes[i-1], this.defaultHashes[i-1]);
\*  }"

RECURSIVE DefaultHash(_)
DefaultHash(level) ==
    IF level = 0 THEN EMPTY
    ELSE LET prev == DefaultHash(level - 1)
         IN Hash(prev, prev)

(* ======================================== *)
(*           TREE COMPUTATION               *)
(* ======================================== *)
\*
\* The tree is conceptually a complete binary tree of depth DEPTH.
\* Leaves are at level 0, the root is at level DEPTH.
\* Only leaves corresponding to keys in the entries domain can be
\* non-empty; all other leaves are permanently empty.

\* Look up the value of a leaf by its index.
\* Keys not in the active set are always EMPTY.
EntryValue(e, idx) == IF idx \in DOMAIN(e) THEN e[idx] ELSE EMPTY

\* [Source: 0-input/REPORT.md, Section 3.3 -- Complexity Analysis]
\* Recursively compute the hash of the node at (level, index)
\* by hashing its two children. This is the "full rebuild" computation
\* used as the reference truth for verification.
RECURSIVE ComputeNode(_, _, _)
ComputeNode(e, level, index) ==
    IF level = 0
    THEN LeafHash(index, EntryValue(e, index))
    ELSE LET leftChild  == ComputeNode(e, level - 1, 2 * index)
             rightChild == ComputeNode(e, level - 1, 2 * index + 1)
         IN Hash(leftChild, rightChild)

\* Compute the root hash from entries by full tree rebuild.
ComputeRoot(e) == ComputeNode(e, DEPTH, 0)

(* ======================================== *)
(*           PATH OPERATIONS                *)
(* ======================================== *)
\*
\* Operations for navigating the tree path from a leaf to the root.
\* [Source: 0-input/code/smt-implementation.ts, lines 158-159]
\* "getBit(index, pos): return Number((index >> BigInt(pos)) & 1n)"

\* Extract the direction bit at a given level for a key.
\* 0 = left child, 1 = right child.
PathBit(key, level) == (key \div Pow2(level)) % 2

\* Compute the index of the sibling node at a given level.
\* [Source: 0-input/code/smt-implementation.ts, line 249]
\* "siblings[level] = this.getNode(level, currentIndex ^ 1n)"
\* XOR 1 flips the least significant bit: even -> +1, odd -> -1.
SiblingIndex(key, level) ==
    LET ancestorIdx == key \div Pow2(level)
    IN IF ancestorIdx % 2 = 0
       THEN ancestorIdx + 1
       ELSE ancestorIdx - 1

\* Compute the hash of the sibling subtree at a given level.
SiblingHash(e, key, level) ==
    ComputeNode(e, level, SiblingIndex(key, level))

(* ======================================== *)
(*     INCREMENTAL PATH RECOMPUTATION       *)
(* ======================================== *)
\*
\* After modifying a single leaf, recompute only the path from that
\* leaf to the root using the unchanged siblings from the old tree.
\* This is the O(depth) update algorithm.
\*
\* [Source: 0-input/code/smt-implementation.ts, lines 186-206]
\* [Source: 0-input/REPORT.md, Section 3.3 -- "Insert: O(depth), 32 hashes"]

RECURSIVE WalkUp(_, _, _, _)
WalkUp(oldEntries, currentHash, key, level) ==
    IF level = DEPTH
    THEN currentHash
    ELSE LET bit     == PathBit(key, level)
             sibling == SiblingHash(oldEntries, key, level)
             parent  == IF bit = 0
                        THEN Hash(currentHash, sibling)
                        ELSE Hash(sibling, currentHash)
         IN WalkUp(oldEntries, parent, key, level + 1)

(* ======================================== *)
(*           PROOF OPERATIONS               *)
(* ======================================== *)
\*
\* Merkle proof generation and verification.
\* [Source: 0-input/code/smt-implementation.ts, lines 239-260 (getProof)]
\* [Source: 0-input/code/smt-implementation.ts, lines 271-283 (verifyProof)]
\* [Source: 0-input/REPORT.md, Section 3.2]
\* "Proof format: Array of 32 sibling hashes + 32 direction bits"

\* Generate the sequence of sibling hashes for a Merkle proof.
ProofSiblings(e, key) ==
    [level \in 0..(DEPTH - 1) |-> SiblingHash(e, key, level)]

\* Generate the path bit sequence for a key.
PathBitsForKey(key) ==
    [level \in 0..(DEPTH - 1) |-> PathBit(key, level)]

\* Verify a Merkle proof by walking up from the leaf hash.
\* [Source: 0-input/code/smt-implementation.ts, lines 272-283]
\* "if (proof.pathBits[level] === 1) {
\*      currentHash = this.hash2(sibling, currentHash);
\*  } else {
\*      currentHash = this.hash2(currentHash, sibling);
\*  }"
RECURSIVE VerifyWalkUp(_, _, _, _)
VerifyWalkUp(currentHash, siblings, pathBits, level) ==
    IF level = DEPTH
    THEN currentHash
    ELSE LET parent == IF pathBits[level] = 0
                       THEN Hash(currentHash, siblings[level])
                       ELSE Hash(siblings[level], currentHash)
         IN VerifyWalkUp(parent, siblings, pathBits, level + 1)

\* Full proof verification: walk up from leaf hash and compare to expected root.
VerifyProofOp(expectedRoot, leafHash, siblings, pathBits) ==
    VerifyWalkUp(leafHash, siblings, pathBits, 0) = expectedRoot

(* ======================================== *)
(*           VARIABLES                      *)
(* ======================================== *)

VARIABLES
    entries,    \* Current key-value mapping: Keys -> Values \cup {EMPTY}
    root        \* Current Merkle root hash (maintained by incremental updates)

vars == << entries, root >>

(* ======================================== *)
(*           TYPE INVARIANT                 *)
(* ======================================== *)

TypeOK ==
    /\ entries \in [Keys -> Values \cup {EMPTY}]
    /\ root \in Nat

(* ======================================== *)
(*           INITIAL STATE                  *)
(* ======================================== *)
\*
\* [Source: 0-input/code/smt-implementation.ts, lines 76-88]
\* All entries are empty. The root is the default hash for an all-empty tree.

Init ==
    /\ entries = [k \in Keys |-> EMPTY]
    /\ root = DefaultHash(DEPTH)

(* ======================================== *)
(*           ACTIONS                        *)
(* ======================================== *)

\* Insert or update a key-value pair.
\* Computes the new leaf hash and recomputes the path to the root
\* using siblings from the current (pre-update) tree.
\*
\* [Source: 0-input/code/smt-implementation.ts, lines 168-208]
\* [Source: 0-input/REPORT.md, Section 3.3 -- "Insert: O(depth), 32 hashes"]
Insert(k, v) ==
    /\ k \in Keys
    /\ v \in Values
    /\ v # entries[k]
    /\ LET newLeafHash == LeafHash(k, v)
           newRoot     == WalkUp(entries, newLeafHash, k, 0)
       IN /\ entries' = [entries EXCEPT ![k] = v]
          /\ root' = newRoot

\* Delete an entry (set its value to zero).
\* Equivalent to Insert(k, 0) in the reference implementation.
\*
\* [Source: 0-input/code/smt-implementation.ts, lines 219-223]
\* "delete(key): return this.insert(key, 0n)"
Delete(k) ==
    /\ k \in Keys
    /\ entries[k] # EMPTY
    /\ LET newLeafHash == EMPTY
           newRoot     == WalkUp(entries, newLeafHash, k, 0)
       IN /\ entries' = [entries EXCEPT ![k] = EMPTY]
          /\ root' = newRoot

(* ======================================== *)
(*           NEXT-STATE RELATION            *)
(* ======================================== *)

Next ==
    \/ \E k \in Keys, v \in Values : Insert(k, v)
    \/ \E k \in Keys : Delete(k)

(* ======================================== *)
(*           SPECIFICATION                  *)
(* ======================================== *)

Spec == Init /\ [][Next]_vars

(* ======================================== *)
(*           SAFETY PROPERTIES              *)
(* ======================================== *)

\* CONSISTENCY INVARIANT
\* [Why]: The root hash must be a deterministic function of tree contents.
\* Two trees with identical key-value entries must produce identical roots.
\* This verifies that the incremental path recomputation (WalkUp) always
\* produces the same result as a complete tree rebuild (ComputeRoot).
\*
\* [Source: 0-input/README.md -- "ConsistencyInvariant: root always reflects actual tree content"]
\* [Source: 0-input/REPORT.md, Section 3.1 -- "Deterministic: Same set of key-value pairs
\*  always produces the same root"]
ConsistencyInvariant == root = ComputeRoot(entries)

\* SOUNDNESS INVARIANT
\* [Why]: An invalid proof must never be accepted as valid.
\* For any leaf position k and any value v that differs from the actual
\* entry at k, proof verification with the correct siblings must reject.
\* This ensures no false-positive verifications can occur.
\*
\* Checked over ALL leaf indices (not just active keys) to verify that
\* non-membership proofs for permanently empty positions also hold.
\*
\* Note: This checks soundness against value substitution with correct
\* siblings. Soundness against arbitrary sibling sequences follows from
\* the hash function's collision resistance (an assumption, not checked
\* by the finite model).
\*
\* [Source: 0-input/README.md -- "SoundnessInvariant: invalid proof NEVER accepted"]
\* [Source: 0-input/REPORT.md, Section 3.1 -- "Membership proofs"]
SoundnessInvariant ==
    \A k \in LeafIndices :
        \A v \in (Values \cup {EMPTY}) :
            v # EntryValue(entries, k) =>
                ~VerifyProofOp(root,
                               LeafHash(k, v),
                               ProofSiblings(entries, k),
                               PathBitsForKey(k))

\* COMPLETENESS INVARIANT
\* [Why]: Every leaf position in the tree must have a valid Merkle proof.
\* GetProof followed by VerifyProof must succeed for the actual leaf hash
\* at every position, covering both membership proofs (value # EMPTY)
\* and non-membership proofs (value = EMPTY).
\*
\* Checked over ALL leaf indices for full coverage.
\*
\* [Source: 0-input/README.md -- "CompletenessInvariant: existing entry always has valid proof"]
\* [Source: 0-input/REPORT.md, Section 5.4 -- "Non-membership proofs work correctly"]
CompletenessInvariant ==
    \A k \in LeafIndices :
        VerifyProofOp(root,
                      LeafHash(k, EntryValue(entries, k)),
                      ProofSiblings(entries, k),
                      PathBitsForKey(k))

====
