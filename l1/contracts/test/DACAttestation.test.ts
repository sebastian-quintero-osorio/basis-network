import { expect } from "chai";
import { ethers } from "hardhat";
import { DACAttestation, EnterpriseRegistry } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("DACAttestation", function () {
  let enterpriseRegistry: EnterpriseRegistry;
  let dacAttestation: DACAttestation;
  let admin: SignerWithAddress;
  let enterprise1: SignerWithAddress;
  let member1: SignerWithAddress;
  let member2: SignerWithAddress;
  let member3: SignerWithAddress;
  let unauthorized: SignerWithAddress;

  const THRESHOLD = 2;

  /**
   * Sign the attestation digest matching the contract's EIP-191 construction:
   *   digest = keccak256(abi.encodePacked(batchId, commitment))
   *   messageHash = keccak256("\x19Ethereum Signed Message:\n32" + digest)
   *
   * ethers.signMessage(bytes) automatically applies the EIP-191 prefix to the
   * 32-byte digest, producing a signature over messageHash.
   */
  async function signAttestation(
    signer: SignerWithAddress,
    batchId: string,
    commitment: string
  ): Promise<string> {
    const digest = ethers.solidityPackedKeccak256(
      ["bytes32", "bytes32"],
      [batchId, commitment]
    );
    return signer.signMessage(ethers.getBytes(digest));
  }

  beforeEach(async function () {
    [admin, enterprise1, member1, member2, member3, unauthorized] =
      await ethers.getSigners();

    const ERFactory = await ethers.getContractFactory("EnterpriseRegistry");
    enterpriseRegistry = await ERFactory.deploy();

    const DACFactory = await ethers.getContractFactory("DACAttestation");
    dacAttestation = await DACFactory.deploy(
      await enterpriseRegistry.getAddress(),
      THRESHOLD
    );

    const metadata = ethers.toUtf8Bytes("{}");
    await enterpriseRegistry.registerEnterprise(
      enterprise1.address,
      "Test Corp",
      metadata
    );

    await dacAttestation.addCommitteeMember(member1.address);
    await dacAttestation.addCommitteeMember(member2.address);
    await dacAttestation.addCommitteeMember(member3.address);
  });

  // -----------------------------------------------------------------------
  // Deployment
  // -----------------------------------------------------------------------

  describe("Deployment", function () {
    it("should set deployer as admin", async function () {
      expect(await dacAttestation.admin()).to.equal(admin.address);
    });

    it("should set initial threshold", async function () {
      expect(await dacAttestation.threshold()).to.equal(THRESHOLD);
    });

    it("should start with zero batches", async function () {
      expect(await dacAttestation.totalBatches()).to.equal(0);
      expect(await dacAttestation.totalCertified()).to.equal(0);
    });

    it("should reject threshold < 1", async function () {
      const DACFactory = await ethers.getContractFactory("DACAttestation");
      await expect(
        DACFactory.deploy(await enterpriseRegistry.getAddress(), 0)
      ).to.be.revertedWithCustomError(dacAttestation, "InvalidThreshold");
    });
  });

  // -----------------------------------------------------------------------
  // Committee Management
  // -----------------------------------------------------------------------

  describe("Committee management", function () {
    it("should register committee members", async function () {
      expect(await dacAttestation.isCommitteeMember(member1.address)).to.be.true;
      expect(await dacAttestation.isCommitteeMember(member2.address)).to.be.true;
      expect(await dacAttestation.isCommitteeMember(member3.address)).to.be.true;
      expect(await dacAttestation.committeeSize()).to.equal(3);
    });

    it("should reject duplicate member registration", async function () {
      await expect(
        dacAttestation.addCommitteeMember(member1.address)
      ).to.be.revertedWithCustomError(dacAttestation, "MemberAlreadyRegistered");
    });

    it("should reject zero address member", async function () {
      await expect(
        dacAttestation.addCommitteeMember(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(dacAttestation, "ZeroAddress");
    });

    it("should only allow admin to add members", async function () {
      await expect(
        dacAttestation.connect(unauthorized).addCommitteeMember(unauthorized.address)
      ).to.be.revertedWithCustomError(dacAttestation, "OnlyAdmin");
    });

    it("should remove committee member", async function () {
      await dacAttestation.removeCommitteeMember(member3.address);
      expect(await dacAttestation.isCommitteeMember(member3.address)).to.be.false;
      expect(await dacAttestation.committeeSize()).to.equal(2);
    });

    it("should reject removing non-member", async function () {
      await expect(
        dacAttestation.removeCommitteeMember(unauthorized.address)
      ).to.be.revertedWithCustomError(dacAttestation, "NotCommitteeMember");
    });

    it("should update threshold", async function () {
      await dacAttestation.setThreshold(3);
      expect(await dacAttestation.threshold()).to.equal(3);
    });

    it("should reject threshold > committeeSize", async function () {
      await expect(dacAttestation.setThreshold(4)).to.be.revertedWithCustomError(
        dacAttestation,
        "InvalidThreshold"
      );
    });

    it("should return committee members list", async function () {
      const members = await dacAttestation.getCommitteeMembers();
      expect(members).to.have.lengthOf(3);
      expect(members).to.include(member1.address);
    });
  });

  // -----------------------------------------------------------------------
  // Attestation Submission
  // -----------------------------------------------------------------------

  describe("submitAttestation", function () {
    const batchId = ethers.keccak256(ethers.toUtf8Bytes("batch-001"));
    const commitment = ethers.keccak256(ethers.toUtf8Bytes("data-commitment"));

    it("should accept valid attestation with threshold signatures", async function () {
      const sig1 = await signAttestation(member1, batchId, commitment);
      const sig2 = await signAttestation(member2, batchId, commitment);

      await expect(
        dacAttestation
          .connect(enterprise1)
          .submitAttestation(
            batchId,
            commitment,
            [member1.address, member2.address],
            [sig1, sig2]
          )
      ).to.emit(dacAttestation, "AttestationSubmitted");

      expect(await dacAttestation.verifyAttestation(batchId)).to.be.true;
      expect(await dacAttestation.totalBatches()).to.equal(1);
      expect(await dacAttestation.totalCertified()).to.equal(1);
    });

    it("should accept attestation with all 3 signatures", async function () {
      const sig1 = await signAttestation(member1, batchId, commitment);
      const sig2 = await signAttestation(member2, batchId, commitment);
      const sig3 = await signAttestation(member3, batchId, commitment);

      await dacAttestation
        .connect(enterprise1)
        .submitAttestation(
          batchId,
          commitment,
          [member1.address, member2.address, member3.address],
          [sig1, sig2, sig3]
        );

      const [, , signatureCount, state] =
        await dacAttestation.getAttestation(batchId);
      expect(signatureCount).to.equal(3);
      expect(state).to.equal(1); // CertState.Valid
    });

    it("should reject duplicate batch submission", async function () {
      const sig1 = await signAttestation(member1, batchId, commitment);
      const sig2 = await signAttestation(member2, batchId, commitment);

      await dacAttestation
        .connect(enterprise1)
        .submitAttestation(
          batchId,
          commitment,
          [member1.address, member2.address],
          [sig1, sig2]
        );

      await expect(
        dacAttestation
          .connect(enterprise1)
          .submitAttestation(
            batchId,
            commitment,
            [member1.address, member2.address],
            [sig1, sig2]
          )
      ).to.be.revertedWithCustomError(dacAttestation, "BatchAlreadyExists");
    });

    it("should reject non-committee member signer", async function () {
      const sig = await signAttestation(unauthorized, batchId, commitment);

      await expect(
        dacAttestation
          .connect(enterprise1)
          .submitAttestation(batchId, commitment, [unauthorized.address], [sig])
      ).to.be.revertedWithCustomError(dacAttestation, "NotCommitteeMember");
    });

    it("should reject unauthorized enterprise", async function () {
      await expect(
        dacAttestation
          .connect(unauthorized)
          .submitAttestation(batchId, commitment, [], [])
      ).to.be.revertedWithCustomError(dacAttestation, "NotAuthorized");
    });

    it("should reject duplicate signer in same submission", async function () {
      const sig1 = await signAttestation(member1, batchId, commitment);

      await expect(
        dacAttestation
          .connect(enterprise1)
          .submitAttestation(
            batchId,
            commitment,
            [member1.address, member1.address],
            [sig1, sig1]
          )
      ).to.be.revertedWithCustomError(dacAttestation, "DuplicateSigner");
    });

    it("should reject forged signature", async function () {
      // member2 signs but we claim member1 signed
      const sig2 = await signAttestation(member2, batchId, commitment);

      await expect(
        dacAttestation
          .connect(enterprise1)
          .submitAttestation(batchId, commitment, [member1.address], [sig2])
      ).to.be.revertedWithCustomError(dacAttestation, "InvalidSignature");
    });
  });

  // -----------------------------------------------------------------------
  // Fallback
  // -----------------------------------------------------------------------

  describe("triggerFallback", function () {
    it("should trigger fallback on uncertified batch", async function () {
      const batchId = ethers.keccak256(ethers.toUtf8Bytes("batch-fallback"));
      const commitment = ethers.keccak256(ethers.toUtf8Bytes("data"));

      // Submit with only 1 signature (below threshold of 2)
      const sig1 = await signAttestation(member1, batchId, commitment);
      await dacAttestation
        .connect(enterprise1)
        .submitAttestation(batchId, commitment, [member1.address], [sig1]);

      expect(await dacAttestation.verifyAttestation(batchId)).to.be.false;

      await expect(
        dacAttestation.connect(enterprise1).triggerFallback(batchId)
      ).to.emit(dacAttestation, "FallbackTriggered");

      const [, , , state] = await dacAttestation.getAttestation(batchId);
      expect(state).to.equal(2); // CertState.Fallback
    });

    it("should reject fallback on nonexistent batch", async function () {
      const fakeBatchId = ethers.keccak256(ethers.toUtf8Bytes("nonexistent"));
      await expect(
        dacAttestation.connect(enterprise1).triggerFallback(fakeBatchId)
      ).to.be.revertedWithCustomError(dacAttestation, "BatchNotFound");
    });
  });

  // -----------------------------------------------------------------------
  // Query Functions
  // -----------------------------------------------------------------------

  describe("Query functions", function () {
    it("should return batch details", async function () {
      const batchId = ethers.keccak256(ethers.toUtf8Bytes("batch-query"));
      const commitment = ethers.keccak256(ethers.toUtf8Bytes("data"));
      const sig1 = await signAttestation(member1, batchId, commitment);
      const sig2 = await signAttestation(member2, batchId, commitment);

      await dacAttestation
        .connect(enterprise1)
        .submitAttestation(
          batchId,
          commitment,
          [member1.address, member2.address],
          [sig1, sig2]
        );

      const [retCommitment, retSubmitter, retSigCount, retState, retTimestamp] =
        await dacAttestation.getAttestation(batchId);

      expect(retCommitment).to.equal(commitment);
      expect(retSubmitter).to.equal(enterprise1.address);
      expect(retSigCount).to.equal(2);
      expect(retState).to.equal(1); // Valid
      expect(retTimestamp).to.be.greaterThan(0);
    });

    it("should revert on nonexistent batch query", async function () {
      const fakeBatchId = ethers.keccak256(ethers.toUtf8Bytes("fake"));
      await expect(
        dacAttestation.getAttestation(fakeBatchId)
      ).to.be.revertedWithCustomError(dacAttestation, "BatchNotFound");
    });

    it("should return all batch IDs", async function () {
      const batchId = ethers.keccak256(ethers.toUtf8Bytes("batch-list"));
      const commitment = ethers.keccak256(ethers.toUtf8Bytes("data"));
      const sig1 = await signAttestation(member1, batchId, commitment);
      const sig2 = await signAttestation(member2, batchId, commitment);

      await dacAttestation
        .connect(enterprise1)
        .submitAttestation(
          batchId,
          commitment,
          [member1.address, member2.address],
          [sig1, sig2]
        );

      const batches = await dacAttestation.getAllBatches();
      expect(batches).to.have.lengthOf(1);
      expect(batches[0]).to.equal(batchId);
    });
  });

  // -----------------------------------------------------------------------
  // Admin Transfer
  // -----------------------------------------------------------------------

  describe("Admin transfer", function () {
    it("should transfer admin", async function () {
      await dacAttestation.transferAdmin(enterprise1.address);
      expect(await dacAttestation.admin()).to.equal(enterprise1.address);
    });

    it("should reject zero address transfer", async function () {
      await expect(
        dacAttestation.transferAdmin(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(dacAttestation, "ZeroAddress");
    });

    it("should reject non-admin transfer", async function () {
      await expect(
        dacAttestation.connect(unauthorized).transferAdmin(unauthorized.address)
      ).to.be.revertedWithCustomError(dacAttestation, "OnlyAdmin");
    });
  });
});
