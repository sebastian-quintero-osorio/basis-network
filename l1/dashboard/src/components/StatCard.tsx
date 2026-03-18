"use client";

interface StatCardProps {
  title: string;
  value: string | number;
  subtitle?: string;
  accent?: boolean;
  className?: string;
}

export default function StatCard({
  title,
  value,
  subtitle,
  accent = false,
  className = "",
}: StatCardProps) {
  return (
    <div className={`card-static p-5 ${className}`}>
      <p className="text-[11px] font-semibold uppercase tracking-widest text-zinc-400 mb-2">
        {title}
      </p>
      <p
        className={`text-3xl font-bold tracking-tight ${
          accent ? "gradient-text" : "text-zinc-800"
        }`}
      >
        {typeof value === "number" ? value.toLocaleString() : value}
      </p>
      {subtitle && (
        <p className="text-[12px] text-zinc-500 mt-1">{subtitle}</p>
      )}
    </div>
  );
}
