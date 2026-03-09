"use client";

interface Enterprise {
  address: string;
  name: string;
  active: boolean;
  registeredAt: string;
}

interface EnterpriseListProps {
  enterprises: Enterprise[];
}

export default function EnterpriseList({ enterprises }: EnterpriseListProps) {
  if (enterprises.length === 0) {
    return (
      <div className="bg-basis-surface border border-basis-border rounded-lg p-6 text-center text-gray-500">
        No enterprises registered yet.
      </div>
    );
  }

  return (
    <div className="bg-basis-surface border border-basis-border rounded-lg overflow-hidden">
      <table className="w-full text-sm">
        <thead className="bg-basis-dark">
          <tr>
            <th className="text-left px-4 py-3 text-gray-400 font-medium">Enterprise</th>
            <th className="text-left px-4 py-3 text-gray-400 font-medium">Address</th>
            <th className="text-left px-4 py-3 text-gray-400 font-medium">Status</th>
            <th className="text-left px-4 py-3 text-gray-400 font-medium">Registered</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-basis-border">
          {enterprises.map((e) => (
            <tr key={e.address} className="hover:bg-basis-dark/50">
              <td className="px-4 py-3 text-white font-medium">{e.name}</td>
              <td className="px-4 py-3 text-gray-400 font-mono text-xs">
                {e.address.slice(0, 6)}...{e.address.slice(-4)}
              </td>
              <td className="px-4 py-3">
                <span
                  className={`px-2 py-0.5 rounded text-xs font-medium ${
                    e.active
                      ? "bg-green-900/30 text-green-400"
                      : "bg-red-900/30 text-red-400"
                  }`}
                >
                  {e.active ? "Active" : "Inactive"}
                </span>
              </td>
              <td className="px-4 py-3 text-gray-400">{e.registeredAt}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
