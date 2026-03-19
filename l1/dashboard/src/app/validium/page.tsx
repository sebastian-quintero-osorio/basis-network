"use client";

import { useNetwork } from "@/lib/NetworkContext";
import StatCard from "@/components/StatCard";

function truncateHash(hash: string): string {
  if (hash.length <= 18) return hash;
  return hash.slice(0, 10) + "..." + hash.slice(-6);
}

function truncateAddress(addr: string): string {
  return addr.slice(0, 6) + "..." + addr.slice(-4);
}

export default function ValidiumPage() {
  const {
    loading,
    totalStateBatches,
    verifyingKeySet,
    dacCommitteeSize,
    dacThreshold,
    dacTotalCertified,
    validiumBatches,
  } = useNetwork();

  if (loading) {
    return (
      <div className="space-y-6">
        <div>
          <div className="skeleton h-7 w-48 mb-2" />
          <div className="skeleton h-4 w-72" />
        </div>
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className="card-static p-5 space-y-3">
              <div className="skeleton h-3 w-20" />
              <div className="skeleton h-8 w-16" />
            </div>
          ))}
        </div>
        <div className="card-static p-5 space-y-3">
          <div className="skeleton h-4 w-32" />
          <div className="skeleton h-32 w-full" />
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="animate-in">
        <h1 className="text-2xl font-extrabold tracking-tight text-zinc-800">
          ZK Validium
        </h1>
        <p className="text-sm text-zinc-500 mt-1">
          Enterprise ZK state commitment and data availability
        </p>
      </div>

      {/* Stats Row */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          title="State Batches"
          value={totalStateBatches}
          subtitle="Committed on L1"
          accent
          className="animate-in delay-1"
        />
        <StatCard
          title="Verifying Key"
          value={verifyingKeySet ? "Active" : "Pending"}
          subtitle="Groth16 circuit key"
          className="animate-in delay-2"
        />
        <StatCard
          title="DAC Committee"
          value={dacCommitteeSize > 0 ? `${dacThreshold}/${dacCommitteeSize}` : "---"}
          subtitle="Threshold / Members"
          className="animate-in delay-3"
        />
        <StatCard
          title="DAC Certified"
          value={dacTotalCertified}
          subtitle="Attestation certificates"
          className="animate-in delay-4"
        />
      </div>

      {/* Architecture Overview */}
      <div className="card-static p-6 animate-in delay-3">
        <h2 className="text-[11px] font-semibold uppercase tracking-widest text-zinc-400 mb-4">
          Pipeline Architecture
        </h2>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
          {[
            {
              step: "1",
              label: "Ingest",
              desc: "REST API + WAL",
              color: "from-emerald-400 to-teal-400",
            },
            {
              step: "2",
              label: "Batch",
              desc: "SMT + Witness",
              color: "from-teal-400 to-cyan-400",
            },
            {
              step: "3",
              label: "Prove",
              desc: "Groth16 ZK",
              color: "from-cyan-400 to-sky-400",
            },
            {
              step: "4",
              label: "Submit",
              desc: "L1 Commit",
              color: "from-sky-400 to-blue-400",
            },
          ].map((item) => (
            <div key={item.step} className="text-center p-4 rounded-xl bg-white/30">
              <div
                className={`w-8 h-8 rounded-full bg-gradient-to-br ${item.color} mx-auto mb-2 flex items-center justify-center text-white text-xs font-bold`}
              >
                {item.step}
              </div>
              <p className="text-[13px] font-semibold text-zinc-700">
                {item.label}
              </p>
              <p className="text-[11px] text-zinc-400">{item.desc}</p>
            </div>
          ))}
        </div>
      </div>

      {/* Two-column: Batch History + Node Status */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        {/* Batch History Table */}
        <div className="lg:col-span-2 card-static p-5 animate-in delay-4">
          <h2 className="text-[11px] font-semibold uppercase tracking-widest text-zinc-400 mb-4">
            State Commitment History
          </h2>
          {validiumBatches.length === 0 ? (
            <div className="text-center py-8 text-zinc-400 text-sm">
              No batches committed yet. The validium node will submit ZK-proven
              state transitions here.
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-left">
                <thead>
                  <tr className="border-b border-black/[0.04]">
                    <th className="text-[10px] font-semibold uppercase tracking-widest text-zinc-400 pb-3 pr-4">
                      Batch
                    </th>
                    <th className="text-[10px] font-semibold uppercase tracking-widest text-zinc-400 pb-3 pr-4">
                      Prev Root
                    </th>
                    <th className="text-[10px] font-semibold uppercase tracking-widest text-zinc-400 pb-3 pr-4">
                      New Root
                    </th>
                    <th className="text-[10px] font-semibold uppercase tracking-widest text-zinc-400 pb-3 pr-4">
                      Enterprise
                    </th>
                    <th className="text-[10px] font-semibold uppercase tracking-widest text-zinc-400 pb-3">
                      Block
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {validiumBatches.slice(0, 10).map((batch) => (
                    <tr
                      key={batch.batchId}
                      className="border-b border-black/[0.02] hover:bg-white/30 transition-colors"
                    >
                      <td className="py-2.5 pr-4 font-mono text-xs text-zinc-700 font-medium">
                        #{batch.batchId}
                      </td>
                      <td className="py-2.5 pr-4 font-mono text-[11px] text-zinc-500">
                        {truncateHash(batch.prevRoot)}
                      </td>
                      <td className="py-2.5 pr-4 font-mono text-[11px] text-zinc-500">
                        {truncateHash(batch.newRoot)}
                      </td>
                      <td className="py-2.5 pr-4 font-mono text-[11px] text-zinc-500">
                        {truncateAddress(batch.enterprise)}
                      </td>
                      <td className="py-2.5 font-mono text-[11px] text-zinc-400">
                        {batch.blockNumber.toLocaleString()}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {/* Node Status / DAC Panel */}
        <div className="space-y-4 animate-in delay-5">
          {/* ZK Circuit Card */}
          <div className="card-static p-5">
            <h2 className="text-[11px] font-semibold uppercase tracking-widest text-zinc-400 mb-3">
              ZK Circuit
            </h2>
            <div className="space-y-2">
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Scheme</span>
                <span className="text-zinc-700 font-medium">Groth16</span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Curve</span>
                <span className="text-zinc-700 font-medium">BN254</span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Depth</span>
                <span className="text-zinc-700 font-medium font-mono">32</span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Batch Size</span>
                <span className="text-zinc-700 font-medium font-mono">8</span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Constraints</span>
                <span className="text-zinc-700 font-medium font-mono">
                  274,291
                </span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Verifying Key</span>
                <span
                  className={`font-medium ${
                    verifyingKeySet ? "text-emerald-600" : "text-zinc-400"
                  }`}
                >
                  {verifyingKeySet ? "Active" : "Pending"}
                </span>
              </div>
            </div>
          </div>

          {/* DAC Status Card */}
          <div className="card-static p-5">
            <h2 className="text-[11px] font-semibold uppercase tracking-widest text-zinc-400 mb-3">
              Data Availability
            </h2>
            <div className="space-y-2">
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Protocol</span>
                <span className="text-zinc-700 font-medium">
                  Shamir (k,n)-SS
                </span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Committee</span>
                <span className="text-zinc-700 font-medium font-mono">
                  {dacCommitteeSize > 0
                    ? `${dacCommitteeSize} members`
                    : "---"}
                </span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Threshold</span>
                <span className="text-zinc-700 font-medium font-mono">
                  {dacThreshold > 0
                    ? `${dacThreshold} of ${dacCommitteeSize}`
                    : "---"}
                </span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Certified</span>
                <span className="text-zinc-700 font-medium font-mono">
                  {dacTotalCertified}
                </span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Privacy</span>
                <span className="text-emerald-600 font-medium">
                  Information-theoretic
                </span>
              </div>
            </div>
          </div>

          {/* State Machine Card */}
          <div className="card-static p-5">
            <h2 className="text-[11px] font-semibold uppercase tracking-widest text-zinc-400 mb-3">
              State Machine
            </h2>
            <div className="space-y-2">
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Pipeline</span>
                <span className="text-zinc-700 font-medium">Pipelined FSM</span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">States</span>
                <span className="text-zinc-700 font-medium font-mono">6</span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Crash Recovery</span>
                <span className="text-emerald-600 font-medium">WAL + Checkpoint</span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-zinc-500">Verification</span>
                <span className="text-emerald-600 font-medium">TLA+ / Coq</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
