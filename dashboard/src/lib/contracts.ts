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
  "event EnterpriseUpdated(address indexed enterprise, uint256 timestamp)",
  "event EnterpriseDeactivated(address indexed enterprise, uint256 timestamp)",
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
  "event EquipmentInspected(bytes32 indexed equipmentId, address indexed enterprise, uint256 timestamp)",
];

export const TRACE_CONNECTOR_ABI = [
  "function totalSales() view returns (uint256)",
  "function totalInventoryMovements() view returns (uint256)",
  "function totalSupplierTransactions() view returns (uint256)",
  "event SaleRecorded(bytes32 indexed saleId, bytes32 indexed productId, address indexed enterprise, uint256 amount, uint256 timestamp)",
  "event InventoryMoved(bytes32 indexed productId, address indexed enterprise, int256 quantity, uint256 timestamp)",
  "event SupplierTransactionRecorded(bytes32 indexed supplierId, bytes32 indexed productId, address indexed enterprise, uint256 timestamp)",
];

export const ZK_VERIFIER_ABI = [
  "function totalBatches() view returns (uint256)",
  "function totalVerified() view returns (uint256)",
  "function totalTransactionsVerified() view returns (uint256)",
  "function verifyingKeySet() view returns (bool)",
  "event BatchSubmitted(bytes32 indexed batchId, address indexed enterprise, bytes32 stateRoot, uint256 transactionCount, uint256 timestamp)",
  "event BatchVerified(bytes32 indexed batchId, address indexed enterprise, bool verified, uint256 timestamp)",
];

export function getContract(address: string, abi: string[]): ethers.Contract {
  const provider = getProvider();
  return new ethers.Contract(address, abi, provider);
}

function decodeBytes32(val: string): string {
  try {
    const decoded = ethers.decodeBytes32String(val);
    return decoded || val.slice(0, 10) + "...";
  } catch {
    return val.slice(0, 10) + "...";
  }
}

interface Activity {
  type: string;
  description: string;
  timestamp: string;
  blockNumber: number;
}

export async function fetchRecentActivities(provider: ethers.JsonRpcProvider): Promise<Activity[]> {
  const plasmaAddr = process.env.NEXT_PUBLIC_PLASMA_CONNECTOR_ADDRESS;
  const traceAddr = process.env.NEXT_PUBLIC_TRACE_CONNECTOR_ADDRESS;
  const zkAddr = process.env.NEXT_PUBLIC_ZK_VERIFIER_ADDRESS;
  const registryAddr = process.env.NEXT_PUBLIC_ENTERPRISE_REGISTRY_ADDRESS;

  const currentBlock = await provider.getBlockNumber();
  const fromBlock = Math.max(0, currentBlock - 1000);

  const activities: Activity[] = [];

  const queries: Promise<void>[] = [];

  if (plasmaAddr) {
    const plasma = new ethers.Contract(plasmaAddr, PLASMA_CONNECTOR_ABI, provider);
    queries.push(
      plasma.queryFilter(plasma.filters.MaintenanceOrderCreated(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "plasma",
            description: `Work order ${decodeBytes32(log.args[0])} created for ${decodeBytes32(log.args[1])} (priority ${log.args[3]})`,
            timestamp: new Date(Number(log.args[4]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
    queries.push(
      plasma.queryFilter(plasma.filters.MaintenanceOrderCompleted(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "plasma",
            description: `Work order ${decodeBytes32(log.args[0])} completed`,
            timestamp: new Date(Number(log.args[1]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
    queries.push(
      plasma.queryFilter(plasma.filters.EquipmentInspected(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "plasma",
            description: `Equipment ${decodeBytes32(log.args[0])} inspected`,
            timestamp: new Date(Number(log.args[2]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
  }

  if (traceAddr) {
    const trace = new ethers.Contract(traceAddr, TRACE_CONNECTOR_ABI, provider);
    queries.push(
      trace.queryFilter(trace.filters.SaleRecorded(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "trace",
            description: `Sale ${decodeBytes32(log.args[0])} recorded: ${decodeBytes32(log.args[1])} (${log.args[3]} units)`,
            timestamp: new Date(Number(log.args[4]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
    queries.push(
      trace.queryFilter(trace.filters.InventoryMoved(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "trace",
            description: `Inventory movement: ${decodeBytes32(log.args[0])} (${log.args[2]} units)`,
            timestamp: new Date(Number(log.args[3]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
    queries.push(
      trace.queryFilter(trace.filters.SupplierTransactionRecorded(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "trace",
            description: `Supplier ${decodeBytes32(log.args[0])} transaction: ${decodeBytes32(log.args[1])}`,
            timestamp: new Date(Number(log.args[3]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
  }

  if (zkAddr) {
    const zk = new ethers.Contract(zkAddr, ZK_VERIFIER_ABI, provider);
    queries.push(
      zk.queryFilter(zk.filters.BatchVerified(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "zk",
            description: `ZK batch proof ${log.args[2] ? "verified" : "rejected"} on-chain`,
            timestamp: new Date(Number(log.args[3]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
  }

  if (registryAddr) {
    const registry = new ethers.Contract(registryAddr, ENTERPRISE_REGISTRY_ABI, provider);
    queries.push(
      registry.queryFilter(registry.filters.EnterpriseRegistered(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "enterprise",
            description: `Enterprise "${log.args[1]}" registered`,
            timestamp: new Date(Number(log.args[2]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
  }

  await Promise.all(queries);

  activities.sort((a, b) => b.blockNumber - a.blockNumber);

  return activities;
}
