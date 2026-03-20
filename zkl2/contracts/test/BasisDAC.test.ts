/// BasisDAC test suite -- Data Availability Committee on-chain verification.
///
/// Maps TLA+ invariants from ProductionDAC.tla to concrete Hardhat tests:
/// - CertificateSoundness: valid cert requires >= threshold attestations
/// - AttestationIntegrity: only registered committee members can attest
/// - No duplicate signers (bitmap check)
/// - AnyTrust fallback: certState transitions
///
/// [Spec: zkl2/specs/units/2026-03-production-dac/ProductionDAC.tla]

import { expect } from "chai";
import { ethers } from "hardhat";
import { BasisDAC } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

/// Signs an attestation digest using raw ECDSA (no EIP-191 prefix).
/// The contract computes: keccak256(abi.encodePacked(batchId, dataHash))
/// and recovers via ecrecover(digest, v, r, s).
function signAttestation(
  wallet: ethers.Wallet,
  batchId: bigint,
  dataHash: string
): string {
  const digest = ethers.solidityPackedKeccak256(
    ["uint64", "bytes32"],
    [batchId, dataHash]
  );
  const sig = wallet.signingKey.sign(digest);
  return ethers.concat([sig.r, sig.s, ethers.toBeHex(sig.v, 1)]);
}

describe("BasisDAC", function () {
  let dac: BasisDAC;
  let admin: HardhatEthersSigner;
  let outsider: HardhatEthersSigner;

  // Committee members as Wallets (private keys needed for ECDSA signing).
  let member1: ethers.Wallet;
  let member2: ethers.Wallet;
  let member3: ethers.Wallet;
  let nonMember: ethers.Wallet;

  const THRESHOLD = 2;
  const BATCH_ID = 1n;
  const DATA_HASH = ethers.keccak256(ethers.toUtf8Bytes("batch-data-001"));

  // Deterministic private keys for reproducible tests.
  const KEYS = [
    "0x0000000000000000000000000000000000000000000000000000000000000001",
    "0x0000000000000000000000000000000000000000000000000000000000000002",
    "0x0000000000000000000000000000000000000000000000000000000000000003",
    "0x0000000000000000000000000000000000000000000000000000000000000004",
  ];

  beforeEach(async function () {
    [admin, outsider] = await ethers.getSigners();

    member1 = new ethers.Wallet(KEYS[0]);
    member2 = new ethers.Wallet(KEYS[1]);
    member3 = new ethers.Wallet(KEYS[2]);
    nonMember = new ethers.Wallet(KEYS[3]);

    const Factory = await ethers.getContractFactory("BasisDAC", admin);
    dac = await Factory.deploy(THRESHOLD, [
      member1.address,
      member2.address,
      member3.address,
    ]);
    await dac.waitForDeployment();
  });

  // =================================================================
  // Deployment
  // =================================================================

  describe("Deployment", function () {
    it("sets admin to deployer", async function () {
      expect(await dac.admin()).to.equal(admin.address);
    });

    it("sets threshold correctly", async function () {
      expect(await dac.threshold()).to.equal(THRESHOLD);
    });

    it("registers initial members", async function () {
      expect(await dac.isMember(member1.address)).to.equal(true);
      expect(await dac.isMember(member2.address)).to.equal(true);
      expect(await dac.isMember(member3.address)).to.equal(true);
      expect(await dac.committeeSize()).to.equal(3);
    });

    it("assigns correct member indices", async function () {
      expect(await dac.memberIndex(member1.address)).to.equal(0);
      expect(await dac.memberIndex(member2.address)).to.equal(1);
      expect(await dac.memberIndex(member3.address)).to.equal(2);
    });

    it("emits MemberAdded for each initial member", async function () {
      const Factory = await ethers.getContractFactory("BasisDAC", admin);
      const tx = await Factory.deploy(THRESHOLD, [
        member1.address,
        member2.address,
      ]);
      const receipt = await tx.deploymentTransaction()!.wait();

      const events = receipt!.logs
        .map((log) => {
          try {
            return tx.interface.parseLog(log as any);
          } catch {
            return null;
          }
        })
        .filter((e) => e?.name === "MemberAdded");

      expect(events.length).to.equal(2);
      expect(events[0]!.args.member).to.equal(member1.address);
      expect(events[0]!.args.index).to.equal(0);
      expect(events[1]!.args.member).to.equal(member2.address);
      expect(events[1]!.args.index).to.equal(1);
    });

    it("reverts if members exceed MAX_COMMITTEE_SIZE", async function () {
      const wallets: string[] = [];
      for (let i = 1; i <= 8; i++) {
        wallets.push(new ethers.Wallet(ethers.toBeHex(i + 100, 32)).address);
      }
      const Factory = await ethers.getContractFactory("BasisDAC", admin);
      await expect(Factory.deploy(1, wallets)).to.be.revertedWithCustomError(
        dac,
        "CommitteeFull"
      );
    });

    it("reverts if threshold is 0", async function () {
      const Factory = await ethers.getContractFactory("BasisDAC", admin);
      await expect(
        Factory.deploy(0, [member1.address])
      ).to.be.revertedWithCustomError(dac, "InvalidThreshold");
    });

    it("reverts if threshold exceeds member count", async function () {
      const Factory = await ethers.getContractFactory("BasisDAC", admin);
      await expect(
        Factory.deploy(3, [member1.address, member2.address])
      ).to.be.revertedWithCustomError(dac, "InvalidThreshold");
    });

    it("reverts if duplicate members in constructor", async function () {
      const Factory = await ethers.getContractFactory("BasisDAC", admin);
      await expect(
        Factory.deploy(1, [member1.address, member1.address])
      ).to.be.revertedWithCustomError(dac, "MemberAlreadyRegistered");
    });
  });

  // =================================================================
  // Committee Management -- addMember
  // =================================================================

  describe("addMember", function () {
    it("adds a new member", async function () {
      const newMember = nonMember.address;
      await dac.addMember(newMember);

      expect(await dac.isMember(newMember)).to.equal(true);
      expect(await dac.committeeSize()).to.equal(4);
      expect(await dac.memberIndex(newMember)).to.equal(3);
    });

    it("emits MemberAdded event", async function () {
      await expect(dac.addMember(nonMember.address))
        .to.emit(dac, "MemberAdded")
        .withArgs(nonMember.address, 3);
    });

    it("reverts if committee is full (MAX_COMMITTEE_SIZE=7)", async function () {
      // Add 4 more to reach 7 total (3 initial + 4 new).
      for (let i = 0; i < 4; i++) {
        const addr = new ethers.Wallet(ethers.toBeHex(i + 200, 32)).address;
        await dac.addMember(addr);
      }
      expect(await dac.committeeSize()).to.equal(7);

      const extra = new ethers.Wallet(ethers.toBeHex(300, 32)).address;
      await expect(dac.addMember(extra)).to.be.revertedWithCustomError(
        dac,
        "CommitteeFull"
      );
    });

    it("reverts if member already registered", async function () {
      await expect(
        dac.addMember(member1.address)
      ).to.be.revertedWithCustomError(dac, "MemberAlreadyRegistered");
    });

    it("reverts if caller is not admin", async function () {
      await expect(
        dac.connect(outsider).addMember(nonMember.address)
      ).to.be.revertedWithCustomError(dac, "NotAdmin");
    });
  });

  // =================================================================
  // Committee Management -- removeMember
  // =================================================================

  describe("removeMember", function () {
    it("removes a member (swap-and-pop)", async function () {
      // Remove member1 (index 0). member3 (last) should take index 0.
      await dac.removeMember(member1.address);

      expect(await dac.isMember(member1.address)).to.equal(false);
      expect(await dac.committeeSize()).to.equal(2);
      // member3 swapped into index 0
      expect(await dac.memberIndex(member3.address)).to.equal(0);
    });

    it("emits MemberRemoved event", async function () {
      await expect(dac.removeMember(member1.address))
        .to.emit(dac, "MemberRemoved")
        .withArgs(member1.address, 0);
    });

    it("reverts if member not registered", async function () {
      await expect(
        dac.removeMember(nonMember.address)
      ).to.be.revertedWithCustomError(dac, "MemberNotRegistered");
    });

    it("reverts if removal would violate threshold", async function () {
      // 3 members, threshold=2. Removing one leaves 2 == threshold, OK.
      await dac.removeMember(member3.address);
      expect(await dac.committeeSize()).to.equal(2);

      // Now 2 members, threshold=2. Removing another would leave 1 < threshold.
      await expect(
        dac.removeMember(member2.address)
      ).to.be.revertedWithCustomError(dac, "InvalidThreshold");
    });

    it("reverts if caller is not admin", async function () {
      await expect(
        dac.connect(outsider).removeMember(member1.address)
      ).to.be.revertedWithCustomError(dac, "NotAdmin");
    });
  });

  // =================================================================
  // Committee Management -- setThreshold
  // =================================================================

  describe("setThreshold", function () {
    it("updates threshold", async function () {
      await dac.setThreshold(3);
      expect(await dac.threshold()).to.equal(3);
    });

    it("emits ThresholdUpdated event", async function () {
      await expect(dac.setThreshold(3))
        .to.emit(dac, "ThresholdUpdated")
        .withArgs(THRESHOLD, 3);
    });

    it("reverts if threshold is 0", async function () {
      await expect(dac.setThreshold(0)).to.be.revertedWithCustomError(
        dac,
        "InvalidThreshold"
      );
    });

    it("reverts if threshold exceeds committee size", async function () {
      await expect(dac.setThreshold(4)).to.be.revertedWithCustomError(
        dac,
        "InvalidThreshold"
      );
    });

    it("reverts if caller is not admin", async function () {
      await expect(
        dac.connect(outsider).setThreshold(1)
      ).to.be.revertedWithCustomError(dac, "NotAdmin");
    });
  });

  // =================================================================
  // Committee Management -- transferAdmin
  // =================================================================

  describe("transferAdmin", function () {
    it("transfers admin role", async function () {
      await dac.transferAdmin(outsider.address);
      expect(await dac.admin()).to.equal(outsider.address);
    });

    it("new admin can manage committee", async function () {
      await dac.transferAdmin(outsider.address);
      // Old admin should fail.
      await expect(
        dac.addMember(nonMember.address)
      ).to.be.revertedWithCustomError(dac, "NotAdmin");
      // New admin should succeed.
      await dac.connect(outsider).addMember(nonMember.address);
      expect(await dac.isMember(nonMember.address)).to.equal(true);
    });

    it("reverts if caller is not admin", async function () {
      await expect(
        dac.connect(outsider).transferAdmin(outsider.address)
      ).to.be.revertedWithCustomError(dac, "NotAdmin");
    });
  });

  // =================================================================
  // CertificateSoundness: Certificate Submission (valid paths)
  // =================================================================

  describe("Certificate submission (valid)", function () {
    it("accepts certificate with exactly threshold signatures", async function () {
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);

      await dac.submitCertificate(
        BATCH_ID,
        DATA_HASH,
        [sig1, sig2],
        [member1.address, member2.address]
      );

      expect(await dac.certState(BATCH_ID)).to.equal(1);
      expect(await dac.certDataHash(BATCH_ID)).to.equal(DATA_HASH);
      expect(await dac.certSignerCount(BATCH_ID)).to.equal(2);
    });

    it("accepts certificate with more than threshold signatures", async function () {
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);
      const sig3 = signAttestation(member3, BATCH_ID, DATA_HASH);

      await dac.submitCertificate(
        BATCH_ID,
        DATA_HASH,
        [sig1, sig2, sig3],
        [member1.address, member2.address, member3.address]
      );

      expect(await dac.certSignerCount(BATCH_ID)).to.equal(3);
    });

    it("stores correct signer bitmap", async function () {
      // member1 at index 0 -> bit 0, member3 at index 2 -> bit 2
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig3 = signAttestation(member3, BATCH_ID, DATA_HASH);

      await dac.submitCertificate(
        BATCH_ID,
        DATA_HASH,
        [sig1, sig3],
        [member1.address, member3.address]
      );

      const bitmap = await dac.certSignerBitmap(BATCH_ID);
      // bit 0 (member1) + bit 2 (member3) = 0b00000101 = 5
      expect(bitmap).to.equal(5);
    });

    it("emits CertificateSubmitted event", async function () {
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);

      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig2],
          [member1.address, member2.address]
        )
      )
        .to.emit(dac, "CertificateSubmitted")
        .withArgs(BATCH_ID, DATA_HASH, 3, 2); // bitmap: bit0 + bit1 = 3
    });

    it("allows anyone to submit (not restricted to admin)", async function () {
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);

      await dac
        .connect(outsider)
        .submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig2],
          [member1.address, member2.address]
        );

      expect(await dac.certState(BATCH_ID)).to.equal(1);
    });

    it("handles multiple batches independently", async function () {
      const batchId2 = 2n;
      const dataHash2 = ethers.keccak256(ethers.toUtf8Bytes("batch-data-002"));

      const sig1a = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig2a = signAttestation(member2, BATCH_ID, DATA_HASH);
      await dac.submitCertificate(
        BATCH_ID,
        DATA_HASH,
        [sig1a, sig2a],
        [member1.address, member2.address]
      );

      const sig1b = signAttestation(member1, batchId2, dataHash2);
      const sig2b = signAttestation(member2, batchId2, dataHash2);
      await dac.submitCertificate(
        batchId2,
        dataHash2,
        [sig1b, sig2b],
        [member1.address, member2.address]
      );

      expect(await dac.certState(BATCH_ID)).to.equal(1);
      expect(await dac.certState(batchId2)).to.equal(1);
      expect(await dac.certDataHash(BATCH_ID)).to.equal(DATA_HASH);
      expect(await dac.certDataHash(batchId2)).to.equal(dataHash2);
    });
  });

  // =================================================================
  // CertificateSoundness: Certificate Submission (invalid paths)
  // =================================================================

  describe("Certificate submission (invalid)", function () {
    it("reverts if certificate already submitted for batch", async function () {
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);

      await dac.submitCertificate(
        BATCH_ID,
        DATA_HASH,
        [sig1, sig2],
        [member1.address, member2.address]
      );

      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig2],
          [member1.address, member2.address]
        )
      ).to.be.revertedWithCustomError(dac, "CertificateAlreadySubmitted");
    });

    it("reverts if insufficient signatures (below threshold)", async function () {
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);

      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1],
          [member1.address]
        )
      ).to.be.revertedWithCustomError(dac, "InsufficientAttestations");
    });

    it("reverts if signatures and signers arrays differ in length", async function () {
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);

      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig2],
          [member1.address] // one signer, two signatures
        )
      ).to.be.revertedWithCustomError(dac, "InsufficientAttestations");
    });

    it("reverts if signer is not a committee member (AttestationIntegrity)", async function () {
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sigNon = signAttestation(nonMember, BATCH_ID, DATA_HASH);

      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sigNon],
          [member1.address, nonMember.address]
        )
      ).to.be.revertedWithCustomError(dac, "SignerNotMember");
    });

    it("reverts if duplicate signer (bitmap check)", async function () {
      const sig1a = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig1b = signAttestation(member1, BATCH_ID, DATA_HASH);

      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1a, sig1b],
          [member1.address, member1.address]
        )
      ).to.be.revertedWithCustomError(dac, "DuplicateSigner");
    });

    it("reverts if signature length is not 65 bytes", async function () {
      const shortSig = ethers.hexlify(ethers.randomBytes(64)); // 64 bytes, not 65

      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [shortSig, shortSig],
          [member1.address, member2.address]
        )
      ).to.be.revertedWithCustomError(dac, "InvalidSignatureLength");
    });

    it("reverts if signature does not match claimed signer", async function () {
      // member1 signs, but we claim member2 signed it.
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);

      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig2],
          [member2.address, member1.address] // swapped: sig1 is member1's but claims member2
        )
      ).to.be.revertedWithCustomError(dac, "InvalidSignature");
    });

    it("reverts if signature is for wrong data hash", async function () {
      const wrongHash = ethers.keccak256(ethers.toUtf8Bytes("wrong-data"));
      const sig1 = signAttestation(member1, BATCH_ID, wrongHash);
      const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);

      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig2],
          [member1.address, member2.address]
        )
      ).to.be.revertedWithCustomError(dac, "InvalidSignature");
    });

    it("reverts if signature is for wrong batch ID", async function () {
      const sig1 = signAttestation(member1, 999n, DATA_HASH); // wrong batchId
      const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);

      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig2],
          [member1.address, member2.address]
        )
      ).to.be.revertedWithCustomError(dac, "InvalidSignature");
    });
  });

  // =================================================================
  // AnyTrust Fallback
  // =================================================================

  describe("AnyTrust fallback", function () {
    it("activates fallback for a batch", async function () {
      await dac.activateFallback(BATCH_ID, DATA_HASH);
      expect(await dac.certState(BATCH_ID)).to.equal(2);
      expect(await dac.fallbackDataHash(BATCH_ID)).to.equal(DATA_HASH);
    });

    it("emits FallbackActivated event", async function () {
      await expect(dac.activateFallback(BATCH_ID, DATA_HASH))
        .to.emit(dac, "FallbackActivated")
        .withArgs(BATCH_ID, DATA_HASH);
    });

    it("reverts if certificate already submitted for batch", async function () {
      // Submit a valid certificate first.
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);
      await dac.submitCertificate(
        BATCH_ID,
        DATA_HASH,
        [sig1, sig2],
        [member1.address, member2.address]
      );

      await expect(
        dac.activateFallback(BATCH_ID, DATA_HASH)
      ).to.be.revertedWithCustomError(dac, "CertificateAlreadySubmitted");
    });

    it("reverts if fallback already active for batch", async function () {
      await dac.activateFallback(BATCH_ID, DATA_HASH);

      await expect(
        dac.activateFallback(BATCH_ID, DATA_HASH)
      ).to.be.revertedWithCustomError(dac, "CertificateAlreadySubmitted");
    });

    it("reverts if caller is not admin", async function () {
      await expect(
        dac.connect(outsider).activateFallback(BATCH_ID, DATA_HASH)
      ).to.be.revertedWithCustomError(dac, "NotAdmin");
    });

    it("cannot submit certificate after fallback is active", async function () {
      await dac.activateFallback(BATCH_ID, DATA_HASH);

      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);

      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig2],
          [member1.address, member2.address]
        )
      ).to.be.revertedWithCustomError(dac, "CertificateAlreadySubmitted");
    });
  });

  // =================================================================
  // Query Functions
  // =================================================================

  describe("Query functions", function () {
    describe("isDataAvailable", function () {
      it("returns false for uncertified batch", async function () {
        expect(await dac.isDataAvailable(BATCH_ID)).to.equal(false);
      });

      it("returns true for valid certificate", async function () {
        const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
        const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);
        await dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig2],
          [member1.address, member2.address]
        );
        expect(await dac.isDataAvailable(BATCH_ID)).to.equal(true);
      });

      it("returns true for fallback", async function () {
        await dac.activateFallback(BATCH_ID, DATA_HASH);
        expect(await dac.isDataAvailable(BATCH_ID)).to.equal(true);
      });
    });

    describe("hasCertificate", function () {
      it("returns false for uncertified batch", async function () {
        expect(await dac.hasCertificate(BATCH_ID)).to.equal(false);
      });

      it("returns true for valid certificate", async function () {
        const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
        const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);
        await dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig2],
          [member1.address, member2.address]
        );
        expect(await dac.hasCertificate(BATCH_ID)).to.equal(true);
      });

      it("returns false for fallback batch", async function () {
        await dac.activateFallback(BATCH_ID, DATA_HASH);
        expect(await dac.hasCertificate(BATCH_ID)).to.equal(false);
      });
    });

    describe("isFallback", function () {
      it("returns false for uncertified batch", async function () {
        expect(await dac.isFallback(BATCH_ID)).to.equal(false);
      });

      it("returns false for valid certificate", async function () {
        const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
        const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);
        await dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig2],
          [member1.address, member2.address]
        );
        expect(await dac.isFallback(BATCH_ID)).to.equal(false);
      });

      it("returns true for fallback batch", async function () {
        await dac.activateFallback(BATCH_ID, DATA_HASH);
        expect(await dac.isFallback(BATCH_ID)).to.equal(true);
      });
    });

    describe("committeeSize", function () {
      it("returns correct size after deployment", async function () {
        expect(await dac.committeeSize()).to.equal(3);
      });

      it("increases after addMember", async function () {
        await dac.addMember(nonMember.address);
        expect(await dac.committeeSize()).to.equal(4);
      });

      it("decreases after removeMember", async function () {
        await dac.removeMember(member3.address);
        expect(await dac.committeeSize()).to.equal(2);
      });
    });

    describe("getCommittee", function () {
      it("returns all members", async function () {
        const committee = await dac.getCommittee();
        expect(committee.length).to.equal(3);
        expect(committee[0]).to.equal(member1.address);
        expect(committee[1]).to.equal(member2.address);
        expect(committee[2]).to.equal(member3.address);
      });

      it("reflects swap-and-pop after removal", async function () {
        await dac.removeMember(member1.address);
        const committee = await dac.getCommittee();
        expect(committee.length).to.equal(2);
        // member3 swapped into index 0
        expect(committee[0]).to.equal(member3.address);
        expect(committee[1]).to.equal(member2.address);
      });
    });
  });

  // =================================================================
  // Edge Cases and Invariant Combinations
  // =================================================================

  describe("Edge cases", function () {
    it("certificate submission after committee change still validates", async function () {
      // Remove member3, add nonMember.
      await dac.removeMember(member3.address);
      await dac.addMember(nonMember.address);

      // nonMember can now sign.
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sigNew = signAttestation(nonMember, BATCH_ID, DATA_HASH);

      await dac.submitCertificate(
        BATCH_ID,
        DATA_HASH,
        [sig1, sigNew],
        [member1.address, nonMember.address]
      );

      expect(await dac.certState(BATCH_ID)).to.equal(1);
    });

    it("removed member signatures are rejected", async function () {
      await dac.removeMember(member3.address);

      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig3 = signAttestation(member3, BATCH_ID, DATA_HASH);

      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig3],
          [member1.address, member3.address]
        )
      ).to.be.revertedWithCustomError(dac, "SignerNotMember");
    });

    it("threshold=1 allows single-signer certificate", async function () {
      await dac.setThreshold(1);
      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);

      await dac.submitCertificate(
        BATCH_ID,
        DATA_HASH,
        [sig1],
        [member1.address]
      );

      expect(await dac.certState(BATCH_ID)).to.equal(1);
    });

    it("threshold raised after deployment rejects previously-sufficient count", async function () {
      await dac.setThreshold(3);

      const sig1 = signAttestation(member1, BATCH_ID, DATA_HASH);
      const sig2 = signAttestation(member2, BATCH_ID, DATA_HASH);

      // 2 signatures < new threshold of 3
      await expect(
        dac.submitCertificate(
          BATCH_ID,
          DATA_HASH,
          [sig1, sig2],
          [member1.address, member2.address]
        )
      ).to.be.revertedWithCustomError(dac, "InsufficientAttestations");
    });

    it("zero-length signatures array reverts", async function () {
      await expect(
        dac.submitCertificate(BATCH_ID, DATA_HASH, [], [])
      ).to.be.revertedWithCustomError(dac, "InsufficientAttestations");
    });

    it("MAX_COMMITTEE_SIZE boundary: deploy with exactly 7 members", async function () {
      const wallets: ethers.Wallet[] = [];
      const addresses: string[] = [];
      for (let i = 0; i < 7; i++) {
        const w = new ethers.Wallet(ethers.toBeHex(i + 500, 32));
        wallets.push(w);
        addresses.push(w.address);
      }

      const Factory = await ethers.getContractFactory("BasisDAC", admin);
      const dac7 = await Factory.deploy(4, addresses);
      await dac7.waitForDeployment();

      expect(await dac7.committeeSize()).to.equal(7);
    });
  });
});
