// Test suite for BasisRollup.sol
// [Spec: zkl2/specs/units/2026-03-basis-rollup/1-formalization/v0-analysis/specs/BasisRollup/BasisRollup.tla]
//
// Maps all 12 TLA+ invariants to concrete Hardhat tests.
// Uses BasisRollupHarness to mock Groth16 verification.

import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// Contract type imports will come from typechain
type BasisRollupHarness = Awaited<ReturnType<Awaited<ReturnType<typeof ethers.getContractFactory<[], []>>>["deploy"]>>;
type MockEnterpriseRegistry = Awaited<ReturnType<Awaited<ReturnType<typeof ethers.getContractFactory<[], []>>>["deploy"]>>;

// Batch status enum values (mirrors Solidity enum)
const BatchStatus = {
  None: 0,
  Committed: 1,
  Proven: 2,
  Executed: 3,
};

// Dummy proof data (harness ignores actual values)
const DUMMY_PROOF = {
  a: [0n, 0n] as [bigint, bigint],
  b: [[0n, 0n], [0n, 0n]] as [[bigint, bigint], [bigint, bigint]],
  c: [0n, 0n] as [bigint, bigint],
  publicSignals: [] as bigint[],
};

// Helper to create a CommitBatchData struct
function makeBatchData(overrides: {
  newStateRoot?: string;
  l2BlockStart?: number;
  l2BlockEnd?: number;
  priorityOpsHash?: string;
  timestamp?: number;
} = {}) {
  return {
    newStateRoot: overrides.newStateRoot ?? ethers.keccak256(ethers.toUtf8Bytes("root-" + Math.random())),
    l2BlockStart: overrides.l2BlockStart ?? 1,
    l2BlockEnd: overrides.l2BlockEnd ?? 10,
    priorityOpsHash: overrides.priorityOpsHash ?? ethers.ZeroHash,
    timestamp: overrides.timestamp ?? Math.floor(Date.now() / 1000),
  };
}

describe("BasisRollup", function () {
  let rollup: any;
  let registry: any;
  let admin: HardhatEthersSigner;
  let enterprise1: HardhatEthersSigner;
  let enterprise2: HardhatEthersSigner;
  let outsider: HardhatEthersSigner;

  const GENESIS_ROOT = ethers.keccak256(ethers.toUtf8Bytes("genesis"));

  beforeEach(async function () {
    [admin, enterprise1, enterprise2, outsider] = await ethers.getSigners();

    const MockRegistry = await ethers.getContractFactory("MockEnterpriseRegistry");
    registry = await MockRegistry.deploy();
    await registry.waitForDeployment();

    const Harness = await ethers.getContractFactory("BasisRollupHarness");
    rollup = await Harness.deploy(await registry.getAddress());
    await rollup.waitForDeployment();

    // Authorize enterprises
    await registry.setAuthorized(enterprise1.address, true);
    await registry.setAuthorized(enterprise2.address, true);

    // Set verifying key (harness ignores it, but proveBatch checks verifyingKeySet)
    await rollup.setVerifyingKey(
      [1n, 2n],
      [[1n, 2n], [3n, 4n]],
      [[1n, 2n], [3n, 4n]],
      [[1n, 2n], [3n, 4n]],
      [[1n, 2n]]
    );
  });

  // Helper: commit a batch for an enterprise
  async function commitBatch(
    signer: HardhatEthersSigner,
    l2BlockStart: number,
    l2BlockEnd: number,
    root?: string
  ) {
    const data = makeBatchData({
      newStateRoot: root ?? ethers.keccak256(ethers.toUtf8Bytes(`root-${l2BlockStart}-${l2BlockEnd}`)),
      l2BlockStart,
      l2BlockEnd,
    });
    return rollup.connect(signer).commitBatch(data);
  }

  // Helper: prove a batch
  async function proveBatch(signer: HardhatEthersSigner, batchId: number) {
    return rollup.connect(signer).proveBatch(
      batchId,
      DUMMY_PROOF.a,
      DUMMY_PROOF.b,
      DUMMY_PROOF.c,
      DUMMY_PROOF.publicSignals
    );
  }

  // Helper: execute a batch
  async function executeBatch(signer: HardhatEthersSigner, batchId: number) {
    return rollup.connect(signer).executeBatch(batchId);
  }

  // Helper: full lifecycle (commit -> prove -> execute)
  async function fullLifecycle(
    signer: HardhatEthersSigner,
    l2BlockStart: number,
    l2BlockEnd: number,
    batchId: number,
    root?: string
  ) {
    await commitBatch(signer, l2BlockStart, l2BlockEnd, root);
    await proveBatch(signer, batchId);
    await executeBatch(signer, batchId);
  }

  // ===================================================================
  // 1. Deployment and Constructor
  // ===================================================================

  describe("Deployment", function () {
    it("sets admin to deployer", async function () {
      expect(await rollup.admin()).to.equal(admin.address);
    });

    it("sets enterprise registry", async function () {
      expect(await rollup.enterpriseRegistry()).to.equal(await registry.getAddress());
    });

    it("starts with zero global counters", async function () {
      expect(await rollup.totalBatchesCommitted()).to.equal(0);
      expect(await rollup.totalBatchesProven()).to.equal(0);
      expect(await rollup.totalBatchesExecuted()).to.equal(0);
    });
  });

  // ===================================================================
  // 2. Enterprise Initialization
  // [Spec: BasisRollup.tla, InitializeEnterprise(e, genesisRoot)]
  // ===================================================================

  describe("InitializeEnterprise", function () {
    it("initializes enterprise with genesis root", async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);

      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(GENESIS_ROOT);
      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(0);
      expect(proven).to.equal(0);
      expect(executed).to.equal(0);
    });

    it("emits EnterpriseInitialized event", async function () {
      await expect(rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT))
        .to.emit(rollup, "EnterpriseInitialized")
        .withArgs(enterprise1.address, GENESIS_ROOT, () => true);
    });

    it("reverts on double initialization (INV-08 NoReversal guard)", async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await expect(
        rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT)
      ).to.be.revertedWithCustomError(rollup, "EnterpriseAlreadyInitialized");
    });

    it("reverts when called by non-admin", async function () {
      await expect(
        rollup.connect(enterprise1).initializeEnterprise(enterprise1.address, GENESIS_ROOT)
      ).to.be.revertedWithCustomError(rollup, "OnlyAdmin");
    });

    it("can initialize multiple enterprises independently", async function () {
      const root2 = ethers.keccak256(ethers.toUtf8Bytes("genesis2"));
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await rollup.initializeEnterprise(enterprise2.address, root2);

      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(GENESIS_ROOT);
      expect(await rollup.getCurrentRoot(enterprise2.address)).to.equal(root2);
    });
  });

  // ===================================================================
  // 3. Phase 1: CommitBatch
  // [Spec: BasisRollup.tla, CommitBatch(e, newRoot)]
  // ===================================================================

  describe("CommitBatch", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
    });

    it("commits first batch with correct state", async function () {
      const root = ethers.keccak256(ethers.toUtf8Bytes("batch0-root"));
      await commitBatch(enterprise1, 1, 10, root);

      const [, stateRoot, , , status] = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(stateRoot).to.equal(root);
      expect(status).to.equal(BatchStatus.Committed);
    });

    it("emits BatchCommitted event", async function () {
      const data = makeBatchData({ l2BlockStart: 1, l2BlockEnd: 10 });
      await expect(rollup.connect(enterprise1).commitBatch(data))
        .to.emit(rollup, "BatchCommitted");
    });

    it("auto-increments batch ID (NoGap)", async function () {
      await commitBatch(enterprise1, 1, 10);
      await commitBatch(enterprise1, 11, 20);

      const [committed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(2);
    });

    it("increments global counter (INV-11 GlobalCountIntegrity)", async function () {
      await commitBatch(enterprise1, 1, 10);
      expect(await rollup.totalBatchesCommitted()).to.equal(1);
    });

    it("stores batch hash for integrity", async function () {
      await commitBatch(enterprise1, 1, 10);
      const [batchHash] = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(batchHash).to.not.equal(ethers.ZeroHash);
    });

    it("updates lastL2Block", async function () {
      await commitBatch(enterprise1, 1, 10);
      expect(await rollup.getLastL2Block(enterprise1.address)).to.equal(10);
    });

    // INV-09 InitBeforeBatch
    it("reverts for uninitialized enterprise (INV-09)", async function () {
      await expect(
        commitBatch(outsider, 1, 10)
      ).to.be.revertedWithCustomError(rollup, "NotAuthorized");
    });

    it("reverts for unauthorized caller", async function () {
      await expect(
        commitBatch(outsider, 1, 10)
      ).to.be.revertedWithCustomError(rollup, "NotAuthorized");
    });

    // INV-R4 MonotonicBlockRange
    it("reverts on invalid block range (end < start)", async function () {
      const data = makeBatchData({ l2BlockStart: 10, l2BlockEnd: 5 });
      await expect(
        rollup.connect(enterprise1).commitBatch(data)
      ).to.be.revertedWithCustomError(rollup, "InvalidBlockRange");
    });

    it("reverts on block range gap (INV-R4)", async function () {
      await commitBatch(enterprise1, 1, 10);
      const data = makeBatchData({ l2BlockStart: 15, l2BlockEnd: 20 });
      await expect(
        rollup.connect(enterprise1).commitBatch(data)
      ).to.be.revertedWithCustomError(rollup, "BlockRangeGap");
    });

    it("reverts when first batch does not start at block 1", async function () {
      const data = makeBatchData({ l2BlockStart: 5, l2BlockEnd: 10 });
      await expect(
        rollup.connect(enterprise1).commitBatch(data)
      ).to.be.revertedWithCustomError(rollup, "BlockRangeGap");
    });
  });

  // ===================================================================
  // 4. Phase 2: ProveBatch
  // [Spec: BasisRollup.tla, ProveBatch(e, proofIsValid)]
  // ===================================================================

  describe("ProveBatch", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await commitBatch(enterprise1, 1, 10);
    });

    it("proves committed batch", async function () {
      await proveBatch(enterprise1, 0);

      const [, , , , status] = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(status).to.equal(BatchStatus.Proven);
    });

    it("emits BatchProven event", async function () {
      await expect(proveBatch(enterprise1, 0))
        .to.emit(rollup, "BatchProven")
        .withArgs(enterprise1.address, 0, () => true);
    });

    it("increments totalBatchesProven", async function () {
      await proveBatch(enterprise1, 0);
      const [, proven] = await rollup.getBatchCounts(enterprise1.address);
      expect(proven).to.equal(1);
    });

    it("increments global proven counter (INV-11)", async function () {
      await proveBatch(enterprise1, 0);
      expect(await rollup.totalBatchesProven()).to.equal(1);
    });

    // INV-06 CommitBeforeProve
    it("reverts when proving out of order (INV-06)", async function () {
      await expect(
        proveBatch(enterprise1, 1)
      ).to.be.revertedWithCustomError(rollup, "BatchNotNextToProve");
    });

    it("reverts when batch not committed", async function () {
      // Prove batch 0 first
      await proveBatch(enterprise1, 0);
      // Batch 1 not committed
      await expect(
        proveBatch(enterprise1, 1)
      ).to.be.revertedWithCustomError(rollup, "BatchNotCommitted");
    });

    it("reverts on invalid proof (INV-S2 ProofBeforeState)", async function () {
      await rollup.setMockProofResult(false);
      await expect(
        proveBatch(enterprise1, 0)
      ).to.be.revertedWithCustomError(rollup, "InvalidProof");
    });

    it("reverts when verifying key not set", async function () {
      // Deploy fresh rollup without VK
      const Harness = await ethers.getContractFactory("BasisRollupHarness");
      const freshRollup = await Harness.deploy(await registry.getAddress());
      await freshRollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);

      const data = makeBatchData({ l2BlockStart: 1, l2BlockEnd: 10 });
      await freshRollup.connect(enterprise1).commitBatch(data);

      await expect(
        freshRollup.connect(enterprise1).proveBatch(
          0, DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
        )
      ).to.be.revertedWithCustomError(freshRollup, "VerifyingKeyNotSet");
    });

    it("cannot double-prove a batch", async function () {
      await proveBatch(enterprise1, 0);
      await expect(
        proveBatch(enterprise1, 0)
      ).to.be.revertedWithCustomError(rollup, "BatchNotNextToProve");
    });
  });

  // ===================================================================
  // 5. Phase 3: ExecuteBatch
  // [Spec: BasisRollup.tla, ExecuteBatch(e)]
  // ===================================================================

  describe("ExecuteBatch", function () {
    const ROOT_1 = ethers.keccak256(ethers.toUtf8Bytes("root-1"));

    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await commitBatch(enterprise1, 1, 10, ROOT_1);
      await proveBatch(enterprise1, 0);
    });

    it("executes proven batch and advances state root (INV-02 BatchChainContinuity)", async function () {
      await executeBatch(enterprise1, 0);

      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(ROOT_1);
      const [, , , , status] = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(status).to.equal(BatchStatus.Executed);
    });

    it("emits BatchExecuted event with prev and new root", async function () {
      await expect(executeBatch(enterprise1, 0))
        .to.emit(rollup, "BatchExecuted")
        .withArgs(enterprise1.address, 0, GENESIS_ROOT, ROOT_1, () => true);
    });

    it("increments totalBatchesExecuted", async function () {
      await executeBatch(enterprise1, 0);
      const [, , executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(executed).to.equal(1);
    });

    it("increments global executed counter (INV-11)", async function () {
      await executeBatch(enterprise1, 0);
      expect(await rollup.totalBatchesExecuted()).to.equal(1);
    });

    // INV-04 ExecuteInOrder
    it("reverts when executing out of order (INV-04)", async function () {
      await expect(
        executeBatch(enterprise1, 1)
      ).to.be.revertedWithCustomError(rollup, "BatchNotNextToExecute");
    });

    // INV-03 ProveBeforeExecute
    it("reverts when batch not proven (INV-03)", async function () {
      // Execute batch 0 first (already proven in beforeEach)
      await executeBatch(enterprise1, 0);
      // Commit batch 1 but do not prove it
      await commitBatch(enterprise1, 11, 20);
      await expect(
        executeBatch(enterprise1, 1)
      ).to.be.revertedWithCustomError(rollup, "BatchNotProven");
    });

    it("cannot double-execute a batch", async function () {
      await executeBatch(enterprise1, 0);
      await expect(
        executeBatch(enterprise1, 0)
      ).to.be.revertedWithCustomError(rollup, "BatchNotNextToExecute");
    });

    it("isExecutedRoot returns true after execution", async function () {
      await executeBatch(enterprise1, 0);
      expect(await rollup.isExecutedRoot(enterprise1.address, 0, ROOT_1)).to.be.true;
    });

    it("isExecutedRoot returns false for wrong root", async function () {
      await executeBatch(enterprise1, 0);
      const wrongRoot = ethers.keccak256(ethers.toUtf8Bytes("wrong"));
      expect(await rollup.isExecutedRoot(enterprise1.address, 0, wrongRoot)).to.be.false;
    });
  });

  // ===================================================================
  // 6. RevertBatch
  // [Spec: BasisRollup.tla, RevertBatch(e)]
  // ===================================================================

  describe("RevertBatch", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
    });

    it("reverts a committed (unproven) batch", async function () {
      await commitBatch(enterprise1, 1, 10);
      await rollup.revertBatch(enterprise1.address);

      const [committed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(0);
      const [, , , , status] = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(status).to.equal(BatchStatus.None);
    });

    it("reverts a proven (unexecuted) batch and decrements proven counter", async function () {
      await commitBatch(enterprise1, 1, 10);
      await proveBatch(enterprise1, 0);
      await rollup.revertBatch(enterprise1.address);

      const [committed, proven] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(0);
      expect(proven).to.equal(0);
      expect(await rollup.totalBatchesProven()).to.equal(0);
    });

    it("emits BatchReverted event", async function () {
      await commitBatch(enterprise1, 1, 10);
      await expect(rollup.revertBatch(enterprise1.address))
        .to.emit(rollup, "BatchReverted")
        .withArgs(enterprise1.address, 0, () => true);
    });

    it("decrements global committed counter (INV-11)", async function () {
      await commitBatch(enterprise1, 1, 10);
      expect(await rollup.totalBatchesCommitted()).to.equal(1);
      await rollup.revertBatch(enterprise1.address);
      expect(await rollup.totalBatchesCommitted()).to.equal(0);
    });

    it("restores lastL2Block to previous batch", async function () {
      await commitBatch(enterprise1, 1, 10);
      await commitBatch(enterprise1, 11, 20);
      await rollup.revertBatch(enterprise1.address);
      expect(await rollup.getLastL2Block(enterprise1.address)).to.equal(10);
    });

    it("restores lastL2Block to 0 when reverting first batch", async function () {
      await commitBatch(enterprise1, 1, 10);
      await rollup.revertBatch(enterprise1.address);
      expect(await rollup.getLastL2Block(enterprise1.address)).to.equal(0);
    });

    // INV-05 RevertSafety
    it("cannot revert executed batch (INV-05)", async function () {
      await commitBatch(enterprise1, 1, 10);
      await proveBatch(enterprise1, 0);
      await executeBatch(enterprise1, 0);

      await expect(
        rollup.revertBatch(enterprise1.address)
      ).to.be.revertedWithCustomError(rollup, "NothingToRevert");
    });

    it("reverts only the most recent batch (LIFO)", async function () {
      await commitBatch(enterprise1, 1, 10);
      await proveBatch(enterprise1, 0);
      await executeBatch(enterprise1, 0);

      // Commit batch 1 and 2
      await commitBatch(enterprise1, 11, 20);
      await commitBatch(enterprise1, 21, 30);

      // Revert batch 2 (most recent)
      await rollup.revertBatch(enterprise1.address);
      const [committed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(2); // batch 0 (executed) + batch 1 (committed)
    });

    it("reverts when nothing to revert", async function () {
      await expect(
        rollup.revertBatch(enterprise1.address)
      ).to.be.revertedWithCustomError(rollup, "NothingToRevert");
    });

    it("reverts when called by non-admin", async function () {
      await commitBatch(enterprise1, 1, 10);
      await expect(
        rollup.connect(enterprise1).revertBatch(enterprise1.address)
      ).to.be.revertedWithCustomError(rollup, "OnlyAdmin");
    });

    it("allows recommitting after revert", async function () {
      await commitBatch(enterprise1, 1, 10);
      await rollup.revertBatch(enterprise1.address);

      // Can commit again from block 1
      await commitBatch(enterprise1, 1, 15);
      const [committed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(1);
    });
  });

  // ===================================================================
  // 7. Full Lifecycle
  // ===================================================================

  describe("Full Lifecycle", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
    });

    it("commit -> prove -> execute single batch", async function () {
      const root = ethers.keccak256(ethers.toUtf8Bytes("final-root"));
      await fullLifecycle(enterprise1, 1, 10, 0, root);

      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(root);
      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(1);
      expect(proven).to.equal(1);
      expect(executed).to.equal(1);
    });

    it("three sequential batches through full lifecycle", async function () {
      const roots = [
        ethers.keccak256(ethers.toUtf8Bytes("root-1")),
        ethers.keccak256(ethers.toUtf8Bytes("root-2")),
        ethers.keccak256(ethers.toUtf8Bytes("root-3")),
      ];

      // Commit all three
      await commitBatch(enterprise1, 1, 10, roots[0]);
      await commitBatch(enterprise1, 11, 20, roots[1]);
      await commitBatch(enterprise1, 21, 30, roots[2]);

      // Prove all three
      await proveBatch(enterprise1, 0);
      await proveBatch(enterprise1, 1);
      await proveBatch(enterprise1, 2);

      // Execute all three
      await executeBatch(enterprise1, 0);
      await executeBatch(enterprise1, 1);
      await executeBatch(enterprise1, 2);

      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(roots[2]);
      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(3);
      expect(proven).to.equal(3);
      expect(executed).to.equal(3);
    });

    it("pipelining: commit batch 2 while proving batch 1", async function () {
      await commitBatch(enterprise1, 1, 10);
      await proveBatch(enterprise1, 0);
      await commitBatch(enterprise1, 11, 20);
      await executeBatch(enterprise1, 0);
      await proveBatch(enterprise1, 1);
      await executeBatch(enterprise1, 1);

      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(2);
      expect(proven).to.equal(2);
      expect(executed).to.equal(2);
    });
  });

  // ===================================================================
  // 8. Enterprise Isolation
  // [Spec: BasisRollup.tla -- EXCEPT ![e] semantics]
  // ===================================================================

  describe("Enterprise Isolation", function () {
    const ROOT_E1 = ethers.keccak256(ethers.toUtf8Bytes("e1-genesis"));
    const ROOT_E2 = ethers.keccak256(ethers.toUtf8Bytes("e2-genesis"));

    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, ROOT_E1);
      await rollup.initializeEnterprise(enterprise2.address, ROOT_E2);
    });

    it("enterprise 1 operations do not affect enterprise 2", async function () {
      await commitBatch(enterprise1, 1, 10);
      await proveBatch(enterprise1, 0);
      await executeBatch(enterprise1, 0);

      // Enterprise 2 remains at genesis
      expect(await rollup.getCurrentRoot(enterprise2.address)).to.equal(ROOT_E2);
      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise2.address);
      expect(committed).to.equal(0);
      expect(proven).to.equal(0);
      expect(executed).to.equal(0);
    });

    it("interleaved operations between two enterprises", async function () {
      const e1Root = ethers.keccak256(ethers.toUtf8Bytes("e1-batch0"));
      const e2Root = ethers.keccak256(ethers.toUtf8Bytes("e2-batch0"));

      await commitBatch(enterprise1, 1, 10, e1Root);
      await commitBatch(enterprise2, 1, 5, e2Root);
      await proveBatch(enterprise1, 0);
      await proveBatch(enterprise2, 0);
      await executeBatch(enterprise2, 0);
      await executeBatch(enterprise1, 0);

      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(e1Root);
      expect(await rollup.getCurrentRoot(enterprise2.address)).to.equal(e2Root);
    });

    it("global counters accumulate across enterprises (INV-11)", async function () {
      await commitBatch(enterprise1, 1, 10);
      await commitBatch(enterprise2, 1, 5);
      await commitBatch(enterprise1, 11, 20);

      expect(await rollup.totalBatchesCommitted()).to.equal(3);
    });

    it("reverting one enterprise does not affect another", async function () {
      await commitBatch(enterprise1, 1, 10);
      await commitBatch(enterprise2, 1, 5);

      await rollup.revertBatch(enterprise1.address);

      const [e1Committed] = await rollup.getBatchCounts(enterprise1.address);
      const [e2Committed] = await rollup.getBatchCounts(enterprise2.address);
      expect(e1Committed).to.equal(0);
      expect(e2Committed).to.equal(1);
    });
  });

  // ===================================================================
  // 9. Counter Invariants
  // [Spec: BasisRollup.tla -- CounterMonotonicity, GlobalCountIntegrity]
  // ===================================================================

  describe("Counter Invariants", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await rollup.initializeEnterprise(enterprise2.address, ethers.keccak256(ethers.toUtf8Bytes("genesis2")));
    });

    // INV-07 CounterMonotonicity
    it("maintains executed <= proven <= committed (INV-07)", async function () {
      await commitBatch(enterprise1, 1, 10);
      await commitBatch(enterprise1, 11, 20);

      let [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(Number(executed)).to.be.lte(Number(proven));
      expect(Number(proven)).to.be.lte(Number(committed));

      await proveBatch(enterprise1, 0);
      [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(Number(executed)).to.be.lte(Number(proven));
      expect(Number(proven)).to.be.lte(Number(committed));

      await executeBatch(enterprise1, 0);
      [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(Number(executed)).to.be.lte(Number(proven));
      expect(Number(proven)).to.be.lte(Number(committed));
    });

    // INV-11 GlobalCountIntegrity
    it("global counters equal sum of enterprise counters (INV-11)", async function () {
      await commitBatch(enterprise1, 1, 10);
      await commitBatch(enterprise2, 1, 5);
      await proveBatch(enterprise1, 0);
      await executeBatch(enterprise1, 0);

      const [e1c, e1p, e1e] = await rollup.getBatchCounts(enterprise1.address);
      const [e2c, e2p, e2e] = await rollup.getBatchCounts(enterprise2.address);

      expect(await rollup.totalBatchesCommitted()).to.equal(Number(e1c) + Number(e2c));
      expect(await rollup.totalBatchesProven()).to.equal(Number(e1p) + Number(e2p));
      expect(await rollup.totalBatchesExecuted()).to.equal(Number(e1e) + Number(e2e));
    });
  });

  // ===================================================================
  // 10. Adversarial Tests
  // ===================================================================

  describe("Adversarial: Proof Bypass", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await commitBatch(enterprise1, 1, 10);
    });

    it("ADV-01: cannot execute uncommitted batch", async function () {
      await expect(executeBatch(enterprise1, 0))
        .to.be.revertedWithCustomError(rollup, "BatchNotProven");
    });

    it("ADV-02: cannot skip prove phase", async function () {
      // Try to execute directly after commit
      await expect(executeBatch(enterprise1, 0))
        .to.be.revertedWithCustomError(rollup, "BatchNotProven");
    });

    it("ADV-03: invalid proof rejected before state mutation", async function () {
      await rollup.setMockProofResult(false);
      const rootBefore = await rollup.getCurrentRoot(enterprise1.address);
      await expect(proveBatch(enterprise1, 0))
        .to.be.revertedWithCustomError(rollup, "InvalidProof");
      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(rootBefore);
    });
  });

  describe("Adversarial: Out-of-Order Operations", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await commitBatch(enterprise1, 1, 10);
      await commitBatch(enterprise1, 11, 20);
    });

    it("ADV-04: cannot prove batch 1 before batch 0", async function () {
      await expect(proveBatch(enterprise1, 1))
        .to.be.revertedWithCustomError(rollup, "BatchNotNextToProve");
    });

    it("ADV-05: cannot execute batch 1 before batch 0", async function () {
      await proveBatch(enterprise1, 0);
      await proveBatch(enterprise1, 1);
      await expect(executeBatch(enterprise1, 1))
        .to.be.revertedWithCustomError(rollup, "BatchNotNextToExecute");
    });

    it("ADV-06: cannot skip a batch ID in sequence", async function () {
      await proveBatch(enterprise1, 0);
      await executeBatch(enterprise1, 0);
      // Try to execute batch 1 which is still only committed (not proven)
      await expect(executeBatch(enterprise1, 1))
        .to.be.revertedWithCustomError(rollup, "BatchNotProven");
    });
  });

  describe("Adversarial: Revert Exploits", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
    });

    it("ADV-07: cannot revert executed batch (INV-05)", async function () {
      await fullLifecycle(enterprise1, 1, 10, 0);
      await expect(rollup.revertBatch(enterprise1.address))
        .to.be.revertedWithCustomError(rollup, "NothingToRevert");
    });

    it("ADV-08: revert-recommit does not corrupt state", async function () {
      const root1 = ethers.keccak256(ethers.toUtf8Bytes("root-1"));
      const root2 = ethers.keccak256(ethers.toUtf8Bytes("root-2"));

      await commitBatch(enterprise1, 1, 10, root1);
      await rollup.revertBatch(enterprise1.address);

      // Recommit with different root
      await commitBatch(enterprise1, 1, 15, root2);
      await proveBatch(enterprise1, 0);
      await executeBatch(enterprise1, 0);

      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(root2);
    });

    it("ADV-09: revert proven batch rolls back proven counter correctly", async function () {
      await commitBatch(enterprise1, 1, 10);
      await commitBatch(enterprise1, 11, 20);
      await proveBatch(enterprise1, 0);
      await proveBatch(enterprise1, 1);

      // Revert batch 1 (proven)
      await rollup.revertBatch(enterprise1.address);
      const [committed, proven] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(1);
      expect(proven).to.equal(1); // batch 0 still proven

      // Can still execute batch 0
      await executeBatch(enterprise1, 0);
    });

    it("ADV-10: sequential reverts maintain consistency", async function () {
      await commitBatch(enterprise1, 1, 10);
      await commitBatch(enterprise1, 11, 20);
      await commitBatch(enterprise1, 21, 30);

      await rollup.revertBatch(enterprise1.address); // revert batch 2
      await rollup.revertBatch(enterprise1.address); // revert batch 1
      await rollup.revertBatch(enterprise1.address); // revert batch 0

      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(0);
      expect(proven).to.equal(0);
      expect(executed).to.equal(0);
      expect(await rollup.totalBatchesCommitted()).to.equal(0);
    });
  });

  describe("Adversarial: Cross-Enterprise Attacks", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await rollup.initializeEnterprise(enterprise2.address, ethers.keccak256(ethers.toUtf8Bytes("genesis2")));
    });

    it("ADV-11: enterprise cannot prove another's batch", async function () {
      await commitBatch(enterprise1, 1, 10);
      // Enterprise 2 tries to prove enterprise 1's batch
      // proveBatch uses msg.sender, so e2 would try to prove its own batch 0
      await expect(proveBatch(enterprise2, 0))
        .to.be.revertedWithCustomError(rollup, "BatchNotCommitted");
    });

    it("ADV-12: enterprise cannot execute another's batch", async function () {
      await commitBatch(enterprise1, 1, 10);
      await proveBatch(enterprise1, 0);
      // Enterprise 2 tries to execute - but it has no proven batch 0
      await expect(executeBatch(enterprise2, 0))
        .to.be.revertedWithCustomError(rollup, "BatchNotProven");
    });

    it("ADV-13: reverting enterprise 1 does not affect enterprise 2 counters", async function () {
      await commitBatch(enterprise1, 1, 10);
      await commitBatch(enterprise2, 1, 5);
      await proveBatch(enterprise2, 0);
      await executeBatch(enterprise2, 0);

      await rollup.revertBatch(enterprise1.address);

      const [e2c, e2p, e2e] = await rollup.getBatchCounts(enterprise2.address);
      expect(e2c).to.equal(1);
      expect(e2p).to.equal(1);
      expect(e2e).to.equal(1);
    });
  });

  describe("Adversarial: Authorization Bypass", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
    });

    it("ADV-14: unauthorized address cannot commit", async function () {
      await expect(commitBatch(outsider, 1, 10))
        .to.be.revertedWithCustomError(rollup, "NotAuthorized");
    });

    it("ADV-15: unauthorized address cannot prove", async function () {
      await commitBatch(enterprise1, 1, 10);
      await expect(
        rollup.connect(outsider).proveBatch(0, DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals)
      ).to.be.revertedWithCustomError(rollup, "NotAuthorized");
    });

    it("ADV-16: unauthorized address cannot execute", async function () {
      await commitBatch(enterprise1, 1, 10);
      await proveBatch(enterprise1, 0);
      await expect(
        rollup.connect(outsider).executeBatch(0)
      ).to.be.revertedWithCustomError(rollup, "NotAuthorized");
    });

    it("ADV-17: deauthorized enterprise blocked mid-lifecycle", async function () {
      await commitBatch(enterprise1, 1, 10);
      await proveBatch(enterprise1, 0);

      // Deauthorize mid-lifecycle
      await registry.setAuthorized(enterprise1.address, false);

      await expect(executeBatch(enterprise1, 0))
        .to.be.revertedWithCustomError(rollup, "NotAuthorized");
    });

    it("ADV-18: non-admin cannot revert batches", async function () {
      await commitBatch(enterprise1, 1, 10);
      await expect(
        rollup.connect(enterprise1).revertBatch(enterprise1.address)
      ).to.be.revertedWithCustomError(rollup, "OnlyAdmin");
    });

    it("ADV-19: non-admin cannot initialize enterprise", async function () {
      await expect(
        rollup.connect(outsider).initializeEnterprise(outsider.address, GENESIS_ROOT)
      ).to.be.revertedWithCustomError(rollup, "OnlyAdmin");
    });

    it("ADV-20: non-admin cannot set verifying key", async function () {
      await expect(
        rollup.connect(outsider).setVerifyingKey(
          [1n, 2n], [[1n, 2n], [3n, 4n]], [[1n, 2n], [3n, 4n]], [[1n, 2n], [3n, 4n]], [[1n, 2n]]
        )
      ).to.be.revertedWithCustomError(rollup, "OnlyAdmin");
    });
  });

  describe("Adversarial: Block Range Manipulation", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
    });

    it("ADV-21: cannot submit overlapping block ranges", async function () {
      await commitBatch(enterprise1, 1, 10);
      const data = makeBatchData({ l2BlockStart: 5, l2BlockEnd: 15 });
      await expect(
        rollup.connect(enterprise1).commitBatch(data)
      ).to.be.revertedWithCustomError(rollup, "BlockRangeGap");
    });

    it("ADV-22: cannot leave block range gaps", async function () {
      await commitBatch(enterprise1, 1, 10);
      const data = makeBatchData({ l2BlockStart: 12, l2BlockEnd: 20 });
      await expect(
        rollup.connect(enterprise1).commitBatch(data)
      ).to.be.revertedWithCustomError(rollup, "BlockRangeGap");
    });

    it("ADV-23: single-block batch is valid", async function () {
      await commitBatch(enterprise1, 1, 1);
      const [committed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(1);
    });
  });

  // ===================================================================
  // 11. View Functions
  // ===================================================================

  describe("View Functions", function () {
    beforeEach(async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
    });

    it("getBatchInfo returns correct data", async function () {
      await commitBatch(enterprise1, 1, 10);
      const [batchHash, stateRoot, l2BlockStart, l2BlockEnd, status] =
        await rollup.getBatchInfo(enterprise1.address, 0);

      expect(batchHash).to.not.equal(ethers.ZeroHash);
      expect(stateRoot).to.not.equal(ethers.ZeroHash);
      expect(l2BlockStart).to.equal(1);
      expect(l2BlockEnd).to.equal(10);
      expect(status).to.equal(BatchStatus.Committed);
    });

    it("getBatchCounts reflects lifecycle progress", async function () {
      await commitBatch(enterprise1, 1, 10);
      await proveBatch(enterprise1, 0);

      const [committed, proven, executed] = await rollup.getBatchCounts(enterprise1.address);
      expect(committed).to.equal(1);
      expect(proven).to.equal(1);
      expect(executed).to.equal(0);
    });

    it("getLastL2Block tracks highest block", async function () {
      await commitBatch(enterprise1, 1, 10);
      await commitBatch(enterprise1, 11, 25);
      expect(await rollup.getLastL2Block(enterprise1.address)).to.equal(25);
    });

    it("getCurrentRoot returns genesis before any execution", async function () {
      expect(await rollup.getCurrentRoot(enterprise1.address)).to.equal(GENESIS_ROOT);
    });

    it("isExecutedRoot returns false for non-executed batch", async function () {
      await commitBatch(enterprise1, 1, 10);
      const [, stateRoot] = await rollup.getBatchInfo(enterprise1.address, 0);
      expect(await rollup.isExecutedRoot(enterprise1.address, 0, stateRoot)).to.be.false;
    });
  });

  // ===================================================================
  // 12. Edge Cases
  // ===================================================================

  describe("Edge Cases", function () {
    it("uninitialized enterprise has zero state", async function () {
      expect(await rollup.getCurrentRoot(outsider.address)).to.equal(ethers.ZeroHash);
      const [committed, proven, executed] = await rollup.getBatchCounts(outsider.address);
      expect(committed).to.equal(0);
      expect(proven).to.equal(0);
      expect(executed).to.equal(0);
    });

    it("commitBatch reverts for initialized but deauthorized enterprise", async function () {
      await rollup.initializeEnterprise(enterprise1.address, GENESIS_ROOT);
      await registry.setAuthorized(enterprise1.address, false);

      await expect(commitBatch(enterprise1, 1, 10))
        .to.be.revertedWithCustomError(rollup, "NotAuthorized");
    });

    it("setVerifyingKey can be called multiple times", async function () {
      await rollup.setVerifyingKey(
        [5n, 6n], [[5n, 6n], [7n, 8n]], [[5n, 6n], [7n, 8n]], [[5n, 6n], [7n, 8n]], [[5n, 6n], [7n, 8n]]
      );
      expect(await rollup.verifyingKeySet()).to.be.true;
    });
  });
});
