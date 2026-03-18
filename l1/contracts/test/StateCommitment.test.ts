import { expect } from "chai";
import { ethers } from "hardhat";
import { EnterpriseRegistry, StateCommitmentHarness } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("StateCommitment", function () {
  let registry: EnterpriseRegistry;
  let sc: StateCommitmentHarness;
  let admin: SignerWithAddress;
  let enterprise1: SignerWithAddress;
  let enterprise2: SignerWithAddress;
  let unauthorized: SignerWithAddress;

  const GENESIS_ROOT = ethers.keccak256(ethers.toUtf8Bytes("genesis"));
  const ROOT_A = ethers.keccak256(ethers.toUtf8Bytes("rootA"));
  const ROOT_B = ethers.keccak256(ethers.toUtf8Bytes("rootB"));
  const ROOT_C = ethers.keccak256(ethers.toUtf8Bytes("rootC"));
  const ZERO_ROOT = ethers.ZeroHash;

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
      IC: [[1n, 2n]] as [bigint, bigint][],
    };
  }

  beforeEach(async function () {
    [admin, enterprise1, enterprise2, unauthorized] = await ethers.getSigners();

    const ERFactory = await ethers.getContractFactory("EnterpriseRegistry");
    registry = await ERFactory.deploy();

    const SCFactory = await ethers.getContractFactory("StateCommitmentHarness");
    sc = await SCFactory.deploy(await registry.getAddress());

    const metadata = ethers.toUtf8Bytes("{}");
    await registry.registerEnterprise(enterprise1.address, "Enterprise One", metadata);
    await registry.registerEnterprise(enterprise2.address, "Enterprise Two", metadata);

    const vk = getDummyVerifyingKey();
    await sc.setVerifyingKey(vk.alfa1, vk.beta2, vk.gamma2, vk.delta2, vk.IC);
  });

  // =========================================================================
  // Deployment
  // =========================================================================

  describe("Deployment", function () {
    it("should set the deployer as admin", async function () {
      expect(await sc.admin()).to.equal(admin.address);
    });

    it("should link to the enterprise registry", async function () {
      expect(await sc.enterpriseRegistry()).to.equal(await registry.getAddress());
    });

    it("should start with verifyingKeySet = true (set in beforeEach)", async function () {
      expect(await sc.verifyingKeySet()).to.be.true;
    });

    it("should start with zero total batches", async function () {
      expect(await sc.totalBatchesCommitted()).to.equal(0);
    });
  });

  // =========================================================================
  // setVerifyingKey
  // =========================================================================

  describe("setVerifyingKey", function () {
    it("should allow admin to set the verifying key", async function () {
      const freshSC = await (await ethers.getContractFactory("StateCommitmentHarness"))
        .deploy(await registry.getAddress());
      expect(await freshSC.verifyingKeySet()).to.be.false;

      const vk = getDummyVerifyingKey();
      await freshSC.setVerifyingKey(vk.alfa1, vk.beta2, vk.gamma2, vk.delta2, vk.IC);
      expect(await freshSC.verifyingKeySet()).to.be.true;
    });

    it("should revert if called by non-admin", async function () {
      const vk = getDummyVerifyingKey();
      await expect(
        sc.connect(enterprise1).setVerifyingKey(vk.alfa1, vk.beta2, vk.gamma2, vk.delta2, vk.IC)
      ).to.be.revertedWithCustomError(sc, "OnlyAdmin");
    });
  });

  // =========================================================================
  // initializeEnterprise
  // =========================================================================

  describe("initializeEnterprise", function () {
    it("should initialize an enterprise with a genesis root", async function () {
      await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);

      const state = await sc.enterprises(enterprise1.address);
      expect(state.currentRoot).to.equal(GENESIS_ROOT);
      expect(state.batchCount).to.equal(0);
      expect(state.initialized).to.be.true;
    });

    it("should emit EnterpriseInitialized event", async function () {
      const tx = await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt!.blockNumber);

      await expect(tx)
        .to.emit(sc, "EnterpriseInitialized")
        .withArgs(enterprise1.address, GENESIS_ROOT, block!.timestamp);
    });

    it("should revert if enterprise already initialized", async function () {
      await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await expect(
        sc.initializeEnterprise(enterprise1.address, ROOT_A)
      ).to.be.revertedWithCustomError(sc, "EnterpriseAlreadyInitialized");
    });

    it("should revert if called by non-admin", async function () {
      await expect(
        sc.connect(enterprise1).initializeEnterprise(enterprise1.address, GENESIS_ROOT)
      ).to.be.revertedWithCustomError(sc, "OnlyAdmin");
    });

    it("should allow initializing different enterprises independently", async function () {
      await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await sc.initializeEnterprise(enterprise2.address, ROOT_A);

      const state1 = await sc.enterprises(enterprise1.address);
      const state2 = await sc.enterprises(enterprise2.address);
      expect(state1.currentRoot).to.equal(GENESIS_ROOT);
      expect(state2.currentRoot).to.equal(ROOT_A);
    });
  });

  // =========================================================================
  // submitBatch -- Happy Path
  // =========================================================================

  describe("submitBatch (happy path)", function () {
    beforeEach(async function () {
      await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
    });

    it("should submit the first batch correctly", async function () {
      await sc.connect(enterprise1).submitBatch(
        GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );

      const state = await sc.enterprises(enterprise1.address);
      expect(state.currentRoot).to.equal(ROOT_A);
      expect(state.batchCount).to.equal(1);
      expect(state.initialized).to.be.true;
    });

    it("should emit BatchCommitted with correct arguments", async function () {
      const tx = await sc.connect(enterprise1).submitBatch(
        GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt!.blockNumber);

      await expect(tx)
        .to.emit(sc, "BatchCommitted")
        .withArgs(enterprise1.address, 0, GENESIS_ROOT, ROOT_A, block!.timestamp);
    });

    it("should auto-increment batchId (NoGap)", async function () {
      await sc.connect(enterprise1).submitBatch(
        GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      await sc.connect(enterprise1).submitBatch(
        ROOT_A, ROOT_B, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      await sc.connect(enterprise1).submitBatch(
        ROOT_B, ROOT_C, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );

      expect(await sc.getBatchCount(enterprise1.address)).to.equal(3);
      expect(await sc.getBatchRoot(enterprise1.address, 0)).to.equal(ROOT_A);
      expect(await sc.getBatchRoot(enterprise1.address, 1)).to.equal(ROOT_B);
      expect(await sc.getBatchRoot(enterprise1.address, 2)).to.equal(ROOT_C);
    });

    it("should store batch root in history", async function () {
      await sc.connect(enterprise1).submitBatch(
        GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );

      expect(await sc.batchRoots(enterprise1.address, 0)).to.equal(ROOT_A);
    });

    it("should increment totalBatchesCommitted", async function () {
      await sc.connect(enterprise1).submitBatch(
        GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      expect(await sc.totalBatchesCommitted()).to.equal(1);

      await sc.connect(enterprise1).submitBatch(
        ROOT_A, ROOT_B, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      expect(await sc.totalBatchesCommitted()).to.equal(2);
    });

    it("should maintain ChainContinuity across sequential batches", async function () {
      // Chain: GENESIS -> A -> B -> C
      await sc.connect(enterprise1).submitBatch(
        GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      await sc.connect(enterprise1).submitBatch(
        ROOT_A, ROOT_B, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      await sc.connect(enterprise1).submitBatch(
        ROOT_B, ROOT_C, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );

      // Verify final state
      expect(await sc.getCurrentRoot(enterprise1.address)).to.equal(ROOT_C);
      // Verify history matches chain
      expect(await sc.getBatchRoot(enterprise1.address, 2)).to.equal(ROOT_C);
    });
  });

  // =========================================================================
  // submitBatch -- Error Paths
  // =========================================================================

  describe("submitBatch (error paths)", function () {
    it("should revert if verifying key not set", async function () {
      const freshSC = await (await ethers.getContractFactory("StateCommitmentHarness"))
        .deploy(await registry.getAddress());
      await freshSC.initializeEnterprise(enterprise1.address, GENESIS_ROOT);

      await expect(
        freshSC.connect(enterprise1).submitBatch(
          GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
        )
      ).to.be.revertedWithCustomError(freshSC, "VerifyingKeyNotSet");
    });

    it("should revert if enterprise not authorized in registry", async function () {
      await expect(
        sc.connect(unauthorized).submitBatch(
          GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
        )
      ).to.be.revertedWithCustomError(sc, "NotAuthorized");
    });

    it("should revert if enterprise not initialized", async function () {
      // enterprise1 is registered but not initialized
      await expect(
        sc.connect(enterprise1).submitBatch(
          GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
        )
      ).to.be.revertedWithCustomError(sc, "EnterpriseNotInitialized");
    });

    it("should revert if prevRoot does not match currentRoot (ChainContinuity)", async function () {
      await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);

      await expect(
        sc.connect(enterprise1).submitBatch(
          ROOT_A, ROOT_B, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
        )
      ).to.be.revertedWithCustomError(sc, "RootChainBroken")
        .withArgs(GENESIS_ROOT, ROOT_A);
    });

    it("should revert if proof is invalid", async function () {
      await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await sc.setMockProofResult(false);

      await expect(
        sc.connect(enterprise1).submitBatch(
          GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
        )
      ).to.be.revertedWithCustomError(sc, "InvalidProof");
    });
  });

  // =========================================================================
  // View Functions
  // =========================================================================

  describe("View functions", function () {
    beforeEach(async function () {
      await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await sc.connect(enterprise1).submitBatch(
        GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
    });

    it("getCurrentRoot should return the latest root", async function () {
      expect(await sc.getCurrentRoot(enterprise1.address)).to.equal(ROOT_A);
    });

    it("getBatchRoot should return the root for a given batch", async function () {
      expect(await sc.getBatchRoot(enterprise1.address, 0)).to.equal(ROOT_A);
    });

    it("getBatchCount should return the number of batches", async function () {
      expect(await sc.getBatchCount(enterprise1.address)).to.equal(1);
    });

    it("isCommittedRoot should return true for a committed root", async function () {
      expect(await sc.isCommittedRoot(enterprise1.address, 0, ROOT_A)).to.be.true;
    });

    it("isCommittedRoot should return false for wrong root", async function () {
      expect(await sc.isCommittedRoot(enterprise1.address, 0, ROOT_B)).to.be.false;
    });

    it("isCommittedRoot should return false for uncommitted batch", async function () {
      expect(await sc.isCommittedRoot(enterprise1.address, 99, ROOT_A)).to.be.false;
    });

    it("getCurrentRoot should return zero for uninitialized enterprise", async function () {
      expect(await sc.getCurrentRoot(unauthorized.address)).to.equal(ZERO_ROOT);
    });
  });

  // =========================================================================
  // Adversarial Tests
  // =========================================================================

  describe("Adversarial", function () {
    beforeEach(async function () {
      await sc.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await sc.initializeEnterprise(enterprise2.address, ROOT_A);
    });

    // --- Gap Attack ---
    it("should prevent gap attack: batch IDs are structural, not caller-supplied", async function () {
      // Batch ID is derived from batchCount, not from any parameter.
      // The caller cannot specify batchId = 5 to skip ahead.
      await sc.connect(enterprise1).submitBatch(
        GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );

      // First batch is always ID 0
      expect(await sc.getBatchRoot(enterprise1.address, 0)).to.equal(ROOT_A);
      // No root at index 1 (gap would mean data here)
      expect(await sc.getBatchRoot(enterprise1.address, 1)).to.equal(ZERO_ROOT);
      expect(await sc.getBatchCount(enterprise1.address)).to.equal(1);
    });

    // --- Replay Attack ---
    it("should prevent replay attack: stale prevRoot rejected after chain advances", async function () {
      // Submit batch 0: GENESIS -> A
      await sc.connect(enterprise1).submitBatch(
        GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );

      // Attempt to replay with old prevRoot (GENESIS_ROOT)
      // Chain head is now ROOT_A, so GENESIS_ROOT is stale
      await expect(
        sc.connect(enterprise1).submitBatch(
          GENESIS_ROOT, ROOT_B, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
        )
      ).to.be.revertedWithCustomError(sc, "RootChainBroken")
        .withArgs(ROOT_A, GENESIS_ROOT);
    });

    // --- Cross-Enterprise Isolation ---
    it("should enforce cross-enterprise isolation", async function () {
      // Enterprise 1 submits a batch
      await sc.connect(enterprise1).submitBatch(
        GENESIS_ROOT, ROOT_B, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );

      // Enterprise 2's state is unchanged
      expect(await sc.getCurrentRoot(enterprise2.address)).to.equal(ROOT_A);
      expect(await sc.getBatchCount(enterprise2.address)).to.equal(0);

      // Enterprise 2 can independently submit with its own chain
      await sc.connect(enterprise2).submitBatch(
        ROOT_A, ROOT_C, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );

      // Both chains advanced independently
      expect(await sc.getCurrentRoot(enterprise1.address)).to.equal(ROOT_B);
      expect(await sc.getCurrentRoot(enterprise2.address)).to.equal(ROOT_C);
      expect(await sc.totalBatchesCommitted()).to.equal(2);
    });

    // --- Deactivated Enterprise ---
    it("should prevent submission by deactivated enterprise", async function () {
      await registry.deactivateEnterprise(enterprise1.address);

      await expect(
        sc.connect(enterprise1).submitBatch(
          GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
        )
      ).to.be.revertedWithCustomError(sc, "NotAuthorized");
    });

    // --- Double Initialization ---
    it("should prevent double initialization", async function () {
      // enterprise1 already initialized in beforeEach
      await expect(
        sc.initializeEnterprise(enterprise1.address, ROOT_B)
      ).to.be.revertedWithCustomError(sc, "EnterpriseAlreadyInitialized");

      // Original genesis root must be preserved
      expect(await sc.getCurrentRoot(enterprise1.address)).to.equal(GENESIS_ROOT);
    });

    // --- GlobalCountIntegrity ---
    it("should maintain GlobalCountIntegrity across multiple enterprises", async function () {
      // Enterprise 1: 2 batches
      await sc.connect(enterprise1).submitBatch(
        GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      await sc.connect(enterprise1).submitBatch(
        ROOT_A, ROOT_B, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );

      // Enterprise 2: 1 batch
      await sc.connect(enterprise2).submitBatch(
        ROOT_A, ROOT_C, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );

      // totalBatchesCommitted = sum of enterprise batchCounts
      const count1 = await sc.getBatchCount(enterprise1.address);
      const count2 = await sc.getBatchCount(enterprise2.address);
      const total = await sc.totalBatchesCommitted();

      expect(total).to.equal(3);
      expect(count1 + count2).to.equal(total);
    });

    // --- NoReversal ---
    it("should never revert currentRoot to zero (NoReversal)", async function () {
      // After initialization, currentRoot is GENESIS_ROOT (non-zero)
      expect(await sc.getCurrentRoot(enterprise1.address)).to.not.equal(ZERO_ROOT);

      // After batch submission, currentRoot advances (never zero)
      await sc.connect(enterprise1).submitBatch(
        GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      expect(await sc.getCurrentRoot(enterprise1.address)).to.not.equal(ZERO_ROOT);
    });

    // --- Wrong Enterprise Submission ---
    it("should reject cross-enterprise submission attempt", async function () {
      // Enterprise 2 tries to submit against Enterprise 1's chain
      // This fails because msg.sender == enterprise2, which has its own chain (ROOT_A)
      // Providing enterprise1's GENESIS_ROOT as prevRoot fails ChainContinuity
      await expect(
        sc.connect(enterprise2).submitBatch(
          GENESIS_ROOT, ROOT_B, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
        )
      ).to.be.revertedWithCustomError(sc, "RootChainBroken")
        .withArgs(ROOT_A, GENESIS_ROOT);
    });

    // --- Proof Invalidity Blocks State Change ---
    it("should not mutate state when proof is invalid (ProofBeforeState)", async function () {
      await sc.setMockProofResult(false);

      await expect(
        sc.connect(enterprise1).submitBatch(
          GENESIS_ROOT, ROOT_A, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
        )
      ).to.be.revertedWithCustomError(sc, "InvalidProof");

      // State unchanged
      expect(await sc.getCurrentRoot(enterprise1.address)).to.equal(GENESIS_ROOT);
      expect(await sc.getBatchCount(enterprise1.address)).to.equal(0);
      expect(await sc.totalBatchesCommitted()).to.equal(0);
    });
  });
});

async function getBlockTimestamp(): Promise<number> {
  const block = await ethers.provider.getBlock("latest");
  return block!.timestamp;
}
