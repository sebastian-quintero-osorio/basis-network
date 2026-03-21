/// BasisAggregator test suite -- Aggregated proof verification and gas accounting.
///
/// Tests the on-chain side of the proof aggregation pipeline formalized in
/// ProofAggregation.tla (TLC verified, 788,734 states, 5 safety properties).
///
/// Test organization maps to TLA+ safety properties:
///   S1 AggregationSoundness:     Valid aggregation accepted, invalid rejected
///   S3 OrderIndependence:        Sorted enterprise addresses enforced
///   S4 GasMonotonicity:          Per-enterprise cost decreases with N
///   Lifecycle:                   Submission, verification, rejection
///   Gas accounting:              Per-enterprise cost tracking
///   Access control:              Admin-only functions
///
/// [Spec: lab/3-architect/implementation-history/prover-aggregation/specs/ProofAggregation.tla]

import { expect } from "chai";
import { ethers } from "hardhat";
import { BasisAggregatorHarness } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("BasisAggregator", function () {
  let aggregator: BasisAggregatorHarness;
  let admin: HardhatEthersSigner;
  let enterprise1: HardhatEthersSigner;
  let enterprise2: HardhatEthersSigner;
  let enterprise3: HardhatEthersSigner;
  let enterprise4: HardhatEthersSigner;
  let other: HardhatEthersSigner;

  // Dummy Groth16 proof values (verification is mocked in harness)
  const DUMMY_A: [bigint, bigint] = [1n, 2n];
  const DUMMY_B: [[bigint, bigint], [bigint, bigint]] = [
    [1n, 2n],
    [3n, 4n],
  ];
  const DUMMY_C: [bigint, bigint] = [1n, 2n];
  const DUMMY_SIGNALS: bigint[] = [100n, 200n, 300n];

  // Aggregation status enum values
  const STATUS_NONE = 0;
  const STATUS_PENDING = 1;
  const STATUS_VERIFIED = 2;
  const STATUS_REJECTED = 3;

  // Gas constants
  const BASE_GAS_PER_PROOF = 420_000n;
  const AGGREGATED_GAS_COST = 220_000n;

  /// Sort addresses numerically (ascending) to match contract requirement.
  function sortAddresses(addrs: string[]): string[] {
    return [...addrs].sort((a, b) => {
      const aNum = BigInt(a);
      const bNum = BigInt(b);
      if (aNum < bNum) return -1;
      if (aNum > bNum) return 1;
      return 0;
    });
  }

  beforeEach(async function () {
    [admin, enterprise1, enterprise2, enterprise3, enterprise4, other] =
      await ethers.getSigners();

    const factory = await ethers.getContractFactory(
      "BasisAggregatorHarness",
      admin
    );
    aggregator = (await factory.deploy(admin.address)) as BasisAggregatorHarness;

    // Bypass verifying key requirement for testing
    await aggregator.setVerifyingKeyForTest();
  });

  // =========================================================================
  // Initialization
  // =========================================================================

  describe("Initialization", function () {
    it("should set admin correctly", async function () {
      expect(await aggregator.admin()).to.equal(admin.address);
    });

    it("should start with zero aggregations", async function () {
      expect(await aggregator.nextAggregationId()).to.equal(0);
      expect(await aggregator.totalAggregationsVerified()).to.equal(0);
      expect(await aggregator.totalProofsAggregated()).to.equal(0);
    });

    it("should have correct gas constants", async function () {
      expect(await aggregator.BASE_GAS_PER_PROOF()).to.equal(BASE_GAS_PER_PROOF);
      expect(await aggregator.AGGREGATED_GAS_COST()).to.equal(AGGREGATED_GAS_COST);
      expect(await aggregator.MIN_AGGREGATION_SIZE()).to.equal(2);
    });
  });

  // =========================================================================
  // S1: AggregationSoundness -- valid proof accepted
  // =========================================================================

  describe("S1: AggregationSoundness", function () {
    it("should accept valid aggregated proof for 2 enterprises", async function () {
      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      const hashes = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];

      await aggregator.setMockVerificationResult(true);
      const tx = await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, hashes
      );

      const receipt = await tx.wait();
      const agg = await aggregator.aggregations(0);
      expect(agg.status).to.equal(STATUS_VERIFIED);
      expect(agg.numEnterprises).to.equal(2);
    });

    it("should accept valid aggregated proof for 4 enterprises", async function () {
      const sorted = sortAddresses([
        enterprise1.address, enterprise2.address,
        enterprise3.address, enterprise4.address,
      ]);
      const hashes = Array(4).fill(ethers.keccak256("0x01"));

      const tx = await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, hashes
      );

      const agg = await aggregator.aggregations(0);
      expect(agg.status).to.equal(STATUS_VERIFIED);
      expect(agg.numEnterprises).to.equal(4);
    });

    it("should reject invalid aggregated proof", async function () {
      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      const hashes = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];

      await aggregator.setMockVerificationResult(false);
      await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, hashes
      );

      const agg = await aggregator.aggregations(0);
      expect(agg.status).to.equal(STATUS_REJECTED);
    });
  });

  // =========================================================================
  // S3: OrderIndependence -- sorted addresses enforced
  // =========================================================================

  describe("S3: OrderIndependence", function () {
    it("should reject unsorted enterprise addresses", async function () {
      // Ensure enterprise1 > enterprise2 numerically to test rejection
      const addr1 = enterprise1.address;
      const addr2 = enterprise2.address;
      const reversed = BigInt(addr1) > BigInt(addr2) ? [addr1, addr2] : [addr2, addr1];
      // The reversed array has the larger address first, which should be rejected
      // unless they happen to be sorted (unlikely)
      if (BigInt(reversed[0]) > BigInt(reversed[1])) {
        const hashes = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];
        await expect(
          aggregator.verifyAggregatedProof(
            DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
            reversed, hashes
          )
        ).to.be.revertedWithCustomError(aggregator, "DuplicateEnterprise");
      }
    });

    it("should reject duplicate enterprise addresses", async function () {
      const hashes = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];
      await expect(
        aggregator.verifyAggregatedProof(
          DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
          [enterprise1.address, enterprise1.address], hashes
        )
      ).to.be.revertedWithCustomError(aggregator, "DuplicateEnterprise");
    });

    it("should produce same result for canonically sorted enterprises", async function () {
      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      const hashes = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];

      await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, hashes
      );

      const agg = await aggregator.aggregations(0);
      expect(agg.status).to.equal(STATUS_VERIFIED);
    });
  });

  // =========================================================================
  // S4: GasMonotonicity -- per-enterprise cost decreases with N
  // =========================================================================

  describe("S4: GasMonotonicity", function () {
    it("should report correct gas per enterprise for N=2", async function () {
      const [perEnterprise, savingsFactor] = await aggregator.gasPerEnterprise(2);
      expect(perEnterprise).to.equal(110_000n); // 220K / 2
      expect(savingsFactor).to.equal(381n); // (420K * 2 * 100) / 220K = 381
    });

    it("should report correct gas per enterprise for N=4", async function () {
      const [perEnterprise, savingsFactor] = await aggregator.gasPerEnterprise(4);
      expect(perEnterprise).to.equal(55_000n); // 220K / 4
      expect(savingsFactor).to.equal(763n); // (420K * 4 * 100) / 220K
    });

    it("should report correct gas per enterprise for N=8", async function () {
      const [perEnterprise, savingsFactor] = await aggregator.gasPerEnterprise(8);
      expect(perEnterprise).to.equal(27_500n); // 220K / 8
      expect(savingsFactor).to.equal(1527n); // ~15.3x
    });

    it("should show monotonically decreasing cost", async function () {
      let prevCost = BASE_GAS_PER_PROOF;
      for (let n = 2; n <= 16; n++) {
        const [perEnterprise] = await aggregator.gasPerEnterprise(n);
        expect(perEnterprise).to.be.lessThan(prevCost);
        prevCost = perEnterprise;
      }
    });
  });

  // =========================================================================
  // Gas accounting
  // =========================================================================

  describe("Gas accounting", function () {
    it("should track per-enterprise gas on successful verification", async function () {
      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      const hashes = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];

      await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, hashes
      );

      // Each enterprise charged 220K / 2 = 110K
      const gas1 = await aggregator.enterpriseGasUsed(sorted[0]);
      const gas2 = await aggregator.enterpriseGasUsed(sorted[1]);
      expect(gas1).to.equal(110_000n);
      expect(gas2).to.equal(110_000n);
    });

    it("should not charge gas on rejected verification", async function () {
      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      const hashes = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];

      await aggregator.setMockVerificationResult(false);
      await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, hashes
      );

      const gas1 = await aggregator.enterpriseGasUsed(sorted[0]);
      const gas2 = await aggregator.enterpriseGasUsed(sorted[1]);
      expect(gas1).to.equal(0);
      expect(gas2).to.equal(0);
    });

    it("should accumulate gas across multiple aggregations", async function () {
      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      const hashes1 = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];
      const hashes2 = [ethers.keccak256("0x03"), ethers.keccak256("0x04")];

      await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, hashes1
      );
      await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, hashes2
      );

      const gas = await aggregator.enterpriseGasUsed(sorted[0]);
      expect(gas).to.equal(220_000n); // 110K * 2
    });

    it("should increment global counters on verified aggregation", async function () {
      const sorted = sortAddresses([
        enterprise1.address, enterprise2.address,
        enterprise3.address, enterprise4.address,
      ]);
      const hashes = Array(4).fill(ethers.keccak256("0x01"));

      await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, hashes
      );

      expect(await aggregator.totalAggregationsVerified()).to.equal(1);
      expect(await aggregator.totalProofsAggregated()).to.equal(4);
    });
  });

  // =========================================================================
  // Input validation
  // =========================================================================

  describe("Input validation", function () {
    it("should reject less than MIN_AGGREGATION_SIZE enterprises", async function () {
      await expect(
        aggregator.verifyAggregatedProof(
          DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
          [enterprise1.address],
          [ethers.keccak256("0x01")]
        )
      ).to.be.revertedWithCustomError(aggregator, "InsufficientProofs");
    });

    it("should reject mismatched enterprise/batch arrays", async function () {
      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      await expect(
        aggregator.verifyAggregatedProof(
          DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
          sorted,
          [ethers.keccak256("0x01")]  // Only 1 hash for 2 enterprises
        )
      ).to.be.revertedWithCustomError(aggregator, "EnterpriseBatchMismatch");
    });

    it("should reject when verifying key not set", async function () {
      // Deploy fresh contract without setting key
      const factory = await ethers.getContractFactory("BasisAggregatorHarness", admin);
      const fresh = (await factory.deploy(admin.address)) as BasisAggregatorHarness;

      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      const hashes = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];

      await expect(
        fresh.verifyAggregatedProof(
          DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
          sorted, hashes
        )
      ).to.be.revertedWithCustomError(fresh, "VerifyingKeyNotSet");
    });
  });

  // =========================================================================
  // Events
  // =========================================================================

  describe("Events", function () {
    it("should emit AggregationSubmitted and AggregationVerified", async function () {
      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      const hashes = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];

      await expect(
        aggregator.verifyAggregatedProof(
          DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
          sorted, hashes
        )
      ).to.emit(aggregator, "AggregationSubmitted")
        .and.to.emit(aggregator, "AggregationVerified");
    });

    it("should emit EnterpriseProofVerified for each enterprise", async function () {
      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      const hashes = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];

      await expect(
        aggregator.verifyAggregatedProof(
          DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
          sorted, hashes
        )
      ).to.emit(aggregator, "EnterpriseProofVerified");
    });
  });

  // =========================================================================
  // Component data retrieval
  // =========================================================================

  describe("Component data", function () {
    it("should store and return component enterprises", async function () {
      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      const hashes = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];

      await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, hashes
      );

      const stored = await aggregator.getAggregationEnterprises(0);
      expect(stored.length).to.equal(2);
      expect(stored[0]).to.equal(sorted[0]);
      expect(stored[1]).to.equal(sorted[1]);
    });

    it("should store and return component batch hashes", async function () {
      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      const hash1 = ethers.keccak256("0x01");
      const hash2 = ethers.keccak256("0x02");

      await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, [hash1, hash2]
      );

      const stored = await aggregator.getAggregationBatchHashes(0);
      expect(stored.length).to.equal(2);
      expect(stored[0]).to.equal(hash1);
      expect(stored[1]).to.equal(hash2);
    });
  });

  // =========================================================================
  // Access control
  // =========================================================================

  describe("Access control", function () {
    it("should allow only admin to set decider key", async function () {
      const factory = await ethers.getContractFactory("BasisAggregatorHarness", admin);
      const fresh = (await factory.deploy(admin.address)) as BasisAggregatorHarness;

      const dummyG1: [bigint, bigint] = [1n, 2n];
      const dummyG2: [[bigint, bigint], [bigint, bigint]] = [[1n, 2n], [3n, 4n]];

      await expect(
        fresh.connect(other).setDeciderKey(dummyG1, dummyG2, dummyG2, dummyG2, [dummyG1])
      ).to.be.revertedWithCustomError(fresh, "NotAdmin");
    });

    it("should prevent setting decider key twice", async function () {
      const dummyG1: [bigint, bigint] = [1n, 2n];
      const dummyG2: [[bigint, bigint], [bigint, bigint]] = [[1n, 2n], [3n, 4n]];

      await expect(
        aggregator.setDeciderKey(dummyG1, dummyG2, dummyG2, dummyG2, [dummyG1])
      ).to.be.revertedWithCustomError(aggregator, "DeciderKeyAlreadySet");
    });
  });

  // =========================================================================
  // Aggregation ID sequencing
  // =========================================================================

  describe("Aggregation ID sequencing", function () {
    it("should assign sequential aggregation IDs", async function () {
      const sorted = sortAddresses([enterprise1.address, enterprise2.address]);
      const hashes1 = [ethers.keccak256("0x01"), ethers.keccak256("0x02")];
      const hashes2 = [ethers.keccak256("0x03"), ethers.keccak256("0x04")];

      await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, hashes1
      );
      await aggregator.verifyAggregatedProof(
        DUMMY_A, DUMMY_B, DUMMY_C, DUMMY_SIGNALS,
        sorted, hashes2
      );

      const agg0 = await aggregator.aggregations(0);
      const agg1 = await aggregator.aggregations(1);
      expect(agg0.numEnterprises).to.equal(2);
      expect(agg1.numEnterprises).to.equal(2);
      expect(await aggregator.nextAggregationId()).to.equal(2);
    });
  });
});
