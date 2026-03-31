"use client";

import {
  createContext,
  useContext,
  useEffect,
  useState,
  useCallback,
  type ReactNode,
} from "react";
import { ethers } from "ethers";
import {
  getProvider,
  getContract,
  fetchRecentActivities,
  fetchRecentBlocks,
  ENTERPRISE_REGISTRY_ABI,
  TRACEABILITY_REGISTRY_ABI,
  ZK_VERIFIER_ABI,
  STATE_COMMITMENT_ABI,
  DAC_ATTESTATION_ABI,
  CROSS_ENTERPRISE_VERIFIER_ABI,
  type BlockInfo,
  type Enterprise,
  type Activity,
  type ValidiumBatch,
} from "./contracts";

interface NetworkState {
  connected: boolean;
  loading: boolean;
  error: string | null;

  blockNumber: number;
  gasPrice: string;
  chainId: number;

  enterpriseCount: number;
  totalEvents: number;
  totalZKVerified: number;
  totalTxVerified: number;
  totalZKBatches: number;
  totalBatchesCommitted: number;
  totalDACCertified: number;
  totalCrossRefsVerified: number;

  // Validium state
  totalStateBatches: number;
  verifyingKeySet: boolean;
  dacCommitteeSize: number;
  dacThreshold: number;
  dacTotalCertified: number;
  validiumBatches: ValidiumBatch[];

  enterprises: Enterprise[];
  activities: Activity[];
  recentBlocks: BlockInfo[];
}

const defaultState: NetworkState = {
  connected: false,
  loading: true,
  error: null,
  blockNumber: 0,
  gasPrice: "0",
  chainId: 43199,
  enterpriseCount: 0,
  totalEvents: 0,
  totalZKVerified: 0,
  totalTxVerified: 0,
  totalZKBatches: 0,
  totalBatchesCommitted: 0,
  totalDACCertified: 0,
  totalCrossRefsVerified: 0,
  totalStateBatches: 0,
  verifyingKeySet: false,
  dacCommitteeSize: 0,
  dacThreshold: 0,
  dacTotalCertified: 0,
  validiumBatches: [],
  enterprises: [],
  activities: [],
  recentBlocks: [],
};

const NetworkContext = createContext<NetworkState>(defaultState);

export function useNetwork(): NetworkState {
  return useContext(NetworkContext);
}

function formatGasPrice(feeData: ethers.FeeData): string {
  if (!feeData.gasPrice) return "0";
  const gwei = parseFloat(ethers.formatUnits(feeData.gasPrice, "gwei"));
  if (gwei === 0) return "0";
  if (gwei < 1) return gwei.toPrecision(2);
  return Math.round(gwei).toString();
}

export function NetworkProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<NetworkState>(defaultState);

  const fetchData = useCallback(async () => {
    try {
      const provider = getProvider();

      const [blockNumber, feeData] = await Promise.all([
        provider.getBlockNumber(),
        provider.getFeeData(),
      ]);

      const gasPrice = formatGasPrice(feeData);

      const registryAddr = process.env.NEXT_PUBLIC_ENTERPRISE_REGISTRY_ADDRESS;
      const traceRegAddr = process.env.NEXT_PUBLIC_TRACEABILITY_REGISTRY_ADDRESS;
      const zkAddr = process.env.NEXT_PUBLIC_ZK_VERIFIER_ADDRESS;

      let enterpriseCount = 0;
      let totalEvents = 0;
      let totalZKBatches = 0;
      let totalZKVerified = 0;
      let totalTxVerified = 0;
      let totalBatchesCommitted = 0;
      let totalDACCertified = 0;
      let totalCrossRefsVerified = 0;
      let totalStateBatches = 0;
      let verifyingKeySet = false;
      let dacCommitteeSize = 0;
      let dacThreshold = 0;
      let dacTotalCertified = 0;
      let validiumBatches: ValidiumBatch[] = [];
      let enterpriseData: Enterprise[] = [];

      const calls: Promise<void>[] = [];

      if (registryAddr) {
        calls.push(
          (async () => {
            try {
              const c = getContract(registryAddr, ENTERPRISE_REGISTRY_ABI);
              enterpriseCount = Number(await c.enterpriseCount());
              const addrs: string[] = await c.listEnterprises();
              enterpriseData = await Promise.all(
                addrs.map(async (addr: string) => {
                  const e = await c.getEnterprise(addr);
                  return {
                    address: addr,
                    name: e.name,
                    active: e.active,
                    registeredAt: new Date(
                      Number(e.registeredAt) * 1000
                    ).toLocaleDateString(),
                  };
                })
              );
            } catch { /* EnterpriseRegistry call failed */ }
          })()
        );
      }

      if (traceRegAddr) {
        calls.push(
          (async () => {
            try {
              totalEvents = Number(
                await getContract(traceRegAddr, TRACEABILITY_REGISTRY_ABI).eventCount()
              );
            } catch { /* TraceabilityRegistry call failed */ }
          })()
        );
      }

      if (zkAddr) {
        calls.push(
          (async () => {
            try {
              const c = getContract(zkAddr, ZK_VERIFIER_ABI);
              [totalZKBatches, totalZKVerified, totalTxVerified] = await Promise.all([
                c.totalBatches().then(Number),
                c.totalVerified().then(Number),
                c.totalTransactionsVerified().then(Number),
              ]);
            } catch { /* ZKVerifier call failed */ }
          })()
        );
      }

      const stateCommitAddr = process.env.NEXT_PUBLIC_STATE_COMMITMENT_ADDRESS;
      if (stateCommitAddr) {
        calls.push(
          (async () => {
            try {
              const c = getContract(stateCommitAddr, STATE_COMMITMENT_ABI);
              [totalStateBatches, verifyingKeySet] = await Promise.all([
                c.totalBatchesCommitted().then(Number),
                c.verifyingKeySet(),
              ]);
              totalBatchesCommitted = totalStateBatches;
              // Fetch recent BatchCommitted events
              const fromBlock = Math.max(0, blockNumber - 5000);
              const events = await c.queryFilter(
                c.filters.BatchCommitted(),
                fromBlock
              );
              validiumBatches = events.map((ev) => {
                const log = ev as ethers.EventLog;
                return {
                  batchId: Number(log.args[1]),
                  prevRoot: String(log.args[2]).slice(0, 18) + "...",
                  newRoot: String(log.args[3]).slice(0, 18) + "...",
                  enterprise: String(log.args[0]),
                  timestamp: new Date(
                    Number(log.args[4]) * 1000
                  ).toLocaleDateString(),
                  blockNumber: log.blockNumber,
                };
              }).reverse();
            } catch { /* StateCommitment not deployed yet */ }
          })()
        );
      }

      const dacAddr = process.env.NEXT_PUBLIC_DAC_ATTESTATION_ADDRESS;
      if (dacAddr) {
        calls.push(
          (async () => {
            try {
              const c = getContract(dacAddr, DAC_ATTESTATION_ABI);
              [dacCommitteeSize, dacThreshold, dacTotalCertified] = await Promise.all([
                c.committeeSize().then(Number),
                c.threshold().then(Number),
                c.totalCertified().then(Number),
              ]);
              totalDACCertified = dacTotalCertified;
            } catch { /* DACAttestation not deployed yet */ }
          })()
        );
      }

      const crossRefAddr = process.env.NEXT_PUBLIC_CROSS_ENTERPRISE_VERIFIER_ADDRESS;
      if (crossRefAddr) {
        calls.push(
          (async () => {
            try {
              const c = getContract(crossRefAddr, CROSS_ENTERPRISE_VERIFIER_ABI);
              totalCrossRefsVerified = Number(await c.totalCrossRefsVerified());
            } catch { /* CrossEnterpriseVerifier call failed */ }
          })()
        );
      }

      const [recentBlocks, activities] = await Promise.all([
        fetchRecentBlocks(provider, 8),
        fetchRecentActivities(provider),
        ...calls,
      ]) as [BlockInfo[], Activity[], ...void[]];

      setState({
        connected: true,
        loading: false,
        error: null,
        blockNumber,
        gasPrice,
        chainId: 43199,
        enterpriseCount,
        totalEvents,
        totalZKVerified,
        totalTxVerified,
        totalZKBatches,
        totalBatchesCommitted,
        totalDACCertified,
        totalCrossRefsVerified,
        totalStateBatches,
        verifyingKeySet,
        dacCommitteeSize,
        dacThreshold,
        dacTotalCertified,
        validiumBatches,
        enterprises: enterpriseData,
        activities,
        recentBlocks,
      });
    } catch (err) {
      setState((prev) => ({
        ...prev,
        connected: false,
        loading: false,
        error: err instanceof Error ? err.message : "Unknown error",
      }));
    }
  }, []);

  useEffect(() => {
    fetchData();
    const iv = setInterval(fetchData, 10000);
    return () => clearInterval(iv);
  }, [fetchData]);

  return (
    <NetworkContext.Provider value={state}>{children}</NetworkContext.Provider>
  );
}
