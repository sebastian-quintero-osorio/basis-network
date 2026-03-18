"use client";

import { useNetwork } from "@/lib/NetworkContext";
import StatCard from "@/components/StatCard";
import BlockList from "@/components/BlockList";
import ActivityFeed from "@/components/ActivityFeed";

function OverviewSkeleton() {
  return (
    <div className="space-y-8">
      <div>
        <div className="skeleton h-7 w-32 mb-2" />
        <div className="skeleton h-4 w-56" />
      </div>
      <div className="hero-card px-8 py-10">
        <div className="skeleton h-5 w-28 mb-3" />
        <div className="skeleton h-12 w-48 mb-3" />
        <div className="skeleton h-4 w-64" />
      </div>
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        {[...Array(4)].map((_, i) => (
          <div key={i} className="card-static p-5">
            <div className="skeleton h-3 w-20 mb-3" />
            <div className="skeleton h-8 w-14" />
          </div>
        ))}
      </div>
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div className="card-static p-5 space-y-3">
          {[...Array(5)].map((_, i) => (
            <div key={i} className="skeleton h-10 w-full" />
          ))}
        </div>
        <div className="card-static p-5 space-y-3">
          {[...Array(5)].map((_, i) => (
            <div key={i} className="skeleton h-10 w-full" />
          ))}
        </div>
      </div>
    </div>
  );
}

export default function OverviewPage() {
  const {
    loading,
    connected,
    blockNumber,
    gasPrice,
    enterpriseCount,
    totalEvents,
    totalZKBatches,
    totalZKVerified,
    totalTxVerified,
    recentBlocks,
    activities,
  } = useNetwork();

  if (loading) return <OverviewSkeleton />;

  return (
    <div className="space-y-8">
      {/* Page Header */}
      <div className="animate-in">
        <h1 className="text-2xl font-extrabold tracking-tight text-zinc-800">
          Overview
        </h1>
        <p className="text-sm text-zinc-500 mt-1">
          Real-time Basis Network L1 monitoring
        </p>
      </div>

      {/* Network Hero */}
      <div className="hero-card px-6 sm:px-8 py-8 sm:py-10 animate-in delay-1">
        <div className="flex flex-col lg:flex-row items-start lg:items-center justify-between gap-6">
          <div>
            <p className="text-[11px] font-semibold uppercase tracking-widest text-zinc-400 mb-1.5">
              Latest Block
            </p>
            <h2 className="text-4xl sm:text-5xl font-extrabold tracking-tight gradient-text">
              {blockNumber > 0 ? blockNumber.toLocaleString() : "--"}
            </h2>
            <div className="flex flex-wrap items-center gap-3 mt-3 text-sm text-zinc-500">
              <span>{gasPrice} Gwei gas</span>
              <span className="w-px h-4 bg-zinc-200" />
              <span>Chain 43199</span>
              <span className="w-px h-4 bg-zinc-200" />
              <span className="flex items-center gap-1.5">
                {connected ? (
                  <>
                    <span className="w-2 h-2 rounded-full bg-emerald-400 pulse-live" />
                    <span className="text-emerald-600 font-medium">Connected</span>
                  </>
                ) : (
                  <>
                    <span className="w-2 h-2 rounded-full bg-red-400" />
                    <span className="text-red-500">Disconnected</span>
                  </>
                )}
              </span>
            </div>
          </div>

          <div className="flex items-center gap-6">
            <div className="text-center">
              <p className="text-3xl font-bold gradient-text">
                {totalZKVerified}
              </p>
              <p className="text-[11px] text-zinc-400 mt-0.5">ZK Proofs</p>
            </div>
            <div className="w-px h-10 bg-zinc-200" />
            <div className="text-center">
              <p className="text-3xl font-bold text-zinc-800">
                {totalTxVerified}
              </p>
              <p className="text-[11px] text-zinc-400 mt-0.5">Validated Tx</p>
            </div>
          </div>
        </div>
      </div>

      {/* Stat Cards */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          title="Enterprises"
          value={enterpriseCount}
          subtitle="Registered"
          className="animate-in delay-2"
        />
        <StatCard
          title="On-Chain Events"
          value={totalEvents}
          subtitle="Total recorded"
          className="animate-in delay-3"
        />
        <StatCard
          title="ZK Batches"
          value={totalZKBatches}
          subtitle="Groth16 proofs"
          accent
          className="animate-in delay-4"
        />
        <StatCard
          title="Tx Validated"
          value={totalTxVerified}
          subtitle="Via ZK proofs"
          className="animate-in delay-5"
        />
      </div>

      {/* Two Columns: Blocks + Activity */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div className="animate-in delay-5">
          <h3 className="text-[11px] font-semibold uppercase tracking-widest text-zinc-400 mb-3">
            Recent Blocks
          </h3>
          <BlockList blocks={recentBlocks} />
        </div>
        <div className="animate-in delay-6">
          <h3 className="text-[11px] font-semibold uppercase tracking-widest text-zinc-400 mb-3">
            Recent Activity
          </h3>
          <ActivityFeed activities={activities} compact />
        </div>
      </div>
    </div>
  );
}
