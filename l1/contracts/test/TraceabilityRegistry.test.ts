import { expect } from "chai";
import { ethers } from "hardhat";
import { EnterpriseRegistry, TraceabilityRegistry } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("TraceabilityRegistry", function () {
  let enterpriseRegistry: EnterpriseRegistry;
  let traceRegistry: TraceabilityRegistry;
  let admin: SignerWithAddress;
  let enterprise1: SignerWithAddress;
  let unauthorized: SignerWithAddress;

  const EVENT_TYPE_A = ethers.keccak256(ethers.toUtf8Bytes("APP_EVENT_TYPE_A"));
  const EVENT_TYPE_B = ethers.keccak256(ethers.toUtf8Bytes("APP_EVENT_TYPE_B"));

  beforeEach(async function () {
    [admin, enterprise1, unauthorized] = await ethers.getSigners();

    const ERFactory = await ethers.getContractFactory("EnterpriseRegistry");
    enterpriseRegistry = await ERFactory.deploy();

    const TRFactory = await ethers.getContractFactory("TraceabilityRegistry");
    traceRegistry = await TRFactory.deploy(await enterpriseRegistry.getAddress());

    // Register enterprise1 as authorized
    const metadata = ethers.toUtf8Bytes("{}");
    await enterpriseRegistry.registerEnterprise(enterprise1.address, "Test Corp", metadata);
  });

  describe("Deployment", function () {
    it("should reference the correct EnterpriseRegistry", async function () {
      expect(await traceRegistry.enterpriseRegistry()).to.equal(
        await enterpriseRegistry.getAddress()
      );
    });

    it("should start with zero events", async function () {
      expect(await traceRegistry.eventCount()).to.equal(0);
    });
  });

  describe("recordEvent", function () {
    it("should record an event from an authorized enterprise", async function () {
      const assetId = ethers.encodeBytes32String("EQUIP-001");
      const data = ethers.toUtf8Bytes("test data");

      await traceRegistry.connect(enterprise1).recordEvent(EVENT_TYPE_A, assetId, data);
      expect(await traceRegistry.eventCount()).to.equal(1);
    });

    it("should emit EventRecorded event", async function () {
      const assetId = ethers.encodeBytes32String("EQUIP-001");
      const data = ethers.toUtf8Bytes("test data");

      await expect(
        traceRegistry.connect(enterprise1).recordEvent(EVENT_TYPE_A, assetId, data)
      ).to.emit(traceRegistry, "EventRecorded");
    });

    it("should revert for unauthorized caller", async function () {
      const assetId = ethers.encodeBytes32String("EQUIP-001");
      const data = ethers.toUtf8Bytes("test data");

      await expect(
        traceRegistry.connect(unauthorized).recordEvent(EVENT_TYPE_A, assetId, data)
      ).to.be.revertedWithCustomError(traceRegistry, "NotAuthorized");
    });

    it("should accept any application-defined event type", async function () {
      const customType = ethers.keccak256(ethers.toUtf8Bytes("MY_CUSTOM_EVENT"));
      const assetId = ethers.encodeBytes32String("ASSET-X");
      const data = ethers.toUtf8Bytes("custom data");

      await traceRegistry.connect(enterprise1).recordEvent(customType, assetId, data);
      expect(await traceRegistry.eventCount()).to.equal(1);

      const events = await traceRegistry.getEventsByType(customType);
      expect(events).to.have.lengthOf(1);
    });

    it("should record multiple events for the same asset", async function () {
      const assetId = ethers.encodeBytes32String("EQUIP-001");
      const data = ethers.toUtf8Bytes("event data");

      await traceRegistry.connect(enterprise1).recordEvent(EVENT_TYPE_A, assetId, data);
      await traceRegistry.connect(enterprise1).recordEvent(EVENT_TYPE_B, assetId, data);

      const history = await traceRegistry.getAssetHistory(assetId);
      expect(history).to.have.lengthOf(2);
    });
  });

  describe("getEvent", function () {
    it("should return event details", async function () {
      const assetId = ethers.encodeBytes32String("EQUIP-001");
      const data = ethers.toUtf8Bytes("inspection passed");

      const tx = await traceRegistry.connect(enterprise1).recordEvent(EVENT_TYPE_A, assetId, data);
      const receipt = await tx.wait();

      // Find the EventRecorded log by parsing all logs
      let eventId: string | undefined;
      for (const log of receipt!.logs) {
        try {
          const parsed = traceRegistry.interface.parseLog({ topics: log.topics as string[], data: log.data });
          if (parsed && parsed.name === "EventRecorded") {
            eventId = parsed.args[0];
            break;
          }
        } catch {
          // Skip logs from other contracts
        }
      }
      expect(eventId).to.not.be.undefined;

      const result = await traceRegistry["getEvent(bytes32)"](eventId!);
      expect(result.eventType).to.equal(EVENT_TYPE_A);
      expect(result.assetId).to.equal(assetId);
      expect(result.enterprise).to.equal(enterprise1.address);
    });

    it("should revert for non-existent event", async function () {
      const fakeId = ethers.encodeBytes32String("FAKE");
      await expect(traceRegistry["getEvent(bytes32)"](fakeId))
        .to.be.revertedWithCustomError(traceRegistry, "EventNotFound");
    });
  });

  describe("Query functions", function () {
    beforeEach(async function () {
      const assetId = ethers.encodeBytes32String("EQUIP-001");
      const data = ethers.toUtf8Bytes("test");

      await traceRegistry.connect(enterprise1).recordEvent(EVENT_TYPE_A, assetId, data);
      await traceRegistry.connect(enterprise1).recordEvent(EVENT_TYPE_B, assetId, data);
    });

    it("should return asset history", async function () {
      const assetId = ethers.encodeBytes32String("EQUIP-001");
      const history = await traceRegistry.getAssetHistory(assetId);
      expect(history).to.have.lengthOf(2);
    });

    it("should return events by enterprise", async function () {
      const events = await traceRegistry.getEventsByEnterprise(enterprise1.address);
      expect(events).to.have.lengthOf(2);
    });

    it("should return events by type", async function () {
      const maintenanceEvents = await traceRegistry.getEventsByType(EVENT_TYPE_A);
      expect(maintenanceEvents).to.have.lengthOf(1);

      const inspectionEvents = await traceRegistry.getEventsByType(EVENT_TYPE_B);
      expect(inspectionEvents).to.have.lengthOf(1);
    });

    it("should verify existing event", async function () {
      const events = await traceRegistry.getEventsByEnterprise(enterprise1.address);
      const valid = await traceRegistry.verifyEvent(events[0]);
      expect(valid).to.be.true;
    });

    it("should return false for non-existent event verification", async function () {
      const fakeId = ethers.encodeBytes32String("FAKE");
      const valid = await traceRegistry.verifyEvent(fakeId);
      expect(valid).to.be.false;
    });
  });
});
