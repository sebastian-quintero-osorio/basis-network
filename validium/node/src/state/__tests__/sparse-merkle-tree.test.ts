/**
 * Tests for Sparse Merkle Tree -- Unit + Adversarial
 *
 * Organized by the three verified TLA+ invariants, plus adversarial scenarios.
 *
 * [Spec: validium/specs/units/2026-03-sparse-merkle-tree/SparseMerkleTree.tla]
 *
 * Invariants under test:
 *   ConsistencyInvariant: root = ComputeRoot(entries) -- deterministic
 *   SoundnessInvariant:   no false-positive proof verification
 *   CompletenessInvariant: every position has a valid proof
 */

import { SparseMerkleTree } from "../sparse-merkle-tree";
import {
  type FieldElement,
  type MerkleProof,
  BN128_PRIME,
  EMPTY_VALUE,
  SMTError,
  SMTErrorCode,
  toFieldElement,
  reduceToField,
} from "../types";

// Use a small depth for fast tests. TLA+ verified at depth 4; algorithmic
// correctness is depth-independent (Phase 1 Formalization Notes, Section 5).
const TEST_DEPTH = 4;

// Test keys: subset of 0..15 (matching TLA+ model's Keys = {0,2,5,7,9,12,14,15})
const TEST_KEYS = [0n, 2n, 5n, 7n, 9n, 12n, 14n, 15n] as FieldElement[];

// Test values: {1, 2, 3} matching TLA+ model's Values
const TEST_VALUES = [1n, 2n, 3n] as FieldElement[];

// Helper: create a tree with small depth for testing
async function createTestTree(): Promise<SparseMerkleTree> {
  return SparseMerkleTree.create(TEST_DEPTH);
}

// ---------------------------------------------------------------------------
// Construction and Initialization
// ---------------------------------------------------------------------------

describe("SparseMerkleTree", () => {
  describe("construction", () => {
    it("should create an empty tree with correct default root", async () => {
      const tree = await createTestTree();
      expect(tree.depth).toBe(TEST_DEPTH);
      expect(tree.entryCount).toBe(0);
      // Root of empty tree is DefaultHash(DEPTH), not 0
      expect(tree.root).not.toBe(EMPTY_VALUE);
    });

    it("should create trees with different depths", async () => {
      const tree4 = await SparseMerkleTree.create(4);
      const tree8 = await SparseMerkleTree.create(8);
      // Different depths produce different default roots
      expect(tree4.root).not.toBe(tree8.root);
      expect(tree4.depth).toBe(4);
      expect(tree8.depth).toBe(8);
    });

    it("should reject depth <= 0", async () => {
      await expect(SparseMerkleTree.create(0)).rejects.toThrow(SMTError);
      await expect(SparseMerkleTree.create(-1)).rejects.toThrow(SMTError);
    });

    it("should reject non-integer depth", async () => {
      await expect(SparseMerkleTree.create(3.5)).rejects.toThrow(SMTError);
    });

    it("should have consistent default hashes", async () => {
      // [Spec: DefaultHash(0) = EMPTY = 0]
      const tree = await createTestTree();
      expect(tree.getDefaultHash(0)).toBe(EMPTY_VALUE);
      // DefaultHash(1) = Hash(0, 0) -- should be non-zero
      expect(tree.getDefaultHash(1)).not.toBe(EMPTY_VALUE);
    });
  });

  // -------------------------------------------------------------------------
  // ConsistencyInvariant: root = ComputeRoot(entries)
  // -------------------------------------------------------------------------

  describe("ConsistencyInvariant", () => {
    it("should change root on insert", async () => {
      const tree = await createTestTree();
      const emptyRoot = tree.root;
      await tree.insert(5n, 1n);
      expect(tree.root).not.toBe(emptyRoot);
    });

    it("should produce deterministic root for same entries", async () => {
      // Two trees with same inserts in same order must produce identical roots
      const tree1 = await createTestTree();
      const tree2 = await createTestTree();

      await tree1.insert(5n, 1n);
      await tree1.insert(7n, 2n);

      await tree2.insert(5n, 1n);
      await tree2.insert(7n, 2n);

      expect(tree1.root).toBe(tree2.root);
    });

    it("should produce deterministic root regardless of insert order", async () => {
      // [Spec: ComputeRoot is a function of entries, not insert history]
      const tree1 = await createTestTree();
      const tree2 = await createTestTree();

      await tree1.insert(5n, 1n);
      await tree1.insert(7n, 2n);
      await tree1.insert(12n, 3n);

      // Different order, same final state
      await tree2.insert(12n, 3n);
      await tree2.insert(5n, 1n);
      await tree2.insert(7n, 2n);

      expect(tree1.root).toBe(tree2.root);
    });

    it("should return to original root after insert then delete", async () => {
      // [Spec: Delete(k) sets entries[k] = EMPTY, restoring previous state]
      const tree = await createTestTree();
      const emptyRoot = tree.root;

      await tree.insert(5n, 1n);
      expect(tree.root).not.toBe(emptyRoot);

      await tree.delete(5n);
      expect(tree.root).toBe(emptyRoot);
    });

    it("should return to original root after multiple inserts and deletes", async () => {
      const tree = await createTestTree();
      const emptyRoot = tree.root;

      // Insert several entries
      await tree.insert(0n, 1n);
      await tree.insert(5n, 2n);
      await tree.insert(15n, 3n);

      // Delete them all
      await tree.delete(0n);
      await tree.delete(5n);
      await tree.delete(15n);

      expect(tree.root).toBe(emptyRoot);
    });

    it("should update root on value change (same key)", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);
      const root1 = tree.root;

      await tree.update(5n, 2n);
      const root2 = tree.root;

      expect(root1).not.toBe(root2);
    });

    it("should produce correct root with all positions filled", async () => {
      const tree1 = await createTestTree();
      const tree2 = await createTestTree();

      // Fill all 16 positions (depth 4 -> 2^4 = 16)
      for (let i = 0n; i < 16n; i++) {
        await tree1.insert(i, (i % 3n) + 1n);
        await tree2.insert(i, (i % 3n) + 1n);
      }

      expect(tree1.root).toBe(tree2.root);
      expect(tree1.entryCount).toBe(16);
    });
  });

  // -------------------------------------------------------------------------
  // CompletenessInvariant: every position has a valid proof
  // -------------------------------------------------------------------------

  describe("CompletenessInvariant", () => {
    it("should generate valid proof for inserted entry", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);

      const proof = tree.getProof(5n);
      const valid = tree.verifyProof(tree.root, 5n as FieldElement, proof.leafHash, proof);
      expect(valid).toBe(true);
    });

    it("should generate valid non-membership proof for empty position", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);

      // Key 7 was never inserted -- non-membership proof
      const proof = tree.getProof(7n);
      expect(proof.leafHash).toBe(EMPTY_VALUE);
      const valid = tree.verifyProof(tree.root, 7n as FieldElement, proof.leafHash, proof);
      expect(valid).toBe(true);
    });

    it("should generate valid proofs for ALL positions in empty tree", async () => {
      // [Spec: CompletenessInvariant checked over ALL LeafIndices]
      const tree = await createTestTree();
      for (let i = 0n; i < 16n; i++) {
        const proof = tree.getProof(i);
        const valid = tree.verifyProof(tree.root, i as FieldElement, proof.leafHash, proof);
        expect(valid).toBe(true);
      }
    });

    it("should generate valid proofs for ALL positions after inserts", async () => {
      const tree = await createTestTree();

      // Insert entries at test keys
      for (const key of TEST_KEYS) {
        await tree.insert(key, TEST_VALUES[Number(key) % TEST_VALUES.length]!);
      }

      // Verify ALL 16 positions (both occupied and empty)
      for (let i = 0n; i < 16n; i++) {
        const proof = tree.getProof(i);
        const valid = tree.verifyProof(tree.root, i as FieldElement, proof.leafHash, proof);
        expect(valid).toBe(true);
      }
    });

    it("should have correct proof structure", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);

      const proof = tree.getProof(5n);
      expect(proof.siblings.length).toBe(TEST_DEPTH);
      expect(proof.pathBits.length).toBe(TEST_DEPTH);
      expect(proof.key).toBe(5n);
      expect(proof.root).toBe(tree.root);
      // All path bits should be 0 or 1
      for (const bit of proof.pathBits) {
        expect(bit === 0 || bit === 1).toBe(true);
      }
    });

    it("should remain valid after tree updates", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);
      await tree.insert(7n, 2n);

      // Get proof, update tree, verify proof still works against ORIGINAL root
      const proofBefore = tree.getProof(5n);
      const rootBefore = tree.root;

      await tree.insert(9n, 3n);

      // Proof against original root should still verify
      const valid = tree.verifyProof(rootBefore, 5n as FieldElement, proofBefore.leafHash, proofBefore);
      expect(valid).toBe(true);

      // Proof against new root should NOT verify (tree changed)
      const invalidAgainstNew = tree.verifyProof(tree.root, 5n as FieldElement, proofBefore.leafHash, proofBefore);
      expect(invalidAgainstNew).toBe(false);
    });
  });

  // -------------------------------------------------------------------------
  // SoundnessInvariant: no false-positive proof verification
  // -------------------------------------------------------------------------

  describe("SoundnessInvariant", () => {
    it("should reject proof with wrong leaf hash", async () => {
      // [Spec: v # EntryValue(entries, k) => ~VerifyProofOp(...)]
      const tree = await createTestTree();
      await tree.insert(5n, 1n);

      const proof = tree.getProof(5n);

      // Use a different leaf hash (wrong value)
      const wrongLeafHash = tree.hash2(5n as FieldElement, 999n as FieldElement);
      const valid = tree.verifyProof(tree.root, 5n as FieldElement, wrongLeafHash, proof);
      expect(valid).toBe(false);
    });

    it("should reject proof with wrong root", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);

      const proof = tree.getProof(5n);
      const fakeRoot = 12345n as FieldElement;
      const valid = tree.verifyProof(fakeRoot, 5n as FieldElement, proof.leafHash, proof);
      expect(valid).toBe(false);
    });

    it("should reject proof with tampered siblings", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);

      const proof = tree.getProof(5n);
      // Tamper with first sibling
      const tamperedSiblings = [...proof.siblings];
      tamperedSiblings[0] = 99999n as FieldElement;

      const tamperedProof: MerkleProof = {
        ...proof,
        siblings: tamperedSiblings,
      };

      const valid = tree.verifyProof(tree.root, 5n as FieldElement, proof.leafHash, tamperedProof);
      expect(valid).toBe(false);
    });

    it("should reject non-membership claim for existing entry", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);

      const proof = tree.getProof(5n);
      // Claim non-membership (leafHash = 0) for an existing entry
      const valid = tree.verifyProof(
        tree.root,
        5n as FieldElement,
        EMPTY_VALUE as FieldElement,
        proof
      );
      expect(valid).toBe(false);
    });

    it("should reject membership claim for non-existing entry", async () => {
      const tree = await createTestTree();

      const proof = tree.getProof(5n);
      // Claim membership with a non-zero leaf hash for empty position
      const fakeLeafHash = tree.hash2(5n as FieldElement, 1n as FieldElement);
      const valid = tree.verifyProof(tree.root, 5n as FieldElement, fakeLeafHash, proof);
      expect(valid).toBe(false);
    });

    it("should reject for ALL wrong values at ALL positions", async () => {
      // [Spec: SoundnessInvariant quantifies over ALL LeafIndices x ALL Values]
      const tree = await createTestTree();

      // Insert at several positions
      await tree.insert(0n, 1n);
      await tree.insert(5n, 2n);
      await tree.insert(15n, 3n);

      // For each position, verify that wrong values produce failed proofs
      for (let k = 0n; k < 16n; k++) {
        const proof = tree.getProof(k);
        const actualLeafHash = proof.leafHash;

        for (const wrongValue of [0n, 1n, 2n, 3n] as FieldElement[]) {
          const wrongLeafHash: FieldElement =
            wrongValue === EMPTY_VALUE
              ? (EMPTY_VALUE as FieldElement)
              : tree.hash2(k as FieldElement, wrongValue);

          if (wrongLeafHash !== actualLeafHash) {
            const valid = tree.verifyProof(tree.root, k as FieldElement, wrongLeafHash, proof);
            expect(valid).toBe(false);
          }
        }
      }
    });
  });

  // -------------------------------------------------------------------------
  // Static Verification
  // -------------------------------------------------------------------------

  describe("static verification", () => {
    it("should verify proof statically (without tree instance)", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);

      const proof = tree.getProof(5n);
      const valid = await SparseMerkleTree.verifyProofStatic(tree.root, proof.leafHash, proof);
      expect(valid).toBe(true);
    });

    it("should reject invalid proof statically", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);

      const proof = tree.getProof(5n);
      const fakeRoot = 12345n as FieldElement;
      const valid = await SparseMerkleTree.verifyProofStatic(fakeRoot, proof.leafHash, proof);
      expect(valid).toBe(false);
    });
  });

  // -------------------------------------------------------------------------
  // Serialization / Deserialization
  // -------------------------------------------------------------------------

  describe("serialization", () => {
    it("should round-trip serialize/deserialize", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);
      await tree.insert(7n, 2n);
      await tree.insert(12n, 3n);

      const serialized = tree.serialize();
      const restored = await SparseMerkleTree.deserialize(serialized);

      expect(restored.root).toBe(tree.root);
      expect(restored.entryCount).toBe(tree.entryCount);
      expect(restored.depth).toBe(tree.depth);
    });

    it("should preserve proof validity after deserialization", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);

      const proofBefore = tree.getProof(5n);
      const serialized = tree.serialize();
      const restored = await SparseMerkleTree.deserialize(serialized);

      const proofAfter = restored.getProof(5n);
      expect(proofAfter.leafHash).toBe(proofBefore.leafHash);
      expect(proofAfter.root).toBe(proofBefore.root);

      const valid = restored.verifyProof(
        restored.root,
        5n as FieldElement,
        proofAfter.leafHash,
        proofAfter
      );
      expect(valid).toBe(true);
    });

    it("should reject invalid version", async () => {
      const tree = await createTestTree();
      const serialized = tree.serialize();
      const corrupted = { ...serialized, version: 99 as 1 };
      await expect(SparseMerkleTree.deserialize(corrupted)).rejects.toThrow(SMTError);
    });
  });

  // -------------------------------------------------------------------------
  // Entry Count
  // -------------------------------------------------------------------------

  describe("entry count", () => {
    it("should track insertions", async () => {
      const tree = await createTestTree();
      expect(tree.entryCount).toBe(0);

      await tree.insert(5n, 1n);
      expect(tree.entryCount).toBe(1);

      await tree.insert(7n, 2n);
      expect(tree.entryCount).toBe(2);
    });

    it("should track deletions", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);
      await tree.insert(7n, 2n);
      expect(tree.entryCount).toBe(2);

      await tree.delete(5n);
      expect(tree.entryCount).toBe(1);
    });

    it("should not double-count updates", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);
      expect(tree.entryCount).toBe(1);

      await tree.update(5n, 2n);
      expect(tree.entryCount).toBe(1);
    });
  });

  // -------------------------------------------------------------------------
  // Statistics
  // -------------------------------------------------------------------------

  describe("statistics", () => {
    it("should report correct stats", async () => {
      const tree = await createTestTree();
      await tree.insert(5n, 1n);

      const stats = tree.getStats();
      expect(stats.entryCount).toBe(1);
      expect(stats.depth).toBe(TEST_DEPTH);
      expect(stats.nodeCount).toBeGreaterThan(0);
      expect(stats.memoryEstimateBytes).toBeGreaterThan(0);
    });
  });

  // -------------------------------------------------------------------------
  // Type Safety
  // -------------------------------------------------------------------------

  describe("type safety", () => {
    it("should reject values outside BN128 field", () => {
      expect(() => toFieldElement(-1n)).toThrow(SMTError);
      expect(() => toFieldElement(BN128_PRIME)).toThrow(SMTError);
      expect(() => toFieldElement(BN128_PRIME + 1n)).toThrow(SMTError);
    });

    it("should accept valid field elements", () => {
      expect(toFieldElement(0n)).toBe(0n);
      expect(toFieldElement(1n)).toBe(1n);
      expect(toFieldElement(BN128_PRIME - 1n)).toBe(BN128_PRIME - 1n);
    });

    it("should reduce arbitrary bigints to field", () => {
      expect(reduceToField(BN128_PRIME)).toBe(0n);
      expect(reduceToField(BN128_PRIME + 1n)).toBe(1n);
      expect(reduceToField(-1n)).toBe(BN128_PRIME - 1n);
    });
  });

  // =========================================================================
  // ADVERSARIAL TESTS
  // =========================================================================

  describe("ADVERSARIAL", () => {
    // -----------------------------------------------------------------------
    // ADV-01: Forged proof (random siblings)
    // -----------------------------------------------------------------------
    describe("ADV-01: Forged proof with random siblings", () => {
      it("should reject proof with entirely fabricated siblings", async () => {
        const tree = await createTestTree();
        await tree.insert(5n, 1n);

        const realProof = tree.getProof(5n);
        const forgedProof: MerkleProof = {
          ...realProof,
          siblings: realProof.siblings.map(
            (_, i) => BigInt(i * 7919 + 42) as FieldElement
          ),
        };

        const valid = tree.verifyProof(
          tree.root,
          5n as FieldElement,
          realProof.leafHash,
          forgedProof
        );
        expect(valid).toBe(false);
      });
    });

    // -----------------------------------------------------------------------
    // ADV-02: Proof transplant (proof from key A used for key B)
    // -----------------------------------------------------------------------
    describe("ADV-02: Proof transplant attack", () => {
      it("should reject proof generated for a different key", async () => {
        const tree = await createTestTree();
        await tree.insert(5n, 1n);
        await tree.insert(7n, 2n);

        const proofFor5 = tree.getProof(5n);
        // Try to use proof-for-5 to verify key 7
        const leafHashOf7 = tree.getLeafHash(7n);
        const valid = tree.verifyProof(
          tree.root,
          7n as FieldElement,
          leafHashOf7,
          proofFor5
        );
        expect(valid).toBe(false);
      });
    });

    // -----------------------------------------------------------------------
    // ADV-03: Stale proof after tree mutation
    // -----------------------------------------------------------------------
    describe("ADV-03: Stale proof after mutation", () => {
      it("should reject stale proof against updated root", async () => {
        const tree = await createTestTree();
        await tree.insert(5n, 1n);

        const staleProof = tree.getProof(5n);
        const staleRoot = tree.root;

        // Mutate the tree
        await tree.insert(7n, 2n);

        // Stale proof against NEW root must fail
        const valid = tree.verifyProof(
          tree.root,
          5n as FieldElement,
          staleProof.leafHash,
          staleProof
        );
        expect(valid).toBe(false);

        // Stale proof against ORIGINAL root should still pass
        const validOriginal = tree.verifyProof(
          staleRoot,
          5n as FieldElement,
          staleProof.leafHash,
          staleProof
        );
        expect(validOriginal).toBe(true);
      });
    });

    // -----------------------------------------------------------------------
    // ADV-04: Duplicate key with different value
    // -----------------------------------------------------------------------
    describe("ADV-04: Duplicate key overwrite", () => {
      it("should overwrite value and produce different root", async () => {
        const tree = await createTestTree();
        await tree.insert(5n, 1n);
        const root1 = tree.root;

        await tree.insert(5n, 2n);
        const root2 = tree.root;

        expect(root1).not.toBe(root2);

        // Proof for the old value should fail
        const proof = tree.getProof(5n);
        const oldLeafHash = tree.hash2(5n as FieldElement, 1n as FieldElement);
        const valid = tree.verifyProof(tree.root, 5n as FieldElement, oldLeafHash, proof);
        expect(valid).toBe(false);

        // Proof for the new value should pass
        const newValid = tree.verifyProof(tree.root, 5n as FieldElement, proof.leafHash, proof);
        expect(newValid).toBe(true);
      });
    });

    // -----------------------------------------------------------------------
    // ADV-05: Empty tree proofs
    // -----------------------------------------------------------------------
    describe("ADV-05: Empty tree proofs", () => {
      it("should have valid non-membership proofs for all positions", async () => {
        const tree = await createTestTree();

        for (let i = 0n; i < 16n; i++) {
          const proof = tree.getProof(i);
          expect(proof.leafHash).toBe(EMPTY_VALUE);
          const valid = tree.verifyProof(
            tree.root,
            i as FieldElement,
            EMPTY_VALUE as FieldElement,
            proof
          );
          expect(valid).toBe(true);
        }
      });

      it("should reject fake membership claims in empty tree", async () => {
        const tree = await createTestTree();

        for (let i = 0n; i < 16n; i++) {
          const proof = tree.getProof(i);
          // Claim there is a value 1 at position i
          const fakeLeafHash = tree.hash2(i as FieldElement, 1n as FieldElement);
          const valid = tree.verifyProof(
            tree.root,
            i as FieldElement,
            fakeLeafHash,
            proof
          );
          expect(valid).toBe(false);
        }
      });
    });

    // -----------------------------------------------------------------------
    // ADV-06: Proof with wrong length (truncated/extended)
    // -----------------------------------------------------------------------
    describe("ADV-06: Malformed proof length", () => {
      it("should reject proof with too few siblings", async () => {
        const tree = await createTestTree();
        await tree.insert(5n, 1n);

        const proof = tree.getProof(5n);
        const truncatedProof: MerkleProof = {
          ...proof,
          siblings: proof.siblings.slice(0, -1),
          pathBits: proof.pathBits.slice(0, -1),
        };

        const valid = tree.verifyProof(
          tree.root,
          5n as FieldElement,
          proof.leafHash,
          truncatedProof
        );
        expect(valid).toBe(false);
      });

      it("should reject proof with too many siblings", async () => {
        const tree = await createTestTree();
        await tree.insert(5n, 1n);

        const proof = tree.getProof(5n);
        const extendedProof: MerkleProof = {
          ...proof,
          siblings: [...proof.siblings, 0n as FieldElement],
          pathBits: [...proof.pathBits, 0],
        };

        const valid = tree.verifyProof(
          tree.root,
          5n as FieldElement,
          proof.leafHash,
          extendedProof
        );
        expect(valid).toBe(false);
      });
    });

    // -----------------------------------------------------------------------
    // ADV-07: Path bit manipulation
    // -----------------------------------------------------------------------
    describe("ADV-07: Flipped path bits", () => {
      it("should reject proof with flipped path bits", async () => {
        const tree = await createTestTree();
        await tree.insert(5n, 1n);
        await tree.insert(7n, 2n);

        const proof = tree.getProof(5n);
        // Flip all path bits
        const flippedProof: MerkleProof = {
          ...proof,
          pathBits: proof.pathBits.map((b) => (b === 0 ? 1 : 0)),
        };

        const valid = tree.verifyProof(
          tree.root,
          5n as FieldElement,
          proof.leafHash,
          flippedProof
        );
        expect(valid).toBe(false);
      });

      it("should reject proof with single flipped bit", async () => {
        const tree = await createTestTree();
        await tree.insert(5n, 1n);

        const proof = tree.getProof(5n);

        for (let flipIdx = 0; flipIdx < TEST_DEPTH; flipIdx++) {
          const flippedBits = [...proof.pathBits];
          flippedBits[flipIdx] = flippedBits[flipIdx] === 0 ? 1 : 0;

          const flippedProof: MerkleProof = { ...proof, pathBits: flippedBits };
          const valid = tree.verifyProof(
            tree.root,
            5n as FieldElement,
            proof.leafHash,
            flippedProof
          );
          expect(valid).toBe(false);
        }
      });
    });

    // -----------------------------------------------------------------------
    // ADV-08: Key outside tree range
    // -----------------------------------------------------------------------
    describe("ADV-08: Key outside tree address space", () => {
      it("should handle key larger than 2^depth via bit masking", async () => {
        const tree = await createTestTree();

        // Key 5 and key 5 + 16 (= 21) should map to the same leaf (depth 4, 2^4 = 16)
        await tree.insert(5n, 1n);
        const root1 = tree.root;

        const tree2 = await createTestTree();
        // 21n & 0xFn = 5n (same leaf index)
        await tree2.insert(21n, 1n);
        const root2 = tree2.root;

        // Different keys but same leaf index -- both produce same leaf hash
        // because leafHash = hash2(key, value) and the keys differ
        // This is expected: key masking maps 21 -> index 5, but the leaf hash
        // includes the FULL key (21 vs 5), so the roots will differ
        // This tests that the tree handles large keys without crashing
        expect(typeof root1).toBe("bigint");
        expect(typeof root2).toBe("bigint");
      });

      it("should reject field elements outside BN128", async () => {
        const tree = await createTestTree();
        await expect(tree.insert(BN128_PRIME, 1n)).rejects.toThrow(SMTError);
        await expect(tree.insert(1n, BN128_PRIME)).rejects.toThrow(SMTError);
        await expect(tree.insert(-1n, 1n)).rejects.toThrow(SMTError);
      });
    });

    // -----------------------------------------------------------------------
    // ADV-09: Zero-value edge cases
    // -----------------------------------------------------------------------
    describe("ADV-09: Zero-value edge cases", () => {
      it("should treat insert(key, 0) as deletion", async () => {
        const tree = await createTestTree();
        const emptyRoot = tree.root;

        await tree.insert(5n, 1n);
        expect(tree.entryCount).toBe(1);

        await tree.insert(5n, 0n);
        expect(tree.entryCount).toBe(0);
        expect(tree.root).toBe(emptyRoot);
      });

      it("should handle repeated deletion of same key", async () => {
        const tree = await createTestTree();
        await tree.insert(5n, 1n);

        await tree.delete(5n);
        const rootAfterFirstDelete = tree.root;
        expect(tree.entryCount).toBe(0);

        // Deleting again should be a no-op
        await tree.delete(5n);
        expect(tree.root).toBe(rootAfterFirstDelete);
        expect(tree.entryCount).toBe(0);
      });
    });

    // -----------------------------------------------------------------------
    // ADV-10: Sibling swap attack
    // -----------------------------------------------------------------------
    describe("ADV-10: Sibling order swap", () => {
      it("should reject proof with siblings in reversed order", async () => {
        const tree = await createTestTree();
        await tree.insert(5n, 1n);
        await tree.insert(7n, 2n);

        const proof = tree.getProof(5n);
        const reversedProof: MerkleProof = {
          ...proof,
          siblings: [...proof.siblings].reverse(),
          pathBits: [...proof.pathBits].reverse(),
        };

        const valid = tree.verifyProof(
          tree.root,
          5n as FieldElement,
          proof.leafHash,
          reversedProof
        );
        expect(valid).toBe(false);
      });
    });

    // -----------------------------------------------------------------------
    // ADV-11: Second preimage (swap leaf hash for sibling at level 0)
    // -----------------------------------------------------------------------
    describe("ADV-11: Second preimage via sibling injection", () => {
      it("should reject when leaf hash is replaced with level-0 sibling", async () => {
        const tree = await createTestTree();
        await tree.insert(4n, 1n); // Index 4 (binary: 0100)
        await tree.insert(5n, 2n); // Index 5 (binary: 0101) -- sibling of 4

        const proof = tree.getProof(4n);
        // Try to pass off the sibling's hash as the leaf hash
        const siblingHash = proof.siblings[0]!;

        const valid = tree.verifyProof(
          tree.root,
          4n as FieldElement,
          siblingHash,
          proof
        );
        expect(valid).toBe(false);
      });
    });
  });
});
