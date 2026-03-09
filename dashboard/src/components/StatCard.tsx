"use client";

interface StatCardProps {
  title: string;
  value: string | number;
  subtitle?: string;
  variant?: "default" | "accent" | "warning";
}

export default function StatCard({ title, value, subtitle, variant = "default" }: StatCardProps) {
  const borderColor =
    variant === "accent"
      ? "border-basis-accent"
      : variant === "warning"
        ? "border-yellow-500"
        : "border-basis-border";

  return (
    <div className={`bg-basis-surface border ${borderColor} rounded-lg p-5`}>
      <p className="text-sm text-gray-400 mb-1">{title}</p>
      <p className="text-2xl font-bold text-white">{value}</p>
      {subtitle && <p className="text-xs text-gray-500 mt-1">{subtitle}</p>}
    </div>
  );
}
