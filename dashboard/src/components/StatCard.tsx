"use client";

interface StatCardProps {
  title: string;
  value: string | number;
  subtitle?: string;
  accent?: boolean;
  className?: string;
}

export default function StatCard({ title, value, subtitle, accent = false, className = "" }: StatCardProps) {
  return (
    <div className={`${accent ? "card-accent" : "card"} p-5 ${className}`}>
      <p className="text-[11px] font-semibold uppercase tracking-widest text-basis-faint mb-2">{title}</p>
      <p className={`text-3xl font-bold tracking-tight ${accent ? "text-gradient" : "text-basis-navy"}`}>
        {value}
      </p>
      {subtitle && <p className="text-[12px] text-basis-slate mt-1">{subtitle}</p>}
    </div>
  );
}
