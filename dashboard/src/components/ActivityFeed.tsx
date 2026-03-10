"use client";

interface Activity {
  type: string;
  description: string;
  timestamp: string;
  blockNumber?: number;
}

interface ActivityFeedProps {
  activities: Activity[];
}

const badgeClass: Record<string, string> = {
  plasma: "badge-plasma",
  trace: "badge-trace",
  zk: "badge-zk",
  enterprise: "badge-enterprise",
};

const badgeLabel: Record<string, string> = {
  plasma: "PLASMA",
  trace: "Trace",
  zk: "ZK",
  enterprise: "Registry",
};

const dotColor: Record<string, string> = {
  plasma: "#F97316",
  trace: "#3B82F6",
  zk: "#8B5CF6",
  enterprise: "#00C8AA",
};

export default function ActivityFeed({ activities }: ActivityFeedProps) {
  if (activities.length === 0) {
    return (
      <div className="card p-8 text-center text-basis-slate text-sm">
        No on-chain activity recorded yet.
      </div>
    );
  }

  return (
    <div className="relative pl-8">
      <div className="timeline-line" />
      <div className="space-y-3">
        {activities.map((a, i) => (
          <div key={i} className="relative flex items-start gap-4">
            <div
              className="timeline-dot mt-3.5 -ml-8"
              style={{ borderColor: dotColor[a.type] || "#00C8AA" }}
            />
            <div className="card px-4 py-3 flex-1 flex items-center gap-3">
              <span className={`badge ${badgeClass[a.type] || "badge-enterprise"}`}>
                {badgeLabel[a.type] || a.type}
              </span>
              <span className="text-sm text-basis-navy flex-1">{a.description}</span>
              <div className="flex items-center gap-2 shrink-0">
                {a.blockNumber !== undefined && (
                  <span className="text-[11px] text-basis-faint font-mono">#{a.blockNumber}</span>
                )}
                <span className="text-[11px] text-basis-faint">{a.timestamp}</span>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
