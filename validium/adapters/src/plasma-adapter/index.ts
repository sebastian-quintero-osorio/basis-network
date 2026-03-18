import { ethers } from "ethers";
import { getSigner, getContractAddress } from "../common/provider";
import { TransactionQueue } from "../common/queue";

// PLASMAConnector ABI (only the functions we need)
const PLASMA_CONNECTOR_ABI = [
  "function recordMaintenanceOrder(bytes32 orderId, bytes32 equipmentId, uint8 priority, bytes details) external",
  "function completeMaintenanceOrder(bytes32 orderId, bytes completionData) external",
  "function recordEquipmentInspection(bytes32 equipmentId, bytes inspectionData) external",
  "function totalOrders() view returns (uint256)",
  "function completedOrders() view returns (uint256)",
  "event MaintenanceOrderCreated(bytes32 indexed orderId, bytes32 indexed equipmentId, address indexed enterprise, uint8 priority, uint256 timestamp)",
  "event MaintenanceOrderCompleted(bytes32 indexed orderId, uint256 timestamp, uint256 duration)",
];

export class PLASMAAdapter {
  private contract: ethers.Contract;
  private queue: TransactionQueue;

  constructor() {
    const signer = getSigner();
    const address = getContractAddress("PLASMA_CONNECTOR");
    this.contract = new ethers.Contract(address, PLASMA_CONNECTOR_ABI, signer);
    this.queue = new TransactionQueue();
  }

  /// Records a maintenance work order from PLASMA on-chain.
  async recordWorkOrder(
    orderId: string,
    equipmentId: string,
    priority: number,
    details: string
  ): Promise<void> {
    const orderIdBytes = ethers.encodeBytes32String(orderId);
    const equipmentIdBytes = ethers.encodeBytes32String(equipmentId);
    const detailsBytes = ethers.toUtf8Bytes(details);

    await this.queue.enqueue(`work-order-${orderId}`, () =>
      this.contract.recordMaintenanceOrder(
        orderIdBytes,
        equipmentIdBytes,
        priority,
        detailsBytes
      )
    );
  }

  /// Records the completion of a maintenance work order.
  async completeWorkOrder(orderId: string, completionDetails: string): Promise<void> {
    const orderIdBytes = ethers.encodeBytes32String(orderId);
    const completionBytes = ethers.toUtf8Bytes(completionDetails);

    await this.queue.enqueue(`complete-${orderId}`, () =>
      this.contract.completeMaintenanceOrder(orderIdBytes, completionBytes)
    );
  }

  /// Records an equipment inspection event.
  async recordInspection(equipmentId: string, inspectionData: string): Promise<void> {
    const equipmentIdBytes = ethers.encodeBytes32String(equipmentId);
    const inspectionBytes = ethers.toUtf8Bytes(inspectionData);

    await this.queue.enqueue(`inspection-${equipmentId}-${Date.now()}`, () =>
      this.contract.recordEquipmentInspection(equipmentIdBytes, inspectionBytes)
    );
  }

  /// Returns current on-chain statistics.
  async getStats(): Promise<{ totalOrders: bigint; completedOrders: bigint }> {
    const [totalOrders, completedOrders] = await Promise.all([
      this.contract.totalOrders(),
      this.contract.completedOrders(),
    ]);
    return { totalOrders, completedOrders };
  }
}
