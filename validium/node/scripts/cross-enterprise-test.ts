/**
 * Cross-Enterprise E2E Test
 *
 * Verifies that two enterprises can build and verify cross-references
 * while maintaining complete data isolation. Uses two separate SMT instances
 * (simulating two enterprise nodes) and the CrossReferenceBuilder.
 *
 * Scenarios:
 *   1. Two enterprises insert different data, build cross-reference, verify isolation
 *   2. Self-loop rejection (src == dst)
 *   3. Cross-reference with non-existent batch -> rejection
 *
 * Usage: npx ts-node scripts/cross-enterprise-test.ts
 */

import { SparseMerkleTree } from "../src/state";
import {
  buildCrossReferenceEvidence,
  verifyCrossReferenceLocally,
} from "../src/cross-enterprise/cross-reference-builder";
import type { CrossReferenceRequest, BatchStatusProvider } from "../src/cross-enterprise/types";
import { CrossReferenceStatus, CrossEnterpriseError } from "../src/cross-enterprise/types";

const DEPTH = 10;

interface TestResult {
  name: string;
  passed: boolean;
  details: string;
  durationMs: number;
}

const results: TestResult[] = [];

async function runScenario(name: string, fn: () => Promise<string>): Promise<void> {
  const start = Date.now();
  try {
    const details = await fn();
    results.push({ name, passed: true, details, durationMs: Date.now() - start });
    console.log(`  [PASS] ${name} (${Date.now() - start}ms)`);
  } catch (err) {
    const details = err instanceof Error ? err.message : String(err);
    results.push({ name, passed: false, details, durationMs: Date.now() - start });
    console.log(`  [FAIL] ${name}: ${details}`);
  }
}

async function main(): Promise<void> {
  console.log("Basis Network Validium -- Cross-Enterprise E2E Test");
  console.log("=".repeat(60));
  console.log();

  // Create two enterprise SMTs
  const treeA = await SparseMerkleTree.create(DEPTH);
  const treeB = await SparseMerkleTree.create(DEPTH);

  // Insert data into enterprise A
  await treeA.insert(100n, 42n);
  await treeA.insert(200n, 84n);
  const rootA = treeA.root;

  // Insert different data into enterprise B
  await treeB.insert(300n, 99n);
  await treeB.insert(400n, 198n);
  const rootB = treeB.root;

  // Mock batch status provider
  const batchProvider: BatchStatusProvider = {
    async isBatchVerified(_enterprise: string, _batchId: number): Promise<boolean> {
      return true;
    },
    async getCurrentRoot(enterprise: string): Promise<string> {
      if (enterprise === "0x1111111111111111111111111111111111111111") return rootA.toString(16);
      if (enterprise === "0x2222222222222222222222222222222222222222") return rootB.toString(16);
      return "0";
    },
  };

  // Scenario 1: Build and verify cross-reference between two enterprises
  await runScenario(
    "Scenario 1: Cross-reference between two enterprises",
    async () => {
      const proofA = treeA.getProof(100n);
      const proofB = treeB.getProof(300n);

      const request: CrossReferenceRequest = {
        id: {
          src: "0x1111111111111111111111111111111111111111",
          dst: "0x2222222222222222222222222222222222222222",
          srcBatch: 0,
          dstBatch: 0,
        },
        proofA: {
          key: 100n as any,
          leafHash: proofA.leafHash,
          siblings: proofA.siblings,
          pathBits: proofA.pathBits,
          root: rootA,
        },
        proofB: {
          key: 300n as any,
          leafHash: proofB.leafHash,
          siblings: proofB.siblings,
          pathBits: proofB.pathBits,
          root: rootB,
        },
        stateRootA: rootA,
        stateRootB: rootB,
      };

      const evidence = await buildCrossReferenceEvidence(request);

      if (!evidence.interactionCommitment) {
        throw new Error("No interaction commitment generated");
      }

      const verification = await verifyCrossReferenceLocally(evidence, batchProvider);

      if (verification.status !== CrossReferenceStatus.Verified) {
        throw new Error(`Expected Verified, got ${verification.status}`);
      }

      return `Cross-reference verified. Commitment: ${String(evidence.interactionCommitment).toString().slice(0, 16)}... Privacy preserved: ${verification.privacyPreserved}`;
    }
  );

  // Scenario 2: Self-loop rejection
  await runScenario(
    "Scenario 2: Self-loop rejection (src == dst)",
    async () => {
      const proof = treeA.getProof(100n);

      try {
        await buildCrossReferenceEvidence({
          id: {
            src: "0x1111111111111111111111111111111111111111",
            dst: "0x1111111111111111111111111111111111111111", // same!
            srcBatch: 0,
            dstBatch: 0,
          },
          proofA: {
            key: 100n as any,
            leafHash: proof.leafHash,
            siblings: proof.siblings,
            pathBits: proof.pathBits,
            root: rootA,
          },
          proofB: {
            key: 100n as any,
            leafHash: proof.leafHash,
            siblings: proof.siblings,
            pathBits: proof.pathBits,
            root: rootA,
          },
          stateRootA: rootA,
          stateRootB: rootA,
        });
        throw new Error("Should have thrown for self-loop");
      } catch (err) {
        if (err instanceof CrossEnterpriseError) {
          return `Correctly rejected self-loop: ${err.message}`;
        }
        throw err;
      }
    }
  );

  // Scenario 3: Enterprise isolation -- tree A data not accessible from tree B proof
  await runScenario(
    "Scenario 3: Enterprise isolation verification",
    async () => {
      // Get proof from tree A for key 100
      const proofA = treeA.getProof(100n);
      // Try to verify it against tree B's root -- should fail
      const validInA = treeA.verifyProof(rootA, 100n as any, proofA.leafHash, proofA);
      const validInB = treeB.verifyProof(rootB, 100n as any, proofA.leafHash, proofA);

      if (!validInA) throw new Error("Proof should be valid in tree A");
      if (validInB) throw new Error("Proof from A should NOT be valid in tree B");

      return "Enterprise A proof valid in A, invalid in B. Isolation confirmed.";
    }
  );

  // Summary
  console.log();
  console.log("=".repeat(60));
  console.log("CROSS-ENTERPRISE TEST SUMMARY");
  console.log("=".repeat(60));
  console.log();

  const passed = results.filter((r) => r.passed).length;
  const failed = results.filter((r) => !r.passed).length;

  for (const r of results) {
    console.log(`  [${r.passed ? "PASS" : "FAIL"}] ${r.name} (${r.durationMs}ms)`);
    console.log(`         ${r.details}`);
  }

  console.log();
  console.log(`Results: ${passed} passed, ${failed} failed, ${results.length} total`);
  console.log("=".repeat(60));

  process.exit(failed > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
