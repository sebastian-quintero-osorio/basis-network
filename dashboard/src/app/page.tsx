"use client";

import { useEffect, useState } from "react";
import { ethers } from "ethers";
import StatCard from "@/components/StatCard";
import EnterpriseList from "@/components/EnterpriseList";
import ActivityFeed from "@/components/ActivityFeed";
import {
  getProvider,
  getContract,
  ENTERPRISE_REGISTRY_ABI,
  TRACEABILITY_REGISTRY_ABI,
  PLASMA_CONNECTOR_ABI,
  TRACE_CONNECTOR_ABI,
  ZK_VERIFIER_ABI,
} from "@/lib/contracts";

interface NetworkStats {
  blockNumber: number;
  gasPrice: string;
  enterpriseCount: number;
  totalEvents: number;
  totalMaintenanceOrders: number;
  completedOrders: number;
  totalSales: number;
  totalInventoryMovements: number;
  totalZKBatches: number;
  totalZKVerified: number;
  totalTxVerified: number;
}

interface Enterprise {
  address: string;
  name: string;
  active: boolean;
  registeredAt: string;
}

interface Activity {
  type: string;
  description: string;
  timestamp: string;
}

export default function Dashboard() {
  const [stats, setStats] = useState<NetworkStats | null>(null);
  const [enterprises, setEnterprises] = useState<Enterprise[]>([]);
  const [activities, setActivities] = useState<Activity[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [demoMode, setDemoMode] = useState(false);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 10000);
    return () => clearInterval(interval);
  }, []);

  function loadDemoData() {
    setStats({
      blockNumber: 18,
      gasPrice: "0",
      enterpriseCount: 3,
      totalEvents: 7,
      totalMaintenanceOrders: 2,
      completedOrders: 1,
      totalSales: 1,
      totalInventoryMovements: 1,
      totalZKBatches: 1,
      totalZKVerified: 1,
      totalTxVerified: 4,
    });
    setEnterprises([
      { address: "0xF486547C8bF764eA4E53a05D745543f8a6973133", name: "PLASMAConnector", active: true, registeredAt: "3/9/2026" },
      { address: "0x3ABC06a56b7F7Ec3711C8282B5B778CE8e34Dda0", name: "TraceConnector", active: true, registeredAt: "3/9/2026" },
      { address: "0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD", name: "Ingenio Sancarlos", active: true, registeredAt: "3/9/2026" },
    ]);
    setActivities([
      { type: "plasma", description: "Work order WO-2026-001 created (BOILER-A1, Critical)", timestamp: "3/9/2026" },
      { type: "plasma", description: "Work order WO-2026-002 created (TURBINE-B3, Scheduled)", timestamp: "3/9/2026" },
      { type: "plasma", description: "Equipment inspection: BOILER-A1 (nominal)", timestamp: "3/9/2026" },
      { type: "plasma", description: "Work order WO-2026-001 completed", timestamp: "3/9/2026" },
      { type: "trace", description: "Sale SALE-001: 100x SUGAR-50KG ($5,000,000)", timestamp: "3/9/2026" },
      { type: "trace", description: "Inventory movement: SUGAR-50KG (-100 units)", timestamp: "3/9/2026" },
      { type: "zk", description: "ZK batch proof verified on-chain (4 transactions, 530K gas)", timestamp: "3/9/2026" },
    ]);
    setDemoMode(true);
  }

  async function fetchData() {
    try {
      const provider = getProvider();

      const [blockNumber, feeData] = await Promise.all([
        provider.getBlockNumber(),
        provider.getFeeData(),
      ]);

      const gasPrice = feeData.gasPrice
        ? ethers.formatUnits(feeData.gasPrice, "gwei")
        : "0";

      const registryAddr = process.env.NEXT_PUBLIC_ENTERPRISE_REGISTRY_ADDRESS;
      const traceRegAddr = process.env.NEXT_PUBLIC_TRACEABILITY_REGISTRY_ADDRESS;
      const plasmaAddr = process.env.NEXT_PUBLIC_PLASMA_CONNECTOR_ADDRESS;
      const traceConnAddr = process.env.NEXT_PUBLIC_TRACE_CONNECTOR_ADDRESS;
      const zkAddr = process.env.NEXT_PUBLIC_ZK_VERIFIER_ADDRESS;

      let enterpriseCount = 0;
      let totalEvents = 0;
      let totalMaintenanceOrders = 0;
      let completedOrders = 0;
      let totalSales = 0;
      let totalInventoryMovements = 0;
      let totalZKBatches = 0;
      let totalZKVerified = 0;
      let totalTxVerified = 0;
      let enterpriseData: Enterprise[] = [];

      if (registryAddr) {
        const registry = getContract(registryAddr, ENTERPRISE_REGISTRY_ABI);
        enterpriseCount = Number(await registry.enterpriseCount());

        const addresses: string[] = await registry.listEnterprises();
        enterpriseData = await Promise.all(
          addresses.map(async (addr: string) => {
            const e = await registry.getEnterprise(addr);
            return {
              address: addr,
              name: e.name,
              active: e.active,
              registeredAt: new Date(Number(e.registeredAt) * 1000).toLocaleDateString(),
            };
          })
        );
      }

      if (traceRegAddr) {
        const traceReg = getContract(traceRegAddr, TRACEABILITY_REGISTRY_ABI);
        totalEvents = Number(await traceReg.eventCount());
      }

      if (plasmaAddr) {
        const plasma = getContract(plasmaAddr, PLASMA_CONNECTOR_ABI);
        totalMaintenanceOrders = Number(await plasma.totalOrders());
        completedOrders = Number(await plasma.completedOrders());
      }

      if (traceConnAddr) {
        const traceCon = getContract(traceConnAddr, TRACE_CONNECTOR_ABI);
        totalSales = Number(await traceCon.totalSales());
        totalInventoryMovements = Number(await traceCon.totalInventoryMovements());
      }

      if (zkAddr) {
        const zk = getContract(zkAddr, ZK_VERIFIER_ABI);
        totalZKBatches = Number(await zk.totalBatches());
        totalZKVerified = Number(await zk.totalVerified());
        totalTxVerified = Number(await zk.totalTransactionsVerified());
      }

      setStats({
        blockNumber,
        gasPrice,
        enterpriseCount,
        totalEvents,
        totalMaintenanceOrders,
        completedOrders,
        totalSales,
        totalInventoryMovements,
        totalZKBatches,
        totalZKVerified,
        totalTxVerified,
      });

      setEnterprises(enterpriseData);
      setError(null);
    } catch {
      loadDemoData();
    } finally {
      setLoading(false);
    }
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center min-h-[60vh]">
        <p className="text-gray-400">Connecting to Basis Network...</p>
      </div>
    );
  }

  const completionRate =
    stats && stats.totalMaintenanceOrders > 0
      ? Math.round((stats.completedOrders / stats.totalMaintenanceOrders) * 100)
      : 0;

  return (
    <div className="space-y-8">
      {demoMode && (
        <div className="bg-yellow-900/20 border border-yellow-700 rounded-lg px-4 py-3 text-sm text-yellow-300">
          Showing data from Fuji testnet deployment. Connect to the L1 RPC for live updates.
        </div>
      )}

      {/* Network Status */}
      <section>
        <h2 className="text-lg font-semibold text-white mb-4">Network Status</h2>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <StatCard
            title="Current Block"
            value={stats?.blockNumber.toLocaleString() || "0"}
            subtitle="Snowman consensus"
          />
          <StatCard
            title="Gas Price"
            value={`${stats?.gasPrice || "0"} Tomos`}
            subtitle="Zero-fee Lithos model"
            variant="accent"
          />
          <StatCard
            title="Enterprises"
            value={stats?.enterpriseCount || 0}
            subtitle="Registered on-chain"
          />
          <StatCard
            title="Total Events"
            value={stats?.totalEvents.toLocaleString() || "0"}
            subtitle="Immutable records"
          />
        </div>
      </section>

      {/* Product Metrics */}
      <section>
        <h2 className="text-lg font-semibold text-white mb-4">Product Metrics</h2>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <StatCard
            title="PLASMA: Work Orders"
            value={stats?.totalMaintenanceOrders || 0}
            subtitle={`${completionRate}% completion rate`}
          />
          <StatCard
            title="PLASMA: Completed"
            value={stats?.completedOrders || 0}
            subtitle="Maintenance orders closed"
            variant="accent"
          />
          <StatCard
            title="Trace: Sales"
            value={stats?.totalSales || 0}
            subtitle="On-chain sale records"
          />
          <StatCard
            title="Trace: Inventory"
            value={stats?.totalInventoryMovements || 0}
            subtitle="Stock movements tracked"
          />
        </div>
      </section>

      {/* ZK Verification */}
      <section>
        <h2 className="text-lg font-semibold text-white mb-4">ZK Proof Verification</h2>
        <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
          <StatCard
            title="Batches Submitted"
            value={stats?.totalZKBatches || 0}
            subtitle="Groth16 proofs"
          />
          <StatCard
            title="Batches Verified"
            value={stats?.totalZKVerified || 0}
            subtitle="Successfully verified on-chain"
            variant="accent"
          />
          <StatCard
            title="Transactions Verified"
            value={stats?.totalTxVerified.toLocaleString() || "0"}
            subtitle="Via ZK validium"
          />
        </div>
      </section>

      {/* Registered Enterprises */}
      <section>
        <h2 className="text-lg font-semibold text-white mb-4">Registered Enterprises</h2>
        <EnterpriseList enterprises={enterprises} />
      </section>

      {/* Activity Feed */}
      <section>
        <h2 className="text-lg font-semibold text-white mb-4">Recent Activity</h2>
        <ActivityFeed activities={activities} />
      </section>
    </div>
  );
}
