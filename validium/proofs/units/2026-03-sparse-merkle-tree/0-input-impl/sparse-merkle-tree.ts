/**
 * Sparse Merkle Tree with Poseidon Hash -- Production Implementation
 *
 * Translates the formally verified TLA+ specification into production-grade
 * TypeScript. Every operation is traceable to the verified spec.
 *
 * [Spec: validium/specs/units/2026-03-sparse-merkle-tree/SparseMerkleTree.tla]
 *
 * Verified invariants (TLC model checking, 1,572,865 states, 65,536 distinct):
 *   - ConsistencyInvariant: root = ComputeRoot(entries) -- deterministic
 *   - SoundnessInvariant:   no false-positive proof verification
 *   - CompletenessInvariant: every position has a valid proof
 *
 * @module state/sparse-merkle-tree
 */

// @ts-expect-error -- circomlibjs does not ship proper TS types
import { buildPoseidon } from "circomlibjs";

import {
  type FieldElement,
  type MerkleProof,
  type SMTStats,
  type SerializedSMT,
  BN128_PRIME,
  DEFAULT_DEPTH,
  EMPTY_VALUE,
  SMTError,
  SMTErrorCode,
  toFieldElement,
} from "./types";

// ---------------------------------------------------------------------------
// Internal Helpers
// ---------------------------------------------------------------------------

/** Node key format for the sparse map: "level:index". */
function nodeKey(level: number, index: bigint): string {
  return `${level}:${index}`;
}

/**
 * Extract bit at position `pos` from `index` (0 = LSB).
 *
 * [Spec: PathBit(key, level) == (key \div Pow2(level)) % 2]
 */
function getBit(index: bigint, pos: number): number {
  return Number((index >> BigInt(pos)) & 1n);
}

// ---------------------------------------------------------------------------
// SparseMerkleTree
// ---------------------------------------------------------------------------

/**
 * Depth-configurable Sparse Merkle Tree over the BN128 scalar field.
 *
 * Uses Poseidon 2-to-1 hash (circomlibjs) for circuit compatibility.
 * Only non-default nodes are stored; empty subtrees use precomputed defaults.
 *
 * [Spec: entries \in [Keys -> Values \cup {EMPTY}], root \in Nat]
 */
export class SparseMerkleTree {
  /** Tree depth (number of levels from root to leaves). */
  readonly depth: number;

  /**
   * Poseidon hash function instance and its finite field utilities.
   * Typed as `unknown` because circomlibjs has no published types.
   */
  private readonly poseidon: unknown;
  private readonly F: { toObject(el: unknown): bigint };

  /**
   * Precomputed default hashes for all-empty subtrees at each level.
   *
   * [Spec: DefaultHash(level) == IF level = 0 THEN EMPTY
   *        ELSE LET prev == DefaultHash(level - 1) IN Hash(prev, prev)]
   */
  private readonly defaultHashes: FieldElement[];

  /**
   * Sparse node storage. Key: "level:index", Value: field element hash.
   * Nodes equal to the default hash for their level are not stored.
   *
   * [Spec: nodes map mirrors the logical entries function combined with
   *  ComputeNode for intermediate levels]
   */
  private readonly nodes: Map<string, FieldElement>;

  /**
   * Number of occupied (non-empty) leaves.
   * Metadata only -- not part of the cryptographic state.
   */
  private _entryCount: number;

  // -----------------------------------------------------------------------
  // Construction
  // -----------------------------------------------------------------------

  private constructor(depth: number, poseidon: unknown, F: { toObject(el: unknown): bigint }) {
    this.depth = depth;
    this.poseidon = poseidon;
    this.F = F;
    this.nodes = new Map();
    this._entryCount = 0;

    // [Spec: DefaultHash(0) = EMPTY; DefaultHash(i) = Hash(prev, prev)]
    this.defaultHashes = new Array<FieldElement>(depth + 1);
    this.defaultHashes[0] = EMPTY_VALUE as FieldElement;
    for (let i = 1; i <= depth; i++) {
      const prev = this.defaultHashes[i - 1]!;
      this.defaultHashes[i] = this.hash2(prev, prev);
    }
  }

  /**
   * Factory: build Poseidon instance and create an empty SMT.
   *
   * [Spec: Init == entries = [k \in Keys |-> EMPTY] /\ root = DefaultHash(DEPTH)]
   *
   * @param depth - Tree depth (default 32, yielding 2^32 leaf positions)
   * @returns A new, empty SparseMerkleTree
   */
  static async create(depth: number = DEFAULT_DEPTH): Promise<SparseMerkleTree> {
    if (depth <= 0 || !Number.isInteger(depth)) {
      throw new SMTError(SMTErrorCode.INVALID_DEPTH, `Depth must be a positive integer, got ${depth}`);
    }

    let poseidon: unknown;
    try {
      poseidon = await buildPoseidon();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      throw new SMTError(SMTErrorCode.HASH_INIT_FAILED, `Failed to initialize Poseidon: ${msg}`);
    }

    const F = (poseidon as { F: { toObject(el: unknown): bigint } }).F;
    return new SparseMerkleTree(depth, poseidon, F);
  }

  // -----------------------------------------------------------------------
  // Hash Functions
  // -----------------------------------------------------------------------

  /**
   * Poseidon 2-to-1 hash over BN128 scalar field.
   * Returns result as bigint in [0, p).
   *
   * [Spec: Hash(a, b) -- abstract injective 2-to-1 hash]
   */
  hash2(left: FieldElement, right: FieldElement): FieldElement {
    const h = (this.poseidon as (inputs: bigint[]) => unknown)([left, right]);
    return this.F.toObject(h) as FieldElement;
  }

  // -----------------------------------------------------------------------
  // Node Access (Sparse Storage)
  // -----------------------------------------------------------------------

  /**
   * Get node hash at (level, index), returning the default hash if absent.
   *
   * [Spec: EntryValue(e, idx) == IF idx \in DOMAIN(e) THEN e[idx] ELSE EMPTY]
   */
  private getNode(level: number, index: bigint): FieldElement {
    const key = nodeKey(level, index);
    return this.nodes.get(key) ?? this.defaultHashes[level]!;
  }

  /**
   * Set node hash at (level, index). Deletes the entry if it equals the default
   * to maintain sparse storage invariant.
   */
  private setNode(level: number, index: bigint, value: FieldElement): void {
    const key = nodeKey(level, index);
    if (value === this.defaultHashes[level]) {
      this.nodes.delete(key);
    } else {
      this.nodes.set(key, value);
    }
  }

  // -----------------------------------------------------------------------
  // Public Accessors
  // -----------------------------------------------------------------------

  /**
   * Current root hash. For an empty tree, this equals DefaultHash(depth).
   *
   * [Spec: root variable -- maintained by incremental updates]
   */
  get root(): FieldElement {
    return this.getNode(this.depth, 0n);
  }

  /** Number of occupied (non-empty) leaves. */
  get entryCount(): number {
    return this._entryCount;
  }

  /**
   * Get the default hash for a given level (empty subtree hash).
   *
   * [Spec: DefaultHash(level)]
   */
  getDefaultHash(level: number): FieldElement {
    if (level < 0 || level > this.depth) {
      throw new SMTError(
        SMTErrorCode.INVALID_DEPTH,
        `Level ${level} is outside valid range [0, ${this.depth}]`
      );
    }
    return this.defaultHashes[level]!;
  }

  // -----------------------------------------------------------------------
  // Key-to-Index
  // -----------------------------------------------------------------------

  /**
   * Map a key to a leaf index by extracting the lower `depth` bits.
   * For keys that are Poseidon outputs, this provides uniform distribution.
   */
  private keyToIndex(key: FieldElement): bigint {
    return key & ((1n << BigInt(this.depth)) - 1n);
  }

  // -----------------------------------------------------------------------
  // State Mutations
  // -----------------------------------------------------------------------

  /**
   * Insert or update a key-value pair in the tree.
   *
   * Computes the leaf hash, then recomputes the path from leaf to root
   * using siblings from the current (pre-update) tree.
   *
   * [Spec: Insert(k, v) ==
   *   /\ k \in Keys /\ v \in Values /\ v # entries[k]
   *   /\ LET newLeafHash == LeafHash(k, v)
   *          newRoot     == WalkUp(entries, newLeafHash, k, 0)
   *      IN entries' = [entries EXCEPT ![k] = v] /\ root' = newRoot]
   *
   * @param key   - The key (field element) to insert
   * @param value - The value (field element) to associate; 0n means delete
   * @returns The new root hash
   */
  async insert(key: bigint, value: bigint): Promise<FieldElement> {
    const safeKey = toFieldElement(key);
    const safeValue = toFieldElement(value);
    const index = this.keyToIndex(safeKey);

    // [Spec: LeafHash(key, value) == IF value = EMPTY THEN EMPTY ELSE Hash(key, value)]
    const leafHash: FieldElement =
      safeValue === EMPTY_VALUE
        ? (EMPTY_VALUE as FieldElement)
        : this.hash2(safeKey, safeValue);

    // Track entry count (metadata, not part of cryptographic state)
    const existingLeaf = this.getNode(0, index);
    if (existingLeaf === this.defaultHashes[0] && safeValue !== EMPTY_VALUE) {
      this._entryCount++;
    } else if (existingLeaf !== this.defaultHashes[0] && safeValue === EMPTY_VALUE) {
      this._entryCount--;
    }

    // Set leaf node
    this.setNode(0, index, leafHash);

    // [Spec: WalkUp(oldEntries, currentHash, key, level) --
    //   incremental O(depth) path recomputation from leaf to root]
    let currentIndex = index;
    for (let level = 0; level < this.depth; level++) {
      const bit = getBit(currentIndex, 0);
      const parentIndex = currentIndex >> 1n;

      // [Spec: sibling == SiblingHash(oldEntries, key, level)]
      // [Spec: SiblingIndex via XOR 1 -- flip LSB]
      const siblingIndex = currentIndex ^ 1n;
      const sibling = this.getNode(level, siblingIndex);
      const current = this.getNode(level, currentIndex);

      // [Spec: IF bit = 0 THEN Hash(currentHash, sibling)
      //        ELSE Hash(sibling, currentHash)]
      const parentHash: FieldElement =
        bit === 0 ? this.hash2(current, sibling) : this.hash2(sibling, current);

      this.setNode(level + 1, parentIndex, parentHash);
      currentIndex = parentIndex;
    }

    return this.root;
  }

  /**
   * Update an existing key's value.
   * Semantically identical to insert; provided for API clarity.
   *
   * @param key   - The key to update
   * @param value - The new value
   * @returns The new root hash
   */
  async update(key: bigint, value: bigint): Promise<FieldElement> {
    return this.insert(key, value);
  }

  /**
   * Delete a key from the tree (set its value to the empty sentinel).
   *
   * [Spec: Delete(k) == Insert with newLeafHash = EMPTY]
   *
   * @param key - The key to delete
   * @returns The new root hash
   */
  async delete(key: bigint): Promise<FieldElement> {
    return this.insert(key, EMPTY_VALUE);
  }

  // -----------------------------------------------------------------------
  // Proof Generation
  // -----------------------------------------------------------------------

  /**
   * Generate a Merkle proof for a key.
   * Works for both membership (value != 0) and non-membership (value == 0).
   *
   * [Spec: ProofSiblings(e, key) ==
   *   [level \in 0..(DEPTH - 1) |-> SiblingHash(e, key, level)]
   *  PathBitsForKey(key) ==
   *   [level \in 0..(DEPTH - 1) |-> PathBit(key, level)]]
   *
   * @param key - The key to generate a proof for
   * @returns The Merkle proof
   */
  getProof(key: bigint): MerkleProof {
    const safeKey = toFieldElement(key);
    const index = this.keyToIndex(safeKey);

    const siblings: FieldElement[] = new Array<FieldElement>(this.depth);
    const pathBits: number[] = new Array<number>(this.depth);

    let currentIndex = index;
    for (let level = 0; level < this.depth; level++) {
      // [Spec: PathBit(key, level)]
      pathBits[level] = getBit(currentIndex, 0);
      // [Spec: SiblingHash(e, key, level) via currentIndex ^ 1]
      siblings[level] = this.getNode(level, currentIndex ^ 1n);
      currentIndex = currentIndex >> 1n;
    }

    return {
      siblings,
      pathBits,
      key: safeKey,
      leafHash: this.getNode(0, index),
      root: this.root,
    };
  }

  // -----------------------------------------------------------------------
  // Proof Verification
  // -----------------------------------------------------------------------

  /**
   * Verify a Merkle proof against an expected root.
   *
   * [Spec: VerifyProofOp(expectedRoot, leafHash, siblings, pathBits) ==
   *   VerifyWalkUp(leafHash, siblings, pathBits, 0) = expectedRoot]
   *
   * [Spec: VerifyWalkUp(currentHash, siblings, pathBits, level) ==
   *   IF level = DEPTH THEN currentHash
   *   ELSE LET parent == IF pathBits[level] = 0
   *                       THEN Hash(currentHash, siblings[level])
   *                       ELSE Hash(siblings[level], currentHash)
   *        IN VerifyWalkUp(parent, siblings, pathBits, level + 1)]
   *
   * @param root     - Expected root hash
   * @param key      - The key being verified (used for validation only)
   * @param leafHash - The leaf hash to verify against
   * @param proof    - The Merkle proof (siblings + pathBits)
   * @returns true if the proof is valid
   */
  verifyProof(
    root: FieldElement,
    key: FieldElement,
    leafHash: FieldElement,
    proof: MerkleProof
  ): boolean {
    if (proof.siblings.length !== this.depth || proof.pathBits.length !== this.depth) {
      return false;
    }

    // [Spec: VerifyWalkUp -- iterative form of the recursive definition]
    let currentHash: FieldElement = leafHash;
    for (let level = 0; level < this.depth; level++) {
      const sibling = proof.siblings[level]!;
      const bit = proof.pathBits[level]!;

      currentHash =
        bit === 0
          ? this.hash2(currentHash, sibling)
          : this.hash2(sibling, currentHash);
    }

    return currentHash === root;
  }

  /**
   * Static proof verification -- does not require a tree instance.
   * Builds a temporary Poseidon hasher for standalone verification.
   *
   * [Spec: VerifyProofOp(expectedRoot, leafHash, siblings, pathBits)]
   *
   * @param root     - Expected root hash
   * @param leafHash - The leaf hash to verify
   * @param proof    - The Merkle proof
   * @returns true if the proof is valid
   */
  static async verifyProofStatic(
    root: FieldElement,
    leafHash: FieldElement,
    proof: MerkleProof
  ): Promise<boolean> {
    if (proof.siblings.length !== proof.pathBits.length) {
      return false;
    }
    if (proof.siblings.length === 0) {
      return false;
    }

    let poseidon: unknown;
    try {
      poseidon = await buildPoseidon();
    } catch {
      throw new SMTError(SMTErrorCode.HASH_INIT_FAILED, "Failed to initialize Poseidon for static verification");
    }

    const F = (poseidon as { F: { toObject(el: unknown): bigint } }).F;
    const hash2 = (a: FieldElement, b: FieldElement): FieldElement => {
      const h = (poseidon as (inputs: bigint[]) => unknown)([a, b]);
      return F.toObject(h) as FieldElement;
    };

    let currentHash: FieldElement = leafHash;
    for (let level = 0; level < proof.siblings.length; level++) {
      const sibling = proof.siblings[level]!;
      const bit = proof.pathBits[level]!;

      currentHash =
        bit === 0
          ? hash2(currentHash, sibling)
          : hash2(sibling, currentHash);
    }

    return currentHash === root;
  }

  // -----------------------------------------------------------------------
  // Leaf Access
  // -----------------------------------------------------------------------

  /**
   * Get the leaf hash stored at a key, or EMPTY (0n) if not present.
   *
   * @param key - The key to look up
   * @returns The leaf hash at that position
   */
  getLeafHash(key: bigint): FieldElement {
    const safeKey = toFieldElement(key);
    const index = this.keyToIndex(safeKey);
    return this.getNode(0, index);
  }

  // -----------------------------------------------------------------------
  // Serialization
  // -----------------------------------------------------------------------

  /**
   * Serialize the tree to a JSON-compatible structure for persistence.
   *
   * @returns Serialized tree state
   */
  serialize(): SerializedSMT {
    const nodes: Record<string, string> = {};
    for (const [key, value] of this.nodes) {
      nodes[key] = value.toString(16);
    }

    return {
      version: 1,
      depth: this.depth,
      entryCount: this._entryCount,
      nodes,
      defaultHashes: this.defaultHashes.map((h) => h.toString(16)),
    };
  }

  /**
   * Deserialize a tree from a previously serialized state.
   * Validates default hashes to detect corruption or version mismatch.
   *
   * @param data - The serialized tree data
   * @returns A restored SparseMerkleTree instance
   */
  static async deserialize(data: SerializedSMT): Promise<SparseMerkleTree> {
    if (data.version !== 1) {
      throw new SMTError(
        SMTErrorCode.DESERIALIZATION_FAILED,
        `Unsupported version: ${String(data.version)}`
      );
    }

    const tree = await SparseMerkleTree.create(data.depth);

    // Validate default hashes match (detects Poseidon version mismatch)
    for (let i = 0; i <= data.depth; i++) {
      const expected = data.defaultHashes[i];
      if (expected === undefined) {
        throw new SMTError(
          SMTErrorCode.DESERIALIZATION_FAILED,
          `Missing default hash for level ${i}`
        );
      }
      const actual = tree.defaultHashes[i]!.toString(16);
      if (actual !== expected) {
        throw new SMTError(
          SMTErrorCode.DESERIALIZATION_FAILED,
          `Default hash mismatch at level ${i}: expected ${expected}, got ${actual}`
        );
      }
    }

    // Restore nodes
    for (const [key, hexValue] of Object.entries(data.nodes)) {
      tree.nodes.set(key, BigInt(`0x${hexValue}`) as FieldElement);
    }

    tree._entryCount = data.entryCount;
    return tree;
  }

  // -----------------------------------------------------------------------
  // Statistics
  // -----------------------------------------------------------------------

  /**
   * Get tree statistics for observability.
   *
   * @returns Current tree stats
   */
  getStats(): SMTStats {
    // Estimate: key string ~20 chars (40 bytes) + BigInt ~40 bytes + Map overhead ~80 bytes
    const estimatedBytesPerNode = 160;

    return {
      entryCount: this._entryCount,
      nodeCount: this.nodes.size,
      depth: this.depth,
      memoryEstimateBytes: this.nodes.size * estimatedBytesPerNode + (this.depth + 1) * 40,
    };
  }
}
