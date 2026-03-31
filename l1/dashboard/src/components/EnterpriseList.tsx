"use client";

import type { Enterprise } from "@/lib/contracts";

interface EnterpriseListProps {
  enterprises: Enterprise[];
}

export default function EnterpriseList({ enterprises }: EnterpriseListProps) {
  if (enterprises.length === 0) {
    return (
      <div className="card-static p-10 text-center">
        <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="mx-auto mb-3 text-zinc-300">
          <path d="M6 22V4a2 2 0 012-2h8a2 2 0 012 2v18" />
          <path d="M6 12H4a2 2 0 00-2 2v6a2 2 0 002 2h2" />
          <path d="M18 9h2a2 2 0 012 2v9a2 2 0 01-2 2h-2" />
          <path d="M10 6h4" /><path d="M10 10h4" /><path d="M10 14h4" /><path d="M10 18h4" />
        </svg>
        <p className="text-sm text-zinc-400">No enterprises registered yet.</p>
        <p className="text-xs text-zinc-300 mt-1">Authorized enterprises will appear once registered on-chain.</p>
      </div>
    );
  }

  return (
    <div className="card-static overflow-hidden">
      {/* Desktop Table */}
      <div className="hidden sm:block">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-black/[0.04]">
              <th className="text-left px-5 py-3 text-[11px] font-semibold uppercase tracking-widest text-zinc-400">
                Enterprise
              </th>
              <th className="text-left px-5 py-3 text-[11px] font-semibold uppercase tracking-widest text-zinc-400">
                Address
              </th>
              <th className="text-left px-5 py-3 text-[11px] font-semibold uppercase tracking-widest text-zinc-400">
                Status
              </th>
              <th className="text-left px-5 py-3 text-[11px] font-semibold uppercase tracking-widest text-zinc-400">
                Registered
              </th>
            </tr>
          </thead>
          <tbody>
            {enterprises.map((e) => (
              <tr
                key={e.address}
                className="border-b border-black/[0.03] last:border-0 hover:bg-white/30 transition-colors"
              >
                <td className="px-5 py-3.5 font-medium text-zinc-800">
                  {e.name}
                </td>
                <td className="px-5 py-3.5 font-mono text-xs text-zinc-500">
                  {e.address.slice(0, 6)}...{e.address.slice(-4)}
                </td>
                <td className="px-5 py-3.5">
                  <span
                    className={`inline-block px-2.5 py-0.5 rounded-full text-[11px] font-medium ${
                      e.active ? "pill-active" : "pill-inactive"
                    }`}
                  >
                    {e.active ? "Active" : "Inactive"}
                  </span>
                </td>
                <td className="px-5 py-3.5 text-xs text-zinc-500">
                  {e.registeredAt}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Mobile Cards */}
      <div className="sm:hidden divide-y divide-black/[0.03]">
        {enterprises.map((e) => (
          <div key={e.address} className="px-5 py-4 space-y-2">
            <div className="flex items-center justify-between">
              <span className="font-medium text-zinc-800">{e.name}</span>
              <span
                className={`px-2 py-0.5 rounded-full text-[10px] font-medium ${
                  e.active ? "pill-active" : "pill-inactive"
                }`}
              >
                {e.active ? "Active" : "Inactive"}
              </span>
            </div>
            <div className="flex items-center justify-between text-xs text-zinc-500">
              <span className="font-mono">
                {e.address.slice(0, 6)}...{e.address.slice(-4)}
              </span>
              <span>{e.registeredAt}</span>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
