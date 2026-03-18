import { ethers } from "ethers";
import { getSigner, getContractAddress } from "../common/provider";
import { TransactionQueue } from "../common/queue";

// TraceConnector ABI (only the functions we need)
const TRACE_CONNECTOR_ABI = [
  "function recordSale(bytes32 saleId, bytes32 productId, uint256 quantity, uint256 amount) external",
  "function recordInventoryMovement(bytes32 productId, int256 quantityChange, bytes32 reason) external",
  "function recordSupplierTransaction(bytes32 supplierId, bytes32 productId, uint256 quantity) external",
  "function totalSales() view returns (uint256)",
  "function totalInventoryMovements() view returns (uint256)",
  "function totalSupplierTransactions() view returns (uint256)",
  "event SaleRecorded(bytes32 indexed saleId, bytes32 indexed productId, address indexed enterprise, uint256 amount, uint256 timestamp)",
];

export class TraceAdapter {
  private contract: ethers.Contract;
  private queue: TransactionQueue;

  constructor() {
    const signer = getSigner();
    const address = getContractAddress("TRACE_CONNECTOR");
    this.contract = new ethers.Contract(address, TRACE_CONNECTOR_ABI, signer);
    this.queue = new TransactionQueue();
  }

  /// Records a sale from Trace ERP on-chain.
  async recordSale(
    saleId: string,
    productId: string,
    quantity: number,
    amount: number
  ): Promise<void> {
    const saleIdBytes = ethers.encodeBytes32String(saleId);
    const productIdBytes = ethers.encodeBytes32String(productId);

    await this.queue.enqueue(`sale-${saleId}`, () =>
      this.contract.recordSale(saleIdBytes, productIdBytes, quantity, amount)
    );
  }

  /// Records an inventory movement (positive = stock in, negative = stock out).
  async recordInventoryMovement(
    productId: string,
    quantityChange: number,
    reason: string
  ): Promise<void> {
    const productIdBytes = ethers.encodeBytes32String(productId);
    const reasonBytes = ethers.encodeBytes32String(reason);

    await this.queue.enqueue(`inventory-${productId}-${Date.now()}`, () =>
      this.contract.recordInventoryMovement(productIdBytes, quantityChange, reasonBytes)
    );
  }

  /// Records a supplier transaction.
  async recordSupplierTransaction(
    supplierId: string,
    productId: string,
    quantity: number
  ): Promise<void> {
    const supplierIdBytes = ethers.encodeBytes32String(supplierId);
    const productIdBytes = ethers.encodeBytes32String(productId);

    await this.queue.enqueue(`supplier-${supplierId}-${Date.now()}`, () =>
      this.contract.recordSupplierTransaction(supplierIdBytes, productIdBytes, quantity)
    );
  }

  /// Returns current on-chain statistics.
  async getStats(): Promise<{
    totalSales: bigint;
    totalInventoryMovements: bigint;
    totalSupplierTransactions: bigint;
  }> {
    const [totalSales, totalInventoryMovements, totalSupplierTransactions] = await Promise.all([
      this.contract.totalSales(),
      this.contract.totalInventoryMovements(),
      this.contract.totalSupplierTransactions(),
    ]);
    return { totalSales, totalInventoryMovements, totalSupplierTransactions };
  }
}
