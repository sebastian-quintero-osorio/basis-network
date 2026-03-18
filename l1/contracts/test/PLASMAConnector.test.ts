import { expect } from "chai";
import { ethers } from "hardhat";
import { EnterpriseRegistry, TraceabilityRegistry, PLASMAConnector } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("PLASMAConnector", function () {
  let enterpriseRegistry: EnterpriseRegistry;
  let traceRegistry: TraceabilityRegistry;
  let plasmaConnector: PLASMAConnector;
  let admin: SignerWithAddress;
  let enterprise1: SignerWithAddress;
  let unauthorized: SignerWithAddress;

  beforeEach(async function () {
    [admin, enterprise1, unauthorized] = await ethers.getSigners();

    const ERFactory = await ethers.getContractFactory("EnterpriseRegistry");
    enterpriseRegistry = await ERFactory.deploy();

    const TRFactory = await ethers.getContractFactory("TraceabilityRegistry");
    traceRegistry = await TRFactory.deploy(await enterpriseRegistry.getAddress());

    const PCFactory = await ethers.getContractFactory("PLASMAConnector");
    plasmaConnector = await PCFactory.deploy(
      await enterpriseRegistry.getAddress(),
      await traceRegistry.getAddress()
    );

    // Register enterprise1 and PLASMAConnector as authorized
    const metadata = ethers.toUtf8Bytes("{}");
    await enterpriseRegistry.registerEnterprise(enterprise1.address, "Ingenio Sancarlos", metadata);
    await enterpriseRegistry.registerEnterprise(
      await plasmaConnector.getAddress(),
      "PLASMAConnector",
      metadata
    );
  });

  describe("recordMaintenanceOrder", function () {
    it("should record a maintenance order", async function () {
      const orderId = ethers.encodeBytes32String("WO-001");
      const equipmentId = ethers.encodeBytes32String("BOILER-01");
      const details = ethers.toUtf8Bytes("Routine boiler inspection");

      await plasmaConnector
        .connect(enterprise1)
        .recordMaintenanceOrder(orderId, equipmentId, 2, details);

      expect(await plasmaConnector.totalOrders()).to.equal(1);
    });

    it("should emit MaintenanceOrderCreated event", async function () {
      const orderId = ethers.encodeBytes32String("WO-001");
      const equipmentId = ethers.encodeBytes32String("BOILER-01");
      const details = ethers.toUtf8Bytes("test");

      await expect(
        plasmaConnector.connect(enterprise1).recordMaintenanceOrder(orderId, equipmentId, 1, details)
      ).to.emit(plasmaConnector, "MaintenanceOrderCreated");
    });

    it("should also record event in TraceabilityRegistry", async function () {
      const orderId = ethers.encodeBytes32String("WO-001");
      const equipmentId = ethers.encodeBytes32String("BOILER-01");
      const details = ethers.toUtf8Bytes("test");

      await plasmaConnector
        .connect(enterprise1)
        .recordMaintenanceOrder(orderId, equipmentId, 2, details);

      expect(await traceRegistry.eventCount()).to.equal(1);
    });

    it("should revert for unauthorized caller", async function () {
      const orderId = ethers.encodeBytes32String("WO-001");
      const equipmentId = ethers.encodeBytes32String("BOILER-01");
      const details = ethers.toUtf8Bytes("test");

      await expect(
        plasmaConnector.connect(unauthorized).recordMaintenanceOrder(orderId, equipmentId, 2, details)
      ).to.be.revertedWithCustomError(plasmaConnector, "NotAuthorized");
    });

    it("should revert for duplicate order ID", async function () {
      const orderId = ethers.encodeBytes32String("WO-001");
      const equipmentId = ethers.encodeBytes32String("BOILER-01");
      const details = ethers.toUtf8Bytes("test");

      await plasmaConnector.connect(enterprise1).recordMaintenanceOrder(orderId, equipmentId, 2, details);
      await expect(
        plasmaConnector.connect(enterprise1).recordMaintenanceOrder(orderId, equipmentId, 2, details)
      ).to.be.revertedWithCustomError(plasmaConnector, "OrderAlreadyExists");
    });
  });

  describe("completeMaintenanceOrder", function () {
    beforeEach(async function () {
      const orderId = ethers.encodeBytes32String("WO-001");
      const equipmentId = ethers.encodeBytes32String("BOILER-01");
      const details = ethers.toUtf8Bytes("test");
      await plasmaConnector
        .connect(enterprise1)
        .recordMaintenanceOrder(orderId, equipmentId, 2, details);
    });

    it("should complete a maintenance order", async function () {
      const orderId = ethers.encodeBytes32String("WO-001");
      const completionData = ethers.toUtf8Bytes("replaced valve, tested pressure");

      await plasmaConnector.connect(enterprise1).completeMaintenanceOrder(orderId, completionData);

      const order = await plasmaConnector.getOrder(orderId);
      expect(order.completed).to.be.true;
      expect(await plasmaConnector.completedOrders()).to.equal(1);
    });

    it("should emit MaintenanceOrderCompleted event", async function () {
      const orderId = ethers.encodeBytes32String("WO-001");
      const completionData = ethers.toUtf8Bytes("done");

      await expect(
        plasmaConnector.connect(enterprise1).completeMaintenanceOrder(orderId, completionData)
      ).to.emit(plasmaConnector, "MaintenanceOrderCompleted");
    });

    it("should remove from open orders", async function () {
      const orderId = ethers.encodeBytes32String("WO-001");
      const completionData = ethers.toUtf8Bytes("done");

      await plasmaConnector.connect(enterprise1).completeMaintenanceOrder(orderId, completionData);
      const openOrders = await plasmaConnector.getOpenOrders();
      expect(openOrders).to.have.lengthOf(0);
    });

    it("should revert for non-existent order", async function () {
      const fakeId = ethers.encodeBytes32String("FAKE");
      await expect(
        plasmaConnector.connect(enterprise1).completeMaintenanceOrder(fakeId, ethers.toUtf8Bytes(""))
      ).to.be.revertedWithCustomError(plasmaConnector, "OrderNotFound");
    });

    it("should revert for already completed order", async function () {
      const orderId = ethers.encodeBytes32String("WO-001");
      const data = ethers.toUtf8Bytes("done");

      await plasmaConnector.connect(enterprise1).completeMaintenanceOrder(orderId, data);
      await expect(
        plasmaConnector.connect(enterprise1).completeMaintenanceOrder(orderId, data)
      ).to.be.revertedWithCustomError(plasmaConnector, "OrderAlreadyCompleted");
    });
  });

  describe("getMaintenanceHistory", function () {
    it("should return equipment maintenance history", async function () {
      const equipmentId = ethers.encodeBytes32String("BOILER-01");
      const details = ethers.toUtf8Bytes("test");

      await plasmaConnector
        .connect(enterprise1)
        .recordMaintenanceOrder(ethers.encodeBytes32String("WO-001"), equipmentId, 2, details);
      await plasmaConnector
        .connect(enterprise1)
        .recordMaintenanceOrder(ethers.encodeBytes32String("WO-002"), equipmentId, 3, details);

      const history = await plasmaConnector.getMaintenanceHistory(equipmentId);
      expect(history).to.have.lengthOf(2);
    });
  });

  describe("getOpenOrders", function () {
    it("should return only open orders", async function () {
      const equipmentId = ethers.encodeBytes32String("BOILER-01");
      const details = ethers.toUtf8Bytes("test");

      await plasmaConnector
        .connect(enterprise1)
        .recordMaintenanceOrder(ethers.encodeBytes32String("WO-001"), equipmentId, 1, details);
      await plasmaConnector
        .connect(enterprise1)
        .recordMaintenanceOrder(ethers.encodeBytes32String("WO-002"), equipmentId, 3, details);

      // Complete first order
      await plasmaConnector
        .connect(enterprise1)
        .completeMaintenanceOrder(ethers.encodeBytes32String("WO-001"), ethers.toUtf8Bytes("done"));

      const openOrders = await plasmaConnector.getOpenOrders();
      expect(openOrders).to.have.lengthOf(1);
      expect(openOrders[0]).to.equal(ethers.encodeBytes32String("WO-002"));
    });
  });

  describe("recordEquipmentInspection", function () {
    it("should record an inspection", async function () {
      const equipmentId = ethers.encodeBytes32String("BOILER-01");
      const inspectionData = ethers.toUtf8Bytes("all parameters normal");

      await expect(
        plasmaConnector.connect(enterprise1).recordEquipmentInspection(equipmentId, inspectionData)
      ).to.emit(plasmaConnector, "EquipmentInspected");
    });
  });
});

async function getBlockTimestamp(): Promise<number> {
  const block = await ethers.provider.getBlock("latest");
  return block!.timestamp;
}
