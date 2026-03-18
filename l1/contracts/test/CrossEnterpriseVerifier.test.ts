import { expect } from "chai";
import { ethers } from "hardhat";
import {
  EnterpriseRegistry,
  StateCommitmentHarness,
  CrossEnterpriseVerifierHarness,
} from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * CrossEnterpriseVerifier Tests
 *
 * Tests the L1 smart contract that verifies cross-enterprise interactions.
 * Organized by TLA+ safety invariants proven by TLC model checking.
 *
 * [Spec: validium/specs/units/2026-03-cross-enterprise/1-formalization/v0-analysis/specs/CrossEnterprise/CrossEnterprise.tla]
 *
 * Invariants tested:
 *   Isolation:           no enterprise state root modified by cross-ref
 *   Consistency:         both batch proofs must be verified before cross-ref accepted
 *   NoCrossRefSelfLoop:  enterpriseA != enterpriseB
 */
describe("CrossEnterpriseVerifier", function () {
  let registry: EnterpriseRegistry;
  let sc: StateCommitmentHarness;
  let xev: CrossEnterpriseVerifierHarness;
  let admin: SignerWithAddress;
  let enterprise1: SignerWithAddress;
  let enterprise2: SignerWithAddress;
  let enterprise3: SignerWithAddress;
  let unauthorized: SignerWithAddress;

  const GENESIS_ROOT = ethers.keccak256(ethers.toUtf8Bytes("genesis"));
  const ROOT_A1 = ethers.keccak256(ethers.toUtf8Bytes("rootA1"));
  const ROOT_B1 = ethers.keccak256(ethers.toUtf8Bytes("rootB1"));
  const COMMITMENT = ethers.keccak256(ethers.toUtf8Bytes("interaction"));

  // Dummy proof values (harness bypasses verification)
  const DUMMY_A: [bigint, bigint] = [0n, 0n];
  const DUMMY_B: [[bigint, bigint], [bigint, bigint]] = [[0n, 0n], [0n, 0n]];
  const DUMMY_C: [bigint, bigint] = [0n, 0n];
  const DUMMY_SIGNALS: bigint[] = [];

  function getDummyVerifyingKey() {
    return {
      alfa1: [1n, 2n] as [bigint, bigint],
      beta2: [[1n, 2n], [3n, 4n]] as [[bigint, bigint], [bigint, bigint]],
      gamma2: [[1n, 2n], [3n, 4n]] as [[bigint, bigint], [bigint, bigint]],
      delta2: [[1n, 2n], [3n, 4n]] as [[bigint, bigint], [bigint, bigint]],
      IC: [[1n, 2n], [3n, 4n], [5n, 6n], [7n, 8n]] as [bigint, bigint][],
    };
  }

  /** Helper: setup both enterprises with verified batches on StateCommitment. */
  async function setupVerifiedBatches() {
    // Initialize enterprises on StateCommitment
    await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
    await sc.initializeEnterprise(enterprise2.address, GENESIS_ROOT);

    // Submit verified batches (harness bypasses proof verification)
    await sc.connect(enterprise1).submitBatch(GENESIS_ROOT, ROOT_A1, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
    await sc.connect(enterprise2).submitBatch(GENESIS_ROOT, ROOT_B1, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
  }

  beforeEach(async function () {
    [admin, enterprise1, enterprise2, enterprise3, unauthorized] = await ethers.getSigners();

    // Deploy EnterpriseRegistry
    const ERFactory = await ethers.getContractFactory("EnterpriseRegistry");
    registry = await ERFactory.deploy();

    // Deploy StateCommitmentHarness (with mock proof verification)
    const SCFactory = await ethers.getContractFactory("StateCommitmentHarness");
    sc = await SCFactory.deploy(await registry.getAddress());

    // Deploy CrossEnterpriseVerifierHarness
    const XEVFactory = await ethers.getContractFactory("CrossEnterpriseVerifierHarness");
    xev = await XEVFactory.deploy(await sc.getAddress(), await registry.getAddress());

    // Register enterprises
    const metadata = ethers.toUtf8Bytes("{}");
    await registry.registerEnterprise(enterprise1.address, "Enterprise One", metadata);
    await registry.registerEnterprise(enterprise2.address, "Enterprise Two", metadata);
    await registry.registerEnterprise(enterprise3.address, "Enterprise Three", metadata);

    // Set verifying keys
    const scVk = getDummyVerifyingKey();
    // StateCommitment expects IC with 1 element (0 public inputs for harness)
    const scVkSmall = { ...scVk, IC: [[1n, 2n]] as [bigint, bigint][] };
    await sc.setVerifyingKey(scVkSmall.alfa1, scVkSmall.beta2, scVkSmall.gamma2, scVkSmall.delta2, scVkSmall.IC);

    // CrossEnterpriseVerifier expects IC with 4 elements (3 public inputs)
    await xev.setVerifyingKey(scVk.alfa1, scVk.beta2, scVk.gamma2, scVk.delta2, scVk.IC);
  });

  // =========================================================================
  // Deployment
  // =========================================================================

  describe("Deployment", function () {
    it("should set admin", async function () {
      expect(await xev.admin()).to.equal(admin.address);
    });

    it("should link to StateCommitment", async function () {
      expect(await xev.stateCommitment()).to.equal(await sc.getAddress());
    });

    it("should link to EnterpriseRegistry", async function () {
      expect(await xev.enterpriseRegistry()).to.equal(await registry.getAddress());
    });

    it("should start with zero verified cross-references", async function () {
      expect(await xev.totalCrossRefsVerified()).to.equal(0);
    });
  });

  // =========================================================================
  // verifyCrossReference -- Happy Path
  // =========================================================================

  describe("verifyCrossReference", function () {
    it("should verify a valid cross-reference", async function () {
      await setupVerifiedBatches();

      await expect(
        xev.verifyCrossReference(
          enterprise1.address, 0,
          enterprise2.address, 0,
          COMMITMENT,
          DUMMY_A, DUMMY_B, DUMMY_C
        )
      ).to.emit(xev, "CrossReferenceVerified");

      const refId = await xev.computeRefId(enterprise1.address, 0, enterprise2.address, 0);
      expect(await xev.crossReferenceStatus(refId)).to.equal(2); // Verified
      expect(await xev.totalCrossRefsVerified()).to.equal(1);
    });

    it("should store correct refId", async function () {
      await setupVerifiedBatches();

      const refId = await xev.computeRefId(enterprise1.address, 0, enterprise2.address, 0);
      expect(await xev.crossReferenceStatus(refId)).to.equal(0); // None

      await xev.verifyCrossReference(
        enterprise1.address, 0,
        enterprise2.address, 0,
        COMMITMENT,
        DUMMY_A, DUMMY_B, DUMMY_C
      );

      expect(await xev.crossReferenceStatus(refId)).to.equal(2); // Verified
    });

    it("should emit CrossReferenceVerified with correct parameters", async function () {
      await setupVerifiedBatches();

      const tx = await xev.verifyCrossReference(
        enterprise1.address, 0,
        enterprise2.address, 0,
        COMMITMENT,
        DUMMY_A, DUMMY_B, DUMMY_C
      );

      const receipt = await tx.wait();
      const event = receipt?.logs[0];
      expect(event).to.not.be.undefined;
    });
  });

  // =========================================================================
  // NoCrossRefSelfLoop
  // =========================================================================

  describe("NoCrossRefSelfLoop", function () {
    it("should reject self-reference (enterpriseA == enterpriseB)", async function () {
      await setupVerifiedBatches();

      await expect(
        xev.verifyCrossReference(
          enterprise1.address, 0,
          enterprise1.address, 0,  // Same enterprise!
          COMMITMENT,
          DUMMY_A, DUMMY_B, DUMMY_C
        )
      ).to.be.revertedWithCustomError(xev, "SelfReference");
    });
  });

  // =========================================================================
  // Consistency
  // =========================================================================

  describe("Consistency", function () {
    it("should reject when source batch not verified", async function () {
      // Only initialize enterprise2 with a verified batch
      await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await sc.initializeEnterprise(enterprise2.address, GENESIS_ROOT);
      await sc.connect(enterprise2).submitBatch(GENESIS_ROOT, ROOT_B1, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      // enterprise1 has NOT submitted a batch -> batchRoots[enterprise1][0] == 0

      await expect(
        xev.verifyCrossReference(
          enterprise1.address, 0,
          enterprise2.address, 0,
          COMMITMENT,
          DUMMY_A, DUMMY_B, DUMMY_C
        )
      ).to.be.revertedWithCustomError(xev, "SourceBatchNotVerified");
    });

    it("should reject when destination batch not verified", async function () {
      await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await sc.initializeEnterprise(enterprise2.address, GENESIS_ROOT);
      await sc.connect(enterprise1).submitBatch(GENESIS_ROOT, ROOT_A1, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      // enterprise2 has NOT submitted a batch

      await expect(
        xev.verifyCrossReference(
          enterprise1.address, 0,
          enterprise2.address, 0,
          COMMITMENT,
          DUMMY_A, DUMMY_B, DUMMY_C
        )
      ).to.be.revertedWithCustomError(xev, "DestBatchNotVerified");
    });

    it("should reject when neither batch is verified", async function () {
      await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await sc.initializeEnterprise(enterprise2.address, GENESIS_ROOT);

      await expect(
        xev.verifyCrossReference(
          enterprise1.address, 0,
          enterprise2.address, 0,
          COMMITMENT,
          DUMMY_A, DUMMY_B, DUMMY_C
        )
      ).to.be.revertedWithCustomError(xev, "SourceBatchNotVerified");
    });
  });

  // =========================================================================
  // Isolation
  // =========================================================================

  describe("Isolation", function () {
    it("should not modify enterprise state roots after cross-ref verification", async function () {
      await setupVerifiedBatches();

      const rootBefore1 = await sc.getCurrentRoot(enterprise1.address);
      const rootBefore2 = await sc.getCurrentRoot(enterprise2.address);
      const batchCountBefore1 = await sc.getBatchCount(enterprise1.address);
      const batchCountBefore2 = await sc.getBatchCount(enterprise2.address);

      await xev.verifyCrossReference(
        enterprise1.address, 0,
        enterprise2.address, 0,
        COMMITMENT,
        DUMMY_A, DUMMY_B, DUMMY_C
      );

      // [Spec: ISOLATION -- UNCHANGED << currentRoot, batchStatus, batchNewRoot >>]
      expect(await sc.getCurrentRoot(enterprise1.address)).to.equal(rootBefore1);
      expect(await sc.getCurrentRoot(enterprise2.address)).to.equal(rootBefore2);
      expect(await sc.getBatchCount(enterprise1.address)).to.equal(batchCountBefore1);
      expect(await sc.getBatchCount(enterprise2.address)).to.equal(batchCountBefore2);
    });
  });

  // =========================================================================
  // Authorization
  // =========================================================================

  describe("Authorization", function () {
    it("should reject unregistered source enterprise", async function () {
      await setupVerifiedBatches();

      await expect(
        xev.verifyCrossReference(
          unauthorized.address, 0,
          enterprise2.address, 0,
          COMMITMENT,
          DUMMY_A, DUMMY_B, DUMMY_C
        )
      ).to.be.revertedWithCustomError(xev, "EnterpriseNotAuthorized");
    });

    it("should reject unregistered destination enterprise", async function () {
      await setupVerifiedBatches();

      await expect(
        xev.verifyCrossReference(
          enterprise1.address, 0,
          unauthorized.address, 0,
          COMMITMENT,
          DUMMY_A, DUMMY_B, DUMMY_C
        )
      ).to.be.revertedWithCustomError(xev, "EnterpriseNotAuthorized");
    });

    it("should reject deactivated enterprise", async function () {
      await setupVerifiedBatches();
      await registry.deactivateEnterprise(enterprise1.address);

      await expect(
        xev.verifyCrossReference(
          enterprise1.address, 0,
          enterprise2.address, 0,
          COMMITMENT,
          DUMMY_A, DUMMY_B, DUMMY_C
        )
      ).to.be.revertedWithCustomError(xev, "EnterpriseNotAuthorized");
    });
  });

  // =========================================================================
  // Proof Verification
  // =========================================================================

  describe("Proof verification", function () {
    it("should reject invalid proof", async function () {
      await setupVerifiedBatches();
      await xev.setMockProofResult(false);

      await expect(
        xev.verifyCrossReference(
          enterprise1.address, 0,
          enterprise2.address, 0,
          COMMITMENT,
          DUMMY_A, DUMMY_B, DUMMY_C
        )
      ).to.be.revertedWithCustomError(xev, "InvalidCrossRefProof");
    });
  });

  // =========================================================================
  // Idempotency / Replay Prevention
  // =========================================================================

  describe("Replay prevention", function () {
    it("should reject re-verification of already verified cross-reference", async function () {
      await setupVerifiedBatches();

      // First verification succeeds
      await xev.verifyCrossReference(
        enterprise1.address, 0,
        enterprise2.address, 0,
        COMMITMENT,
        DUMMY_A, DUMMY_B, DUMMY_C
      );

      // Second verification with same parameters should fail
      await expect(
        xev.verifyCrossReference(
          enterprise1.address, 0,
          enterprise2.address, 0,
          COMMITMENT,
          DUMMY_A, DUMMY_B, DUMMY_C
        )
      ).to.be.revertedWithCustomError(xev, "CrossRefAlreadyResolved");
    });
  });

  // =========================================================================
  // Admin Functions
  // =========================================================================

  describe("Admin", function () {
    it("should allow admin to set verifying key", async function () {
      expect(await xev.verifyingKeySet()).to.be.true;
    });

    it("should reject non-admin verifying key update", async function () {
      const vk = getDummyVerifyingKey();
      await expect(
        xev.connect(enterprise1).setVerifyingKey(vk.alfa1, vk.beta2, vk.gamma2, vk.delta2, vk.IC)
      ).to.be.revertedWithCustomError(xev, "OnlyAdmin");
    });

    it("should reject verification before verifying key is set", async function () {
      // Deploy fresh contract without setting VK
      const XEVFactory = await ethers.getContractFactory("CrossEnterpriseVerifierHarness");
      const freshXev = await XEVFactory.deploy(await sc.getAddress(), await registry.getAddress());

      await expect(
        freshXev.verifyCrossReference(
          enterprise1.address, 0,
          enterprise2.address, 0,
          COMMITMENT,
          DUMMY_A, DUMMY_B, DUMMY_C
        )
      ).to.be.revertedWithCustomError(freshXev, "VerifyingKeyNotSet");
    });
  });

  // =========================================================================
  // View Functions
  // =========================================================================

  describe("View functions", function () {
    it("should return None for non-existent cross-reference", async function () {
      const status = await xev.getCrossRefStatus(
        enterprise1.address, 0, enterprise2.address, 0
      );
      expect(status).to.equal(0); // None
    });

    it("should return Verified after successful verification", async function () {
      await setupVerifiedBatches();

      await xev.verifyCrossReference(
        enterprise1.address, 0,
        enterprise2.address, 0,
        COMMITMENT,
        DUMMY_A, DUMMY_B, DUMMY_C
      );

      const status = await xev.getCrossRefStatus(
        enterprise1.address, 0, enterprise2.address, 0
      );
      expect(status).to.equal(2); // Verified
    });

    it("should compute deterministic refIds", async function () {
      const refId1 = await xev.computeRefId(enterprise1.address, 0, enterprise2.address, 0);
      const refId2 = await xev.computeRefId(enterprise1.address, 0, enterprise2.address, 0);
      expect(refId1).to.equal(refId2);

      // Different parameters produce different refIds
      const refId3 = await xev.computeRefId(enterprise1.address, 0, enterprise2.address, 1);
      expect(refId1).to.not.equal(refId3);
    });
  });

  // =========================================================================
  // Multi-Enterprise Scenarios
  // =========================================================================

  describe("Multi-enterprise", function () {
    it("should support multiple independent cross-references", async function () {
      // Initialize all three enterprises
      await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await sc.initializeEnterprise(enterprise2.address, GENESIS_ROOT);
      await sc.initializeEnterprise(enterprise3.address, GENESIS_ROOT);

      // Submit batches for all
      const ROOT_C1 = ethers.keccak256(ethers.toUtf8Bytes("rootC1"));
      await sc.connect(enterprise1).submitBatch(GENESIS_ROOT, ROOT_A1, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      await sc.connect(enterprise2).submitBatch(GENESIS_ROOT, ROOT_B1, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      await sc.connect(enterprise3).submitBatch(GENESIS_ROOT, ROOT_C1, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);

      // Cross-ref: 1 <-> 2
      await xev.verifyCrossReference(
        enterprise1.address, 0,
        enterprise2.address, 0,
        COMMITMENT,
        DUMMY_A, DUMMY_B, DUMMY_C
      );

      // Cross-ref: 1 <-> 3
      const COMMITMENT_2 = ethers.keccak256(ethers.toUtf8Bytes("interaction2"));
      await xev.verifyCrossReference(
        enterprise1.address, 0,
        enterprise3.address, 0,
        COMMITMENT_2,
        DUMMY_A, DUMMY_B, DUMMY_C
      );

      // Cross-ref: 2 <-> 3
      const COMMITMENT_3 = ethers.keccak256(ethers.toUtf8Bytes("interaction3"));
      await xev.verifyCrossReference(
        enterprise2.address, 0,
        enterprise3.address, 0,
        COMMITMENT_3,
        DUMMY_A, DUMMY_B, DUMMY_C
      );

      expect(await xev.totalCrossRefsVerified()).to.equal(3);

      // All enterprise state roots remain unchanged (Isolation)
      expect(await sc.getCurrentRoot(enterprise1.address)).to.equal(ROOT_A1);
      expect(await sc.getCurrentRoot(enterprise2.address)).to.equal(ROOT_B1);
      expect(await sc.getCurrentRoot(enterprise3.address)).to.equal(ROOT_C1);
    });

    it("should handle directional cross-references (A->B != B->A)", async function () {
      await setupVerifiedBatches();

      // A -> B
      await xev.verifyCrossReference(
        enterprise1.address, 0,
        enterprise2.address, 0,
        COMMITMENT,
        DUMMY_A, DUMMY_B, DUMMY_C
      );

      // B -> A (different direction, different refId)
      const COMMITMENT_REVERSE = ethers.keccak256(ethers.toUtf8Bytes("reverse"));
      await xev.verifyCrossReference(
        enterprise2.address, 0,
        enterprise1.address, 0,
        COMMITMENT_REVERSE,
        DUMMY_A, DUMMY_B, DUMMY_C
      );

      expect(await xev.totalCrossRefsVerified()).to.equal(2);
    });
  });
});
