"use client";

import { useState } from "react";
import { useNetwork } from "@/lib/NetworkContext";
import ActivityFeed from "@/components/ActivityFeed";

const filterTypes = [
  { key: "all", label: "All" },
  { key: "registry", label: "Registry" },
  { key: "traceability", label: "Traceability" },
  { key: "zk", label: "Verification" },
  { key: "state", label: "State" },
  { key: "dac", label: "DAC" },
  { key: "crossref", label: "Cross-Ref" },
];

export default function ActivityPage() {
  const { activities, loading } = useNetwork();
  const [filter, setFilter] = useState("all");

  const filtered =
    filter === "all"
      ? activities
      : activities.filter((a) => a.type === filter);

  if (loading) {
    return (
      <div className="space-y-6">
        <div>
          <div className="skeleton h-7 w-28 mb-2" />
          <div className="skeleton h-4 w-64" />
        </div>
        <div className="flex gap-2">
          {[...Array(4)].map((_, i) => (
            <div key={i} className="skeleton h-8 w-24 rounded-xl" />
          ))}
        </div>
        <div className="space-y-3 pl-8">
          {[...Array(6)].map((_, i) => (
            <div key={i} className="skeleton h-12 w-full" />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="animate-in">
        <h1 className="text-2xl font-extrabold tracking-tight text-zinc-800">
          Activity
        </h1>
        <p className="text-sm text-zinc-500 mt-1">
          On-chain event feed from protocol contracts
        </p>
      </div>

      {/* Filter Buttons */}
      <div className="flex flex-wrap gap-2 animate-in delay-1">
        {filterTypes.map((t) => (
          <button
            key={t.key}
            onClick={() => setFilter(t.key)}
            className={`px-3.5 py-1.5 rounded-xl text-xs font-medium transition-all duration-150 ${
              filter === t.key
                ? "bg-white/60 text-zinc-800 shadow-sm border border-white/60"
                : "text-zinc-500 hover:text-zinc-700 hover:bg-white/30"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* Activity Feed */}
      <div className="animate-in delay-2">
        <ActivityFeed activities={filtered} />
      </div>

      {filter !== "all" && filtered.length === 0 && activities.length > 0 && (
        <p className="text-sm text-zinc-500 animate-in delay-2">
          No {filterTypes.find((t) => t.key === filter)?.label} events
          recorded.
        </p>
      )}
    </div>
  );
}
