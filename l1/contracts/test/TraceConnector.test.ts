import { expect } from "chai";
import { ethers } from "hardhat";
import { EnterpriseRegistry, TraceabilityRegistry, TraceConnector } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("TraceConnector", function () {
  let enterpriseRegistry: EnterpriseRegistry;
  let traceRegistry: TraceabilityRegistry;
  let traceConnector: TraceConnector;
  let admin: SignerWithAddress;
  let enterprise1: SignerWithAddress;
  let unauthorized: SignerWithAddress;

  beforeEach(async function () {
    [admin, enterprise1, unauthorized] = await ethers.getSigners();

    const ERFactory = await ethers.getContractFactory("EnterpriseRegistry");
    enterpriseRegistry = await ERFactory.deploy();

    const TRFactory = await ethers.getContractFactory("TraceabilityRegistry");
    traceRegistry = await TRFactory.deploy(await enterpriseRegistry.getAddress());

    const TCFactory = await ethers.getContractFactory("TraceConnector");
    traceConnector = await TCFactory.deploy(
      await enterpriseRegistry.getAddress(),
      await traceRegistry.getAddress()
    );

    // Register enterprise1 and TraceConnector as authorized
    const metadata = ethers.toUtf8Bytes("{}");
    await enterpriseRegistry.registerEnterprise(enterprise1.address, "SME Store", metadata);
    await enterpriseRegistry.registerEnterprise(
      await traceConnector.getAddress(),
      "TraceConnector",
      metadata
    );
  });

  describe("recordSale", function () {
    it("should record a sale", async function () {
      const saleId = ethers.encodeBytes32String("SALE-001");
      const productId = ethers.encodeBytes32String("PROD-001");

      await traceConnector.connect(enterprise1).recordSale(saleId, productId, 5, 150000);

      const sale = await traceConnector.getSale(saleId);
      expect(sale.productId).to.equal(productId);
      expect(sale.quantity).to.equal(5);
      expect(sale.amount).to.equal(150000);
      expect(sale.enterprise).to.equal(enterprise1.address);
    });

    it("should emit SaleRecorded event", async function () {
      const saleId = ethers.encodeBytes32String("SALE-001");
      const productId = ethers.encodeBytes32String("PROD-001");

      await expect(
        traceConnector.connect(enterprise1).recordSale(saleId, productId, 5, 150000)
      ).to.emit(traceConnector, "SaleRecorded");
    });

    it("should also record event in TraceabilityRegistry", async function () {
      const saleId = ethers.encodeBytes32String("SALE-001");
      const productId = ethers.encodeBytes32String("PROD-001");

      await traceConnector.connect(enterprise1).recordSale(saleId, productId, 5, 150000);
      expect(await traceRegistry.eventCount()).to.equal(1);
    });

    it("should revert for unauthorized caller", async function () {
      const saleId = ethers.encodeBytes32String("SALE-001");
      const productId = ethers.encodeBytes32String("PROD-001");

      await expect(
        traceConnector.connect(unauthorized).recordSale(saleId, productId, 5, 150000)
      ).to.be.revertedWithCustomError(traceConnector, "NotAuthorized");
    });

    it("should revert for duplicate sale", async function () {
      const saleId = ethers.encodeBytes32String("SALE-001");
      const productId = ethers.encodeBytes32String("PROD-001");

      await traceConnector.connect(enterprise1).recordSale(saleId, productId, 5, 150000);
      await expect(
        traceConnector.connect(enterprise1).recordSale(saleId, productId, 5, 150000)
      ).to.be.revertedWithCustomError(traceConnector, "SaleAlreadyExists");
    });
  });

  describe("recordInventoryMovement", function () {
    it("should record stock in", async function () {
      const productId = ethers.encodeBytes32String("PROD-001");
      const reason = ethers.encodeBytes32String("PURCHASE");

      await traceConnector.connect(enterprise1).recordInventoryMovement(productId, 100, reason);
      expect(await traceConnector.totalInventoryMovements()).to.equal(1);
    });

    it("should record stock out (negative)", async function () {
      const productId = ethers.encodeBytes32String("PROD-001");
      const reason = ethers.encodeBytes32String("SALE");

      await traceConnector.connect(enterprise1).recordInventoryMovement(productId, -5, reason);

      const ledger = await traceConnector.getInventoryLedger(productId);
      expect(ledger).to.have.lengthOf(1);
      expect(ledger[0].quantityChange).to.equal(-5);
    });

    it("should emit InventoryMoved event", async function () {
      const productId = ethers.encodeBytes32String("PROD-001");
      const reason = ethers.encodeBytes32String("ADJUSTMENT");

      await expect(
        traceConnector.connect(enterprise1).recordInventoryMovement(productId, 10, reason)
      ).to.emit(traceConnector, "InventoryMoved");
    });
  });

  describe("recordSupplierTransaction", function () {
    it("should record a supplier transaction", async function () {
      const supplierId = ethers.encodeBytes32String("SUPP-001");
      const productId = ethers.encodeBytes32String("PROD-001");

      await traceConnector.connect(enterprise1).recordSupplierTransaction(supplierId, productId, 200);
      expect(await traceConnector.totalSupplierTransactions()).to.equal(1);
    });

    it("should emit SupplierTransactionRecorded event", async function () {
      const supplierId = ethers.encodeBytes32String("SUPP-001");
      const productId = ethers.encodeBytes32String("PROD-001");

      await expect(
        traceConnector.connect(enterprise1).recordSupplierTransaction(supplierId, productId, 200)
      ).to.emit(traceConnector, "SupplierTransactionRecorded");
    });

    it("should track supplier history", async function () {
      const supplierId = ethers.encodeBytes32String("SUPP-001");

      await traceConnector.connect(enterprise1).recordSupplierTransaction(
        supplierId, ethers.encodeBytes32String("PROD-001"), 200
      );
      await traceConnector.connect(enterprise1).recordSupplierTransaction(
        supplierId, ethers.encodeBytes32String("PROD-002"), 100
      );

      const history = await traceConnector.getSupplierHistory(supplierId);
      expect(history).to.have.lengthOf(2);
    });
  });

  describe("getSaleHistory", function () {
    it("should return all sales for a product", async function () {
      const productId = ethers.encodeBytes32String("PROD-001");

      await traceConnector.connect(enterprise1).recordSale(
        ethers.encodeBytes32String("SALE-001"), productId, 5, 150000
      );
      await traceConnector.connect(enterprise1).recordSale(
        ethers.encodeBytes32String("SALE-002"), productId, 3, 90000
      );

      const history = await traceConnector.getSaleHistory(productId);
      expect(history).to.have.lengthOf(2);
    });
  });
});
