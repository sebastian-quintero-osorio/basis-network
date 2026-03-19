pragma circom 2.0.0;

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/comparators.circom";
include "../node_modules/circomlib/circuits/bitify.circom";
include "merkle_proof_verifier.circom";

/// StateTransition: Proves a batch of sequential state transitions in a Sparse Merkle Tree.
///
/// Each transaction updates one key-value pair in the enterprise's SMT. The state root
/// after transaction i becomes the input state root for transaction i+1, creating a
/// verifiable chain: prevStateRoot -> tx0 -> tx1 -> ... -> newStateRoot.
///
/// Path bits are derived from keys via Num2Bits decomposition rather than provided as
/// inputs. This prevents the prover from supplying inconsistent path directions and
/// reduces the witness size by depth * batchSize field elements.
///
/// Verified invariants from the TLA+ specification:
///   StateRootChain  -- Final chained root equals ComputeRoot of the resulting tree
///   BatchIntegrity  -- Each per-tx WalkUp agrees with ComputeRoot at every reachable state
///   ProofSoundness  -- Wrong oldValue always causes circuit unsatisfiability
///
/// [Spec: validium/specs/units/2026-03-state-transition-circuit/1-formalization/v0-analysis/specs/StateTransitionCircuit/StateTransitionCircuit.tla]
///
/// @param depth     The depth of the Sparse Merkle Tree (capacity: 2^depth leaves).
/// @param batchSize The number of transactions in the batch.
template StateTransition(depth, batchSize) {
    // -- Public inputs --
    signal input prevStateRoot;     // Root before batch application
    signal input newStateRoot;      // Root after batch application
    signal input batchNum;          // Batch sequence number (on-chain identification)
    signal input enterpriseId;      // Enterprise identifier (enterprise isolation)

    // -- Private inputs (witness) --
    // [Spec: Tx == [key: Keys, oldValue: Values \cup {EMPTY}, newValue: Values \cup {EMPTY}]]
    signal input txKeys[batchSize];
    signal input txOldValues[batchSize];
    signal input txNewValues[batchSize];
    signal input txSiblings[batchSize][depth];

    // -- Per-transaction components --
    component keyBits[batchSize];
    component oldLeafHashers[batchSize];
    component newLeafHashers[batchSize];
    component oldPathVerifiers[batchSize];
    component newPathVerifiers[batchSize];
    component oldRootChecks[batchSize];

    // -- Chain of state roots --
    // chainedRoots[0] = prevStateRoot
    // chainedRoots[batchSize] must equal newStateRoot
    // [Spec: ApplyBatch chains tree state and root across sequential transactions]
    signal chainedRoots[batchSize + 1];
    chainedRoots[0] <== prevStateRoot;

    for (var i = 0; i < batchSize; i++) {
        // Step 1: Derive path bits from key (bit decomposition).
        // Num2Bits(depth) extracts the lower `depth` bits of the key.
        // Bit j corresponds to level j: 0 = left child, 1 = right child.
        // [Spec: PathBit(key, level) == (key \div Pow2(level)) % 2]
        keyBits[i] = Num2Bits(depth);
        keyBits[i].in <== txKeys[i];

        // Step 2: Compute old leaf hash = Poseidon(key, oldValue).
        // [Spec: LeafHash(key, value) == IF value = EMPTY THEN EMPTY ELSE Hash(key, value)]
        oldLeafHashers[i] = Poseidon(2);
        oldLeafHashers[i].inputs[0] <== txKeys[i];
        oldLeafHashers[i].inputs[1] <== txOldValues[i];

        // Step 3: Compute new leaf hash = Poseidon(key, newValue).
        newLeafHashers[i] = Poseidon(2);
        newLeafHashers[i].inputs[0] <== txKeys[i];
        newLeafHashers[i].inputs[1] <== txNewValues[i];

        // Step 4: Verify old Merkle path produces the current chained root.
        // This enforces: WalkUp(treeEntries, oldLeafHash, key, 0) == chainedRoots[i].
        // [Spec: ApplyTx checks treeEntries[tx.key] = tx.oldValue via Merkle proof]
        oldPathVerifiers[i] = MerkleProofVerifier(depth);
        oldPathVerifiers[i].leaf <== oldLeafHashers[i].out;
        for (var j = 0; j < depth; j++) {
            oldPathVerifiers[i].siblings[j] <== txSiblings[i][j];
            oldPathVerifiers[i].pathBits[j] <== keyBits[i].out[j];
        }

        // Step 5: Constrain old path root == current chained root.
        // If the prover provides a wrong oldValue, the computed root will differ
        // from chainedRoots[i], making the circuit unsatisfiable.
        // [Spec: ProofSoundness -- wrong oldValue always causes rejection]
        oldRootChecks[i] = IsEqual();
        oldRootChecks[i].in[0] <== oldPathVerifiers[i].root;
        oldRootChecks[i].in[1] <== chainedRoots[i];
        oldRootChecks[i].out === 1;

        // Step 6: Compute new root using same siblings but different leaf.
        // The key insight: only the leaf changes, so all off-path siblings
        // remain identical. The new root is WalkUp with newLeafHash.
        // [Spec: newRoot == WalkUp(treeEntries, newLeafHash, tx.key, 0)]
        newPathVerifiers[i] = MerkleProofVerifier(depth);
        newPathVerifiers[i].leaf <== newLeafHashers[i].out;
        for (var j = 0; j < depth; j++) {
            newPathVerifiers[i].siblings[j] <== txSiblings[i][j];
            newPathVerifiers[i].pathBits[j] <== keyBits[i].out[j];
        }

        // Step 7: Chain the new root to the next transaction.
        // [Spec: chainedRoots[i+1] <== newPathVerifiers[i].root]
        chainedRoots[i + 1] <== newPathVerifiers[i].root;
    }

    // -- Final root verification --
    // The last chained root must equal the declared newStateRoot.
    // [Spec: StateRootChain invariant -- roots[e] = ComputeRoot(trees[e])]
    component finalCheck = IsEqual();
    finalCheck.in[0] <== chainedRoots[batchSize];
    finalCheck.in[1] <== newStateRoot;
    finalCheck.out === 1;
}

// Default instantiation for testing: depth 10 (1024 leaves), batch 4.
// Production target: depth 32 (4.3B leaves), batch 16-64.
// Constraint formula: ~1,038 * (depth + 1) * batchSize + depth * batchSize (Num2Bits)
component main {public [prevStateRoot, newStateRoot, batchNum, enterpriseId]} = StateTransition(10, 4);
