pragma circom 2.0.0;

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/mux1.circom";

/// MerkleProofVerifier: Verifies a Merkle inclusion proof using Poseidon hash.
///
/// Given a leaf hash, a path of sibling hashes, and path direction bits,
/// computes the Merkle root by hashing up the tree. At each level, the
/// path bit determines ordering: 0 = current node is left child,
/// 1 = current node is right child.
///
/// This directly models the TLA+ WalkUp operator:
///   WalkUp(treeEntries, currentHash, key, level) ==
///     IF level = DEPTH THEN currentHash
///     ELSE LET bit = PathBit(key, level)
///              sibling = SiblingHash(treeEntries, key, level)
///              parent = IF bit = 0 THEN Hash(currentHash, sibling)
///                                  ELSE Hash(sibling, currentHash)
///          IN WalkUp(treeEntries, parent, key, level + 1)
///
/// [Spec: validium/specs/units/2026-03-state-transition-circuit/1-formalization/v0-analysis/specs/StateTransitionCircuit/StateTransitionCircuit.tla]
///
/// @param depth The depth of the Merkle tree (number of levels from leaf to root).
template MerkleProofVerifier(depth) {
    signal input leaf;
    signal input siblings[depth];
    signal input pathBits[depth]; // 0 = left child, 1 = right child

    signal output root;

    signal intermediateHashes[depth + 1];
    intermediateHashes[0] <== leaf;

    component hashers[depth];
    component muxLeft[depth];
    component muxRight[depth];

    for (var i = 0; i < depth; i++) {
        // Select left and right inputs based on path bit.
        // If pathBit = 0: current is left, sibling is right.
        // If pathBit = 1: sibling is left, current is right.
        // [Spec: PathBit(key, level) determines child position]
        muxLeft[i] = Mux1();
        muxLeft[i].c[0] <== intermediateHashes[i];
        muxLeft[i].c[1] <== siblings[i];
        muxLeft[i].s <== pathBits[i];

        muxRight[i] = Mux1();
        muxRight[i].c[0] <== siblings[i];
        muxRight[i].c[1] <== intermediateHashes[i];
        muxRight[i].s <== pathBits[i];

        // Hash(left, right) using Poseidon 2-to-1
        // [Spec: Hash(a, b) models Poseidon(2) over BN128 scalar field]
        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== muxLeft[i].out;
        hashers[i].inputs[1] <== muxRight[i].out;

        intermediateHashes[i + 1] <== hashers[i].out;
    }

    root <== intermediateHashes[depth];
}
