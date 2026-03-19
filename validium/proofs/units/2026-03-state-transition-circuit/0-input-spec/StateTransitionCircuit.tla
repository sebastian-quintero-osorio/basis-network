---- MODULE StateTransitionCircuit ----
(* ================================================================ *)
(* State Transition Circuit -- Formal Specification                 *)
(* ================================================================ *)
(*                                                                  *)
(* Basis Network Enterprise ZK Validium -- Batch State Transitions  *)
(* Research Unit: RU-V2 (State Transition Circuit)                  *)
(*                                                                  *)
(* This module formalizes the ChainedBatchStateTransition circuit:   *)
(* a Groth16 ZK proof that a batch of sequential key-value updates  *)
(* correctly transitions an enterprise's Sparse Merkle Tree from    *)
(* prevStateRoot to newStateRoot. Multiple enterprises operate      *)
(* concurrently, each with an independent SMT.                      *)
(*                                                                  *)
(* Depends on: RU-V1 (SparseMerkleTree). The hash function, tree   *)
(* computation, and incremental path recomputation (WalkUp) are     *)
(* replicated from the RU-V1 specification for self-containment.    *)
(* The Soundness and Completeness invariants verified in RU-V1      *)
(* justify the abstraction used here: a valid Merkle proof for      *)
(* (key, value) is equivalent to tree[key] = value.                 *)
(*                                                                  *)
(* [Source: 0-input/REPORT.md, "Experimental Results"]              *)
(* [Source: 0-input/code/state_transition_verifier.circom]          *)
(* [Source: 0-input/README.md, "Objectives for Formalization"]      *)
(*                                                                  *)
(* FORMALIZED OPERATIONS:                                           *)
(*   StateTransition(e, batch) -- Verify and apply a batch of       *)
(*     sequential state transitions for enterprise e                *)
(*   RejectInvalid(e, batch)   -- Reject a batch with at least one  *)
(*     invalid Merkle proof (no state change)                       *)
(*                                                                  *)
(* VERIFIED INVARIANTS:                                             *)
(*   StateRootChain  -- Root = deterministic hash of tree contents  *)
(*                      after chained multi-tx batch application    *)
(*   BatchIntegrity  -- Each single-tx WalkUp agrees with           *)
(*                      ComputeRoot at every reachable state        *)
(*   ProofSoundness  -- Wrong oldValue always causes rejection      *)
(*                                                                  *)
(* KEY VERIFICATION TARGET:                                         *)
(*   RU-V1 verified single-operation WalkUp correctness.            *)
(*   RU-V2 verifies CHAINED multi-operation WalkUp correctness:     *)
(*   applying N transactions sequentially through WalkUp must       *)
(*   produce a root consistent with ComputeRoot of the final tree.  *)
(* ================================================================ *)

EXTENDS Integers, Sequences, FiniteSets, TLC

(* ======================================== *)
(*           CONSTANTS                      *)
(* ======================================== *)

CONSTANTS
    Enterprises,    \* Set of enterprise identifiers (e.g., {1, 2, 3})
    Keys,           \* Set of keys that can be stored (leaf indices in 0..2^DEPTH - 1)
    Values,         \* Set of non-zero values (models BN128 field elements)
    DEPTH,          \* Tree depth (number of levels from root to leaves)
    MaxBatchSize    \* Maximum number of transactions per batch

(* ======================================== *)
(*           DERIVED CONSTANTS              *)
(* ======================================== *)

\* [Source: RU-V1 SparseMerkleTree, line 57]
\* Sentinel value for empty (unoccupied) leaves.
\* In the real system: field element 0 (BigInt 0n).
EMPTY == 0

\* Power of 2 (TLA+ standard library does not provide exponentiation).
RECURSIVE Pow2(_)
Pow2(n) == IF n = 0 THEN 1 ELSE 2 * Pow2(n - 1)

\* The complete set of leaf indices in the tree.
\* [Source: 0-input/REPORT.md, "Tree Depth" -- depth D gives 2^D leaves]
LeafIndices == 0..(Pow2(DEPTH) - 1)

\* The set of all tree states: mappings from Keys to values (including EMPTY).
TreeState == [Keys -> Values \cup {EMPTY}]

(* ======================================== *)
(*           ASSUMPTIONS                    *)
(* ======================================== *)

ASSUME DEPTH \in (Nat \ {0})
ASSUME Keys \subseteq LeafIndices
ASSUME Keys # {}
ASSUME EMPTY \notin Values
ASSUME Values # {}
ASSUME Enterprises # {}
ASSUME MaxBatchSize \in (Nat \ {0})

(* ======================================== *)
(*           HASH FUNCTION                  *)
(* ======================================== *)
\*
\* Replicated from RU-V1 (SparseMerkleTree) for self-containment.
\* Models Poseidon 2-to-1 hash as a prime-field linear function:
\*   Hash(a, b) = (a * 31 + b * 17 + 1) mod 65537 + 1
\*
\* Properties (verified in RU-V1):
\*   P1. Hash(a, b) >= 1 for all a, b >= 0 (distinguishes from EMPTY = 0).
\*   P2. Injective within the model's finite domain (no modular collisions).
\*
\* In the real system: Poseidon(2) over BN128 scalar field (240 R1CS
\* constraints per hash invocation).
\*
\* [Source: 0-input/REPORT.md, "Poseidon Hash Constraints in Circom"]
\* [Source: 0-input/code/state_transition_verifier.circom, lines 39, 69-76]
\*   "oldLeafHashers[i] = Poseidon(2); inputs[0] <== keys[i]"

HASH_MOD == 65537

Hash(a, b) == ((a * 31 + b * 17 + 1) % HASH_MOD) + 1

\* Leaf hash: H(key, value) for occupied leaves, 0 for empty.
\* [Source: 0-input/code/state_transition_verifier.circom, lines 212-218]
\*   "oldLeafHashers[i] = Poseidon(2);
\*    oldLeafHashers[i].inputs[0] <== keys[i];
\*    oldLeafHashers[i].inputs[1] <== oldValues[i];"
LeafHash(key, value) == IF value = EMPTY THEN EMPTY ELSE Hash(key, value)

(* ======================================== *)
(*           DEFAULT HASHES                 *)
(* ======================================== *)
\*
\* Precomputed hashes for all-empty subtrees at each level.
\* [Source: 0-input/code/generate_input.js, lines 28-35]
\*   "defaults[0] = BigInt(0);
\*    for (let i = 1; i <= depth; i++) {
\*        defaults[i] = F.toObject(poseidon([defaults[i-1], defaults[i-1]]));
\*    }"

RECURSIVE DefaultHash(_)
DefaultHash(level) ==
    IF level = 0 THEN EMPTY
    ELSE LET prev == DefaultHash(level - 1)
         IN Hash(prev, prev)

(* ======================================== *)
(*           TREE COMPUTATION               *)
(* ======================================== *)
\*
\* Full tree rebuild from entries. This is the REFERENCE TRUTH used
\* for invariant checking. State transitions use the incremental
\* WalkUp algorithm instead (O(depth) vs O(2^depth)).
\*
\* [Source: RU-V1 SparseMerkleTree, ComputeNode/ComputeRoot]

\* Look up the value of a leaf by its index.
\* Keys not in the active set are always EMPTY.
EntryValue(e, idx) == IF idx \in DOMAIN(e) THEN e[idx] ELSE EMPTY

\* Recursively compute the hash of the node at (level, index)
\* by hashing its two children.
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
\* [Source: 0-input/code/state_transition_verifier.circom, lines 27-46]
\*   MerklePathVerifier: walks from leaf to root using sibling hashes
\*   and path direction bits.

\* Extract the direction bit at a given level for a key.
\* 0 = left child, 1 = right child.
\* [Source: 0-input/code/state_transition_verifier.circom, line 33]
\*   "muxLeft[i].s <== pathBits[i]"
PathBit(key, level) == (key \div Pow2(level)) % 2

\* Compute the index of the sibling node at a given level.
SiblingIndex(key, level) ==
    LET ancestorIdx == key \div Pow2(level)
    IN IF ancestorIdx % 2 = 0
       THEN ancestorIdx + 1
       ELSE ancestorIdx - 1

\* Compute the hash of the sibling subtree at a given level.
SiblingHash(e, key, level) ==
    ComputeNode(e, level, SiblingIndex(key, level))

(* ======================================== *)
(*     INCREMENTAL ROOT RECOMPUTATION       *)
(* ======================================== *)
\*
\* After modifying a single leaf, recompute the root by walking up
\* from the new leaf hash using sibling hashes from the current tree.
\* The siblings are OFF-PATH and unchanged by the current update.
\*
\* This directly models the circuit's MerklePathVerifier:
\* [Source: 0-input/code/state_transition_verifier.circom, lines 220-243]
\*   "oldPathVerifiers[i] = MerklePathVerifier(depth);
\*    oldPathVerifiers[i].leaf <== oldLeafHashers[i].out;
\*    ...
\*    newPathVerifiers[i] = MerklePathVerifier(depth);
\*    newPathVerifiers[i].leaf <== newLeafHashers[i].out;
\*    ...
\*    chainedRoots[i + 1] <== newPathVerifiers[i].root;"
\*
\* The circuit uses the SAME siblings for both old and new path
\* verification. This is correct because only the leaf changes;
\* all siblings (off-path subtrees) remain identical.

RECURSIVE WalkUp(_, _, _, _)
WalkUp(treeEntries, currentHash, key, level) ==
    IF level = DEPTH
    THEN currentHash
    ELSE LET bit     == PathBit(key, level)
             sibling == SiblingHash(treeEntries, key, level)
             parent  == IF bit = 0
                        THEN Hash(currentHash, sibling)
                        ELSE Hash(sibling, currentHash)
         IN WalkUp(treeEntries, parent, key, level + 1)

(* ======================================== *)
(*           VARIABLES                      *)
(* ======================================== *)

VARIABLES
    trees,      \* [Enterprises -> TreeState] -- SMT key-value entries per enterprise
    roots       \* [Enterprises -> Nat] -- Merkle root per enterprise (maintained by WalkUp)

vars == << trees, roots >>

(* ======================================== *)
(*           TYPE INVARIANT                 *)
(* ======================================== *)

TypeOK ==
    /\ trees \in [Enterprises -> TreeState]
    /\ roots \in [Enterprises -> Nat]

(* ======================================== *)
(*           INITIAL STATE                  *)
(* ======================================== *)
\*
\* All enterprises start with empty trees. The root is the default
\* hash for an all-empty tree of the configured depth.
\*
\* [Source: 0-input/code/generate_input.js, lines 103-113]
\*   "const tree = new WitnessSMT(poseidon, F, DEPTH);
\*    const prevStateRoot = tree.getRoot().toString();"

Init ==
    /\ trees = [e \in Enterprises |-> [k \in Keys |-> EMPTY]]
    /\ roots = [e \in Enterprises |-> DefaultHash(DEPTH)]

(* ======================================== *)
(*           TRANSACTION APPLICATION        *)
(* ======================================== *)
\*
\* A transaction updates a single key-value pair in an enterprise's SMT.
\*
\* The "valid Merkle proof" check is abstracted as: tree[key] = oldValue.
\* This abstraction is justified by the SoundnessInvariant verified in
\* RU-V1: a Merkle proof for (key, value) against a root succeeds if and
\* only if tree[key] = value. Therefore, checking tree[key] = oldValue is
\* equivalent to requiring a valid Merkle proof.
\*
\* [Source: 0-input/code/state_transition_verifier.circom, lines 59-105]
\*   SingleStateTransition template:
\*   - Computes oldLeafHash = Poseidon(key, oldValue)
\*   - Verifies old Merkle path against current root
\*   - Computes newLeafHash = Poseidon(key, newValue)
\*   - Computes new root from new leaf + same siblings
\*   - Constrains: oldPathVerifier.root == oldRoot
\*   - Constrains: newPathVerifier.root == newRoot

ApplyTx(treeEntries, currentRoot, tx) ==
    IF treeEntries[tx.key] = tx.oldValue
    THEN LET newEntries  == [treeEntries EXCEPT ![tx.key] = tx.newValue]
             newLeafHash == LeafHash(tx.key, tx.newValue)
             newRoot     == WalkUp(treeEntries, newLeafHash, tx.key, 0)
         IN [valid |-> TRUE, tree |-> newEntries, root |-> newRoot]
    ELSE [valid |-> FALSE, tree |-> treeEntries, root |-> currentRoot]

\* Apply a batch of transactions sequentially, chaining intermediate roots.
\* Each transaction operates on the tree state resulting from all previous
\* transactions in the batch, mirroring the circuit's chainedRoots mechanism.
\*
\* [Source: 0-input/code/state_transition_verifier.circom, lines 185-251]
\*   "chainedRoots[0] <== prevStateRoot;
\*    ...
\*    chainedRoots[i + 1] <== newPathVerifiers[i].root;"
\*
\* The circuit chains roots: the new root from tx[i] becomes the expected
\* old root for tx[i+1]. In this TLA+ model, we chain both the tree state
\* AND the root, which is strictly more informative.

RECURSIVE ApplyBatch(_, _, _)
ApplyBatch(treeEntries, currentRoot, txs) ==
    IF Len(txs) = 0
    THEN [valid |-> TRUE, tree |-> treeEntries, root |-> currentRoot]
    ELSE LET result == ApplyTx(treeEntries, currentRoot, Head(txs))
         IN IF ~result.valid
            THEN [valid |-> FALSE, tree |-> treeEntries, root |-> currentRoot]
            ELSE ApplyBatch(result.tree, result.root, Tail(txs))

(* ======================================== *)
(*           ACTIONS                        *)
(* ======================================== *)

\* StateTransition: A valid batch is verified and applied.
\*
\* Models the successful execution of ChainedBatchStateTransition:
\* all transactions have valid Merkle proofs against their respective
\* intermediate states, and the final root is accepted.
\*
\* The enterprise's tree and root are updated atomically. Other
\* enterprises' state is unchanged (enterprise isolation).
\*
\* [Source: 0-input/code/state_transition_verifier.circom, lines 185-251]
\* [Source: 0-input/REPORT.md, "Circuit Design: ChainedBatchStateTransition"]
StateTransition(e, txBatch) ==
    /\ e \in Enterprises
    /\ Len(txBatch) >= 1
    /\ Len(txBatch) <= MaxBatchSize
    /\ LET result == ApplyBatch(trees[e], roots[e], txBatch)
       IN /\ result.valid
          /\ trees' = [trees EXCEPT ![e] = result.tree]
          /\ roots' = [roots EXCEPT ![e] = result.root]

\* RejectInvalid: An invalid batch is rejected with no state change.
\*
\* Models a batch where at least one transaction has an invalid Merkle
\* proof (claimed oldValue does not match actual tree state). The ZK
\* circuit verification fails, and no state is modified.
\*
\* This action is a stutter step (UNCHANGED vars). It is included for
\* specification completeness: the model explicitly represents both the
\* acceptance and rejection paths of the verification circuit.
\*
\* [Source: 0-input/README.md, Objective 2 -- "ProofSoundness"]
RejectInvalid(e, txBatch) ==
    /\ e \in Enterprises
    /\ Len(txBatch) >= 1
    /\ Len(txBatch) <= MaxBatchSize
    /\ LET result == ApplyBatch(trees[e], roots[e], txBatch)
       IN ~result.valid
    /\ UNCHANGED vars

(* ======================================== *)
(*           NEXT-STATE RELATION            *)
(* ======================================== *)

\* Transaction record: a single key-value update.
\* Models the private inputs to SingleStateTransition in the circuit.
Tx == [key: Keys, oldValue: Values \cup {EMPTY}, newValue: Values \cup {EMPTY}]

\* All non-empty sequences of transactions up to MaxBatchSize.
BatchSeq == UNION {[1..n -> Tx] : n \in 1..MaxBatchSize}

Next ==
    \E e \in Enterprises, batch \in BatchSeq :
        \/ StateTransition(e, batch)
        \/ RejectInvalid(e, batch)

(* ======================================== *)
(*           SPECIFICATION                  *)
(* ======================================== *)

Spec == Init /\ [][Next]_vars

(* ======================================== *)
(*           SAFETY PROPERTIES              *)
(* ======================================== *)

\* STATE ROOT CHAIN INVARIANT
\* [Why]: The Merkle root published for each enterprise must be a
\*        deterministic function of the enterprise's actual tree contents.
\*        This is the CORE correctness property of the state transition
\*        protocol.
\*
\*        It verifies that the incremental root computation (WalkUp)
\*        applied across a CHAINED BATCH of transactions produces the
\*        same result as a full tree rebuild (ComputeRoot). This extends
\*        the ConsistencyInvariant from RU-V1 (single-operation) to
\*        multi-operation chained batches -- the novel verification
\*        target of RU-V2.
\*
\*        If this invariant fails, either:
\*        (a) WalkUp diverges from ComputeRoot when chained across
\*            multiple transactions (chaining bug), or
\*        (b) The tree state was updated without a corresponding root
\*            update (state corruption), or
\*        (c) The root was updated without a corresponding tree state
\*            update (phantom transition).
\*
\* [Source: 0-input/README.md, Objective 2 -- "StateRootChain"]
\* [Source: 0-input/code/state_transition_verifier.circom, lines 246-250]
\*   "finalCheck: chainedRoots[batchSize] == newStateRoot"
StateRootChain == \A e \in Enterprises : roots[e] = ComputeRoot(trees[e])

\* BATCH INTEGRITY INVARIANT
\* [Why]: For any valid single-transaction transition from the current
\*        state, the incremental root (WalkUp) must match the full
\*        rebuild (ComputeRoot). This verifies per-transaction Merkle
\*        proof integrity at every reachable state.
\*
\*        While StateRootChain checks the FINAL root after a batch,
\*        this invariant checks that EACH INDIVIDUAL WalkUp operation
\*        is correct at every state the system can reach -- including
\*        intermediate states produced by prior batch applications.
\*        If WalkUp gives incorrect results at any intermediate state,
\*        subsequent chained transactions would propagate the error.
\*
\*        Together with StateRootChain, this provides full coverage:
\*        StateRootChain verifies end-to-end batch correctness, and
\*        BatchIntegrity verifies per-step correctness.
\*
\* [Source: 0-input/README.md, Objective 2 -- "BatchIntegrity"]
\* [Source: 0-input/code/state_transition_verifier.circom, lines 228-232]
\*   "oldRootChecks[i]: oldPathVerifiers[i].root == chainedRoots[i]"
BatchIntegrity ==
    \A e \in Enterprises :
        \A k \in Keys :
            \A v \in Values \cup {EMPTY} :
                LET currentVal == trees[e][k]
                    tx == [key |-> k, oldValue |-> currentVal, newValue |-> v]
                    result == ApplyTx(trees[e], roots[e], tx)
                IN result.valid => result.root = ComputeRoot(result.tree)

\* PROOF SOUNDNESS INVARIANT
\* [Why]: A transaction claiming a wrong old value (i.e., presenting an
\*        invalid Merkle proof) must ALWAYS be rejected. At every
\*        reachable state, for every enterprise, key, and incorrect old
\*        value, the verification must fail.
\*
\*        This is the abstract equivalent of the circuit's Merkle path
\*        constraint: if oldPathVerifier.root != chainedRoot, the
\*        IsEqual check forces the circuit to be unsatisfiable, making
\*        it impossible to generate a valid ZK proof.
\*
\*        The invariant checks this at every reachable state to ensure
\*        no sequence of valid transitions can lead to a state where
\*        the proof check is bypassable.
\*
\* [Source: 0-input/README.md, Objective 2 -- "ProofSoundness"]
\* [Source: 0-input/code/state_transition_verifier.circom, lines 96-98]
\*   "checkOldRoot.out === 1" (old path root must equal expected root)
ProofSoundness ==
    \A e \in Enterprises :
        \A k \in Keys :
            \A wrongVal \in (Values \cup {EMPTY}) \ {trees[e][k]} :
                LET tx == [key |-> k, oldValue |-> wrongVal, newValue |-> EMPTY]
                    result == ApplyTx(trees[e], roots[e], tx)
                IN ~result.valid

====
