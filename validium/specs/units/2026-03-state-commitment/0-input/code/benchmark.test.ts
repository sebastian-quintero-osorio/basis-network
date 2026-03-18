import { ethers } from "hardhat";
import { expect } from "chai";

// Gas cost of Groth16 verification with 4 public inputs (BN256 precompiles)
// = 4 * ecMul(6000) + 4 * ecAdd(150) + pairing(45000 + 34000*4)
const ZK_VERIFICATION_GAS = 205_600;

describe("StateCommitment Benchmark", function () {
  // Generate deterministic mock state roots
  function mockRoot(n: number): string {
    return ethers.solidityPackedKeccak256(["string", "uint256"], ["root", n]);
  }

  describe("Layout A: Minimal (roots only + events)", function () {
    let contract: any;
    let enterprise: any;
    let admin: any;

    beforeEach(async function () {
      [admin, enterprise] = await ethers.getSigners();
      const Factory = await ethers.getContractFactory("BenchmarkMinimal");
      contract = await Factory.deploy();
      await contract.waitForDeployment();
      await contract.initializeEnterprise(enterprise.address, mockRoot(0));
    });

    it("measures gas for first batch submission (cold storage)", async function () {
      const tx = await contract.connect(enterprise).submitBatch(
        mockRoot(0), // prevRoot
        mockRoot(1), // newRoot
        8            // batchSize
      );
      const receipt = await tx.wait();
      const storageGas = Number(receipt!.gasUsed);
      const totalEstimate = storageGas + ZK_VERIFICATION_GAS;

      console.log("--- Layout A: Minimal ---");
      console.log(`  Storage + logic gas:  ${storageGas}`);
      console.log(`  ZK verification gas:  ${ZK_VERIFICATION_GAS}`);
      console.log(`  Total estimate:       ${totalEstimate}`);
      console.log(`  Under 300K target:    ${totalEstimate < 300_000 ? "YES" : "NO"}`);
      console.log(`  Storage per batch:    32 bytes (1 slot)`);
    });

    it("measures gas for 10th batch submission (warm patterns)", async function () {
      // Submit 9 batches first
      for (let i = 0; i < 9; i++) {
        await contract.connect(enterprise).submitBatch(
          mockRoot(i), mockRoot(i + 1), 8
        );
      }
      // Measure the 10th
      const tx = await contract.connect(enterprise).submitBatch(
        mockRoot(9), mockRoot(10), 8
      );
      const receipt = await tx.wait();
      const storageGas = Number(receipt!.gasUsed);
      console.log(`  10th batch gas (storage+logic): ${storageGas}`);
      console.log(`  10th batch total estimate:      ${storageGas + ZK_VERIFICATION_GAS}`);
    });

    it("detects root chain gap (wrong prevRoot)", async function () {
      // Submit batch 0
      await contract.connect(enterprise).submitBatch(mockRoot(0), mockRoot(1), 8);

      // Try to submit with wrong prevRoot (gap)
      await expect(
        contract.connect(enterprise).submitBatch(mockRoot(0), mockRoot(2), 8)
      ).to.be.revertedWithCustomError(contract, "RootChainBroken")
        .withArgs(mockRoot(1), mockRoot(0));

      console.log("  Gap detection: PASS (rejects wrong prevRoot)");
    });

    it("detects reversal attempt (resubmit old root)", async function () {
      // Submit batches 0 and 1
      await contract.connect(enterprise).submitBatch(mockRoot(0), mockRoot(1), 8);
      await contract.connect(enterprise).submitBatch(mockRoot(1), mockRoot(2), 8);

      // Try to revert to root 0
      await expect(
        contract.connect(enterprise).submitBatch(mockRoot(0), mockRoot(1), 8)
      ).to.be.revertedWithCustomError(contract, "RootChainBroken");

      console.log("  Reversal detection: PASS (rejects old prevRoot)");
    });

    it("enforces enterprise isolation", async function () {
      const [, , otherEnterprise] = await ethers.getSigners();
      await contract.initializeEnterprise(otherEnterprise.address, mockRoot(100));

      // Enterprise A submits
      await contract.connect(enterprise).submitBatch(mockRoot(0), mockRoot(1), 8);

      // Enterprise B cannot use A's state
      await expect(
        contract.connect(otherEnterprise).submitBatch(mockRoot(1), mockRoot(2), 8)
      ).to.be.revertedWithCustomError(contract, "RootChainBroken");

      // Enterprise B can use its own state
      await contract.connect(otherEnterprise).submitBatch(
        mockRoot(100), mockRoot(101), 4
      );

      // Verify isolation
      expect(await contract.getCurrentRoot(enterprise.address)).to.equal(mockRoot(1));
      expect(await contract.getCurrentRoot(otherEnterprise.address)).to.equal(mockRoot(101));

      console.log("  Enterprise isolation: PASS");
    });

    it("verifies batch history queryability", async function () {
      for (let i = 0; i < 5; i++) {
        await contract.connect(enterprise).submitBatch(mockRoot(i), mockRoot(i + 1), 8);
      }

      // Query historical roots
      for (let i = 0; i < 5; i++) {
        expect(await contract.getBatchRoot(enterprise.address, i)).to.equal(mockRoot(i + 1));
      }

      expect(await contract.getCurrentRoot(enterprise.address)).to.equal(mockRoot(5));
      console.log("  History queryability: PASS (all 5 batch roots retrievable)");
    });
  });

  describe("Layout B: Rich (roots + packed metadata)", function () {
    let contract: any;
    let enterprise: any;

    beforeEach(async function () {
      const [admin, ent] = await ethers.getSigners();
      enterprise = ent;
      const Factory = await ethers.getContractFactory("BenchmarkRich");
      contract = await Factory.deploy();
      await contract.waitForDeployment();
      await contract.initializeEnterprise(enterprise.address, mockRoot(0));
    });

    it("measures gas for first batch submission", async function () {
      const tx = await contract.connect(enterprise).submitBatch(
        mockRoot(0), mockRoot(1), 8
      );
      const receipt = await tx.wait();
      const storageGas = Number(receipt!.gasUsed);
      const totalEstimate = storageGas + ZK_VERIFICATION_GAS;

      console.log("--- Layout B: Rich ---");
      console.log(`  Storage + logic gas:  ${storageGas}`);
      console.log(`  ZK verification gas:  ${ZK_VERIFICATION_GAS}`);
      console.log(`  Total estimate:       ${totalEstimate}`);
      console.log(`  Under 300K target:    ${totalEstimate < 300_000 ? "YES" : "NO"}`);
      console.log(`  Storage per batch:    64 bytes (2 slots)`);
    });

    it("measures gas for 10th batch submission", async function () {
      for (let i = 0; i < 9; i++) {
        await contract.connect(enterprise).submitBatch(mockRoot(i), mockRoot(i + 1), 8);
      }
      const tx = await contract.connect(enterprise).submitBatch(
        mockRoot(9), mockRoot(10), 8
      );
      const receipt = await tx.wait();
      console.log(`  10th batch gas (storage+logic): ${Number(receipt!.gasUsed)}`);
    });

    it("verifies cumulative transaction tracking", async function () {
      for (let i = 0; i < 5; i++) {
        await contract.connect(enterprise).submitBatch(mockRoot(i), mockRoot(i + 1), 8);
      }
      const [, , , cumTx] = await contract.getBatchInfo(enterprise.address, 4);
      expect(cumTx).to.equal(40); // 5 * 8
      console.log("  Cumulative tx tracking: PASS (40 after 5 batches of 8)");
    });

    it("detects root chain gap", async function () {
      await contract.connect(enterprise).submitBatch(mockRoot(0), mockRoot(1), 8);
      await expect(
        contract.connect(enterprise).submitBatch(mockRoot(0), mockRoot(2), 8)
      ).to.be.revertedWithCustomError(contract, "RootChainBroken");
      console.log("  Gap detection: PASS");
    });
  });

  describe("Layout C: Events Only (no per-batch storage)", function () {
    let contract: any;
    let enterprise: any;

    beforeEach(async function () {
      const [admin, ent] = await ethers.getSigners();
      enterprise = ent;
      const Factory = await ethers.getContractFactory("BenchmarkEventsOnly");
      contract = await Factory.deploy();
      await contract.waitForDeployment();
      await contract.initializeEnterprise(enterprise.address, mockRoot(0));
    });

    it("measures gas for first batch submission", async function () {
      const tx = await contract.connect(enterprise).submitBatch(
        mockRoot(0), mockRoot(1), 8
      );
      const receipt = await tx.wait();
      const storageGas = Number(receipt!.gasUsed);
      const totalEstimate = storageGas + ZK_VERIFICATION_GAS;

      console.log("--- Layout C: Events Only ---");
      console.log(`  Storage + logic gas:  ${storageGas}`);
      console.log(`  ZK verification gas:  ${ZK_VERIFICATION_GAS}`);
      console.log(`  Total estimate:       ${totalEstimate}`);
      console.log(`  Under 300K target:    ${totalEstimate < 300_000 ? "YES" : "NO"}`);
      console.log(`  Storage per batch:    0 bytes (events only)`);
    });

    it("measures gas for 10th batch submission", async function () {
      for (let i = 0; i < 9; i++) {
        await contract.connect(enterprise).submitBatch(mockRoot(i), mockRoot(i + 1), 8);
      }
      const tx = await contract.connect(enterprise).submitBatch(
        mockRoot(9), mockRoot(10), 8
      );
      const receipt = await tx.wait();
      console.log(`  10th batch gas (storage+logic): ${Number(receipt!.gasUsed)}`);
    });

    it("detects root chain gap", async function () {
      await contract.connect(enterprise).submitBatch(mockRoot(0), mockRoot(1), 8);
      await expect(
        contract.connect(enterprise).submitBatch(mockRoot(0), mockRoot(2), 8)
      ).to.be.revertedWithCustomError(contract, "RootChainBroken");
      console.log("  Gap detection: PASS");
    });

    it("detects reversal attempt", async function () {
      await contract.connect(enterprise).submitBatch(mockRoot(0), mockRoot(1), 8);
      await contract.connect(enterprise).submitBatch(mockRoot(1), mockRoot(2), 8);
      await expect(
        contract.connect(enterprise).submitBatch(mockRoot(0), mockRoot(1), 8)
      ).to.be.revertedWithCustomError(contract, "RootChainBroken");
      console.log("  Reversal detection: PASS");
    });

    it("event data is recoverable", async function () {
      const tx = await contract.connect(enterprise).submitBatch(
        mockRoot(0), mockRoot(1), 8
      );
      const receipt = await tx.wait();
      const event = receipt!.logs[0];

      // Verify event contains all batch metadata
      const iface = contract.interface;
      const parsed = iface.parseLog({ topics: event.topics, data: event.data });
      expect(parsed!.args.enterprise).to.equal(enterprise.address);
      expect(parsed!.args.batchId).to.equal(0);
      expect(parsed!.args.prevRoot).to.equal(mockRoot(0));
      expect(parsed!.args.newRoot).to.equal(mockRoot(1));
      expect(parsed!.args.batchSize).to.equal(8);
      console.log("  Event data recovery: PASS");
    });
  });

  describe("Comparative Summary", function () {
    it("prints gas comparison across all layouts", async function () {
      const [admin, enterprise] = await ethers.getSigners();

      // Deploy all three
      const MinFactory = await ethers.getContractFactory("BenchmarkMinimal");
      const minimal = await MinFactory.deploy();
      await minimal.waitForDeployment();

      const RichFactory = await ethers.getContractFactory("BenchmarkRich");
      const rich = await RichFactory.deploy();
      await rich.waitForDeployment();

      const EvFactory = await ethers.getContractFactory("BenchmarkEventsOnly");
      const evOnly = await EvFactory.deploy();
      await evOnly.waitForDeployment();

      // Initialize all
      await minimal.initializeEnterprise(enterprise.address, mockRoot(0));
      await rich.initializeEnterprise(enterprise.address, mockRoot(0));
      await evOnly.initializeEnterprise(enterprise.address, mockRoot(0));

      // First batch (cold)
      const txMin = await minimal.connect(enterprise).submitBatch(mockRoot(0), mockRoot(1), 8);
      const txRich = await rich.connect(enterprise).submitBatch(mockRoot(0), mockRoot(1), 8);
      const txEv = await evOnly.connect(enterprise).submitBatch(mockRoot(0), mockRoot(1), 8);

      const rMin = await txMin.wait();
      const rRich = await txRich.wait();
      const rEv = await txEv.wait();

      const gMin = Number(rMin!.gasUsed);
      const gRich = Number(rRich!.gasUsed);
      const gEv = Number(rEv!.gasUsed);

      console.log("\n=== COMPARATIVE GAS RESULTS ===\n");
      console.log("Layout                | Storage Gas | + ZK Verify | Total Est  | Storage/Batch | Under 300K?");
      console.log("----------------------|-------------|-------------|------------|---------------|------------");
      console.log(`A: Minimal (roots)    | ${String(gMin).padStart(11)} | ${String(ZK_VERIFICATION_GAS).padStart(11)} | ${String(gMin + ZK_VERIFICATION_GAS).padStart(10)} | 32 bytes      | ${gMin + ZK_VERIFICATION_GAS < 300_000 ? "YES" : "NO"}`);
      console.log(`B: Rich (metadata)    | ${String(gRich).padStart(11)} | ${String(ZK_VERIFICATION_GAS).padStart(11)} | ${String(gRich + ZK_VERIFICATION_GAS).padStart(10)} | 64 bytes      | ${gRich + ZK_VERIFICATION_GAS < 300_000 ? "YES" : "NO"}`);
      console.log(`C: Events Only        | ${String(gEv).padStart(11)} | ${String(ZK_VERIFICATION_GAS).padStart(11)} | ${String(gEv + ZK_VERIFICATION_GAS).padStart(10)} | 0 bytes       | ${gEv + ZK_VERIFICATION_GAS < 300_000 ? "YES" : "NO"}`);

      // Second batch (warm enterprise state)
      const txMin2 = await minimal.connect(enterprise).submitBatch(mockRoot(1), mockRoot(2), 8);
      const txRich2 = await rich.connect(enterprise).submitBatch(mockRoot(1), mockRoot(2), 8);
      const txEv2 = await evOnly.connect(enterprise).submitBatch(mockRoot(1), mockRoot(2), 8);

      const rMin2 = await txMin2.wait();
      const rRich2 = await txRich2.wait();
      const rEv2 = await txEv2.wait();

      const gMin2 = Number(rMin2!.gasUsed);
      const gRich2 = Number(rRich2!.gasUsed);
      const gEv2 = Number(rEv2!.gasUsed);

      console.log("\n--- Second Batch (warm enterprise state) ---\n");
      console.log(`A: Minimal (roots)    | ${String(gMin2).padStart(11)} | ${String(ZK_VERIFICATION_GAS).padStart(11)} | ${String(gMin2 + ZK_VERIFICATION_GAS).padStart(10)} | 32 bytes      | ${gMin2 + ZK_VERIFICATION_GAS < 300_000 ? "YES" : "NO"}`);
      console.log(`B: Rich (metadata)    | ${String(gRich2).padStart(11)} | ${String(ZK_VERIFICATION_GAS).padStart(11)} | ${String(gRich2 + ZK_VERIFICATION_GAS).padStart(10)} | 64 bytes      | ${gRich2 + ZK_VERIFICATION_GAS < 300_000 ? "YES" : "NO"}`);
      console.log(`C: Events Only        | ${String(gEv2).padStart(11)} | ${String(ZK_VERIFICATION_GAS).padStart(11)} | ${String(gEv2 + ZK_VERIFICATION_GAS).padStart(10)} | 0 bytes       | ${gEv2 + ZK_VERIFICATION_GAS < 300_000 ? "YES" : "NO"}`);

      console.log("\n--- Delta (Rich - Minimal) = cost of on-chain metadata ---");
      console.log(`  First batch:  +${gRich - gMin} gas (+${((gRich - gMin) / gMin * 100).toFixed(1)}%)`);
      console.log(`  Second batch: +${gRich2 - gMin2} gas (+${((gRich2 - gMin2) / gMin2 * 100).toFixed(1)}%)`);
      console.log(`\n--- Delta (Minimal - EventsOnly) = cost of root history ---`);
      console.log(`  First batch:  +${gMin - gEv} gas`);
      console.log(`  Second batch: +${gMin2 - gEv2} gas`);
    });
  });
});
