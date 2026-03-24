/// BasisVerifier test suite -- Dual verification + migration phase management.
///
/// Tests all 8 safety invariants and migration state machine transitions
/// defined in PlonkMigration.tla (TLC verified, 3.9M distinct states).
///
/// [Spec: lab/3-architect/implementation-history/prover-plonk-migration/specs/PlonkMigration.tla]

import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { ethers } from "hardhat";
import { BasisVerifierHarness } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("BasisVerifier", function () {
  let verifier: BasisVerifierHarness;
  let admin: HardhatEthersSigner;
  let enterprise: HardhatEthersSigner;
  let other: HardhatEthersSigner;

  // Default parameters
  const MAX_MIGRATION_STEPS = 100;

  // Dummy proof values (actual verification is mocked in harness)
  const DUMMY_A: [bigint, bigint] = [1n, 2n];
  const DUMMY_B: [[bigint, bigint], [bigint, bigint]] = [
    [1n, 2n],
    [3n, 4n],
  ];
  const DUMMY_C: [bigint, bigint] = [1n, 2n];
  const DUMMY_SIGNALS: bigint[] = [100n, 200n, 300n];
  const DUMMY_PLONK_PROOF = ethers.hexlify(ethers.randomBytes(160));

  // Proof system enum values
  const GROTH16 = 0;
  const PLONK = 1;

  // Phase enum values
  const PHASE_GROTH16_ONLY = 0;
  const PHASE_DUAL = 1;
  const PHASE_PLONK_ONLY = 2;
  const PHASE_ROLLBACK = 3;

  beforeEach(async function () {
    [admin, enterprise, other] = await ethers.getSigners();

    const factory = await ethers.getContractFactory(
      "BasisVerifierHarness",
      admin
    );
    verifier = (await factory.deploy(
      MAX_MIGRATION_STEPS
    )) as BasisVerifierHarness;

    // Set mock keys as configured
    await verifier.setMockGroth16Result(true);
    await verifier.setMockPlonkResult(true);

    // Mark keys as set (harness bypasses actual key validation)
    const dummyG1: [bigint, bigint] = [1n, 2n];
    const dummyG2: [[bigint, bigint], [bigint, bigint]] = [
      [1n, 2n],
      [3n, 4n],
    ];
    const dummyIC: [bigint, bigint][] = [[1n, 2n], [3n, 4n]];
    await verifier.setGroth16VerifyingKey(
      dummyG1,
      dummyG2,
      dummyG2,
      dummyG2,
      dummyIC
    );
    await verifier.setPlonkVerifyingKey(dummyG2, dummyG2, dummyG1, 1n, 14n);
  });

  // =================================================================
  // Initialization
  // =================================================================

  describe("Initialization", function () {
    it("should deploy in Groth16Only phase", async function () {
      expect(await verifier.migrationPhase()).to.equal(PHASE_GROTH16_ONLY);
    });

    it("should have failureDetected = false", async function () {
      expect(await verifier.failureDetected()).to.equal(false);
    });

    it("should have migrationStepCount = 0", async function () {
      expect(await verifier.migrationStepCount()).to.equal(0);
    });

    it("should have maxMigrationSteps set correctly", async function () {
      expect(await verifier.maxMigrationSteps()).to.equal(MAX_MIGRATION_STEPS);
    });

    it("should set admin to deployer", async function () {
      expect(await verifier.admin()).to.equal(admin.address);
    });
  });

  // =================================================================
  // S6: PhaseConsistency (activeVerifiers matches phase)
  // =================================================================

  describe("S6: PhaseConsistency", function () {
    it("Groth16Only: only Groth16 active", async function () {
      const [g16, plonk] = await verifier.activeVerifiers();
      expect(g16).to.equal(true);
      expect(plonk).to.equal(false);
    });

    it("Dual: both active", async function () {
      await verifier.startDualVerification();
      const [g16, plonk] = await verifier.activeVerifiers();
      expect(g16).to.equal(true);
      expect(plonk).to.equal(true);
    });

    it("PlonkOnly: only PLONK active", async function () {
      await verifier.startDualVerification();
      await verifier.cutoverToPlonkOnly(0);
      const [g16, plonk] = await verifier.activeVerifiers();
      expect(g16).to.equal(false);
      expect(plonk).to.equal(true);
    });

    it("Rollback: only Groth16 active", async function () {
      await verifier.startDualVerification();
      await verifier.detectFailure("test failure");
      await verifier.rollbackMigration();
      const [g16, plonk] = await verifier.activeVerifiers();
      expect(g16).to.equal(true);
      expect(plonk).to.equal(false);
    });
  });

  // =================================================================
  // S2: BackwardCompatibility (Groth16 accepted when active)
  // =================================================================

  describe("S2: BackwardCompatibility", function () {
    it("Groth16 accepted in Groth16Only phase", async function () {
      const tx = await verifier
        .connect(enterprise)
        .verifyProof(
          GROTH16,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          "0x"
        );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.valid).to.equal(true);
    });

    it("Groth16 accepted in Dual phase", async function () {
      await verifier.startDualVerification();
      const tx = await verifier
        .connect(enterprise)
        .verifyProof(
          GROTH16,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          "0x"
        );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.valid).to.equal(true);
    });

    it("Groth16 accepted in Rollback phase", async function () {
      await verifier.startDualVerification();
      await verifier.detectFailure("test failure");
      await verifier.rollbackMigration();

      const tx = await verifier
        .connect(enterprise)
        .verifyProof(
          GROTH16,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          "0x"
        );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.valid).to.equal(true);
    });
  });

  // =================================================================
  // S5: NoGroth16AfterCutover
  // =================================================================

  describe("S5: NoGroth16AfterCutover", function () {
    it("Groth16 rejected in PlonkOnly phase", async function () {
      await verifier.startDualVerification();
      await verifier.cutoverToPlonkOnly(0);

      const tx = await verifier
        .connect(enterprise)
        .verifyProof(
          GROTH16,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          "0x"
        );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.valid).to.equal(false);
    });
  });

  // =================================================================
  // PLONK Verification in Various Phases
  // =================================================================

  describe("PLONK phase acceptance", function () {
    it("PLONK rejected in Groth16Only phase", async function () {
      const tx = await verifier
        .connect(enterprise)
        .verifyProof(
          PLONK,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          DUMMY_PLONK_PROOF
        );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.valid).to.equal(false);
    });

    it("PLONK accepted in Dual phase", async function () {
      await verifier.startDualVerification();
      const tx = await verifier
        .connect(enterprise)
        .verifyProof(
          PLONK,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          DUMMY_PLONK_PROOF
        );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.valid).to.equal(true);
    });

    it("PLONK accepted in PlonkOnly phase", async function () {
      await verifier.startDualVerification();
      await verifier.cutoverToPlonkOnly(0);

      const tx = await verifier
        .connect(enterprise)
        .verifyProof(
          PLONK,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          DUMMY_PLONK_PROOF
        );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.valid).to.equal(true);
    });

    it("PLONK rejected in Rollback phase", async function () {
      await verifier.startDualVerification();
      await verifier.detectFailure("test failure");
      await verifier.rollbackMigration();

      const tx = await verifier
        .connect(enterprise)
        .verifyProof(
          PLONK,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          DUMMY_PLONK_PROOF
        );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.valid).to.equal(false);
    });
  });

  // =================================================================
  // Phase Transitions
  // =================================================================

  describe("Phase transitions", function () {
    it("Groth16Only -> Dual", async function () {
      await expect(verifier.startDualVerification())
        .to.emit(verifier, "PhaseTransition")
        .withArgs(PHASE_GROTH16_ONLY, PHASE_DUAL, anyValue);
      expect(await verifier.migrationPhase()).to.equal(PHASE_DUAL);
    });

    it("Dual -> PlonkOnly (with empty queues)", async function () {
      await verifier.startDualVerification();
      await expect(verifier.cutoverToPlonkOnly(0))
        .to.emit(verifier, "PhaseTransition");
      expect(await verifier.migrationPhase()).to.equal(PHASE_PLONK_ONLY);
    });

    it("Cannot start dual from Dual phase", async function () {
      await verifier.startDualVerification();
      await expect(verifier.startDualVerification()).to.be.revertedWithCustomError(
        verifier,
        "InvalidPhaseTransition"
      );
    });

    it("Cannot start dual from PlonkOnly phase", async function () {
      await verifier.startDualVerification();
      await verifier.cutoverToPlonkOnly(0);
      await expect(verifier.startDualVerification()).to.be.revertedWithCustomError(
        verifier,
        "InvalidPhaseTransition"
      );
    });

    it("Cannot cutover from Groth16Only", async function () {
      await expect(verifier.cutoverToPlonkOnly(0)).to.be.revertedWithCustomError(
        verifier,
        "InvalidPhaseTransition"
      );
    });

    it("Cannot cutover with pending batches", async function () {
      await verifier.startDualVerification();
      await expect(verifier.cutoverToPlonkOnly(5)).to.be.revertedWithCustomError(
        verifier,
        "QueuesNotEmpty"
      );
    });

    it("Cannot cutover after failure detected", async function () {
      await verifier.startDualVerification();
      await verifier.detectFailure("test");
      await expect(verifier.cutoverToPlonkOnly(0)).to.be.revertedWithCustomError(
        verifier,
        "InvalidPhaseTransition"
      );
    });
  });

  // =================================================================
  // S7: RollbackOnlyOnFailure
  // =================================================================

  describe("S7: RollbackOnlyOnFailure", function () {
    it("Cannot rollback without failure", async function () {
      await verifier.startDualVerification();
      await expect(verifier.rollbackMigration()).to.be.revertedWithCustomError(
        verifier,
        "FailureNotDetected"
      );
    });

    it("Cannot rollback from Groth16Only", async function () {
      await expect(verifier.rollbackMigration()).to.be.revertedWithCustomError(
        verifier,
        "NotInDualPhase"
      );
    });

    it("Rollback succeeds after failure detection", async function () {
      await verifier.startDualVerification();
      await verifier.detectFailure("PLONK verifier incorrect results");
      await expect(verifier.rollbackMigration())
        .to.emit(verifier, "RollbackInitiated");
      expect(await verifier.migrationPhase()).to.equal(PHASE_ROLLBACK);
    });
  });

  // =================================================================
  // Rollback Completion
  // =================================================================

  describe("Rollback completion", function () {
    it("Complete rollback returns to Groth16Only", async function () {
      await verifier.startDualVerification();
      await verifier.detectFailure("test");
      await verifier.rollbackMigration();
      await verifier.completeRollback(0);

      expect(await verifier.migrationPhase()).to.equal(PHASE_GROTH16_ONLY);
      expect(await verifier.failureDetected()).to.equal(false);
      expect(await verifier.migrationStepCount()).to.equal(0);
    });

    it("Cannot complete rollback with pending batches", async function () {
      await verifier.startDualVerification();
      await verifier.detectFailure("test");
      await verifier.rollbackMigration();
      await expect(verifier.completeRollback(3)).to.be.revertedWithCustomError(
        verifier,
        "QueuesNotEmpty"
      );
    });

    it("Cannot complete rollback from non-Rollback phase", async function () {
      await expect(verifier.completeRollback(0)).to.be.revertedWithCustomError(
        verifier,
        "NotInRollbackPhase"
      );
    });

    it("Full migration cycle: G16 -> Dual -> Rollback -> G16", async function () {
      // Start in Groth16Only
      expect(await verifier.migrationPhase()).to.equal(PHASE_GROTH16_ONLY);

      // Transition to Dual
      await verifier.startDualVerification();
      expect(await verifier.migrationPhase()).to.equal(PHASE_DUAL);

      // Detect failure
      await verifier.detectFailure("gas budget exceeded");

      // Rollback
      await verifier.rollbackMigration();
      expect(await verifier.migrationPhase()).to.equal(PHASE_ROLLBACK);

      // Complete rollback
      await verifier.completeRollback(0);
      expect(await verifier.migrationPhase()).to.equal(PHASE_GROTH16_ONLY);
      expect(await verifier.failureDetected()).to.equal(false);
    });
  });

  // =================================================================
  // Dual Period Management
  // =================================================================

  describe("Dual period management", function () {
    it("Tick increments step counter", async function () {
      await verifier.startDualVerification();
      await verifier.dualPeriodTick();
      expect(await verifier.migrationStepCount()).to.equal(1);
    });

    it("Tick reverts when not in dual phase", async function () {
      await expect(verifier.dualPeriodTick()).to.be.revertedWithCustomError(
        verifier,
        "NotInDualPhase"
      );
    });

    it("Tick reverts when max steps exceeded", async function () {
      const factory = await ethers.getContractFactory(
        "BasisVerifierHarness",
        admin
      );
      const smallVerifier = await factory.deploy(2); // maxSteps = 2
      await smallVerifier.startDualVerification();
      await smallVerifier.dualPeriodTick(); // step 1
      await smallVerifier.dualPeriodTick(); // step 2
      await expect(smallVerifier.dualPeriodTick()).to.be.revertedWithCustomError(
        smallVerifier,
        "MaxMigrationStepsExceeded"
      );
    });
  });

  // =================================================================
  // Failure Detection
  // =================================================================

  describe("Failure detection", function () {
    it("DetectFailure emits event", async function () {
      await verifier.startDualVerification();
      await expect(verifier.detectFailure("critical vulnerability"))
        .to.emit(verifier, "FailureDetected");
      expect(await verifier.failureDetected()).to.equal(true);
    });

    it("Cannot detect failure twice", async function () {
      await verifier.startDualVerification();
      await verifier.detectFailure("first");
      await expect(verifier.detectFailure("second")).to.be.revertedWithCustomError(
        verifier,
        "FailureAlreadyDetected"
      );
    });

    it("Cannot detect failure outside dual phase", async function () {
      await expect(verifier.detectFailure("test")).to.be.revertedWithCustomError(
        verifier,
        "NotInDualPhase"
      );
    });
  });

  // =================================================================
  // S3: Soundness (invalid proofs rejected)
  // =================================================================

  describe("S3: Soundness", function () {
    it("Invalid Groth16 proof rejected", async function () {
      await verifier.setMockGroth16Result(false);

      const tx = await verifier
        .connect(enterprise)
        .verifyProof(
          GROTH16,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          "0x"
        );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.valid).to.equal(false);
    });

    it("Invalid PLONK proof rejected in Dual phase", async function () {
      await verifier.startDualVerification();
      await verifier.setMockPlonkResult(false);

      const tx = await verifier
        .connect(enterprise)
        .verifyProof(
          PLONK,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          DUMMY_PLONK_PROOF
        );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.valid).to.equal(false);
    });
  });

  // =================================================================
  // Access Control
  // =================================================================

  describe("Access control", function () {
    it("Non-admin cannot start dual verification", async function () {
      await expect(
        verifier.connect(other).startDualVerification()
      ).to.be.revertedWithCustomError(verifier, "OnlyAdmin");
    });

    it("Non-admin cannot cutover", async function () {
      await verifier.startDualVerification();
      await expect(
        verifier.connect(other).cutoverToPlonkOnly(0)
      ).to.be.revertedWithCustomError(verifier, "OnlyAdmin");
    });

    it("Non-admin cannot detect failure", async function () {
      await verifier.startDualVerification();
      await expect(
        verifier.connect(other).detectFailure("test")
      ).to.be.revertedWithCustomError(verifier, "OnlyAdmin");
    });

    it("Non-admin cannot rollback", async function () {
      await verifier.startDualVerification();
      await verifier.detectFailure("test");
      await expect(
        verifier.connect(other).rollbackMigration()
      ).to.be.revertedWithCustomError(verifier, "OnlyAdmin");
    });
  });

  // =================================================================
  // Proof Counter Tracking
  // =================================================================

  describe("Proof counters", function () {
    it("Tracks Groth16 proof count", async function () {
      await verifier
        .connect(enterprise)
        .verifyProof(
          GROTH16,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          "0x"
        );
      expect(await verifier.proofsVerified(GROTH16)).to.equal(1);
    });

    it("Tracks PLONK proof count in Dual phase", async function () {
      await verifier.startDualVerification();
      await verifier
        .connect(enterprise)
        .verifyProof(
          PLONK,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          DUMMY_PLONK_PROOF
        );
      expect(await verifier.proofsVerified(PLONK)).to.equal(1);
    });

    it("Does not increment counter for rejected proofs", async function () {
      // PLONK not active in Groth16Only -> rejected, counter stays at 0
      await verifier
        .connect(enterprise)
        .verifyProof(
          PLONK,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          DUMMY_PLONK_PROOF
        );
      expect(await verifier.proofsVerified(PLONK)).to.equal(0);
    });
  });

  // =================================================================
  // Migration Status View
  // =================================================================

  describe("Migration status", function () {
    it("Returns complete migration state", async function () {
      await verifier.startDualVerification();
      await verifier.dualPeriodTick();

      await verifier
        .connect(enterprise)
        .verifyProof(
          GROTH16,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          "0x"
        );

      const status = await verifier.getMigrationStatus();
      expect(status.phase).to.equal(PHASE_DUAL);
      expect(status.failure).to.equal(false);
      expect(status.stepCount).to.equal(1);
      expect(status.maxSteps).to.equal(MAX_MIGRATION_STEPS);
      expect(status.groth16Count).to.equal(1);
      expect(status.plonkCount).to.equal(0);
    });
  });

  // =================================================================
  // Full Migration Lifecycle
  // =================================================================

  describe("Full migration lifecycle", function () {
    it("G16Only -> Dual -> PlonkOnly (happy path)", async function () {
      // Phase 1: Groth16Only -- verify a Groth16 proof
      await verifier
        .connect(enterprise)
        .verifyProof(
          GROTH16,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          "0x"
        );

      // Phase 2: Start dual verification
      await verifier.startDualVerification();

      // Verify both proof types during dual period
      await verifier
        .connect(enterprise)
        .verifyProof(
          GROTH16,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          "0x"
        );
      await verifier
        .connect(enterprise)
        .verifyProof(
          PLONK,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          DUMMY_PLONK_PROOF
        );

      // Phase 3: Cutover to PLONK-only
      await verifier.cutoverToPlonkOnly(0);

      // Verify PLONK works
      const tx = await verifier
        .connect(enterprise)
        .verifyProof(
          PLONK,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          DUMMY_PLONK_PROOF
        );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.valid).to.equal(true);

      // Verify Groth16 is rejected
      const tx2 = await verifier
        .connect(enterprise)
        .verifyProof(
          GROTH16,
          DUMMY_A,
          DUMMY_B,
          DUMMY_C,
          DUMMY_SIGNALS,
          "0x"
        );
      const receipt2 = await tx2.wait();
      const event2 = receipt2!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed2 = verifier.interface.parseLog(event2 as any);
      expect(parsed2!.args.valid).to.equal(false);

      // Final counts
      expect(await verifier.proofsVerified(GROTH16)).to.equal(2); // 2 valid G16 proofs
      expect(await verifier.proofsVerified(PLONK)).to.equal(2); // 2 valid PLONK proofs
    });
  });

});
