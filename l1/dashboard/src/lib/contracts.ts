import { ethers } from "ethers";

const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || "https://rpc.basisnetwork.com.co";

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

export const ZK_VERIFIER_ABI = [
  "function totalBatches() view returns (uint256)",
  "function totalVerified() view returns (uint256)",
  "function totalTransactionsVerified() view returns (uint256)",
  "function verifyingKeySet() view returns (bool)",
  "event BatchSubmitted(bytes32 indexed batchId, address indexed enterprise, bytes32 stateRoot, uint256 transactionCount, uint256 timestamp)",
  "event BatchVerified(bytes32 indexed batchId, address indexed enterprise, bool verified, uint256 timestamp)",
];

export const STATE_COMMITMENT_ABI = [
  "function totalBatchesCommitted() view returns (uint256)",
  "function getBatchCount(address) view returns (uint256)",
  "function getCurrentRoot(address) view returns (bytes32)",
  "event BatchCommitted(address indexed enterprise, uint256 indexed batchId, bytes32 prevRoot, bytes32 newRoot, uint256 timestamp)",
  "event EnterpriseInitialized(address indexed enterprise, bytes32 genesisRoot, uint256 timestamp)",
];

export const DAC_ATTESTATION_ABI = [
  "function totalBatches() view returns (uint256)",
  "function totalCertified() view returns (uint256)",
  "function committeeSize() view returns (uint256)",
  "function threshold() view returns (uint256)",
  "event AttestationSubmitted(bytes32 indexed batchId, bytes32 commitment, uint256 signatureCount, uint8 state, uint256 timestamp)",
];

export const CROSS_ENTERPRISE_VERIFIER_ABI = [
  "function totalCrossRefsVerified() view returns (uint256)",
  "function totalCrossRefsRejected() view returns (uint256)",
  "event CrossReferenceVerified(bytes32 indexed refId, address indexed enterpriseA, address indexed enterpriseB, uint256 batchIdA, uint256 batchIdB, bytes32 interactionCommitment, uint256 timestamp)",
  "event CrossReferenceRejected(bytes32 indexed refId, address indexed enterpriseA, address indexed enterpriseB, uint256 batchIdA, uint256 batchIdB, string reason, uint256 timestamp)",
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

function truncateAddress(addr: string): string {
  return addr.slice(0, 6) + "..." + addr.slice(-4);
}

export interface BlockInfo {
  number: number;
  timestamp: number;
  transactions: number;
}

export interface Enterprise {
  address: string;
  name: string;
  active: boolean;
  registeredAt: string;
}

export interface Activity {
  type: string;
  description: string;
  timestamp: string;
  blockNumber: number;
}

export async function fetchRecentBlocks(
  provider: ethers.JsonRpcProvider,
  count: number = 8
): Promise<BlockInfo[]> {
  const blockNumber = await provider.getBlockNumber();
  const promises = [];
  for (let i = 0; i < count && blockNumber - i >= 0; i++) {
    promises.push(provider.getBlock(blockNumber - i));
  }
  const blocks = await Promise.all(promises);
  return blocks
    .filter((b): b is ethers.Block => b !== null)
    .map((b) => ({
      number: b.number,
      timestamp: b.timestamp,
      transactions: b.transactions.length,
    }));
}

export async function fetchRecentActivities(
  provider: ethers.JsonRpcProvider
): Promise<Activity[]> {
  const registryAddr = process.env.NEXT_PUBLIC_ENTERPRISE_REGISTRY_ADDRESS;
  const traceRegAddr = process.env.NEXT_PUBLIC_TRACEABILITY_REGISTRY_ADDRESS;
  const zkAddr = process.env.NEXT_PUBLIC_ZK_VERIFIER_ADDRESS;

  const currentBlock = await provider.getBlockNumber();
  const fromBlock = Math.max(0, currentBlock - 1000);

  const activities: Activity[] = [];
  const queries: Promise<void>[] = [];

  if (registryAddr) {
    const registry = new ethers.Contract(registryAddr, ENTERPRISE_REGISTRY_ABI, provider);
    queries.push(
      registry.queryFilter(registry.filters.EnterpriseRegistered(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "registry",
            description: `Enterprise "${log.args[1]}" registered`,
            timestamp: new Date(Number(log.args[2]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
    queries.push(
      registry.queryFilter(registry.filters.EnterpriseDeactivated(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "registry",
            description: `Enterprise ${truncateAddress(log.args[0])} deactivated`,
            timestamp: new Date(Number(log.args[1]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
  }

  if (traceRegAddr) {
    const traceReg = new ethers.Contract(traceRegAddr, TRACEABILITY_REGISTRY_ABI, provider);
    queries.push(
      traceReg.queryFilter(traceReg.filters.EventRecorded(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "traceability",
            description: `Event recorded by ${truncateAddress(log.args[1])} (type: ${decodeBytes32(log.args[2])}, asset: ${decodeBytes32(log.args[3])})`,
            timestamp: new Date(Number(log.args[4]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
  }

  if (zkAddr) {
    const zk = new ethers.Contract(zkAddr, ZK_VERIFIER_ABI, provider);
    queries.push(
      zk.queryFilter(zk.filters.BatchSubmitted(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "zk",
            description: `ZK batch submitted with ${log.args[3]} transactions`,
            timestamp: new Date(Number(log.args[4]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
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

  const stateAddr = process.env.NEXT_PUBLIC_STATE_COMMITMENT_ADDRESS;
  const dacAddr = process.env.NEXT_PUBLIC_DAC_ATTESTATION_ADDRESS;
  const crossRefAddr = process.env.NEXT_PUBLIC_CROSS_ENTERPRISE_VERIFIER_ADDRESS;

  if (stateAddr) {
    const sc = new ethers.Contract(stateAddr, STATE_COMMITMENT_ABI, provider);
    queries.push(
      sc.queryFilter(sc.filters.BatchCommitted(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "state",
            description: `Batch #${log.args[1]} committed by ${truncateAddress(log.args[0])}`,
            timestamp: new Date(Number(log.args[4]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
    queries.push(
      sc.queryFilter(sc.filters.EnterpriseInitialized(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "state",
            description: `Enterprise ${truncateAddress(log.args[0])} state initialized`,
            timestamp: new Date(Number(log.args[2]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
  }

  if (dacAddr) {
    const dac = new ethers.Contract(dacAddr, DAC_ATTESTATION_ABI, provider);
    queries.push(
      dac.queryFilter(dac.filters.AttestationSubmitted(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "dac",
            description: `DAC attestation for batch ${log.args[0].slice(0, 10)}... (${log.args[2]} signatures)`,
            timestamp: new Date(Number(log.args[4]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
  }

  if (crossRefAddr) {
    const cv = new ethers.Contract(crossRefAddr, CROSS_ENTERPRISE_VERIFIER_ABI, provider);
    queries.push(
      cv.queryFilter(cv.filters.CrossReferenceVerified(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "crossref",
            description: `Cross-ref verified: ${truncateAddress(log.args[1])} ↔ ${truncateAddress(log.args[2])}`,
            timestamp: new Date(Number(log.args[6]) * 1000).toLocaleDateString(),
            blockNumber: log.blockNumber,
          });
        }
      }).catch(() => {})
    );
    queries.push(
      cv.queryFilter(cv.filters.CrossReferenceRejected(), fromBlock).then((events) => {
        for (const ev of events) {
          const log = ev as ethers.EventLog;
          activities.push({
            type: "crossref",
            description: `Cross-ref rejected: ${truncateAddress(log.args[1])} ↔ ${truncateAddress(log.args[2])}`,
            timestamp: new Date(Number(log.args[6]) * 1000).toLocaleDateString(),
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
