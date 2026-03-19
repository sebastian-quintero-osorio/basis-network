import { ethers } from "ethers";
import { getSigner, getContractAddress } from "../common/provider";
import { TransactionQueue } from "../common/queue";

// TraceabilityRegistry ABI (generic event recording)
const TRACEABILITY_REGISTRY_ABI = [
  "function recordEvent(bytes32 eventType, bytes32 assetId, bytes data) external returns (bytes32)",
  "function eventCount() view returns (uint256)",
];

// PLASMA event types — application-defined, not in the contract
const PLASMA_EVENT_TYPES = {
  ORDER_CREATED: ethers.keccak256(ethers.toUtf8Bytes("ORDER_CREATED")),
  ORDER_COMPLETED: ethers.keccak256(ethers.toUtf8Bytes("ORDER_COMPLETED")),
  EQUIPMENT_INSPECTION: ethers.keccak256(ethers.toUtf8Bytes("EQUIPMENT_INSPECTION")),
  TASK_CREATED: ethers.keccak256(ethers.toUtf8Bytes("TASK_CREATED")),
  TASK_COMPLETED: ethers.keccak256(ethers.toUtf8Bytes("TASK_COMPLETED")),
  REPORT_CREATED: ethers.keccak256(ethers.toUtf8Bytes("REPORT_CREATED")),
} as const;

export class PLASMAAdapter {
  private contract: ethers.Contract;
  private queue: TransactionQueue;

  constructor() {
    const signer = getSigner();
    const address = getContractAddress("TRACEABILITY_REGISTRY");
    this.contract = new ethers.Contract(address, TRACEABILITY_REGISTRY_ABI, signer);
    this.queue = new TransactionQueue();
  }

  /// Records a maintenance work order from PLASMA on-chain.
  async recordWorkOrder(
    orderId: string,
    equipmentId: string,
    priority: number,
    details: string
  ): Promise<void> {
    const equipmentIdBytes = ethers.encodeBytes32String(equipmentId);
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "uint8", "string"],
      [ethers.encodeBytes32String(orderId), priority, details]
    );

    await this.queue.enqueue(`work-order-${orderId}`, () =>
      this.contract.recordEvent(
        PLASMA_EVENT_TYPES.ORDER_CREATED,
        equipmentIdBytes,
        data
      )
    );
  }

  /// Records the completion of a maintenance work order.
  async completeWorkOrder(orderId: string, completionDetails: string): Promise<void> {
    const orderIdBytes = ethers.encodeBytes32String(orderId);
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      ["string"],
      [completionDetails]
    );

    await this.queue.enqueue(`complete-${orderId}`, () =>
      this.contract.recordEvent(
        PLASMA_EVENT_TYPES.ORDER_COMPLETED,
        orderIdBytes,
        data
      )
    );
  }

  /// Records an equipment inspection event.
  async recordInspection(equipmentId: string, inspectionData: string): Promise<void> {
    const equipmentIdBytes = ethers.encodeBytes32String(equipmentId);
    const data = ethers.toUtf8Bytes(inspectionData);

    await this.queue.enqueue(`inspection-${equipmentId}-${Date.now()}`, () =>
      this.contract.recordEvent(
        PLASMA_EVENT_TYPES.EQUIPMENT_INSPECTION,
        equipmentIdBytes,
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
