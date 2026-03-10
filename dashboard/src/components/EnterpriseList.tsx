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
      <div className="card p-8 text-center text-basis-slate text-sm">
        No enterprises registered yet.
      </div>
    );
  }

  return (
    <div className="card overflow-hidden">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-black/[0.04]">
            <th className="text-left px-5 py-3 text-[11px] font-semibold uppercase tracking-widest text-basis-faint">Enterprise</th>
            <th className="text-left px-5 py-3 text-[11px] font-semibold uppercase tracking-widest text-basis-faint">Address</th>
            <th className="text-left px-5 py-3 text-[11px] font-semibold uppercase tracking-widest text-basis-faint">Status</th>
            <th className="text-left px-5 py-3 text-[11px] font-semibold uppercase tracking-widest text-basis-faint">Registered</th>
          </tr>
        </thead>
        <tbody>
          {enterprises.map((e) => (
            <tr key={e.address} className="border-b border-black/[0.03] last:border-0 hover:bg-black/[0.01] transition-colors">
              <td className="px-5 py-3.5 font-medium text-basis-navy">{e.name}</td>
              <td className="px-5 py-3.5 font-mono text-xs text-basis-slate">
                {e.address.slice(0, 6)}...{e.address.slice(-4)}
              </td>
              <td className="px-5 py-3.5">
                <span className={`inline-block px-2.5 py-0.5 rounded-full text-[11px] font-medium ${e.active ? "pill-active" : "pill-inactive"}`}>
                  {e.active ? "Active" : "Inactive"}
                </span>
              </td>
              <td className="px-5 py-3.5 text-xs text-basis-slate">{e.registeredAt}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
