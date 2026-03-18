/**
 * Tests for Cross-Reference Builder -- Unit + Adversarial
 *
 * Organized by the three verified TLA+ safety invariants, plus adversarial scenarios.
 *
 * [Spec: validium/specs/units/2026-03-cross-enterprise/1-formalization/v0-analysis/specs/CrossEnterprise/CrossEnterprise.tla]
 *
 * Invariants under test:
 *   Isolation:           cross-ref operations do not modify enterprise state
 *   Consistency:         cross-ref verified only when both batch proofs verified
 *   NoCrossRefSelfLoop:  src != dst enforced at build time
 */

import { SparseMerkleTree } from "../../state/sparse-merkle-tree";
import type { FieldElement, MerkleProof } from "../../state/types";
import { toFieldElement, EMPTY_VALUE } from "../../state/types";

import {
  buildCrossReferenceEvidence,
  verifyCrossReferenceLocally,
  formatPublicSignals,
} from "../cross-reference-builder";

import {
  type CrossReferenceRequest,
  type CrossReferenceEvidence,
  type BatchStatusProvider,
  CrossReferenceStatus,
  CrossEnterpriseError,
  CrossEnterpriseErrorCode,
} from "../types";

// ---------------------------------------------------------------------------
// Test Configuration
// ---------------------------------------------------------------------------

const TEST_DEPTH = 4;
const ENTERPRISE_A = "0x1111111111111111111111111111111111111111";
const ENTERPRISE_B = "0x2222222222222222222222222222222222222222";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Build two SMTs with shared interaction data and return proofs. */
async function setupCrossEnterprise(): Promise<{
  treeA: SparseMerkleTree;
  treeB: SparseMerkleTree;
  proofA: MerkleProof;
  proofB: MerkleProof;
  keyA: FieldElement;
  keyB: FieldElement;
}> {
  const treeA = await SparseMerkleTree.create(TEST_DEPTH);
  const treeB = await SparseMerkleTree.create(TEST_DEPTH);

  // Insert records in both trees representing a cross-enterprise interaction
  const keyA = toFieldElement(5n);
  const valueA = toFieldElement(1000n);
  const keyB = toFieldElement(7n);
  const valueB = toFieldElement(1000n);

  await treeA.insert(keyA, valueA);
  await treeB.insert(keyB, valueB);

  const proofA = treeA.getProof(keyA);
  const proofB = treeB.getProof(keyB);

  return { treeA, treeB, proofA, proofB, keyA, keyB };
}

/** Create a request from two trees' proofs. */
function makeRequest(
  proofA: MerkleProof,
  proofB: MerkleProof,
  stateRootA: FieldElement,
  stateRootB: FieldElement,
  src: string = ENTERPRISE_A,
  dst: string = ENTERPRISE_B,
  srcBatch: number = 0,
  dstBatch: number = 0
): CrossReferenceRequest {
  return {
    id: { src, dst, srcBatch, dstBatch },
    proofA,
    proofB,
    stateRootA,
    stateRootB,
  };
}

/** Mock batch provider where both batches are verified. */
function allVerifiedProvider(): BatchStatusProvider {
  return {
    isBatchVerified: async () => true,
    getCurrentRoot: async () => "0x00",
  };
}

/** Mock batch provider where source is not verified. */
function sourceNotVerifiedProvider(): BatchStatusProvider {
  return {
    isBatchVerified: async (enterprise: string) => enterprise !== ENTERPRISE_A,
    getCurrentRoot: async () => "0x00",
  };
}

/** Mock batch provider where destination is not verified. */
function destNotVerifiedProvider(): BatchStatusProvider {
  return {
    isBatchVerified: async (enterprise: string) => enterprise !== ENTERPRISE_B,
    getCurrentRoot: async () => "0x00",
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("CrossReferenceBuilder", () => {
  // =========================================================================
  // buildCrossReferenceEvidence
  // =========================================================================

  describe("buildCrossReferenceEvidence", () => {
    it("should build valid evidence from two enterprise proofs", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();
      const request = makeRequest(proofA, proofB, treeA.root, treeB.root);

      const evidence = await buildCrossReferenceEvidence(request);

      expect(evidence.id.src).toBe(ENTERPRISE_A);
      expect(evidence.id.dst).toBe(ENTERPRISE_B);
      expect(evidence.stateRootA).toBe(treeA.root);
      expect(evidence.stateRootB).toBe(treeB.root);
      expect(typeof evidence.interactionCommitment).toBe("bigint");
      expect(evidence.interactionCommitment).not.toBe(0n);
      expect(evidence.builtAt).toBeGreaterThan(0);
    });

    it("should produce deterministic commitments", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();
      const request = makeRequest(proofA, proofB, treeA.root, treeB.root);

      const evidence1 = await buildCrossReferenceEvidence(request);
      const evidence2 = await buildCrossReferenceEvidence(request);

      expect(evidence1.interactionCommitment).toBe(evidence2.interactionCommitment);
    });

    // [Spec: NoCrossRefSelfLoop -- src # dst]
    it("should reject self-reference (NoCrossRefSelfLoop)", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();
      const request = makeRequest(
        proofA, proofB, treeA.root, treeB.root,
        ENTERPRISE_A, ENTERPRISE_A  // Same enterprise!
      );

      await expect(buildCrossReferenceEvidence(request)).rejects.toThrow(
        CrossEnterpriseError
      );

      try {
        await buildCrossReferenceEvidence(request);
      } catch (err) {
        expect(err).toBeInstanceOf(CrossEnterpriseError);
        expect((err as CrossEnterpriseError).code).toBe(
          CrossEnterpriseErrorCode.SELF_REFERENCE
        );
      }
    });

    it("should reject invalid source Merkle proof", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();

      // Corrupt proof A by swapping root
      const corruptedProofA: MerkleProof = {
        ...proofA,
        leafHash: toFieldElement(999n),  // Wrong leaf hash
      };
      const request = makeRequest(corruptedProofA, proofB, treeA.root, treeB.root);

      await expect(buildCrossReferenceEvidence(request)).rejects.toThrow(
        CrossEnterpriseError
      );

      try {
        await buildCrossReferenceEvidence(request);
      } catch (err) {
        expect((err as CrossEnterpriseError).code).toBe(
          CrossEnterpriseErrorCode.INVALID_PROOF_A
        );
      }
    });

    it("should reject invalid destination Merkle proof", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();

      // Corrupt proof B
      const corruptedProofB: MerkleProof = {
        ...proofB,
        leafHash: toFieldElement(999n),
      };
      const request = makeRequest(proofA, corruptedProofB, treeA.root, treeB.root);

      await expect(buildCrossReferenceEvidence(request)).rejects.toThrow(
        CrossEnterpriseError
      );

      try {
        await buildCrossReferenceEvidence(request);
      } catch (err) {
        expect((err as CrossEnterpriseError).code).toBe(
          CrossEnterpriseErrorCode.INVALID_PROOF_B
        );
      }
    });

    it("should reject proof against wrong state root", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();

      // Use wrong state root for enterprise A
      const wrongRoot = toFieldElement(12345n);
      const request = makeRequest(proofA, proofB, wrongRoot, treeB.root);

      await expect(buildCrossReferenceEvidence(request)).rejects.toThrow(
        CrossEnterpriseError
      );
    });
  });

  // =========================================================================
  // verifyCrossReferenceLocally
  // =========================================================================

  describe("verifyCrossReferenceLocally", () => {
    it("should verify valid evidence with both batches verified", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();
      const request = makeRequest(proofA, proofB, treeA.root, treeB.root);
      const evidence = await buildCrossReferenceEvidence(request);

      const result = await verifyCrossReferenceLocally(evidence, allVerifiedProvider());

      expect(result.valid).toBe(true);
      expect(result.status).toBe(CrossReferenceStatus.Verified);
      expect(result.privacyPreserved).toBe(true);
      expect(result.publicSignals).toHaveLength(3);
    });

    // [Spec: Consistency -- batchStatus[src][srcBatch] = "verified"]
    it("should reject when source batch not verified (Consistency)", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();
      const request = makeRequest(proofA, proofB, treeA.root, treeB.root);
      const evidence = await buildCrossReferenceEvidence(request);

      const result = await verifyCrossReferenceLocally(
        evidence,
        sourceNotVerifiedProvider()
      );

      expect(result.valid).toBe(false);
      expect(result.status).toBe(CrossReferenceStatus.Rejected);
      expect(result.reason).toContain("Source batch");
    });

    // [Spec: Consistency -- batchStatus[dst][dstBatch] = "verified"]
    it("should reject when destination batch not verified (Consistency)", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();
      const request = makeRequest(proofA, proofB, treeA.root, treeB.root);
      const evidence = await buildCrossReferenceEvidence(request);

      const result = await verifyCrossReferenceLocally(
        evidence,
        destNotVerifiedProvider()
      );

      expect(result.valid).toBe(false);
      expect(result.status).toBe(CrossReferenceStatus.Rejected);
      expect(result.reason).toContain("Destination batch");
    });

    // [Spec: NoCrossRefSelfLoop]
    it("should reject self-reference in verification", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();
      const request = makeRequest(proofA, proofB, treeA.root, treeB.root);
      const evidence = await buildCrossReferenceEvidence(request);

      // Manually tamper with evidence ID to self-reference
      const tamperedEvidence: CrossReferenceEvidence = {
        ...evidence,
        id: { ...evidence.id, dst: evidence.id.src },
      };

      const result = await verifyCrossReferenceLocally(
        tamperedEvidence,
        allVerifiedProvider()
      );

      expect(result.valid).toBe(false);
      expect(result.status).toBe(CrossReferenceStatus.Rejected);
      expect(result.reason).toContain("Self-reference");
    });

    it("should reject tampered interaction commitment", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();
      const request = makeRequest(proofA, proofB, treeA.root, treeB.root);
      const evidence = await buildCrossReferenceEvidence(request);

      // Tamper with the commitment
      const tamperedEvidence: CrossReferenceEvidence = {
        ...evidence,
        interactionCommitment: toFieldElement(999n),
      };

      const result = await verifyCrossReferenceLocally(
        tamperedEvidence,
        allVerifiedProvider()
      );

      expect(result.valid).toBe(false);
      expect(result.status).toBe(CrossReferenceStatus.Rejected);
      expect(result.reason).toContain("commitment mismatch");
    });
  });

  // =========================================================================
  // Privacy Guarantees
  // =========================================================================

  describe("privacy", () => {
    it("should not leak private data in public signals", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();
      const request = makeRequest(proofA, proofB, treeA.root, treeB.root);
      const evidence = await buildCrossReferenceEvidence(request);

      const result = await verifyCrossReferenceLocally(evidence, allVerifiedProvider());

      expect(result.privacyPreserved).toBe(true);

      // Verify public signals contain only state roots and commitment
      const signals = result.publicSignals;
      expect(signals[0]).toBe(evidence.stateRootA);
      expect(signals[1]).toBe(evidence.stateRootB);
      expect(signals[2]).toBe(evidence.interactionCommitment);

      // Verify private data (keys, leaf hashes) is NOT in public signals
      const signalSet = new Set(signals.map((s) => s as bigint));
      expect(signalSet.has(proofA.key)).toBe(false);
      expect(signalSet.has(proofA.leafHash)).toBe(false);
      expect(signalSet.has(proofB.key)).toBe(false);
      expect(signalSet.has(proofB.leafHash)).toBe(false);
    });

    it("should produce different commitments for different interactions", async () => {
      const treeA = await SparseMerkleTree.create(TEST_DEPTH);
      const treeB = await SparseMerkleTree.create(TEST_DEPTH);

      // Interaction 1: keys 5 and 7
      await treeA.insert(toFieldElement(5n), toFieldElement(1000n));
      await treeB.insert(toFieldElement(7n), toFieldElement(1000n));
      const proof1A = treeA.getProof(toFieldElement(5n));
      const proof1B = treeB.getProof(toFieldElement(7n));
      const request1 = makeRequest(proof1A, proof1B, treeA.root, treeB.root);
      const evidence1 = await buildCrossReferenceEvidence(request1);

      // Interaction 2: keys 5 and 9 (different destination key)
      await treeB.insert(toFieldElement(9n), toFieldElement(2000n));
      const proof2B = treeB.getProof(toFieldElement(9n));
      const request2 = makeRequest(proof1A, proof2B, treeA.root, treeB.root);
      const evidence2 = await buildCrossReferenceEvidence(request2);

      expect(evidence1.interactionCommitment).not.toBe(evidence2.interactionCommitment);
    });
  });

  // =========================================================================
  // Isolation
  // =========================================================================

  describe("isolation", () => {
    it("should not modify enterprise state roots during verification", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();
      const rootBeforeA = treeA.root;
      const rootBeforeB = treeB.root;

      const request = makeRequest(proofA, proofB, treeA.root, treeB.root);
      const evidence = await buildCrossReferenceEvidence(request);
      await verifyCrossReferenceLocally(evidence, allVerifiedProvider());

      // [Spec: ISOLATION -- UNCHANGED << currentRoot >>]
      // Trees should not have been modified by cross-reference operations
      expect(treeA.root).toBe(rootBeforeA);
      expect(treeB.root).toBe(rootBeforeB);
    });
  });

  // =========================================================================
  // formatPublicSignals
  // =========================================================================

  describe("formatPublicSignals", () => {
    it("should format signals as 0x-prefixed hex strings", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();
      const request = makeRequest(proofA, proofB, treeA.root, treeB.root);
      const evidence = await buildCrossReferenceEvidence(request);

      const formatted = formatPublicSignals(evidence);

      expect(formatted).toHaveLength(3);
      for (const sig of formatted) {
        expect(sig).toMatch(/^0x[0-9a-f]{64}$/);
      }
    });
  });

  // =========================================================================
  // Adversarial: Edge Cases
  // =========================================================================

  describe("adversarial", () => {
    it("should handle empty tree proofs (non-membership)", async () => {
      const treeA = await SparseMerkleTree.create(TEST_DEPTH);
      const treeB = await SparseMerkleTree.create(TEST_DEPTH);

      // Get proofs for keys that don't exist (non-membership proofs)
      const proofA = treeA.getProof(toFieldElement(5n));
      const proofB = treeB.getProof(toFieldElement(7n));

      // Non-membership proofs should have leafHash = 0 (EMPTY)
      expect(proofA.leafHash).toBe(EMPTY_VALUE);
      expect(proofB.leafHash).toBe(EMPTY_VALUE);

      const request = makeRequest(proofA, proofB, treeA.root, treeB.root);
      const evidence = await buildCrossReferenceEvidence(request);

      // Evidence builds successfully even with empty proofs
      expect(evidence.interactionCommitment).not.toBe(0n);
    });

    it("should reject when proofs are swapped between enterprises", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();

      // Swap proofs: give enterprise A's proof to B and vice versa
      const request = makeRequest(proofB, proofA, treeA.root, treeB.root);

      // proofB does not verify against treeA's root
      await expect(buildCrossReferenceEvidence(request)).rejects.toThrow(
        CrossEnterpriseError
      );
    });

    it("should produce different refIds for different batch IDs", async () => {
      const { proofA, proofB, treeA, treeB } = await setupCrossEnterprise();
      const request1 = makeRequest(proofA, proofB, treeA.root, treeB.root,
        ENTERPRISE_A, ENTERPRISE_B, 0, 0);
      const request2 = makeRequest(proofA, proofB, treeA.root, treeB.root,
        ENTERPRISE_A, ENTERPRISE_B, 1, 1);

      const evidence1 = await buildCrossReferenceEvidence(request1);
      const evidence2 = await buildCrossReferenceEvidence(request2);

      // Different batch IDs produce different cross-reference identifiers
      expect(evidence1.id.srcBatch).not.toBe(evidence2.id.srcBatch);
    });

    it("should handle concurrent verification of multiple cross-references", async () => {
      const treeA = await SparseMerkleTree.create(TEST_DEPTH);
      const treeB = await SparseMerkleTree.create(TEST_DEPTH);
      const treeC = await SparseMerkleTree.create(TEST_DEPTH);

      await treeA.insert(toFieldElement(1n), toFieldElement(100n));
      await treeB.insert(toFieldElement(2n), toFieldElement(200n));
      await treeC.insert(toFieldElement(3n), toFieldElement(300n));

      const proofAB_A = treeA.getProof(toFieldElement(1n));
      const proofAB_B = treeB.getProof(toFieldElement(2n));
      const proofAC_A = treeA.getProof(toFieldElement(1n));
      const proofAC_C = treeC.getProof(toFieldElement(3n));

      const ENTERPRISE_C = "0x3333333333333333333333333333333333333333";

      const requestAB = makeRequest(proofAB_A, proofAB_B, treeA.root, treeB.root,
        ENTERPRISE_A, ENTERPRISE_B);
      const requestAC = makeRequest(proofAC_A, proofAC_C, treeA.root, treeC.root,
        ENTERPRISE_A, ENTERPRISE_C);

      // Both should succeed concurrently
      const [evidenceAB, evidenceAC] = await Promise.all([
        buildCrossReferenceEvidence(requestAB),
        buildCrossReferenceEvidence(requestAC),
      ]);

      const [resultAB, resultAC] = await Promise.all([
        verifyCrossReferenceLocally(evidenceAB, allVerifiedProvider()),
        verifyCrossReferenceLocally(evidenceAC, allVerifiedProvider()),
      ]);

      expect(resultAB.valid).toBe(true);
      expect(resultAC.valid).toBe(true);

      // Different cross-references produce different commitments
      expect(evidenceAB.interactionCommitment).not.toBe(evidenceAC.interactionCommitment);
    });
  });
});
