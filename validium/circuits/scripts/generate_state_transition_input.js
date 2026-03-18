/// generate_state_transition_input.js -- Generate valid witness inputs for the StateTransition circuit.
///
/// Builds a Sparse Merkle Tree using circomlibjs Poseidon, performs a batch of
/// state transitions, and captures Merkle proofs for each transaction. The output
/// JSON matches the circuit's signal names exactly.
///
/// The circuit derives pathBits from keys internally (Num2Bits), so pathBits are
/// NOT included in the output. This is a security improvement over providing them
/// as inputs: the prover cannot supply inconsistent path directions.
///
/// Usage: node generate_state_transition_input.js [depth] [batchSize] [outputPath]
///   depth:      Merkle tree depth (default: 10)
///   batchSize:  Number of transactions (default: 4)
///   outputPath: Where to write the JSON (default: build/state_transition/input.json)
///
/// [Spec: validium/specs/units/2026-03-state-transition-circuit/1-formalization/v0-analysis/specs/StateTransitionCircuit/StateTransitionCircuit.tla]

const { buildPoseidon } = require("circomlibjs");
const fs = require("fs");
const path = require("path");

const DEPTH = parseInt(process.argv[2]) || 10;
const BATCH_SIZE = parseInt(process.argv[3]) || 4;
const OUTPUT_PATH = process.argv[4] || path.join(
    __dirname, "..", "build", "state_transition", "input.json"
);

/// Minimal Sparse Merkle Tree for witness generation.
/// Stores nodes keyed by "level:index" strings. Uses Poseidon 2-to-1 hashing.
///
/// [Spec: ComputeNode(e, level, index) -- full tree computation]
/// [Spec: WalkUp(treeEntries, currentHash, key, level) -- incremental path recomputation]
class WitnessSMT {
    constructor(poseidon, F, depth) {
        this.poseidon = poseidon;
        this.F = F;
        this.depth = depth;
        this.nodes = new Map();
        this.defaultHashes = this._computeDefaultHashes();
    }

    /// Pre-compute hashes for all-empty subtrees at each level.
    /// [Spec: DefaultHash(level) == IF level = 0 THEN EMPTY ELSE Hash(prev, prev)]
    _computeDefaultHashes() {
        const defaults = new Array(this.depth + 1);
        defaults[0] = BigInt(0);
        for (let i = 1; i <= this.depth; i++) {
            const h = this.poseidon([defaults[i - 1], defaults[i - 1]]);
            defaults[i] = this.F.toObject(h);
        }
        return defaults;
    }

    _nodeKey(level, index) {
        return `${level}:${index}`;
    }

    _getNode(level, index) {
        const key = this._nodeKey(level, index);
        if (this.nodes.has(key)) return this.nodes.get(key);
        return this.defaultHashes[level];
    }

    _setNode(level, index, value) {
        this.nodes.set(this._nodeKey(level, index), value);
    }

    getRoot() {
        return this._getNode(this.depth, BigInt(0));
    }

    /// Insert or update a leaf and recompute the path to root.
    /// Leaf hash = Poseidon(key, value).
    /// [Spec: LeafHash(key, value) == Hash(key, value)]
    update(key, value) {
        const leafHash = this.F.toObject(this.poseidon([key, value]));
        let index = key;

        this._setNode(0, index, leafHash);

        for (let level = 0; level < this.depth; level++) {
            const parentIndex = index >> BigInt(1);
            const isRight = index & BigInt(1);
            const siblingIndex = isRight ? index - BigInt(1) : index + BigInt(1);

            const left = isRight
                ? this._getNode(level, siblingIndex)
                : this._getNode(level, index);
            const right = isRight
                ? this._getNode(level, index)
                : this._getNode(level, siblingIndex);

            const parentHash = this.F.toObject(this.poseidon([left, right]));
            this._setNode(level + 1, parentIndex, parentHash);
            index = parentIndex;
        }
    }

    /// Get the Merkle proof (siblings only) for a given key.
    /// Path bits are derived from the key by the circuit (Num2Bits).
    /// [Spec: SiblingHash(e, key, level) -- hash of sibling subtree at each level]
    getProof(key) {
        const siblings = [];
        let index = key;

        for (let level = 0; level < this.depth; level++) {
            const isRight = index & BigInt(1);
            const siblingIndex = isRight ? index - BigInt(1) : index + BigInt(1);
            siblings.push(this._getNode(level, siblingIndex).toString());
            index = index >> BigInt(1);
        }

        return { siblings };
    }
}

async function main() {
    console.log(`Generating StateTransition input: depth=${DEPTH}, batchSize=${BATCH_SIZE}`);

    const poseidon = await buildPoseidon();
    const F = poseidon.F;
    const tree = new WitnessSMT(poseidon, F, DEPTH);

    // Pre-populate tree with initial values for the keys we will update.
    // Keys are small integers (0..BATCH_SIZE-1) that fit within depth bits.
    const maxKey = BigInt(1) << BigInt(DEPTH);
    for (let i = 0; i < BATCH_SIZE * 2; i++) {
        const key = BigInt(i) % maxKey;
        const value = BigInt(100 + i);
        tree.update(key, value);
    }

    // Record the state root before the batch.
    const prevStateRoot = tree.getRoot().toString();

    const txKeys = [];
    const txOldValues = [];
    const txNewValues = [];
    const txSiblings = [];

    // Generate batch of state transitions.
    // Each transaction updates key i from oldValue (100+i) to newValue (200+i).
    // [Spec: StateTransition(e, batch) -- atomically apply batch if all TXs valid]
    for (let i = 0; i < BATCH_SIZE; i++) {
        const key = BigInt(i) % maxKey;
        const oldValue = BigInt(100 + i);
        const newValue = BigInt(200 + i);

        // Capture Merkle proof BEFORE update (proves old value exists).
        // [Spec: ApplyTx checks treeEntries[tx.key] = tx.oldValue]
        const proof = tree.getProof(key);
        txKeys.push(key.toString());
        txOldValues.push(oldValue.toString());
        txNewValues.push(newValue.toString());
        txSiblings.push(proof.siblings);

        // Apply the update so subsequent transactions see the new state.
        // [Spec: ApplyBatch chains tree state across sequential transactions]
        tree.update(key, newValue);
    }

    // Record the state root after the batch.
    const newStateRoot = tree.getRoot().toString();

    // Build the circuit input JSON. Signal names must match the circuit exactly.
    const input = {
        prevStateRoot,
        newStateRoot,
        batchNum: "1",
        enterpriseId: "42",
        txKeys,
        txOldValues,
        txNewValues,
        txSiblings
    };

    // Write output
    const outputDir = path.dirname(OUTPUT_PATH);
    if (!fs.existsSync(outputDir)) {
        fs.mkdirSync(outputDir, { recursive: true });
    }

    fs.writeFileSync(OUTPUT_PATH, JSON.stringify(input, null, 2));
    console.log(`Input written to: ${OUTPUT_PATH}`);
    console.log(`prevStateRoot: ${prevStateRoot}`);
    console.log(`newStateRoot:  ${newStateRoot}`);
    console.log(`Transactions:  ${BATCH_SIZE}`);
}

main().catch(err => {
    console.error("Error:", err);
    process.exit(1);
});
