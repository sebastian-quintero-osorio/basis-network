"use client";

import type { Activity } from "@/lib/contracts";

interface ActivityFeedProps {
  activities: Activity[];
  compact?: boolean;
}

const badgeClass: Record<string, string> = {
  registry: "badge-registry",
  traceability: "badge-traceability",
  zk: "badge-zk",
  state: "badge-state",
  dac: "badge-dac",
  crossref: "badge-crossref",
};

const badgeLabel: Record<string, string> = {
  registry: "Registry",
  traceability: "Traceability",
  zk: "Verification",
  state: "State",
  dac: "DAC",
  crossref: "Cross-Ref",
};

const dotColor: Record<string, string> = {
  registry: "#00FFCC",
  traceability: "#3B82F6",
  zk: "#00CCFF",
  state: "#F59E0B",
  dac: "#8B5CF6",
  crossref: "#EC4899",
};

export default function ActivityFeed({
  activities,
  compact = false,
}: ActivityFeedProps) {
  if (activities.length === 0) {
    return (
      <div className="card-static p-10 text-center">
        <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="mx-auto mb-3 text-zinc-300">
          <polyline points="22 12 18 12 15 21 9 3 6 12 2 12" />
        </svg>
        <p className="text-sm text-zinc-400">No on-chain activity recorded yet.</p>
        <p className="text-xs text-zinc-300 mt-1">Events from protocol contracts will appear here in real time.</p>
      </div>
    );
  }

  const items = compact ? activities.slice(0, 6) : activities;

  return (
    <div className="relative pl-8">
      <div className="timeline-line" />
      <div className="space-y-2.5">
        {items.map((a, i) => (
          <div key={i} className="relative flex items-start gap-3">
            <div
              className="timeline-dot mt-3 -ml-8"
              style={{ borderColor: dotColor[a.type] || "#00FFCC" }}
            />
            <div className="card-static px-4 py-3 flex-1">
              <div className="flex flex-wrap items-center gap-2">
                <span
                  className={`badge ${
                    badgeClass[a.type] || "badge-registry"
                  }`}
                >
                  {badgeLabel[a.type] || a.type}
                </span>
                <span className="text-sm text-zinc-700 flex-1 min-w-0">
                  {a.description}
                </span>
                <div className="flex items-center gap-2 shrink-0">
                  {a.blockNumber !== undefined && (
                    <span className="text-[11px] text-zinc-400 font-mono">
                      #{a.blockNumber.toLocaleString()}
                    </span>
                  )}
                  <span className="text-[11px] text-zinc-400">
                    {a.timestamp}
                  </span>
                </div>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
