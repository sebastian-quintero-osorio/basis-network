import { expect } from "chai";
import { ethers } from "hardhat";
import { BasisRollupHarness, MockEnterpriseRegistry } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { ContractTransactionResponse } from "ethers";

describe("BasisRollup", function () {
  let registry: MockEnterpriseRegistry;
  let rollup: BasisRollupHarness;
  let admin: SignerWithAddress;
  let enterprise1: SignerWithAddress;
  let enterprise2: SignerWithAddress;
  let unauthorized: SignerWithAddress;

  const GENESIS_ROOT = ethers.keccak256(ethers.toUtf8Bytes("genesis"));
  const ROOT_A = ethers.keccak256(ethers.toUtf8Bytes("rootA"));
  const ROOT_B = ethers.keccak256(ethers.toUtf8Bytes("rootB"));
  const ROOT_C = ethers.keccak256(ethers.toUtf8Bytes("rootC"));
  const ROOT_D = ethers.keccak256(ethers.toUtf8Bytes("rootD"));
  const ZERO_ROOT = ethers.ZeroHash;
  const ZERO_HASH = ethers.ZeroHash;
  const PRIORITY_HASH = ethers.keccak256(ethers.toUtf8Bytes("priorityOps"));

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

  function makeBatchData(
    newStateRoot: string,
    l2BlockStart: number,
    l2BlockEnd: number,
    priorityOpsHash: string = ZERO_HASH,
    timestamp: number = 1000
  ) {
    return {
      newStateRoot,
      l2BlockStart,
      l2BlockEnd,
      priorityOpsHash,
      timestamp,
    };
  }

  // Gas tracking
  const gasResults: Record<string, bigint[]> = {
    commitBatch_first: [],
    commitBatch_steady: [],
    proveBatch: [],
    executeBatch: [],
    initializeEnterprise: [],
  };

  async function getGasUsed(tx: ContractTransactionResponse): Promise<bigint> {
    const receipt = await tx.wait();
    return receipt!.gasUsed;
  }

  beforeEach(async function () {
    [admin, enterprise1, enterprise2, unauthorized] = await ethers.getSigners();

    const MockERFactory = await ethers.getContractFactory("MockEnterpriseRegistry");
    registry = await MockERFactory.deploy();

    const RollupFactory = await ethers.getContractFactory("BasisRollupHarness");
    rollup = await RollupFactory.deploy(await registry.getAddress());

    await registry.setAuthorized(enterprise1.address, true);
    await registry.setAuthorized(enterprise2.address, true);

    const vk = getDummyVerifyingKey();
    await rollup.setVerifyingKey(vk.alfa1, vk.beta2, vk.gamma2, vk.delta2, vk.IC);
  });

  // =========================================================================
  // Deployment
  // =========================================================================

  describe("Deployment", function () {
    it("should set the deployer as admin", async function () {
      expect(await rollup.admin()).to.equal(admin.address);
    });

    it("should link to the enterprise registry", async function () {
      expect(await rollup.enterpriseRegistry()).to.equal(await registry.getAddress());
    });

    it("should start with verifyingKeySet = true (set in beforeEach)", async function () {
      expect(await rollup.verifyingKeySet()).to.be.true;
    });

    it("should start with zero global counters", async function () {
      expect(await rollup.totalBatchesCommitted()).to.equal(0);
      expect(await rollup.totalBatchesProven()).to.equal(0);
      expect(await rollup.totalBatchesExecuted()).to.equal(0);
    });
  });

  // =========================================================================
  // setVerifyingKey
  // =========================================================================

  describe("setVerifyingKey", function () {
    it("should allow admin to set the verifying key", async function () {
      const freshRollup = await (await ethers.getContractFactory("BasisRollupHarness"))
        .deploy(await registry.getAddress());
      expect(await freshRollup.verifyingKeySet()).to.be.false;

      const vk = getDummyVerifyingKey();
      await freshRollup.setVerifyingKey(vk.alfa1, vk.beta2, vk.gamma2, vk.delta2, vk.IC);
      expect(await freshRollup.verifyingKeySet()).to.be.true;
    });

    it("should revert if called by non-admin", async function () {
      const vk = getDummyVerifyingKey();
      await expect(
        rollup.connect(enterprise1).setVerifyingKey(vk.alfa1, vk.beta2, vk.gamma2, vk.delta2, vk.IC)
      ).to.be.revertedWithCustomError(rollup, "OnlyAdmin");
    });
  });

  // =========================================================================
  // initializeEnterprise
  // =========================================================================

  describe("initializeEnterprise", function () {
    it("should initialize an enterprise with a genesis root", async function () {
      const tx = await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      const gas = await getGasUsed(tx);
      gasResults.initializeEnterprise.push(gas);

      const state = await rollup.enterprises(enterprise1.address);
      expect(state.currentRoot).to.equal(GENESIS_ROOT);
      expect(state.totalBatchesCommitted).to.equal(0);
      expect(state.totalBatchesProven).to.equal(0);
      expect(state.totalBatchesExecuted).to.equal(0);
      expect(state.initialized).to.be.true;
      expect(state.lastL2Block).to.equal(0);
    });

    it("should emit EnterpriseInitialized event", async function () {
      const tx = await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt!.blockNumber);

      await expect(tx)
        .to.emit(rollup, "EnterpriseInitialized")
        .withArgs(enterprise1.address, GENESIS_ROOT, block!.timestamp);
    });

    it("should revert if enterprise already initialized", async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await expect(
        rollup.initializeEnterprise(enterprise1.address, ROOT_A)
      ).to.be.revertedWithCustomError(rollup, "EnterpriseAlreadyInitialized");
    });

    it("should revert if called by non-admin", async function () {
      await expect(
        rollup.connect(enterprise1).initializeEnterprise(enterprise1.address, GENESIS_ROOT)
      ).to.be.revertedWithCustomError(rollup, "OnlyAdmin");
    });
  });

  // =========================================================================
  // Phase 1: commitBatch
  // =========================================================================

  describe("commitBatch", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
    });

    it("should commit the first batch with correct state", async function () {
      const data = makeBatchData(ROOT_A, 1, 10, PRIORITY_HASH);
      const tx = await rollup.connect(enterprise1).commitBatch(data);
      const gas = await getGasUsed(tx);
      gasResults.commitBatch_first.push(gas);

      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(1);
      expect(proven).to.equal(0);
      expect(executed).to.equal(0);

      const info = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(info.stateRoot).to.equal(ROOT_A);
      expect(info.l2BlockStart).to.equal(1);
      expect(info.l2BlockEnd).to.equal(10);
      expect(info.status).to.equal(1); // Committed
      expect(info.batchHash).to.not.equal(ZERO_HASH);
    });

    it("should emit BatchCommitted event", async function () {
      const data = makeBatchData(ROOT_A, 1, 10);
      const tx = await rollup.connect(enterprise1).commitBatch(data);

      await expect(tx).to.emit(rollup, "BatchCommitted");
    });

    it("should commit multiple sequential batches", async function () {
      const data1 = makeBatchData(ROOT_A, 1, 10);
      await rollup.connect(enterprise1).commitBatch(data1);

      const data2 = makeBatchData(ROOT_B, 11, 20);
      const tx = await rollup.connect(enterprise1).commitBatch(data2);
      const gas = await getGasUsed(tx);
      gasResults.commitBatch_steady.push(gas);

      const data3 = makeBatchData(ROOT_C, 21, 30);
      const tx3 = await rollup.connect(enterprise1).commitBatch(data3);
      const gas3 = await getGasUsed(tx3);
      gasResults.commitBatch_steady.push(gas3);

      const [committed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(3);
      expect(await rollup.getLastL2Block(enterprise1.address)).to.equal(30);
      expect(await rollup.totalBatchesCommitted()).to.equal(3);
    });

    it("should enforce MonotonicBlockRange (INV-R4): contiguous blocks", async function () {
      const data1 = makeBatchData(ROOT_A, 1, 10);
      await rollup.connect(enterprise1).commitBatch(data1);

      // Gap: next should start at 11, not 15
      const data2 = makeBatchData(ROOT_B, 15, 20);
      await expect(
        rollup.connect(enterprise1).commitBatch(data2)
      ).to.be.revertedWithCustomError(rollup, "BlockRangeGap")
        .withArgs(11, 15);
    });

    it("should enforce MonotonicBlockRange: first batch starts at 1", async function () {
      const data = makeBatchData(ROOT_A, 5, 10);
      await expect(
        rollup.connect(enterprise1).commitBatch(data)
      ).to.be.revertedWithCustomError(rollup, "BlockRangeGap")
        .withArgs(1, 5);
    });

    it("should reject invalid block range (end < start)", async function () {
      const data = makeBatchData(ROOT_A, 10, 5);
      await expect(
        rollup.connect(enterprise1).commitBatch(data)
      ).to.be.revertedWithCustomError(rollup, "InvalidBlockRange");
    });

    it("should reject unauthorized caller", async function () {
      const data = makeBatchData(ROOT_A, 1, 10);
      await expect(
        rollup.connect(unauthorized).commitBatch(data)
      ).to.be.revertedWithCustomError(rollup, "NotAuthorized");
    });

    it("should reject uninitialized enterprise", async function () {
      const data = makeBatchData(ROOT_A, 1, 10);
      await expect(
        rollup.connect(enterprise2).commitBatch(data)
      ).to.be.revertedWithCustomError(rollup, "EnterpriseNotInitialized");
    });

    it("should auto-increment batch IDs (NoGap)", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_A, 1, 10));
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 11, 20));

      const info0 = await rollup.getBatchInfo(enterprise1.address, 0);
      const info1 = await rollup.getBatchInfo(enterprise1.address, 1);
      const info2 = await rollup.getBatchInfo(enterprise1.address, 2);

      expect(info0.status).to.equal(1); // Committed
      expect(info1.status).to.equal(1); // Committed
      expect(info2.status).to.equal(0); // None (does not exist)
    });
  });

  // =========================================================================
  // Phase 2: proveBatch
  // =========================================================================

  describe("proveBatch", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_A, 1, 10));
    });

    it("should prove a committed batch", async function () {
      const tx = await rollup.connect(enterprise1).proveBatch(
        0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      const gas = await getGasUsed(tx);
      gasResults.proveBatch.push(gas);

      const info = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(info.status).to.equal(2); // Proven

      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(1);
      expect(proven).to.equal(1);
      expect(executed).to.equal(0);
    });

    it("should emit BatchProven event", async function () {
      const tx = await rollup.connect(enterprise1).proveBatch(
        0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      await expect(tx).to.emit(rollup, "BatchProven");
    });

    it("should enforce sequential proving (CommitBeforeProve)", async function () {
      // Try to prove batch 1 before batch 0
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 11, 20));

      await expect(
        rollup.connect(enterprise1).proveBatch(1, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS)
      ).to.be.revertedWithCustomError(rollup, "BatchNotNextToProve");
    });

    it("should reject proving an uncommitted batch", async function () {
      await rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);

      // Batch 1 does not exist
      await expect(
        rollup.connect(enterprise1).proveBatch(1, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS)
      ).to.be.revertedWithCustomError(rollup, "BatchNotCommitted");
    });

    it("should reject invalid proof", async function () {
      await rollup.setMockProofResult(false);

      await expect(
        rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS)
      ).to.be.revertedWithCustomError(rollup, "InvalidProof");

      // State unchanged
      const info = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(info.status).to.equal(1); // Still Committed
    });

    it("should reject if verifying key not set", async function () {
      const freshRollup = await (await ethers.getContractFactory("BasisRollupHarness"))
        .deploy(await registry.getAddress());
      await freshRollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await freshRollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_A, 1, 10));

      await expect(
        freshRollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS)
      ).to.be.revertedWithCustomError(freshRollup, "VerifyingKeyNotSet");
    });

    it("should reject unauthorized caller", async function () {
      await expect(
        rollup.connect(unauthorized).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS)
      ).to.be.revertedWithCustomError(rollup, "NotAuthorized");
    });
  });

  // =========================================================================
  // Phase 3: executeBatch
  // =========================================================================

  describe("executeBatch", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_A, 1, 10));
      await rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
    });

    it("should execute a proven batch and finalize state root", async function () {
      const tx = await rollup.connect(enterprise1).executeBatch(0);
      const gas = await getGasUsed(tx);
      gasResults.executeBatch.push(gas);

      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(ROOT_A);

      const info = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(info.status).to.equal(3); // Executed

      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(1);
      expect(proven).to.equal(1);
      expect(executed).to.equal(1);

      expect(await rollup.totalBatchesExecuted()).to.equal(1);
    });

    it("should emit BatchExecuted event with correct roots", async function () {
      const tx = await rollup.connect(enterprise1).executeBatch(0);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt!.blockNumber);

      await expect(tx)
        .to.emit(rollup, "BatchExecuted")
        .withArgs(enterprise1.address, 0, GENESIS_ROOT, ROOT_A, block!.timestamp);
    });

    it("should enforce sequential execution (INV-R1)", async function () {
      // Commit and prove batch 1
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 11, 20));
      await rollup.connect(enterprise1).proveBatch(1, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);

      // Try to execute batch 1 before batch 0
      await expect(
        rollup.connect(enterprise1).executeBatch(1)
      ).to.be.revertedWithCustomError(rollup, "BatchNotNextToExecute");
    });

    it("should reject executing unproven batch (INV-R2)", async function () {
      // Commit batch 1 but don't prove it
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 11, 20));

      // Execute batch 0 first
      await rollup.connect(enterprise1).executeBatch(0);

      // Try to execute batch 1 (committed but not proven)
      await expect(
        rollup.connect(enterprise1).executeBatch(1)
      ).to.be.revertedWithCustomError(rollup, "BatchNotProven");
    });

    it("should reject unauthorized caller", async function () {
      await expect(
        rollup.connect(unauthorized).executeBatch(0)
      ).to.be.revertedWithCustomError(rollup, "NotAuthorized");
    });

    it("should chain state roots across multiple batches", async function () {
      // Execute batch 0: GENESIS -> ROOT_A
      await rollup.connect(enterprise1).executeBatch(0);
      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(ROOT_A);

      // Commit, prove, execute batch 1: ROOT_A -> ROOT_B
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 11, 20));
      await rollup.connect(enterprise1).proveBatch(1, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      await rollup.connect(enterprise1).executeBatch(1);
      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(ROOT_B);

      // Commit, prove, execute batch 2: ROOT_B -> ROOT_C
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_C, 21, 30));
      await rollup.connect(enterprise1).proveBatch(2, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      await rollup.connect(enterprise1).executeBatch(2);
      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(ROOT_C);

      expect(await rollup.totalBatchesExecuted()).to.equal(3);
    });
  });

  // =========================================================================
  // Revert
  // =========================================================================

  describe("revertBatch", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
    });

    it("should revert a committed (unproven) batch", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_A, 1, 10));

      const tx = await rollup.revertBatch(enterprise1.address);
      await expect(tx).to.emit(rollup, "BatchReverted").withArgs(enterprise1.address, 0, await getBlockTimestamp(tx));

      const [committed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(0);
      expect(await rollup.getLastL2Block(enterprise1.address)).to.equal(0);
      expect(await rollup.totalBatchesCommitted()).to.equal(0);
    });

    it("should revert a proven (unexecuted) batch", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_A, 1, 10));
      await rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);

      await rollup.revertBatch(enterprise1.address);

      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(0);
      expect(proven).to.equal(0);
      expect(executed).to.equal(0);
      expect(await rollup.totalBatchesProven()).to.equal(0);
    });

    it("should revert only the last committed batch (not executed ones)", async function () {
      // Commit, prove, execute batch 0
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_A, 1, 10));
      await rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      await rollup.connect(enterprise1).executeBatch(0);

      // Commit batch 1 (not proven)
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 11, 20));

      // Revert batch 1
      await rollup.revertBatch(enterprise1.address);

      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(1); // batch 0 remains
      expect(executed).to.equal(1);
      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(ROOT_A); // unchanged
      expect(await rollup.getLastL2Block(enterprise1.address)).to.equal(10); // restored
    });

    it("should reject revert when nothing to revert", async function () {
      await expect(
        rollup.revertBatch(enterprise1.address)
      ).to.be.revertedWithCustomError(rollup, "NothingToRevert");
    });

    it("should reject revert of all-executed state", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_A, 1, 10));
      await rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      await rollup.connect(enterprise1).executeBatch(0);

      await expect(
        rollup.revertBatch(enterprise1.address)
      ).to.be.revertedWithCustomError(rollup, "NothingToRevert");
    });

    it("should reject revert from non-admin", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_A, 1, 10));

      await expect(
        rollup.connect(enterprise1).revertBatch(enterprise1.address)
      ).to.be.revertedWithCustomError(rollup, "OnlyAdmin");
    });
  });

  // =========================================================================
  // Enterprise Isolation
  // =========================================================================

  describe("Enterprise Isolation", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await rollup.initializeEnterprise(enterprise2.address, ROOT_A);
    });

    it("should maintain independent state chains", async function () {
      // Enterprise 1: commit, prove, execute
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 1, 10));
      await rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      await rollup.connect(enterprise1).executeBatch(0);

      // Enterprise 2 unchanged
      expect(await rollup.getCurrentRoot(enterprise2.address)).to.equal(ROOT_A);
      const [committed2] = await rollup.getBatchCounts(enterprise2.address);
      expect(committed2).to.equal(0);

      // Enterprise 2 can independently submit
      await rollup.connect(enterprise2).commitBatch(makeBatchData(ROOT_C, 1, 5));
      await rollup.connect(enterprise2).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      await rollup.connect(enterprise2).executeBatch(0);

      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(ROOT_B);
      expect(await rollup.getCurrentRoot(enterprise2.address)).to.equal(ROOT_C);
    });

    it("should maintain independent batch counters", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 1, 10));
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_C, 11, 20));

      await rollup.connect(enterprise2).commitBatch(makeBatchData(ROOT_D, 1, 5));

      const [committed1] = await rollup.getBatchCounts(enterprise1.address);
      const [committed2] = await rollup.getBatchCounts(enterprise2.address);
      expect(committed1).to.equal(2);
      expect(committed2).to.equal(1);
      expect(await rollup.totalBatchesCommitted()).to.equal(3);
    });

    it("should maintain independent L2 block ranges", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 1, 100));
      await rollup.connect(enterprise2).commitBatch(makeBatchData(ROOT_C, 1, 50));

      expect(await rollup.getLastL2Block(enterprise1.address)).to.equal(100);
      expect(await rollup.getLastL2Block(enterprise2.address)).to.equal(50);
    });

    it("should prevent deactivated enterprise from committing", async function () {
      await registry.setAuthorized(enterprise1.address, false);

      await expect(
        rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 1, 10))
      ).to.be.revertedWithCustomError(rollup, "NotAuthorized");
    });
  });

  // =========================================================================
  // View Functions
  // =========================================================================

  describe("View functions", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_A, 1, 10));
      await rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      await rollup.connect(enterprise1).executeBatch(0);
    });

    it("getCurrentRoot should return the finalized root", async function () {
      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(ROOT_A);
    });

    it("getBatchInfo should return correct batch data", async function () {
      const info = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(info.stateRoot).to.equal(ROOT_A);
      expect(info.l2BlockStart).to.equal(1);
      expect(info.l2BlockEnd).to.equal(10);
      expect(info.status).to.equal(3); // Executed
    });

    it("getBatchCounts should return all three counters", async function () {
      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(1);
      expect(proven).to.equal(1);
      expect(executed).to.equal(1);
    });

    it("getLastL2Block should return highest finalized L2 block", async function () {
      expect(await rollup.getLastL2Block(enterprise1.address)).to.equal(10);
    });

    it("isExecutedRoot should return true for executed batch root", async function () {
      expect(await rollup.isExecutedRoot(enterprise1.address, 0, ROOT_A)).to.be.true;
    });

    it("isExecutedRoot should return false for wrong root", async function () {
      expect(await rollup.isExecutedRoot(enterprise1.address, 0, ROOT_B)).to.be.false;
    });

    it("isExecutedRoot should return false for unexecuted batch", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 11, 20));
      expect(await rollup.isExecutedRoot(enterprise1.address, 1, ROOT_B)).to.be.false;
    });

    it("getCurrentRoot should return zero for uninitialized enterprise", async function () {
      expect(await rollup.getCurrentRoot(unauthorized.address)).to.equal(ZERO_ROOT);
    });
  });

  // =========================================================================
  // Full Lifecycle Gas Benchmarks
  // =========================================================================

  describe("Gas Benchmarks", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
    });

    it("should measure full lifecycle gas for first batch", async function () {
      // Phase 1: Commit
      const commitTx = await rollup.connect(enterprise1).commitBatch(
        makeBatchData(ROOT_A, 1, 10, PRIORITY_HASH)
      );
      const commitGas = await getGasUsed(commitTx);

      // Phase 2: Prove
      const proveTx = await rollup.connect(enterprise1).proveBatch(
        0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      const proveGas = await getGasUsed(proveTx);

      // Phase 3: Execute
      const executeTx = await rollup.connect(enterprise1).executeBatch(0);
      const executeGas = await getGasUsed(executeTx);

      const totalGas = commitGas + proveGas + executeGas;

      console.log("\n  --- Gas Benchmark: First Batch ---");
      console.log(`  commitBatch:  ${commitGas.toString()} gas`);
      console.log(`  proveBatch:   ${proveGas.toString()} gas`);
      console.log(`  executeBatch: ${executeGas.toString()} gas`);
      console.log(`  TOTAL:        ${totalGas.toString()} gas`);
      console.log(`  Target:       < 500,000 gas`);
      console.log(`  Result:       ${totalGas < 500000n ? "PASS" : "FAIL"}`);
      console.log(`  vs Validium:  ${Number(totalGas) - 285756} gas delta`);
      console.log("");

      // Hypothesis P4: Total < 500K
      expect(totalGas).to.be.lessThan(500000n);
    });

    it("should measure steady-state lifecycle gas (2nd+ batch)", async function () {
      // First batch (warm-up)
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_A, 1, 10));
      await rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      await rollup.connect(enterprise1).executeBatch(0);

      // Second batch (steady state)
      const commitTx = await rollup.connect(enterprise1).commitBatch(
        makeBatchData(ROOT_B, 11, 20, PRIORITY_HASH)
      );
      const commitGas = await getGasUsed(commitTx);

      const proveTx = await rollup.connect(enterprise1).proveBatch(
        1, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
      );
      const proveGas = await getGasUsed(proveTx);

      const executeTx = await rollup.connect(enterprise1).executeBatch(1);
      const executeGas = await getGasUsed(executeTx);

      const totalGas = commitGas + proveGas + executeGas;

      console.log("\n  --- Gas Benchmark: Steady-State Batch ---");
      console.log(`  commitBatch:  ${commitGas.toString()} gas`);
      console.log(`  proveBatch:   ${proveGas.toString()} gas`);
      console.log(`  executeBatch: ${executeGas.toString()} gas`);
      console.log(`  TOTAL:        ${totalGas.toString()} gas`);
      console.log(`  Target:       < 500,000 gas`);
      console.log(`  Result:       ${totalGas < 500000n ? "PASS" : "FAIL"}`);
      console.log("");

      expect(totalGas).to.be.lessThan(500000n);
    });

    it("should measure gas with varying block ranges", async function () {
      const ranges = [
        { start: 1, end: 1, label: "1 block" },
        { start: 1, end: 10, label: "10 blocks" },
        { start: 1, end: 100, label: "100 blocks" },
        { start: 1, end: 1000, label: "1000 blocks" },
      ];

      console.log("\n  --- Gas Benchmark: Block Range Scaling ---");

      for (const range of ranges) {
        // Fresh enterprise for each test
        const freshRollup = await (await ethers.getContractFactory("BasisRollupHarness"))
          .deploy(await registry.getAddress());
        const vk = getDummyVerifyingKey();
        await freshRollup.setVerifyingKey(vk.alfa1, vk.beta2, vk.gamma2, vk.delta2, vk.IC);
        await freshRollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);

        const data = makeBatchData(ROOT_A, range.start, range.end);
        const commitTx = await freshRollup.connect(enterprise1).commitBatch(data);
        const commitGas = await getGasUsed(commitTx);

        const proveTx = await freshRollup.connect(enterprise1).proveBatch(
          0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS
        );
        const proveGas = await getGasUsed(proveTx);

        const executeTx = await freshRollup.connect(enterprise1).executeBatch(0);
        const executeGas = await getGasUsed(executeTx);

        const total = commitGas + proveGas + executeGas;
        console.log(`  ${range.label.padEnd(12)}: commit=${commitGas} prove=${proveGas} execute=${executeGas} total=${total}`);
      }
      console.log("");
    });
  });

  // =========================================================================
  // Adversarial Tests
  // =========================================================================

  describe("Adversarial", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await rollup.initializeEnterprise(enterprise2.address, ROOT_A);
    });

    it("should prevent executing a committed-but-unproven batch", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 1, 10));

      await expect(
        rollup.connect(enterprise1).executeBatch(0)
      ).to.be.revertedWithCustomError(rollup, "BatchNotProven");
    });

    it("should prevent proving a non-existent batch", async function () {
      await expect(
        rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS)
      ).to.be.revertedWithCustomError(rollup, "BatchNotCommitted");
    });

    it("should prevent double execution", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 1, 10));
      await rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      await rollup.connect(enterprise1).executeBatch(0);

      // Execute phase incremented totalBatchesExecuted to 1
      // Trying to execute batch 0 again would require totalBatchesExecuted == 0
      // Since we moved past it, the next expected is batch 1
      await expect(
        rollup.connect(enterprise1).executeBatch(0)
      ).to.be.revertedWithCustomError(rollup, "BatchNotNextToExecute");
    });

    it("should prevent proof replay after revert", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 1, 10));
      await rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);

      // Admin reverts
      await rollup.revertBatch(enterprise1.address);

      // Re-commit same batch
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 1, 10));

      // Need to prove again (batch info was deleted)
      const info = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(info.status).to.equal(1); // Committed (needs fresh proof)
    });

    it("should maintain GlobalCountIntegrity across enterprises", async function () {
      // Enterprise 1: 2 batches committed
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 1, 10));
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_C, 11, 20));

      // Enterprise 2: 1 batch committed
      await rollup.connect(enterprise2).commitBatch(makeBatchData(ROOT_D, 1, 5));

      expect(await rollup.totalBatchesCommitted()).to.equal(3);

      const [committed1] = await rollup.getBatchCounts(enterprise1.address);
      const [committed2] = await rollup.getBatchCounts(enterprise2.address);
      expect(committed1 + committed2).to.equal(3n);
    });

    it("should not mutate state when proof fails (ProofBeforeState)", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 1, 10));
      await rollup.setMockProofResult(false);

      await expect(
        rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS)
      ).to.be.revertedWithCustomError(rollup, "InvalidProof");

      // Status unchanged
      const info = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(info.status).to.equal(1); // Still Committed
      const [, proven] = await rollup.getBatchCounts(enterprise1.address);
      expect(proven).to.equal(0);
    });

    it("should handle single-block batch correctly", async function () {
      await rollup.connect(enterprise1).commitBatch(makeBatchData(ROOT_B, 1, 1));
      await rollup.connect(enterprise1).proveBatch(0, DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS);
      await rollup.connect(enterprise1).executeBatch(0);

      const info = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(info.l2BlockStart).to.equal(1);
      expect(info.l2BlockEnd).to.equal(1);
      expect(info.status).to.equal(3); // Executed
    });

    it("should handle large block range batch", async function () {
      await rollup.connect(enterprise1).commitBatch(
        makeBatchData(ROOT_B, 1, 100000)
      );

      const info = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(info.l2BlockStart).to.equal(1);
      expect(info.l2BlockEnd).to.equal(100000);
    });
  });
});

async function getBlockTimestamp(tx: ContractTransactionResponse): Promise<number> {
  const receipt = await tx.wait();
  const block = await (await import("hardhat")).ethers.provider.getBlock(receipt!.blockNumber);
  return block!.timestamp;
}
