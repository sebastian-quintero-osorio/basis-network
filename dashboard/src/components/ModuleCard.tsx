"use client";

interface ModuleMetric {
  label: string;
  value: number;
}

interface ModuleData {
  name: string;
  category: string;
  address?: string;
  description: string;
  metrics: ModuleMetric[];
}

interface ModuleCardProps {
  module: ModuleData;
  className?: string;
}

export default function ModuleCard({ module, className = "" }: ModuleCardProps) {
  const deployed = !!module.address;

  return (
    <div
      className={`card-static p-6 ${
        deployed ? "module-deployed" : "module-pending"
      } ${className}`}
    >
      <div className="flex items-start justify-between mb-3">
        <div>
          <h3 className="font-semibold text-zinc-800">{module.name}</h3>
          <p className="text-[11px] text-zinc-400 mt-0.5 uppercase tracking-wider">
            {module.category}
          </p>
        </div>
        <span
          className={`inline-block px-2.5 py-0.5 rounded-full text-[10px] font-semibold uppercase tracking-wider ${
            deployed ? "pill-active" : "pill-pending"
          }`}
        >
          {deployed ? "Deployed" : "Pending"}
        </span>
      </div>

      <p className="text-sm text-zinc-500 mb-4 leading-relaxed">
        {module.description}
      </p>

      {deployed && (
        <>
          <p className="text-[11px] text-zinc-400 font-mono mb-4">
            {module.address!.slice(0, 6)}...{module.address!.slice(-4)}
          </p>
          {module.metrics.length > 0 && (
            <div className="flex gap-6 pt-3 border-t border-black/[0.04]">
              {module.metrics.map((m) => (
                <div key={m.label}>
                  <p className="text-xl font-bold text-zinc-800">
                    {m.value.toLocaleString()}
                  </p>
                  <p className="text-[11px] text-zinc-400">{m.label}</p>
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </div>
  );
}
