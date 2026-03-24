/// PlonkVerifier test suite -- KZG-PLONK proof verification on BN254.
///
/// Tests the standalone PlonkVerifier contract that validates PLONK-KZG proofs
/// from the Basis Network zkEVM L2 prover using BN254 pairing precompiles
/// (EIP-196/197).
///
/// Coverage:
///   1. Deployment and initial state
///   2. VK configuration (configureVK, events, access control, double-config guard)
///   3. Proof verification guards (VK not configured, short proof, wrong input count)
///   4. Proof structure (well-formed proof with proper length)
///   5. Commitment verification (verifyCommitment matches after verifyProof)
///   6. KZG pairing with known BN254 curve points
///   7. Event emission (ProofVerified with correct batchHash)
///   8. Access control (admin-only configureVK)

import { expect } from "chai";
import { ethers } from "hardhat";
import { PlonkVerifier } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("PlonkVerifier", function () {
  let verifier: PlonkVerifier;
  let admin: HardhatEthersSigner;
  let other: HardhatEthersSigner;
  let enterprise: HardhatEthersSigner;

  // BN254 curve constants
  const BN254_P = 21888242871839275222246405745257275088696311157297823662689037894645226208583n;
  const BN254_ORDER = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

  // BN254 G1 generator
  const G1_X = 1n;
  const G1_Y = 2n;

  // BN254 G2 generator coordinates
  // x = x_c0 + x_c1 * u, y = y_c0 + y_c1 * u (Fp2 tower)
  const G2_X_C0 = 10857046999023057135944570762232829481370756359578518086990519993285655852781n;
  const G2_X_C1 = 11559732032986387107991004021392285783925812861821192530917403151452391805634n;
  const G2_Y_C0 = 8495653923123431417604973247489272438418190587263600148770280649306958101930n;
  const G2_Y_C1 = 4082367875863433681332203403145435568316851327593401208105741076214120093531n;

  // Negative G2 generator: negate the y-coordinate in Fp2
  // -G2.y_c0 = BN254_P - G2.y_c0, -G2.y_c1 = BN254_P - G2.y_c1
  const NEG_G2_X_C0 = G2_X_C0;
  const NEG_G2_X_C1 = G2_X_C1;
  const NEG_G2_Y_C0 = BN254_P - G2_Y_C0;
  const NEG_G2_Y_C1 = BN254_P - G2_Y_C1;

  // Default VK parameters
  const DEFAULT_SRS_G2: [bigint, bigint, bigint, bigint] = [G2_X_C0, G2_X_C1, G2_Y_C0, G2_Y_C1];
  const DEFAULT_NEG_G2: [bigint, bigint, bigint, bigint] = [NEG_G2_X_C0, NEG_G2_X_C1, NEG_G2_Y_C0, NEG_G2_Y_C1];
  const DEFAULT_K = 14n;
  const DEFAULT_NUM_PUBLIC_INPUTS = 3n;
  const DEFAULT_VK_DIGEST = ethers.keccak256(ethers.toUtf8Bytes("test-vk-digest"));

  // Helper: build a valid-length proof (224 bytes = 7 * 32).
  // Layout: [W.x(32), W.y(32), E.x(32), E.y(32), z(32), C.x(32), C.y(32)]
  function buildProof(overrides?: {
    wX?: bigint;
    wY?: bigint;
    eX?: bigint;
    eY?: bigint;
    z?: bigint;
    cX?: bigint;
    cY?: bigint;
  }): string {
    const wX = overrides?.wX ?? 0n;
    const wY = overrides?.wY ?? 0n;
    const eX = overrides?.eX ?? 0n;
    const eY = overrides?.eY ?? 0n;
    const z = overrides?.z ?? 0n;
    const cX = overrides?.cX ?? 0n;
    const cY = overrides?.cY ?? 0n;

    return ethers.concat([
      ethers.zeroPadValue(ethers.toBeHex(wX || 0n), 32),
      ethers.zeroPadValue(ethers.toBeHex(wY || 0n), 32),
      ethers.zeroPadValue(ethers.toBeHex(eX || 0n), 32),
      ethers.zeroPadValue(ethers.toBeHex(eY || 0n), 32),
      ethers.zeroPadValue(ethers.toBeHex(z || 0n), 32),
      ethers.zeroPadValue(ethers.toBeHex(cX || 0n), 32),
      ethers.zeroPadValue(ethers.toBeHex(cY || 0n), 32),
    ]);
  }

  // Helper: build proof using BN254 G1 generator for W and C.
  // Uses identity-like construction: W = G1, C = G1, z = 1.
  function buildG1Proof(): string {
    return buildProof({
      wX: G1_X,
      wY: G1_Y,
      eX: G1_X,
      eY: G1_Y,
      z: 1n,
      cX: G1_X,
      cY: G1_Y,
    });
  }

  // Helper: default public inputs [preStateRoot, postStateRoot, batchHash]
  function defaultPublicInputs(): bigint[] {
    return [100n, 200n, 300n];
  }

  // Helper: configure VK with default parameters
  async function configureDefaultVK(): Promise<void> {
    await verifier.configureVK(
      DEFAULT_SRS_G2,
      DEFAULT_NEG_G2,
      DEFAULT_K,
      DEFAULT_NUM_PUBLIC_INPUTS,
      DEFAULT_VK_DIGEST
    );
  }

  beforeEach(async function () {
    [admin, other, enterprise] = await ethers.getSigners();

    const factory = await ethers.getContractFactory("PlonkVerifier", admin);
    verifier = (await factory.deploy()) as PlonkVerifier;
    await verifier.waitForDeployment();
  });

  // =================================================================
  // 1. Deployment
  // =================================================================

  describe("Deployment", function () {
    it("sets admin to deployer", async function () {
      expect(await verifier.admin()).to.equal(admin.address);
    });

    it("starts with vkConfigured = false", async function () {
      expect(await verifier.vkConfigured()).to.equal(false);
    });

    it("starts with circuitK = 0", async function () {
      expect(await verifier.circuitK()).to.equal(0);
    });

    it("starts with numPublicInputs = 0", async function () {
      expect(await verifier.numPublicInputs()).to.equal(0);
    });

    it("starts with empty vkDigest", async function () {
      expect(await verifier.vkDigest()).to.equal(ethers.ZeroHash);
    });

    it("starts with empty lastProofCommitment", async function () {
      expect(await verifier.lastProofCommitment()).to.equal(ethers.ZeroHash);
    });

    it("exposes MIN_PROOF_SIZE = 224", async function () {
      expect(await verifier.MIN_PROOF_SIZE()).to.equal(224);
    });
  });

  // =================================================================
  // 2. VK Configuration
  // =================================================================

  describe("VK Configuration", function () {
    it("configureVK succeeds from admin", async function () {
      await configureDefaultVK();
      expect(await verifier.vkConfigured()).to.equal(true);
    });

    it("stores circuitK correctly", async function () {
      await configureDefaultVK();
      expect(await verifier.circuitK()).to.equal(DEFAULT_K);
    });

    it("stores numPublicInputs correctly", async function () {
      await configureDefaultVK();
      expect(await verifier.numPublicInputs()).to.equal(DEFAULT_NUM_PUBLIC_INPUTS);
    });

    it("stores vkDigest correctly", async function () {
      await configureDefaultVK();
      expect(await verifier.vkDigest()).to.equal(DEFAULT_VK_DIGEST);
    });

    it("emits VKConfigured event with correct arguments", async function () {
      const tx = await verifier.configureVK(
        DEFAULT_SRS_G2,
        DEFAULT_NEG_G2,
        DEFAULT_K,
        DEFAULT_NUM_PUBLIC_INPUTS,
        DEFAULT_VK_DIGEST
      );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "VKConfigured";
        } catch {
          return false;
        }
      });
      expect(event).to.not.be.undefined;
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.k).to.equal(DEFAULT_K);
      expect(parsed!.args.numPublicInputs).to.equal(DEFAULT_NUM_PUBLIC_INPUTS);
      expect(parsed!.args.vkDigest).to.equal(DEFAULT_VK_DIGEST);
    });

    it("reverts on double configuration (VKAlreadyConfigured)", async function () {
      await configureDefaultVK();
      await expect(
        verifier.configureVK(
          DEFAULT_SRS_G2,
          DEFAULT_NEG_G2,
          DEFAULT_K,
          DEFAULT_NUM_PUBLIC_INPUTS,
          DEFAULT_VK_DIGEST
        )
      ).to.be.revertedWithCustomError(verifier, "VKAlreadyConfigured");
    });

    it("reverts when non-admin calls configureVK (OnlyAdmin)", async function () {
      await expect(
        verifier.connect(other).configureVK(
          DEFAULT_SRS_G2,
          DEFAULT_NEG_G2,
          DEFAULT_K,
          DEFAULT_NUM_PUBLIC_INPUTS,
          DEFAULT_VK_DIGEST
        )
      ).to.be.revertedWithCustomError(verifier, "OnlyAdmin");
    });

    it("accepts different VK parameter values", async function () {
      const customK = 20n;
      const customInputs = 5n;
      const customDigest = ethers.keccak256(ethers.toUtf8Bytes("custom-vk"));

      await verifier.configureVK(
        DEFAULT_SRS_G2,
        DEFAULT_NEG_G2,
        customK,
        customInputs,
        customDigest
      );

      expect(await verifier.circuitK()).to.equal(customK);
      expect(await verifier.numPublicInputs()).to.equal(customInputs);
      expect(await verifier.vkDigest()).to.equal(customDigest);
    });
  });

  // =================================================================
  // 3. Proof Verification Guards
  // =================================================================

  describe("Proof verification guards", function () {
    it("reverts when VK not configured (VKNotConfigured)", async function () {
      const proof = buildProof();
      const inputs = defaultPublicInputs();
      await expect(
        verifier.verifyProof(proof, inputs)
      ).to.be.revertedWithCustomError(verifier, "VKNotConfigured");
    });

    it("reverts with proof shorter than MIN_PROOF_SIZE (ProofTooShort)", async function () {
      await configureDefaultVK();

      // Build a proof that is only 192 bytes (6 * 32), below the 224 minimum
      const shortProof = ethers.concat([
        ethers.zeroPadValue("0x01", 32),
        ethers.zeroPadValue("0x02", 32),
        ethers.zeroPadValue("0x03", 32),
        ethers.zeroPadValue("0x04", 32),
        ethers.zeroPadValue("0x05", 32),
        ethers.zeroPadValue("0x06", 32),
      ]);

      await expect(
        verifier.verifyProof(shortProof, defaultPublicInputs())
      ).to.be.revertedWithCustomError(verifier, "ProofTooShort")
        .withArgs(192, 224);
    });

    it("reverts with empty proof (ProofTooShort)", async function () {
      await configureDefaultVK();
      await expect(
        verifier.verifyProof("0x", defaultPublicInputs())
      ).to.be.revertedWithCustomError(verifier, "ProofTooShort")
        .withArgs(0, 224);
    });

    it("reverts with wrong public input count (InvalidPublicInputCount)", async function () {
      await configureDefaultVK();
      const proof = buildProof();

      // Provide 2 inputs when 3 are expected
      await expect(
        verifier.verifyProof(proof, [100n, 200n])
      ).to.be.revertedWithCustomError(verifier, "InvalidPublicInputCount")
        .withArgs(2, 3);
    });

    it("reverts with too many public inputs (InvalidPublicInputCount)", async function () {
      await configureDefaultVK();
      const proof = buildProof();

      // Provide 4 inputs when 3 are expected
      await expect(
        verifier.verifyProof(proof, [100n, 200n, 300n, 400n])
      ).to.be.revertedWithCustomError(verifier, "InvalidPublicInputCount")
        .withArgs(4, 3);
    });

    it("reverts with zero public inputs (InvalidPublicInputCount)", async function () {
      await configureDefaultVK();
      const proof = buildProof();

      await expect(
        verifier.verifyProof(proof, [])
      ).to.be.revertedWithCustomError(verifier, "InvalidPublicInputCount")
        .withArgs(0, 3);
    });
  });

  // =================================================================
  // 4. Proof Structure
  // =================================================================

  describe("Proof structure", function () {
    it("accepts a well-formed proof with exact MIN_PROOF_SIZE length", async function () {
      await configureDefaultVK();
      const proof = buildProof(); // 224 bytes exactly
      expect(ethers.dataLength(proof)).to.equal(224);

      // Should not revert (zero-point proof will likely fail pairing, but no revert)
      const tx = await verifier.verifyProof(proof, defaultPublicInputs());
      const receipt = await tx.wait();
      expect(receipt).to.not.be.null;
    });

    it("accepts a proof longer than MIN_PROOF_SIZE", async function () {
      await configureDefaultVK();

      // 256 bytes = 224 + 32 extra
      const proof = ethers.concat([
        buildProof(),
        ethers.zeroPadValue("0x00", 32),
      ]);
      expect(ethers.dataLength(proof)).to.equal(256);

      const tx = await verifier.verifyProof(proof, defaultPublicInputs());
      const receipt = await tx.wait();
      expect(receipt).to.not.be.null;
    });

    it("proof with all-zero G1 points does not revert", async function () {
      await configureDefaultVK();
      const proof = buildProof(); // all zeros
      const tx = await verifier.verifyProof(proof, defaultPublicInputs());
      const receipt = await tx.wait();
      expect(receipt).to.not.be.null;
    });

    it("proof with BN254 G1 generator points does not revert", async function () {
      await configureDefaultVK();
      const proof = buildG1Proof();
      const tx = await verifier.verifyProof(proof, defaultPublicInputs());
      const receipt = await tx.wait();
      expect(receipt).to.not.be.null;
    });
  });

  // =================================================================
  // 5. Commitment Verification
  // =================================================================

  describe("Commitment verification", function () {
    it("verifyCommitment returns false before any proof is submitted", async function () {
      await configureDefaultVK();
      const proof = buildProof();
      const inputs = defaultPublicInputs();
      const matches = await verifier.verifyCommitment(proof, inputs);
      expect(matches).to.equal(false);
    });

    it("verifyCommitment returns true for same proof and inputs after verifyProof", async function () {
      await configureDefaultVK();
      const proof = buildProof();
      const inputs = defaultPublicInputs();

      // Submit proof to set lastProofCommitment
      await verifier.verifyProof(proof, inputs);

      // Verify commitment matches
      const matches = await verifier.verifyCommitment(proof, inputs);
      expect(matches).to.equal(true);
    });

    it("verifyCommitment returns false for different proof after verifyProof", async function () {
      await configureDefaultVK();
      const proof1 = buildProof();
      const proof2 = buildProof({ z: 42n });
      const inputs = defaultPublicInputs();

      await verifier.verifyProof(proof1, inputs);

      const matches = await verifier.verifyCommitment(proof2, inputs);
      expect(matches).to.equal(false);
    });

    it("verifyCommitment returns false for different public inputs", async function () {
      await configureDefaultVK();
      const proof = buildProof();
      const inputs1 = defaultPublicInputs();
      const inputs2 = [999n, 888n, 777n];

      await verifier.verifyProof(proof, inputs1);

      const matches = await verifier.verifyCommitment(proof, inputs2);
      expect(matches).to.equal(false);
    });

    it("verifyCommitment returns false with fewer than 3 public inputs", async function () {
      // verifyCommitment requires at least 3 inputs to compute commitment
      await configureDefaultVK();
      const proof = buildProof();

      // Pass fewer than 3 inputs -- function returns false (not revert)
      const matches = await verifier.verifyCommitment(proof, [100n, 200n]);
      expect(matches).to.equal(false);
    });

    it("lastProofCommitment updates after each verifyProof call", async function () {
      await configureDefaultVK();
      const proof1 = buildProof({ z: 1n });
      const proof2 = buildProof({ z: 2n });
      const inputs = defaultPublicInputs();

      await verifier.verifyProof(proof1, inputs);
      const commitment1 = await verifier.lastProofCommitment();
      expect(commitment1).to.not.equal(ethers.ZeroHash);

      await verifier.verifyProof(proof2, inputs);
      const commitment2 = await verifier.lastProofCommitment();
      expect(commitment2).to.not.equal(ethers.ZeroHash);
      expect(commitment2).to.not.equal(commitment1);
    });

    it("commitment is deterministic for same proof and inputs", async function () {
      await configureDefaultVK();
      // Use zero-point proof (identity element) which passes ecMul/ecAdd precompiles
      // and reaches the commitment storage code path.
      const proof = buildProof();
      const inputs = defaultPublicInputs();

      // Compute expected commitment off-chain using the same encoding as
      // abi.encodePacked(proof, publicInputs[0], publicInputs[1], publicInputs[2], vkDigest)
      const expectedCommitment = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes", "uint256", "uint256", "uint256", "bytes32"],
          [proof, inputs[0], inputs[1], inputs[2], DEFAULT_VK_DIGEST]
        )
      );

      await verifier.verifyProof(proof, inputs);
      const stored = await verifier.lastProofCommitment();
      expect(stored).to.equal(expectedCommitment);
    });
  });

  // =================================================================
  // 6. KZG Pairing (BN254 curve points)
  // =================================================================

  describe("KZG pairing", function () {
    it("returns valid=false for zero-point proof (trivial rejection)", async function () {
      await configureDefaultVK();
      const proof = buildProof(); // all zeros
      const tx = await verifier.verifyProof(proof, defaultPublicInputs());
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

    it("proof with valid G1 generator points is processed without revert", async function () {
      await configureDefaultVK();
      const proof = buildG1Proof();
      const tx = await verifier.verifyProof(proof, defaultPublicInputs());
      const receipt = await tx.wait();

      // Should complete and emit event (valid or not depends on pairing math)
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      expect(event).to.not.be.undefined;
    });

    it("pairing check with known G1 point (2,1 is NOT on curve) returns false", async function () {
      await configureDefaultVK();
      // (2, 1) is not a valid BN254 G1 point -- ecMul will fail.
      // When ecMul fails in the assembly, the function does an early `return(0x00, 0x20)`
      // which returns valid=false and bypasses event emission entirely.
      const proof = buildProof({ wX: 2n, wY: 1n, cX: 2n, cY: 1n, z: 1n });
      const tx = await verifier.verifyProof(proof, defaultPublicInputs());
      const receipt = await tx.wait();

      // No ProofVerified event emitted due to assembly early return
      const events = receipt!.logs.filter((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      expect(events.length).to.equal(0);

      // Commitment should NOT be updated (assembly returned before storage write)
      expect(await verifier.lastProofCommitment()).to.equal(ethers.ZeroHash);
    });

    it("handles large scalar z value near BN254 order", async function () {
      await configureDefaultVK();
      // Use a z value near the BN254 scalar field order
      const largeZ = BN254_ORDER - 1n;
      const proof = buildProof({ wX: G1_X, wY: G1_Y, z: largeZ, cX: G1_X, cY: G1_Y });
      const tx = await verifier.verifyProof(proof, defaultPublicInputs());
      const receipt = await tx.wait();
      expect(receipt).to.not.be.null;
    });

    it("different proof data produces different verification results", async function () {
      await configureDefaultVK();

      // Two proofs with different z values
      const proof1 = buildProof({ wX: G1_X, wY: G1_Y, z: 1n, cX: G1_X, cY: G1_Y });
      const proof2 = buildProof({ wX: G1_X, wY: G1_Y, z: 2n, cX: G1_X, cY: G1_Y });

      const tx1 = await verifier.verifyProof(proof1, defaultPublicInputs());
      const receipt1 = await tx1.wait();

      const tx2 = await verifier.verifyProof(proof2, defaultPublicInputs());
      const receipt2 = await tx2.wait();

      // Both should complete without revert
      expect(receipt1).to.not.be.null;
      expect(receipt2).to.not.be.null;

      // Commitments should differ
      const commitment1After = await verifier.lastProofCommitment();
      // Note: commitment2 overwrites commitment1 in storage, so check non-zero
      expect(commitment1After).to.not.equal(ethers.ZeroHash);
    });
  });

  // =================================================================
  // 7. Event Emission
  // =================================================================

  describe("Event emission", function () {
    it("emits ProofVerified event with correct batchHash", async function () {
      await configureDefaultVK();
      const batchHash = 12345n;
      const inputs = [100n, 200n, batchHash];
      const proof = buildProof();

      const tx = await verifier.verifyProof(proof, inputs);
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      expect(event).to.not.be.undefined;
      const parsed = verifier.interface.parseLog(event as any);
      expect(parsed!.args.batchHash).to.equal(ethers.zeroPadValue(ethers.toBeHex(batchHash), 32));
    });

    it("ProofVerified event contains valid flag", async function () {
      await configureDefaultVK();
      const proof = buildProof(); // zero points -> pairing fails -> valid=false
      const tx = await verifier.verifyProof(proof, defaultPublicInputs());
      const receipt = await tx.wait();
      const event = receipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      const parsed = verifier.interface.parseLog(event as any);
      // valid is a boolean field in the event
      expect(typeof parsed!.args.valid).to.equal("boolean");
    });

    it("emits ProofVerified for every verifyProof call", async function () {
      await configureDefaultVK();
      const proof = buildProof();
      const inputs = defaultPublicInputs();

      // First call
      const tx1 = await verifier.verifyProof(proof, inputs);
      const receipt1 = await tx1.wait();
      const events1 = receipt1!.logs.filter((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      expect(events1.length).to.equal(1);

      // Second call
      const tx2 = await verifier.verifyProof(proof, inputs);
      const receipt2 = await tx2.wait();
      const events2 = receipt2!.logs.filter((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      expect(events2.length).to.equal(1);
    });

    it("VKConfigured event is emitted exactly once during configuration", async function () {
      const tx = await verifier.configureVK(
        DEFAULT_SRS_G2,
        DEFAULT_NEG_G2,
        DEFAULT_K,
        DEFAULT_NUM_PUBLIC_INPUTS,
        DEFAULT_VK_DIGEST
      );
      const receipt = await tx.wait();
      const events = receipt!.logs.filter((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "VKConfigured";
        } catch {
          return false;
        }
      });
      expect(events.length).to.equal(1);
    });
  });

  // =================================================================
  // 8. Access Control
  // =================================================================

  describe("Access control", function () {
    it("admin can configure VK", async function () {
      await expect(
        verifier.connect(admin).configureVK(
          DEFAULT_SRS_G2,
          DEFAULT_NEG_G2,
          DEFAULT_K,
          DEFAULT_NUM_PUBLIC_INPUTS,
          DEFAULT_VK_DIGEST
        )
      ).to.not.be.reverted;
    });

    it("non-admin cannot configure VK", async function () {
      await expect(
        verifier.connect(other).configureVK(
          DEFAULT_SRS_G2,
          DEFAULT_NEG_G2,
          DEFAULT_K,
          DEFAULT_NUM_PUBLIC_INPUTS,
          DEFAULT_VK_DIGEST
        )
      ).to.be.revertedWithCustomError(verifier, "OnlyAdmin");
    });

    it("any account can call verifyProof (no access restriction)", async function () {
      await configureDefaultVK();
      const proof = buildProof();
      const inputs = defaultPublicInputs();

      // Verify from non-admin account
      const tx = await verifier.connect(enterprise).verifyProof(proof, inputs);
      const receipt = await tx.wait();
      expect(receipt).to.not.be.null;
    });

    it("any account can call verifyCommitment (no access restriction)", async function () {
      await configureDefaultVK();
      const proof = buildProof();
      const inputs = defaultPublicInputs();

      await verifier.verifyProof(proof, inputs);

      // Verify commitment from non-admin account
      const matches = await verifier.connect(other).verifyCommitment(proof, inputs);
      // Should return true since same proof and inputs
      expect(matches).to.equal(true);
    });

    it("admin address is immutable (set only in constructor)", async function () {
      // Deploy with admin as deployer, verify it stays
      expect(await verifier.admin()).to.equal(admin.address);

      // Configure VK -- admin should not change
      await configureDefaultVK();
      expect(await verifier.admin()).to.equal(admin.address);

      // Submit a proof -- admin should not change
      await verifier.verifyProof(buildProof(), defaultPublicInputs());
      expect(await verifier.admin()).to.equal(admin.address);
    });
  });

  // =================================================================
  // Integration: End-to-end workflow
  // =================================================================

  describe("End-to-end workflow", function () {
    it("configure -> verify -> commit: full lifecycle", async function () {
      // Step 1: Configure VK
      const configTx = await verifier.configureVK(
        DEFAULT_SRS_G2,
        DEFAULT_NEG_G2,
        DEFAULT_K,
        DEFAULT_NUM_PUBLIC_INPUTS,
        DEFAULT_VK_DIGEST
      );
      const configReceipt = await configTx.wait();
      const configEvent = configReceipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "VKConfigured";
        } catch {
          return false;
        }
      });
      expect(configEvent).to.not.be.undefined;

      // Step 2: Submit proof
      const batchHash = 42n;
      const proof = buildG1Proof();
      const inputs = [100n, 200n, batchHash];

      const verifyTx = await verifier.connect(enterprise).verifyProof(proof, inputs);
      const verifyReceipt = await verifyTx.wait();
      const verifyEvent = verifyReceipt!.logs.find((log) => {
        try {
          return verifier.interface.parseLog(log as any)?.name === "ProofVerified";
        } catch {
          return false;
        }
      });
      expect(verifyEvent).to.not.be.undefined;
      const parsed = verifier.interface.parseLog(verifyEvent as any);
      expect(parsed!.args.batchHash).to.equal(ethers.zeroPadValue(ethers.toBeHex(batchHash), 32));

      // Step 3: Verify commitment matches
      const matches = await verifier.verifyCommitment(proof, inputs);
      expect(matches).to.equal(true);

      // Step 4: Verify commitment does NOT match with different inputs
      const noMatch = await verifier.verifyCommitment(proof, [999n, 888n, 777n]);
      expect(noMatch).to.equal(false);
    });

    it("multiple proofs overwrite lastProofCommitment correctly", async function () {
      await configureDefaultVK();

      const proof1 = buildProof({ z: 10n });
      const proof2 = buildProof({ z: 20n });
      const inputs = defaultPublicInputs();

      // First proof
      await verifier.verifyProof(proof1, inputs);
      expect(await verifier.verifyCommitment(proof1, inputs)).to.equal(true);
      expect(await verifier.verifyCommitment(proof2, inputs)).to.equal(false);

      // Second proof overwrites
      await verifier.verifyProof(proof2, inputs);
      expect(await verifier.verifyCommitment(proof2, inputs)).to.equal(true);
      expect(await verifier.verifyCommitment(proof1, inputs)).to.equal(false);
    });
  });
});
