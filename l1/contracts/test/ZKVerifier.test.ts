import { expect } from "chai";
import { ethers } from "hardhat";
import { EnterpriseRegistry, ZKVerifier } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("ZKVerifier", function () {
  let enterpriseRegistry: EnterpriseRegistry;
  let zkVerifier: ZKVerifier;
  let admin: SignerWithAddress;
  let enterprise1: SignerWithAddress;
  let unauthorized: SignerWithAddress;

  beforeEach(async function () {
    [admin, enterprise1, unauthorized] = await ethers.getSigners();

    const ERFactory = await ethers.getContractFactory("EnterpriseRegistry");
    enterpriseRegistry = await ERFactory.deploy();

    const ZKFactory = await ethers.getContractFactory("ZKVerifier");
    zkVerifier = await ZKFactory.deploy(await enterpriseRegistry.getAddress());

    const metadata = ethers.toUtf8Bytes("{}");
    await enterpriseRegistry.registerEnterprise(enterprise1.address, "Test Corp", metadata);
  });

  describe("Deployment", function () {
    it("should set the deployer as admin", async function () {
      expect(await zkVerifier.admin()).to.equal(admin.address);
    });

    it("should start with verifying key not set", async function () {
      expect(await zkVerifier.verifyingKeySet()).to.be.false;
    });

    it("should start with zero batches", async function () {
      expect(await zkVerifier.totalBatches()).to.equal(0);
    });
  });

  describe("setVerifyingKey", function () {
    it("should allow admin to set verifying key", async function () {
      const dummyKey = getDummyVerifyingKey();
      await zkVerifier.setVerifyingKey(
        dummyKey.alfa1,
        dummyKey.beta2,
        dummyKey.gamma2,
        dummyKey.delta2,
        dummyKey.IC
      );
      expect(await zkVerifier.verifyingKeySet()).to.be.true;
    });

    it("should emit VerifyingKeyUpdated event", async function () {
      const dummyKey = getDummyVerifyingKey();
      await expect(
        zkVerifier.setVerifyingKey(
          dummyKey.alfa1,
          dummyKey.beta2,
          dummyKey.gamma2,
          dummyKey.delta2,
          dummyKey.IC
        )
      ).to.emit(zkVerifier, "VerifyingKeyUpdated");
    });

    it("should revert if called by non-admin", async function () {
      const dummyKey = getDummyVerifyingKey();
      await expect(
        zkVerifier.connect(enterprise1).setVerifyingKey(
          dummyKey.alfa1,
          dummyKey.beta2,
          dummyKey.gamma2,
          dummyKey.delta2,
          dummyKey.IC
        )
      ).to.be.revertedWithCustomError(zkVerifier, "OnlyAdmin");
    });
  });

  describe("verifyBatchProof", function () {
    it("should revert if verifying key not set", async function () {
      const stateRoot = ethers.encodeBytes32String("ROOT");
      const a: [bigint, bigint] = [1n, 2n];
      const b: [[bigint, bigint], [bigint, bigint]] = [[1n, 2n], [3n, 4n]];
      const c: [bigint, bigint] = [1n, 2n];

      await expect(
        zkVerifier.connect(enterprise1).verifyBatchProof(stateRoot, 10, a, b, c, [1n])
      ).to.be.revertedWithCustomError(zkVerifier, "VerifyingKeyNotSet");
    });

    it("should revert if called by unauthorized address", async function () {
      const dummyKey = getDummyVerifyingKey();
      await zkVerifier.setVerifyingKey(
        dummyKey.alfa1,
        dummyKey.beta2,
        dummyKey.gamma2,
        dummyKey.delta2,
        dummyKey.IC
      );

      const stateRoot = ethers.encodeBytes32String("ROOT");
      const a: [bigint, bigint] = [1n, 2n];
      const b: [[bigint, bigint], [bigint, bigint]] = [[1n, 2n], [3n, 4n]];
      const c: [bigint, bigint] = [1n, 2n];

      await expect(
        zkVerifier.connect(unauthorized).verifyBatchProof(stateRoot, 10, a, b, c, [1n])
      ).to.be.revertedWithCustomError(zkVerifier, "NotAuthorized");
    });
  });

  describe("getBatch", function () {
    it("should revert for non-existent batch", async function () {
      const fakeId = ethers.encodeBytes32String("FAKE");
      await expect(zkVerifier.getBatch(fakeId))
        .to.be.revertedWithCustomError(zkVerifier, "BatchNotFound");
    });
  });

  describe("getAllBatches", function () {
    it("should return empty array initially", async function () {
      const batches = await zkVerifier.getAllBatches();
      expect(batches).to.have.lengthOf(0);
    });
  });
});

function getDummyVerifyingKey() {
  return {
    alfa1: [1n, 2n] as [bigint, bigint],
    beta2: [[1n, 2n], [3n, 4n]] as [[bigint, bigint], [bigint, bigint]],
    gamma2: [[1n, 2n], [3n, 4n]] as [[bigint, bigint], [bigint, bigint]],
    delta2: [[1n, 2n], [3n, 4n]] as [[bigint, bigint], [bigint, bigint]],
    IC: [[1n, 2n], [3n, 4n]] as [bigint, bigint][],
  };
}
