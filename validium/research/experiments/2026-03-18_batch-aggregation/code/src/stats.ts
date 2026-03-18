/// Statistical utilities for benchmark analysis.

export function mean(arr: number[]): number {
  if (arr.length === 0) return 0;
  return arr.reduce((sum, v) => sum + v, 0) / arr.length;
}

export function stdev(arr: number[]): number {
  if (arr.length < 2) return 0;
  const m = mean(arr);
  const variance = arr.reduce((sum, v) => sum + (v - m) ** 2, 0) / (arr.length - 1);
  return Math.sqrt(variance);
}

export function percentile(arr: number[], p: number): number {
  if (arr.length === 0) return 0;
  const sorted = [...arr].sort((a, b) => a - b);
  const idx = Math.ceil((p / 100) * sorted.length) - 1;
  return sorted[Math.max(0, idx)];
}

export function ci95(arr: number[]): { lower: number; upper: number; halfWidth: number } {
  const m = mean(arr);
  const se = stdev(arr) / Math.sqrt(arr.length);
  const z = 1.96; // 95% CI
  return {
    lower: m - z * se,
    upper: m + z * se,
    halfWidth: z * se,
  };
}

/// Check if 95% CI half-width is less than 10% of the mean.
export function ciWithinThreshold(arr: number[], threshold: number = 0.1): boolean {
  const m = mean(arr);
  if (m === 0) return true;
  const { halfWidth } = ci95(arr);
  return halfWidth / Math.abs(m) < threshold;
}

export function formatNumber(n: number, decimals: number = 2): string {
  return n.toFixed(decimals);
}

export function formatLatency(us: number): string {
  if (us < 1000) return `${formatNumber(us, 1)} us`;
  if (us < 1000000) return `${formatNumber(us / 1000, 2)} ms`;
  return `${formatNumber(us / 1000000, 2)} s`;
}
