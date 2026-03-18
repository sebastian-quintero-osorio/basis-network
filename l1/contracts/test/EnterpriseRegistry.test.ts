import { expect } from "chai";
import { ethers } from "hardhat";
import { EnterpriseRegistry } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("EnterpriseRegistry", function () {
  let registry: EnterpriseRegistry;
  let admin: SignerWithAddress;
  let enterprise1: SignerWithAddress;
  let enterprise2: SignerWithAddress;
  let unauthorized: SignerWithAddress;

  beforeEach(async function () {
    [admin, enterprise1, enterprise2, unauthorized] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("EnterpriseRegistry");
    registry = await Factory.deploy();
  });

  describe("Deployment", function () {
    it("should set the deployer as admin", async function () {
      expect(await registry.admin()).to.equal(admin.address);
    });

    it("should start with zero enterprises", async function () {
      expect(await registry.enterpriseCount()).to.equal(0);
    });
  });

  describe("registerEnterprise", function () {
    it("should register a new enterprise", async function () {
      const metadata = ethers.toUtf8Bytes('{"industry":"sugar","jurisdiction":"CO"}');
      await registry.registerEnterprise(enterprise1.address, "Ingenio Sancarlos", metadata);

      const e = await registry.getEnterprise(enterprise1.address);
      expect(e.name).to.equal("Ingenio Sancarlos");
      expect(e.active).to.be.true;
      expect(await registry.enterpriseCount()).to.equal(1);
    });

    it("should emit EnterpriseRegistered event", async function () {
      const metadata = ethers.toUtf8Bytes("{}");
      await expect(registry.registerEnterprise(enterprise1.address, "Test Corp", metadata))
        .to.emit(registry, "EnterpriseRegistered");
    });

    it("should revert if called by non-admin", async function () {
      const metadata = ethers.toUtf8Bytes("{}");
      await expect(
        registry.connect(enterprise1).registerEnterprise(enterprise2.address, "Test", metadata)
      ).to.be.revertedWithCustomError(registry, "OnlyAdmin");
    });

    it("should revert for zero address", async function () {
      const metadata = ethers.toUtf8Bytes("{}");
      await expect(
        registry.registerEnterprise(ethers.ZeroAddress, "Test", metadata)
      ).to.be.revertedWithCustomError(registry, "ZeroAddress");
    });

    it("should revert for empty name", async function () {
      const metadata = ethers.toUtf8Bytes("{}");
      await expect(
        registry.registerEnterprise(enterprise1.address, "", metadata)
      ).to.be.revertedWithCustomError(registry, "EmptyName");
    });

    it("should revert if enterprise already registered", async function () {
      const metadata = ethers.toUtf8Bytes("{}");
      await registry.registerEnterprise(enterprise1.address, "Test", metadata);
      await expect(
        registry.registerEnterprise(enterprise1.address, "Test Again", metadata)
      ).to.be.revertedWithCustomError(registry, "AlreadyRegistered");
    });
  });

  describe("updateEnterprise", function () {
    beforeEach(async function () {
      const metadata = ethers.toUtf8Bytes("{}");
      await registry.registerEnterprise(enterprise1.address, "Test Corp", metadata);
    });

    it("should allow enterprise to update its own metadata", async function () {
      const newMetadata = ethers.toUtf8Bytes('{"updated":true}');
      await registry.connect(enterprise1).updateEnterprise(enterprise1.address, newMetadata);
      const e = await registry.getEnterprise(enterprise1.address);
      expect(ethers.toUtf8String(e.metadata)).to.equal('{"updated":true}');
    });

    it("should allow admin to update any enterprise metadata", async function () {
      const newMetadata = ethers.toUtf8Bytes('{"admin_update":true}');
      await registry.updateEnterprise(enterprise1.address, newMetadata);
      const e = await registry.getEnterprise(enterprise1.address);
      expect(ethers.toUtf8String(e.metadata)).to.equal('{"admin_update":true}');
    });

    it("should emit EnterpriseUpdated event", async function () {
      const newMetadata = ethers.toUtf8Bytes("{}");
      await expect(registry.connect(enterprise1).updateEnterprise(enterprise1.address, newMetadata))
        .to.emit(registry, "EnterpriseUpdated");
    });

    it("should revert if unauthorized caller", async function () {
      const newMetadata = ethers.toUtf8Bytes("{}");
      await expect(
        registry.connect(unauthorized).updateEnterprise(enterprise1.address, newMetadata)
      ).to.be.revertedWithCustomError(registry, "OnlyAuthorized");
    });

    it("should revert if enterprise not registered", async function () {
      const newMetadata = ethers.toUtf8Bytes("{}");
      await expect(
        registry.updateEnterprise(enterprise2.address, newMetadata)
      ).to.be.revertedWithCustomError(registry, "NotRegistered");
    });
  });

  describe("deactivateEnterprise", function () {
    beforeEach(async function () {
      const metadata = ethers.toUtf8Bytes("{}");
      await registry.registerEnterprise(enterprise1.address, "Test Corp", metadata);
    });

    it("should deactivate an enterprise", async function () {
      await registry.deactivateEnterprise(enterprise1.address);
      const e = await registry.getEnterprise(enterprise1.address);
      expect(e.active).to.be.false;
    });

    it("should make isAuthorized return false", async function () {
      await registry.deactivateEnterprise(enterprise1.address);
      expect(await registry.isAuthorized(enterprise1.address)).to.be.false;
    });

    it("should emit EnterpriseDeactivated event", async function () {
      await expect(registry.deactivateEnterprise(enterprise1.address))
        .to.emit(registry, "EnterpriseDeactivated");
    });

    it("should revert if called by non-admin", async function () {
      await expect(
        registry.connect(enterprise1).deactivateEnterprise(enterprise1.address)
      ).to.be.revertedWithCustomError(registry, "OnlyAdmin");
    });
  });

  describe("isAuthorized", function () {
    it("should return true for active enterprise", async function () {
      const metadata = ethers.toUtf8Bytes("{}");
      await registry.registerEnterprise(enterprise1.address, "Test", metadata);
      expect(await registry.isAuthorized(enterprise1.address)).to.be.true;
    });

    it("should return false for unregistered address", async function () {
      expect(await registry.isAuthorized(unauthorized.address)).to.be.false;
    });
  });

  describe("listEnterprises", function () {
    it("should return all registered enterprise addresses", async function () {
      const metadata = ethers.toUtf8Bytes("{}");
      await registry.registerEnterprise(enterprise1.address, "Corp 1", metadata);
      await registry.registerEnterprise(enterprise2.address, "Corp 2", metadata);

      const list = await registry.listEnterprises();
      expect(list).to.have.lengthOf(2);
      expect(list[0]).to.equal(enterprise1.address);
      expect(list[1]).to.equal(enterprise2.address);
    });
  });

  describe("transferAdmin", function () {
    it("should transfer admin to new address", async function () {
      await registry.transferAdmin(enterprise1.address);
      expect(await registry.admin()).to.equal(enterprise1.address);
    });

    it("should emit AdminTransferred event", async function () {
      await expect(registry.transferAdmin(enterprise1.address))
        .to.emit(registry, "AdminTransferred")
        .withArgs(admin.address, enterprise1.address);
    });

    it("should revert for zero address", async function () {
      await expect(
        registry.transferAdmin(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(registry, "ZeroAddress");
    });

    it("should revert if called by non-admin", async function () {
      await expect(
        registry.connect(enterprise1).transferAdmin(enterprise1.address)
      ).to.be.revertedWithCustomError(registry, "OnlyAdmin");
    });
  });
});

async function getBlockTimestamp(): Promise<number> {
  const block = await ethers.provider.getBlock("latest");
  return block!.timestamp;
}
