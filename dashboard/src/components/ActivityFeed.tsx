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
};

const badgeLabel: Record<string, string> = {
  registry: "Registry",
  traceability: "Traceability",
  zk: "Verification",
};

const dotColor: Record<string, string> = {
  registry: "#00FFCC",
  traceability: "#3B82F6",
  zk: "#00CCFF",
};

export default function ActivityFeed({
  activities,
  compact = false,
}: ActivityFeedProps) {
  if (activities.length === 0) {
    return (
      <div className="card-static p-8 text-center text-zinc-500 text-sm">
        No on-chain activity recorded yet.
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
