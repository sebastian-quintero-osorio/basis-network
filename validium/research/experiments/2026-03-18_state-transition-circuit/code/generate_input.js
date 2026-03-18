/// generate_input.js -- Generate valid witness inputs for the state transition circuit.
///
/// This script builds a real Sparse Merkle Tree using circomlibjs Poseidon,
/// performs state transitions, and captures the Merkle proofs needed as circuit inputs.
///
/// Usage: node generate_input.js <depth> <batchSize> [outputPath]

const { buildPoseidon } = require("circomlibjs");
const fs = require("fs");
const path = require("path");

const DEPTH = parseInt(process.argv[2]) || 10;
const BATCH_SIZE = parseInt(process.argv[3]) || 4;
const OUTPUT_PATH = process.argv[4] || path.join(__dirname, "..", "results", `input_d${DEPTH}_b${BATCH_SIZE}.json`);

/// Minimal Sparse Merkle Tree for witness generation.
/// Not production-grade -- just enough to generate valid Merkle proofs.
class WitnessSMT {
    constructor(poseidon, F, depth) {
        this.poseidon = poseidon;
        this.F = F;
        this.depth = depth;
        this.nodes = new Map();
        this.defaultHashes = this._computeDefaultHashes();
    }

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

    /// Insert or update a leaf. Key is used to determine the path.
    /// Leaf hash = Poseidon(key, value).
    update(key, value) {
        const leafHash = this.F.toObject(this.poseidon([key, value]));
        let index = key;

        // Set leaf
        this._setNode(0, index, leafHash);

        // Recompute path to root
        for (let level = 0; level < this.depth; level++) {
            const parentIndex = index >> BigInt(1);
            const isRight = index & BigInt(1);
            const siblingIndex = isRight ? index - BigInt(1) : index + BigInt(1);

            const left = isRight ? this._getNode(level, siblingIndex) : this._getNode(level, index);
            const right = isRight ? this._getNode(level, index) : this._getNode(level, siblingIndex);

            const parentHash = this.F.toObject(this.poseidon([left, right]));
            this._setNode(level + 1, parentIndex, parentHash);
            index = parentIndex;
        }
    }

    /// Get the Merkle proof (siblings + path bits) for a given key.
    getProof(key) {
        const siblings = [];
        const pathBits = [];
        let index = key;

        for (let level = 0; level < this.depth; level++) {
            const isRight = index & BigInt(1);
            const siblingIndex = isRight ? index - BigInt(1) : index + BigInt(1);

            siblings.push(this._getNode(level, siblingIndex).toString());
            pathBits.push(Number(isRight));
            index = index >> BigInt(1);
        }

        return { siblings, pathBits };
    }
}

async function main() {
    console.log(`Generating input: depth=${DEPTH}, batchSize=${BATCH_SIZE}`);

    const poseidon = await buildPoseidon();
    const F = poseidon.F;
    const tree = new WitnessSMT(poseidon, F, DEPTH);

    // Pre-populate tree with some initial values
    // Use small keys that fit within depth bits
    const maxKey = BigInt(1) << BigInt(DEPTH);
    for (let i = 0; i < BATCH_SIZE * 2; i++) {
        const key = BigInt(i) % maxKey;
        const value = BigInt(100 + i);
        tree.update(key, value);
    }

    const prevStateRoot = tree.getRoot().toString();
    const keys = [];
    const oldValues = [];
    const newValues = [];
    const siblings = [];
    const pathBits = [];

    // Generate batch of state transitions
    for (let i = 0; i < BATCH_SIZE; i++) {
        const key = BigInt(i) % maxKey;
        const oldValue = BigInt(100 + i);
        const newValue = BigInt(200 + i);

        // Get proof BEFORE update
        const proof = tree.getProof(key);
        keys.push(key.toString());
        oldValues.push(oldValue.toString());
        newValues.push(newValue.toString());
        siblings.push(proof.siblings);
        pathBits.push(proof.pathBits);

        // Apply update to tree
        tree.update(key, newValue);
    }

    const newStateRoot = tree.getRoot().toString();

    const input = {
        prevStateRoot,
        newStateRoot,
        batchNum: "1",
        enterpriseId: "42",
        keys,
        oldValues,
        newValues,
        siblings,
        pathBits
    };

    // Ensure output directory exists
    const outputDir = path.dirname(OUTPUT_PATH);
    if (!fs.existsSync(outputDir)) {
        fs.mkdirSync(outputDir, { recursive: true });
    }

    fs.writeFileSync(OUTPUT_PATH, JSON.stringify(input, null, 2));
    console.log(`Input written to ${OUTPUT_PATH}`);
    console.log(`prevStateRoot: ${prevStateRoot}`);
    console.log(`newStateRoot:  ${newStateRoot}`);
    console.log(`Transactions:  ${BATCH_SIZE}`);
}

main().catch(err => {
    console.error("Error:", err);
    process.exit(1);
});
