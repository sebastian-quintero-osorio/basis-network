pragma circom 2.0.0;

include "../../../../circuits/node_modules/circomlib/circuits/poseidon.circom";
include "../../../../circuits/node_modules/circomlib/circuits/comparators.circom";
include "../../../../circuits/node_modules/circomlib/circuits/mux1.circom";

/// MerklePathVerifier: Verifies a Merkle inclusion proof using Poseidon hash.
///
/// Given a leaf hash, a path of sibling hashes, and path direction bits,
/// computes the root by hashing up the tree and outputs the computed root.
///
/// @param depth The depth of the Merkle tree (number of levels).
template MerklePathVerifier(depth) {
    signal input leaf;
    signal input siblings[depth];
    signal input pathBits[depth]; // 0 = leaf is left child, 1 = leaf is right child

    signal output root;

    signal intermediateHashes[depth + 1];
    intermediateHashes[0] <== leaf;

    component hashers[depth];
    component muxLeft[depth];
    component muxRight[depth];

    for (var i = 0; i < depth; i++) {
        // Select left and right inputs based on path bit
        muxLeft[i] = Mux1();
        muxLeft[i].c[0] <== intermediateHashes[i];
        muxLeft[i].c[1] <== siblings[i];
        muxLeft[i].s <== pathBits[i];

        muxRight[i] = Mux1();
        muxRight[i].c[0] <== siblings[i];
        muxRight[i].c[1] <== intermediateHashes[i];
        muxRight[i].s <== pathBits[i];

        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== muxLeft[i].out;
        hashers[i].inputs[1] <== muxRight[i].out;

        intermediateHashes[i + 1] <== hashers[i].out;
    }

    root <== intermediateHashes[depth];
}

/// SingleStateTransition: Proves one state transition in a Sparse Merkle Tree.
///
/// Verifies that:
/// 1. The old leaf (key, oldValue) exists at the given path in the tree with oldRoot
/// 2. Replacing oldValue with newValue at the same path produces newRoot
///
/// The key insight is that both old and new proofs share the SAME siblings --
/// only the leaf value changes, which propagates new hashes up the path.
///
/// @param depth The depth of the Sparse Merkle Tree.
template SingleStateTransition(depth) {
    signal input oldRoot;
    signal input newRoot;
    signal input key;
    signal input oldValue;
    signal input newValue;
    signal input siblings[depth];
    signal input pathBits[depth];

    // Compute old leaf hash: H(key, oldValue)
    component oldLeafHash = Poseidon(2);
    oldLeafHash.inputs[0] <== key;
    oldLeafHash.inputs[1] <== oldValue;

    // Compute new leaf hash: H(key, newValue)
    component newLeafHash = Poseidon(2);
    newLeafHash.inputs[0] <== key;
    newLeafHash.inputs[1] <== newValue;

    // Verify old Merkle path
    component oldPathVerifier = MerklePathVerifier(depth);
    oldPathVerifier.leaf <== oldLeafHash.out;
    for (var i = 0; i < depth; i++) {
        oldPathVerifier.siblings[i] <== siblings[i];
        oldPathVerifier.pathBits[i] <== pathBits[i];
    }

    // Verify new Merkle path (same siblings, different leaf)
    component newPathVerifier = MerklePathVerifier(depth);
    newPathVerifier.leaf <== newLeafHash.out;
    for (var i = 0; i < depth; i++) {
        newPathVerifier.siblings[i] <== siblings[i];
        newPathVerifier.pathBits[i] <== pathBits[i];
    }

    // Constrain: computed old root must match provided old root
    component checkOldRoot = IsEqual();
    checkOldRoot.in[0] <== oldPathVerifier.root;
    checkOldRoot.in[1] <== oldRoot;
    checkOldRoot.out === 1;

    // Constrain: computed new root must match provided new root
    component checkNewRoot = IsEqual();
    checkNewRoot.in[0] <== newPathVerifier.root;
    checkNewRoot.in[1] <== newRoot;
    checkNewRoot.out === 1;
}

/// BatchStateTransition: Proves a batch of sequential state transitions.
///
/// Each transaction updates one key-value pair in the SMT. The state root
/// after transaction i becomes the input state root for transaction i+1.
/// This creates a verifiable chain: prevStateRoot -> tx0 -> tx1 -> ... -> newStateRoot.
///
/// Public inputs: prevStateRoot, newStateRoot, batchSize, enterpriseId
/// Private inputs: per-tx keys, values, siblings, pathBits
///
/// @param depth The depth of the Sparse Merkle Tree.
/// @param batchSize The number of transactions in the batch.
template BatchStateTransition(depth, batchSize) {
    // Public inputs
    signal input prevStateRoot;
    signal input newStateRoot;
    signal input batchNum;
    signal input enterpriseId;

    // Per-transaction private inputs
    signal input keys[batchSize];
    signal input oldValues[batchSize];
    signal input newValues[batchSize];
    signal input siblings[batchSize][depth];
    signal input pathBits[batchSize][depth];

    // Intermediate state roots (chain of roots)
    signal intermediateRoots[batchSize + 1];
    intermediateRoots[0] <== prevStateRoot;

    // Process each transaction
    component txTransitions[batchSize];

    for (var i = 0; i < batchSize; i++) {
        txTransitions[i] = SingleStateTransition(depth);
        txTransitions[i].oldRoot <== intermediateRoots[i];
        txTransitions[i].key <== keys[i];
        txTransitions[i].oldValue <== oldValues[i];
        txTransitions[i].newValue <== newValues[i];

        for (var j = 0; j < depth; j++) {
            txTransitions[i].siblings[j] <== siblings[i][j];
            txTransitions[i].pathBits[j] <== pathBits[i][j];
        }

        // The new root from this tx is passed as input (not computed in-circuit
        // as intermediate -- we verify it matches)
        // Actually, we compute it: newPathVerifier.root IS the new root
        // But we need to extract it. Let's chain via the newRoot signal.
        // The SingleStateTransition already constrains newRoot to match.
        // We need the newRoot to be an intermediate signal we can chain.
    }

    // We need to redesign: SingleStateTransition constrains newRoot as input.
    // For chaining, we need to COMPUTE newRoot and pass it along.
    // This is handled by having intermediateRoots computed from the path verifiers.
    // Let's use a different approach: trust the new root output from path verification.

    // Actually the cleanest approach: just require intermediate roots as inputs
    // and verify each transition. The circuit already constrains consistency.

    // Chain verification: final root must match newStateRoot
    component finalRootCheck = IsEqual();
    finalRootCheck.in[0] <== intermediateRoots[batchSize];
    finalRootCheck.in[1] <== newStateRoot;
    finalRootCheck.out === 1;
}

// NOTE: The above BatchStateTransition has a design issue with intermediate root chaining.
// The correct approach is below: ChainedBatchStateTransition.

/// ChainedBatchStateTransition: Correct batch state transition with root chaining.
///
/// Instead of constraining newRoot as an input, we COMPUTE it from the Merkle path
/// and chain it to the next transaction's oldRoot. This ensures the entire batch
/// forms a valid state transition chain.
///
/// @param depth The depth of the Sparse Merkle Tree.
/// @param batchSize The number of transactions in the batch.
template ChainedBatchStateTransition(depth, batchSize) {
    // Public inputs
    signal input prevStateRoot;
    signal input newStateRoot;
    signal input batchNum;
    signal input enterpriseId;

    // Per-transaction private inputs
    signal input keys[batchSize];
    signal input oldValues[batchSize];
    signal input newValues[batchSize];
    signal input siblings[batchSize][depth];
    signal input pathBits[batchSize][depth];

    // Per-transaction: compute old leaf, new leaf, verify old path, compute new root
    component oldLeafHashers[batchSize];
    component newLeafHashers[batchSize];
    component oldPathVerifiers[batchSize];
    component newPathVerifiers[batchSize];
    component oldRootChecks[batchSize];

    // Chain of state roots
    signal chainedRoots[batchSize + 1];
    chainedRoots[0] <== prevStateRoot;

    for (var i = 0; i < batchSize; i++) {
        // Compute leaf hashes
        oldLeafHashers[i] = Poseidon(2);
        oldLeafHashers[i].inputs[0] <== keys[i];
        oldLeafHashers[i].inputs[1] <== oldValues[i];

        newLeafHashers[i] = Poseidon(2);
        newLeafHashers[i].inputs[0] <== keys[i];
        newLeafHashers[i].inputs[1] <== newValues[i];

        // Verify old Merkle path produces the chained root
        oldPathVerifiers[i] = MerklePathVerifier(depth);
        oldPathVerifiers[i].leaf <== oldLeafHashers[i].out;
        for (var j = 0; j < depth; j++) {
            oldPathVerifiers[i].siblings[j] <== siblings[i][j];
            oldPathVerifiers[i].pathBits[j] <== pathBits[i][j];
        }

        // Check: old path root == current chained root
        oldRootChecks[i] = IsEqual();
        oldRootChecks[i].in[0] <== oldPathVerifiers[i].root;
        oldRootChecks[i].in[1] <== chainedRoots[i];
        oldRootChecks[i].out === 1;

        // Compute new root (same siblings, different leaf)
        newPathVerifiers[i] = MerklePathVerifier(depth);
        newPathVerifiers[i].leaf <== newLeafHashers[i].out;
        for (var j = 0; j < depth; j++) {
            newPathVerifiers[i].siblings[j] <== siblings[i][j];
            newPathVerifiers[i].pathBits[j] <== pathBits[i][j];
        }

        // Chain: new root becomes next tx's old root
        chainedRoots[i + 1] <== newPathVerifiers[i].root;
    }

    // Final root must match the declared newStateRoot
    component finalCheck = IsEqual();
    finalCheck.in[0] <== chainedRoots[batchSize];
    finalCheck.in[1] <== newStateRoot;
    finalCheck.out === 1;
}

// Instantiate with small parameters for benchmarking.
// Depth 10 for faster compilation; batch size 4 for PoC.
// Production target: depth 32, batch 64.
component main {public [prevStateRoot, newStateRoot, batchNum, enterpriseId]} = ChainedBatchStateTransition(10, 4);
