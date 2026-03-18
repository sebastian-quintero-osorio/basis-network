/**
 * Sparse Merkle Tree with Poseidon Hash -- RU-V1 Experiment
 *
 * Depth-32 binary SMT operating over the BN128 scalar field.
 * Uses circomlibjs Poseidon for compatibility with Circom circuits.
 *
 * BN128 scalar field prime:
 * p = 21888242871839275222246405745257275088548364400416034343698204186575808495617
 */

// circomlibjs uses dynamic imports and CommonJS internally
// @ts-ignore -- circomlibjs does not ship proper TS types
import { buildPoseidon } from "circomlibjs";

// BN128 scalar field prime
const BN128_PRIME = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

/** Field element type -- BigInt in BN128 scalar field */
type FieldElement = bigint;

/** Merkle proof structure */
export interface MerkleProof {
  /** Sibling hashes along the path from leaf to root */
  siblings: FieldElement[];
  /** Direction bits: 0 = left, 1 = right (for each level from leaf to root) */
  pathBits: number[];
  /** The key whose membership/non-membership is proved */
  key: FieldElement;
  /** The value at the leaf (0n if non-membership proof) */
  value: FieldElement;
  /** The root at time of proof generation */
  root: FieldElement;
}

/** SMT statistics for benchmarking */
export interface SMTStats {
  entryCount: number;
  nodeCount: number;
  depth: number;
  memoryEstimateBytes: number;
}

/**
 * Sparse Merkle Tree with Poseidon Hash
 *
 * A binary Merkle tree of fixed depth where most leaves are empty (zero).
 * Supports membership proofs, non-membership proofs, and efficient updates.
 *
 * Storage: Only non-empty nodes are stored in a Map keyed by (level, index).
 * Default (empty) subtree hashes are precomputed at initialization.
 */
export class SparseMerkleTree {
  /** Tree depth (number of levels from root to leaves) */
  readonly depth: number;

  /** Poseidon hash function instance (from circomlibjs) */
  private poseidon: any;
  private F: any; // Finite field utilities from circomlibjs

  /**
   * Precomputed default hashes for each level.
   * defaultHashes[0] = hash of empty leaf = 0n
   * defaultHashes[i] = poseidon(defaultHashes[i-1], defaultHashes[i-1])
   */
  private defaultHashes: FieldElement[];

  /**
   * Node storage: Map<string, FieldElement>
   * Key format: "level:index" where level 0 = leaves, level depth = root
   */
  private nodes: Map<string, FieldElement>;

  /** Number of non-zero entries in the tree */
  private _entryCount: number = 0;

  private constructor(depth: number, poseidon: any) {
    this.depth = depth;
    this.poseidon = poseidon;
    this.F = poseidon.F;
    this.nodes = new Map();
    this.defaultHashes = new Array(depth + 1);

    // Precompute default (empty) hashes for each level
    this.defaultHashes[0] = 0n; // Empty leaf
    for (let i = 1; i <= depth; i++) {
      this.defaultHashes[i] = this.hash2(this.defaultHashes[i - 1], this.defaultHashes[i - 1]);
    }
  }

  /**
   * Factory method: builds the Poseidon instance and creates the SMT.
   */
  static async create(depth: number = 32): Promise<SparseMerkleTree> {
    const poseidon = await buildPoseidon();
    return new SparseMerkleTree(depth, poseidon);
  }

  /**
   * Poseidon 2-to-1 hash over BN128 scalar field.
   * Returns result as BigInt in [0, p).
   */
  hash2(left: FieldElement, right: FieldElement): FieldElement {
    const h = this.poseidon([left, right]);
    return this.F.toObject(h);
  }

  /**
   * Hash a single value (for key derivation).
   */
  hash1(value: FieldElement): FieldElement {
    const h = this.poseidon([value]);
    return this.F.toObject(h);
  }

  /** Reduce a value to BN128 field */
  toField(value: bigint): FieldElement {
    return ((value % BN128_PRIME) + BN128_PRIME) % BN128_PRIME;
  }

  /** Get node hash at given level and index, returning default if absent */
  private getNode(level: number, index: bigint): FieldElement {
    const key = `${level}:${index}`;
    return this.nodes.get(key) ?? this.defaultHashes[level];
  }

  /** Set node hash at given level and index */
  private setNode(level: number, index: bigint, value: FieldElement): void {
    const key = `${level}:${index}`;
    if (value === this.defaultHashes[level]) {
      this.nodes.delete(key); // Don't store default values
    } else {
      this.nodes.set(key, value);
    }
  }

  /** Get the current root hash */
  get root(): FieldElement {
    return this.getNode(this.depth, 0n);
  }

  /** Get number of non-zero entries */
  get entryCount(): number {
    return this._entryCount;
  }

  /**
   * Convert a key to a leaf index by extracting the lower `depth` bits.
   * For keys that are already hashed (Poseidon output), this provides
   * uniform distribution across the tree.
   */
  private keyToIndex(key: FieldElement): bigint {
    return key & ((1n << BigInt(this.depth)) - 1n);
  }

  /**
   * Get the bit at position `pos` of `index` (0 = LSB).
   */
  private getBit(index: bigint, pos: number): number {
    return Number((index >> BigInt(pos)) & 1n);
  }

  /**
   * Insert a key-value pair into the tree.
   * If the key already exists, updates the value.
   *
   * @returns The new root hash
   */
  insert(key: FieldElement, value: FieldElement): FieldElement {
    const index = this.keyToIndex(key);

    // Hash key and value together to form leaf hash
    const leafHash = value === 0n ? 0n : this.hash2(key, value);

    // Check if this is a new entry or update
    const existingLeaf = this.getNode(0, index);
    if (existingLeaf === this.defaultHashes[0] && value !== 0n) {
      this._entryCount++;
    } else if (existingLeaf !== this.defaultHashes[0] && value === 0n) {
      this._entryCount--;
    }

    // Set leaf
    this.setNode(0, index, leafHash);

    // Recompute path from leaf to root
    let currentIndex = index;
    for (let level = 0; level < this.depth; level++) {
      const isRight = this.getBit(currentIndex, 0);
      const parentIndex = currentIndex >> 1n;

      let left: FieldElement;
      let right: FieldElement;

      if (isRight) {
        left = this.getNode(level, currentIndex ^ 1n); // sibling
        right = this.getNode(level, currentIndex);
      } else {
        left = this.getNode(level, currentIndex);
        right = this.getNode(level, currentIndex ^ 1n); // sibling
      }

      const parentHash = this.hash2(left, right);
      this.setNode(level + 1, parentIndex, parentHash);

      currentIndex = parentIndex;
    }

    return this.root;
  }

  /**
   * Update an existing key's value.
   * Equivalent to insert but semantically indicates an update.
   */
  update(key: FieldElement, value: FieldElement): FieldElement {
    return this.insert(key, value);
  }

  /**
   * Delete a key from the tree (set its value to zero).
   */
  delete(key: FieldElement): FieldElement {
    return this.insert(key, 0n);
  }

  /**
   * Get the value stored at a key, or 0n if not present.
   * Note: This returns the leaf hash, not the original value.
   */
  getLeafHash(key: FieldElement): FieldElement {
    const index = this.keyToIndex(key);
    return this.getNode(0, index);
  }

  /**
   * Generate a Merkle proof for a key.
   * Works for both membership (value != 0) and non-membership (value == 0) proofs.
   */
  getProof(key: FieldElement): MerkleProof {
    const index = this.keyToIndex(key);
    const siblings: FieldElement[] = new Array(this.depth);
    const pathBits: number[] = new Array(this.depth);

    let currentIndex = index;
    for (let level = 0; level < this.depth; level++) {
      const bit = this.getBit(currentIndex, 0);
      pathBits[level] = bit;
      // Sibling is the node at the same level with the opposite last bit
      siblings[level] = this.getNode(level, currentIndex ^ 1n);
      currentIndex = currentIndex >> 1n;
    }

    return {
      siblings,
      pathBits,
      key,
      value: this.getNode(0, index),
      root: this.root,
    };
  }

  /**
   * Verify a Merkle proof.
   *
   * @param root Expected root hash
   * @param key The key being proved
   * @param leafHash The leaf hash (hash(key, value) or 0 for non-membership)
   * @param proof The Merkle proof
   * @returns true if the proof is valid
   */
  verifyProof(root: FieldElement, key: FieldElement, leafHash: FieldElement, proof: MerkleProof): boolean {
    let currentHash = leafHash;

    for (let level = 0; level < this.depth; level++) {
      const sibling = proof.siblings[level];
      if (proof.pathBits[level] === 1) {
        currentHash = this.hash2(sibling, currentHash);
      } else {
        currentHash = this.hash2(currentHash, sibling);
      }
    }

    return currentHash === root;
  }

  /**
   * Static proof verification (does not need a tree instance, just the hash function).
   * Useful for verifying proofs in isolation.
   */
  static async verifyProofStatic(
    root: FieldElement,
    leafHash: FieldElement,
    proof: MerkleProof
  ): Promise<boolean> {
    const poseidon = await buildPoseidon();
    const F = poseidon.F;

    const hash2 = (a: FieldElement, b: FieldElement): FieldElement => {
      return F.toObject(poseidon([a, b]));
    };

    let currentHash = leafHash;
    for (let level = 0; level < proof.siblings.length; level++) {
      const sibling = proof.siblings[level];
      if (proof.pathBits[level] === 1) {
        currentHash = hash2(sibling, currentHash);
      } else {
        currentHash = hash2(currentHash, sibling);
      }
    }

    return currentHash === root;
  }

  /**
   * Get tree statistics for benchmarking.
   */
  getStats(): SMTStats {
    // Estimate memory: each Map entry is roughly key string + BigInt value
    // Key string: ~20 chars = ~40 bytes, BigInt: ~40 bytes, Map overhead: ~80 bytes
    const estimatedBytesPerNode = 160;

    return {
      entryCount: this._entryCount,
      nodeCount: this.nodes.size,
      depth: this.depth,
      memoryEstimateBytes: this.nodes.size * estimatedBytesPerNode + (this.depth + 1) * 40,
    };
  }
}
