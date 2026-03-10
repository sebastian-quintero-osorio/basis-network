"use client";

import { useEffect, useState, useCallback } from "react";
import { ethers } from "ethers";
import dynamic from "next/dynamic";
import StatCard from "@/components/StatCard";
import EnterpriseList from "@/components/EnterpriseList";
import ActivityFeed from "@/components/ActivityFeed";
import {
  getProvider,
  getContract,
  fetchRecentActivities,
  ENTERPRISE_REGISTRY_ABI,
  TRACEABILITY_REGISTRY_ABI,
  PLASMA_CONNECTOR_ABI,
  TRACE_CONNECTOR_ABI,
  ZK_VERIFIER_ABI,
} from "@/lib/contracts";

const NetworkParticles = dynamic(() => import("@/components/NetworkParticles"), { ssr: false });

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
  blockNumber?: number;
}

export default function Dashboard() {
  const [stats, setStats] = useState<NetworkStats | null>(null);
  const [enterprises, setEnterprises] = useState<Enterprise[]>([]);
  const [activities, setActivities] = useState<Activity[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async () => {
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

      const calls: Promise<void>[] = [];

      if (registryAddr) {
        calls.push((async () => {
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
                registeredAt: new Date(Number(e.registeredAt) * 1000).toLocaleDateString(),
              };
            })
          );
        })());
      }

      if (traceRegAddr) {
        calls.push((async () => {
          totalEvents = Number(await getContract(traceRegAddr, TRACEABILITY_REGISTRY_ABI).eventCount());
        })());
      }

      if (plasmaAddr) {
        calls.push((async () => {
          const c = getContract(plasmaAddr, PLASMA_CONNECTOR_ABI);
          [totalMaintenanceOrders, completedOrders] = await Promise.all([
            c.totalOrders().then(Number),
            c.completedOrders().then(Number),
          ]);
        })());
      }

      if (traceConnAddr) {
        calls.push((async () => {
          const c = getContract(traceConnAddr, TRACE_CONNECTOR_ABI);
          [totalSales, totalInventoryMovements] = await Promise.all([
            c.totalSales().then(Number),
            c.totalInventoryMovements().then(Number),
          ]);
        })());
      }

      if (zkAddr) {
        calls.push((async () => {
          const c = getContract(zkAddr, ZK_VERIFIER_ABI);
          [totalZKBatches, totalZKVerified, totalTxVerified] = await Promise.all([
            c.totalBatches().then(Number),
            c.totalVerified().then(Number),
            c.totalTransactionsVerified().then(Number),
          ]);
        })());
      }

      calls.push(fetchRecentActivities(provider).then(setActivities));

      await Promise.all(calls);

      setStats({
        blockNumber, gasPrice, enterpriseCount, totalEvents,
        totalMaintenanceOrders, completedOrders, totalSales,
        totalInventoryMovements, totalZKBatches, totalZKVerified, totalTxVerified,
      });
      setEnterprises(enterpriseData);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Unknown error");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const iv = setInterval(fetchData, 10000);
    return () => clearInterval(iv);
  }, [fetchData]);

  /* ── Loading ── */
  if (loading) {
    return (
      <>
        <NetworkParticles />
        <div className="space-y-6">
          <div className="hero-gradient p-8 flex items-center justify-center">
            <div className="text-center">
              <div className="skeleton h-4 w-48 mx-auto mb-3" />
              <div className="skeleton h-10 w-24 mx-auto" />
            </div>
          </div>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            {[...Array(4)].map((_, i) => (
              <div key={i} className="card p-5">
                <div className="skeleton h-3 w-20 mb-3" />
                <div className="skeleton h-8 w-14" />
              </div>
            ))}
          </div>
        </div>
      </>
    );
  }

  /* ── Error ── */
  if (error) {
    return (
      <>
        <NetworkParticles />
        <div className="flex flex-col items-center justify-center min-h-[50vh]">
          <div className="card-accent p-10 max-w-md text-center">
            <div className="w-14 h-14 rounded-full mx-auto mb-5 flex items-center justify-center"
              style={{ background: "linear-gradient(135deg, rgba(0,200,170,0.1), rgba(139,92,246,0.08))" }}>
              <svg className="w-7 h-7 text-basis-cyan" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m9-.75a9 9 0 11-18 0 9 9 0 0118 0zm-9 3.75h.008v.008H12v-.008z" />
              </svg>
            </div>
            <h2 className="text-lg font-semibold text-basis-navy mb-2">L1 Node Unreachable</h2>
            <p className="text-sm text-basis-slate mb-4">
              Unable to connect to the Basis Network RPC endpoint. Ensure the Avalanche node is running.
            </p>
            <p className="text-[11px] text-basis-faint font-mono break-all">
              {process.env.NEXT_PUBLIC_RPC_URL}
            </p>
          </div>
        </div>
      </>
    );
  }

  const completionRate =
    stats && stats.totalMaintenanceOrders > 0
      ? Math.round((stats.completedOrders / stats.totalMaintenanceOrders) * 100)
      : 0;

  /* ── Dashboard ── */
  return (
    <>
      <NetworkParticles />

      <div className="space-y-8">
        {/* ── Hero ── */}
        <section className="hero-gradient px-8 py-10">
          <div className="flex flex-col md:flex-row items-center justify-between gap-6">
            <div>
              <p className="text-[11px] font-semibold uppercase tracking-widest text-basis-faint mb-1">Basis Network L1</p>
              <h2 className="text-4xl md:text-5xl font-bold tracking-tight">
                <span className="text-gradient">Block {stats?.blockNumber.toLocaleString()}</span>
              </h2>
              <p className="text-sm text-basis-slate mt-2">
                {stats?.gasPrice || "0"} Tomos gas &middot; {stats?.enterpriseCount} enterprises &middot; {stats?.totalEvents} events
              </p>
            </div>
            <div className="flex items-center gap-6">
              <div className="text-center">
                <p className="text-3xl font-bold text-gradient">{stats?.totalZKVerified}</p>
                <p className="text-[11px] text-basis-faint mt-0.5">ZK Proofs Verified</p>
              </div>
              <div className="w-px h-10 bg-black/[0.06]" />
              <div className="text-center">
                <p className="text-3xl font-bold text-basis-navy">{stats?.totalTxVerified}</p>
                <p className="text-[11px] text-basis-faint mt-0.5">Tx via Validium</p>
              </div>
            </div>
          </div>
        </section>

        {/* ── PLASMA ── */}
        <section>
          <p className="text-[11px] font-semibold uppercase tracking-widest text-basis-faint mb-3">PLASMA &middot; Industrial Maintenance</p>
          <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
            <StatCard title="Work Orders" value={stats?.totalMaintenanceOrders || 0} subtitle={`${completionRate}% completion`} />
            <StatCard title="Completed" value={stats?.completedOrders || 0} subtitle="Orders closed" accent />
            <StatCard
              title="Open Orders"
              value={(stats?.totalMaintenanceOrders || 0) - (stats?.completedOrders || 0)}
              subtitle="In progress"
              className="hidden md:block"
            />
          </div>
        </section>

        {/* ── Trace ── */}
        <section>
          <p className="text-[11px] font-semibold uppercase tracking-widest text-basis-faint mb-3">Trace &middot; Commercial ERP</p>
          <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
            <StatCard title="Sales" value={stats?.totalSales || 0} subtitle="On-chain records" accent />
            <StatCard title="Inventory" value={stats?.totalInventoryMovements || 0} subtitle="Stock movements" />
            <StatCard title="ZK Batches" value={stats?.totalZKBatches || 0} subtitle="Groth16 proofs" />
          </div>
        </section>

        {/* ── Enterprises ── */}
        <section>
          <p className="text-[11px] font-semibold uppercase tracking-widest text-basis-faint mb-3">Registered Enterprises</p>
          <EnterpriseList enterprises={enterprises} />
        </section>

        {/* ── Activity ── */}
        <section>
          <p className="text-[11px] font-semibold uppercase tracking-widest text-basis-faint mb-3">On-Chain Activity</p>
          <ActivityFeed activities={activities} />
        </section>
      </div>
    </>
  );
}
