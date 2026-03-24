pragma circom 2.0.0;

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/comparators.circom";
include "../node_modules/circomlib/circuits/mux1.circom";
include "../node_modules/circomlib/circuits/bitify.circom";

/// MerklePathVerifier: Reconstructs a Merkle root from a leaf and sibling path.
///
/// Given a leaf value, an array of sibling hashes, and path direction bits,
/// computes the Merkle root by hashing pairs from leaf to root.
///
/// @param depth The tree depth (number of hash levels).
template MerklePathVerifier(depth) {
    signal input leaf;
    signal input siblings[depth];
    signal input pathBits[depth];
    signal output root;

    signal intermediateHashes[depth + 1];
    intermediateHashes[0] <== leaf;

    component hashers[depth];
    component muxLeft[depth];
    component muxRight[depth];

    for (var i = 0; i < depth; i++) {
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

/// ChainedBatchStateTransition: Proves a batch of sequential SMT state transitions.
///
/// Each transaction updates one key-value pair in the enterprise's Sparse Merkle Tree.
/// The state root after transaction i becomes the input for transaction i+1, forming
/// a verifiable chain: prevStateRoot -> tx0 -> tx1 -> ... -> newStateRoot.
///
/// EMPTY leaf convention:
///   When value = 0, the leaf hash is 0 (EMPTY), NOT Poseidon(key, 0).
///   This matches the TypeScript SMT implementation where defaultHashes[0] = 0
///   and empty leaf positions store 0. The IsZero + Mux1 conditional handles this:
///     leaf = (value == 0) ? 0 : Poseidon(key, value)
///
/// For padding (identity transitions): key=0, oldValue=0, newValue=0.
///   Both old and new leaves are 0, and the Merkle path verification produces
///   the same root. The prover must supply real siblings from the current tree
///   state at key=0 for padding slots.
///
/// Verified invariants from the TLA+ specification:
///   StateRootChain  -- Final chained root equals ComputeRoot of the resulting tree
///   BatchIntegrity  -- Each per-tx WalkUp agrees with ComputeRoot at every reachable state
///   ProofSoundness  -- Wrong oldValue always causes circuit unsatisfiability
///
/// [Spec: validium/specs/units/2026-03-state-transition-circuit]
///
/// @param depth     The depth of the Sparse Merkle Tree (capacity: 2^depth leaves).
/// @param batchSize The number of transactions in the batch (including padding).
template ChainedBatchStateTransition(depth, batchSize) {
    // -- Public inputs --
    signal input prevStateRoot;
    signal input newStateRoot;
    signal input batchNum;
    signal input enterpriseId;

    // -- Private inputs (witness) --
    signal input keys[batchSize];
    signal input oldValues[batchSize];
    signal input newValues[batchSize];
    signal input siblings[batchSize][depth];
    signal input pathBits[batchSize][depth];

    // -- Per-transaction components --
    component oldLeafHashers[batchSize];
    component newLeafHashers[batchSize];
    component oldIsZero[batchSize];
    component newIsZero[batchSize];
    component oldLeafMux[batchSize];
    component newLeafMux[batchSize];
    component oldPathVerifiers[batchSize];
    component newPathVerifiers[batchSize];
    component oldRootChecks[batchSize];

    signal oldLeaf[batchSize];
    signal newLeaf[batchSize];

    // -- Chain of state roots --
    signal chainedRoots[batchSize + 1];
    chainedRoots[0] <== prevStateRoot;

    for (var i = 0; i < batchSize; i++) {
        // Step 1: Compute Poseidon(key, oldValue) -- always computed, may not be used.
        oldLeafHashers[i] = Poseidon(2);
        oldLeafHashers[i].inputs[0] <== keys[i];
        oldLeafHashers[i].inputs[1] <== oldValues[i];

        // Step 2: EMPTY leaf handling -- if oldValue == 0, leaf = 0 (not Poseidon(key, 0)).
        oldIsZero[i] = IsZero();
        oldIsZero[i].in <== oldValues[i];

        oldLeafMux[i] = Mux1();
        oldLeafMux[i].c[0] <== oldLeafHashers[i].out;
        oldLeafMux[i].c[1] <== 0;
        oldLeafMux[i].s <== oldIsZero[i].out;
        oldLeaf[i] <== oldLeafMux[i].out;

        // Step 3: Same for new leaf.
        newLeafHashers[i] = Poseidon(2);
        newLeafHashers[i].inputs[0] <== keys[i];
        newLeafHashers[i].inputs[1] <== newValues[i];

        newIsZero[i] = IsZero();
        newIsZero[i].in <== newValues[i];

        newLeafMux[i] = Mux1();
        newLeafMux[i].c[0] <== newLeafHashers[i].out;
        newLeafMux[i].c[1] <== 0;
        newLeafMux[i].s <== newIsZero[i].out;
        newLeaf[i] <== newLeafMux[i].out;

        // Step 4: Verify old Merkle path produces the current chained root.
        oldPathVerifiers[i] = MerklePathVerifier(depth);
        oldPathVerifiers[i].leaf <== oldLeaf[i];
        for (var j = 0; j < depth; j++) {
            oldPathVerifiers[i].siblings[j] <== siblings[i][j];
            oldPathVerifiers[i].pathBits[j] <== pathBits[i][j];
        }

        // Step 5: Constrain old path root == current chained root.
        oldRootChecks[i] = IsEqual();
        oldRootChecks[i].in[0] <== oldPathVerifiers[i].root;
        oldRootChecks[i].in[1] <== chainedRoots[i];
        oldRootChecks[i].out === 1;

        // Step 6: Compute new root using same siblings but new leaf.
        newPathVerifiers[i] = MerklePathVerifier(depth);
        newPathVerifiers[i].leaf <== newLeaf[i];
        for (var j = 0; j < depth; j++) {
            newPathVerifiers[i].siblings[j] <== siblings[i][j];
            newPathVerifiers[i].pathBits[j] <== pathBits[i][j];
        }

        // Step 7: Chain the new root to the next transaction.
        chainedRoots[i + 1] <== newPathVerifiers[i].root;
    }

    // -- Final root verification --
    component finalCheck = IsEqual();
    finalCheck.in[0] <== chainedRoots[batchSize];
    finalCheck.in[1] <== newStateRoot;
    finalCheck.out === 1;
}

// Production instantiation: depth 32 (4.3B leaves), batch 8.
// ~274K constraints. Requires pot19 (2^19 = 524,288) for trusted setup.
component main {public [prevStateRoot, newStateRoot, batchNum, enterpriseId]} = ChainedBatchStateTransition(32, 8);
