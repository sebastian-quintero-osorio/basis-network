"use client";

interface Activity {
  type: string;
  description: string;
  timestamp: string;
  txHash?: string;
}

interface ActivityFeedProps {
  activities: Activity[];
}

const typeColors: Record<string, string> = {
  MAINTENANCE: "text-orange-400 bg-orange-900/20",
  SALE: "text-blue-400 bg-blue-900/20",
  INVENTORY: "text-purple-400 bg-purple-900/20",
  SUPPLIER: "text-cyan-400 bg-cyan-900/20",
  INSPECTION: "text-yellow-400 bg-yellow-900/20",
  ZK_PROOF: "text-green-400 bg-green-900/20",
  ENTERPRISE: "text-basis-primary bg-red-900/20",
};

export default function ActivityFeed({ activities }: ActivityFeedProps) {
  if (activities.length === 0) {
    return (
      <div className="bg-basis-surface border border-basis-border rounded-lg p-6 text-center text-gray-500">
        No activity yet. Deploy contracts and start writing data on-chain.
      </div>
    );
  }

  return (
    <div className="bg-basis-surface border border-basis-border rounded-lg divide-y divide-basis-border">
      {activities.map((activity, i) => (
        <div key={i} className="px-4 py-3 flex items-center gap-3">
          <span
            className={`px-2 py-0.5 rounded text-xs font-medium whitespace-nowrap ${
              typeColors[activity.type] || "text-gray-400 bg-gray-800"
            }`}
          >
            {activity.type}
          </span>
          <span className="text-sm text-gray-300 flex-1">{activity.description}</span>
          <span className="text-xs text-gray-500 whitespace-nowrap">{activity.timestamp}</span>
        </div>
      ))}
    </div>
  );
}
