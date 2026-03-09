import { ethers } from "ethers";

const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || "http://127.0.0.1:9650/ext/bc/C/rpc";

export function getProvider(): ethers.JsonRpcProvider {
  return new ethers.JsonRpcProvider(RPC_URL);
}

export const ENTERPRISE_REGISTRY_ABI = [
  "function admin() view returns (address)",
  "function enterpriseCount() view returns (uint256)",
  "function listEnterprises() view returns (address[])",
  "function getEnterprise(address) view returns (string name, bytes metadata, bool active, uint256 registeredAt, uint256 updatedAt)",
  "function isAuthorized(address) view returns (bool)",
  "event EnterpriseRegistered(address indexed enterprise, string name, uint256 timestamp)",
];

export const TRACEABILITY_REGISTRY_ABI = [
  "function eventCount() view returns (uint256)",
  "function getEventsByEnterprise(address) view returns (bytes32[])",
  "function getEventsByType(bytes32) view returns (bytes32[])",
  "event EventRecorded(bytes32 indexed eventId, address indexed enterprise, bytes32 indexed eventType, bytes32 assetId, uint256 timestamp)",
];

export const PLASMA_CONNECTOR_ABI = [
  "function totalOrders() view returns (uint256)",
  "function completedOrders() view returns (uint256)",
  "function getOpenOrders() view returns (bytes32[])",
  "event MaintenanceOrderCreated(bytes32 indexed orderId, bytes32 indexed equipmentId, address indexed enterprise, uint8 priority, uint256 timestamp)",
  "event MaintenanceOrderCompleted(bytes32 indexed orderId, uint256 timestamp, uint256 duration)",
];

export const TRACE_CONNECTOR_ABI = [
  "function totalSales() view returns (uint256)",
  "function totalInventoryMovements() view returns (uint256)",
  "function totalSupplierTransactions() view returns (uint256)",
  "event SaleRecorded(bytes32 indexed saleId, bytes32 indexed productId, address indexed enterprise, uint256 amount, uint256 timestamp)",
];

export const ZK_VERIFIER_ABI = [
  "function totalBatches() view returns (uint256)",
  "function totalVerified() view returns (uint256)",
  "function totalTransactionsVerified() view returns (uint256)",
  "function verifyingKeySet() view returns (bool)",
  "event BatchVerified(bytes32 indexed batchId, address indexed enterprise, bool verified, uint256 timestamp)",
];

export function getContract(address: string, abi: string[]): ethers.Contract {
  const provider = getProvider();
  return new ethers.Contract(address, abi, provider);
}
