import { ethers } from "ethers";
import { getSigner, getContractAddress } from "../common/provider";
import { TransactionQueue } from "../common/queue";

// TraceabilityRegistry ABI (generic event recording)
const TRACEABILITY_REGISTRY_ABI = [
  "function recordEvent(bytes32 eventType, bytes32 assetId, bytes data) external returns (bytes32)",
  "function eventCount() view returns (uint256)",
];

// Trace event types — application-defined, not in the contract
const TRACE_EVENT_TYPES = {
  SALE_CREATED: ethers.keccak256(ethers.toUtf8Bytes("SALE_CREATED")),
  INVENTORY_MOVEMENT: ethers.keccak256(ethers.toUtf8Bytes("INVENTORY_MOVEMENT")),
  PURCHASE_ORDER_CREATED: ethers.keccak256(ethers.toUtf8Bytes("PURCHASE_ORDER_CREATED")),
  GOODS_RECEIVED: ethers.keccak256(ethers.toUtf8Bytes("GOODS_RECEIVED")),
  GOODS_SHIPPED: ethers.keccak256(ethers.toUtf8Bytes("GOODS_SHIPPED")),
  SUPPLIER_REGISTERED: ethers.keccak256(ethers.toUtf8Bytes("SUPPLIER_REGISTERED")),
} as const;

export class TraceAdapter {
  private contract: ethers.Contract;
  private queue: TransactionQueue;

  constructor() {
    const signer = getSigner();
    const address = getContractAddress("TRACEABILITY_REGISTRY");
    this.contract = new ethers.Contract(address, TRACEABILITY_REGISTRY_ABI, signer);
    this.queue = new TransactionQueue();
  }

  /// Records a sale from Trace ERP on-chain.
  async recordSale(
    saleId: string,
    productId: string,
    quantity: number,
    amount: number
  ): Promise<void> {
    const productIdBytes = ethers.encodeBytes32String(productId);
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "uint256", "uint256"],
      [ethers.encodeBytes32String(saleId), quantity, amount]
    );

    await this.queue.enqueue(`sale-${saleId}`, () =>
      this.contract.recordEvent(
        TRACE_EVENT_TYPES.SALE_CREATED,
        productIdBytes,
        data
      )
    );
  }

  /// Records an inventory movement (positive = stock in, negative = stock out).
  async recordInventoryMovement(
    productId: string,
    quantityChange: number,
    reason: string
  ): Promise<void> {
    const productIdBytes = ethers.encodeBytes32String(productId);
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      ["int256", "string"],
      [quantityChange, reason]
    );

    await this.queue.enqueue(`inventory-${productId}-${Date.now()}`, () =>
      this.contract.recordEvent(
        TRACE_EVENT_TYPES.INVENTORY_MOVEMENT,
        productIdBytes,
        data
      )
    );
  }

  /// Records a supplier transaction.
  async recordSupplierTransaction(
    supplierId: string,
    productId: string,
    quantity: number
  ): Promise<void> {
    const productIdBytes = ethers.encodeBytes32String(productId);
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "uint256"],
      [ethers.encodeBytes32String(supplierId), quantity]
    );

    await this.queue.enqueue(`supplier-${supplierId}-${Date.now()}`, () =>
      this.contract.recordEvent(
        TRACE_EVENT_TYPES.PURCHASE_ORDER_CREATED,
        productIdBytes,
        data
      )
    );
  }

  /// Returns current on-chain statistics.
  async getStats(): Promise<{ eventCount: bigint }> {
    const eventCount = await this.contract.eventCount();
    return { eventCount };
  }
}
