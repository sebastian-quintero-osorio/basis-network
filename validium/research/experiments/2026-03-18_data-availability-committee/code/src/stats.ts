// RU-V6: Statistical utilities for benchmark analysis
// Reused pattern from prior experiments (RU-V1, RU-V4)

export interface Stats {
  mean: number;
  stdev: number;
  min: number;
  max: number;
  p50: number;
  p95: number;
  p99: number;
  ci95Lower: number;
  ci95Upper: number;
  n: number;
}

export function computeStats(values: number[]): Stats {
  if (values.length === 0) {
    throw new Error('Cannot compute stats on empty array');
  }

  const sorted = [...values].sort((a, b) => a - b);
  const n = sorted.length;
  const mean = sorted.reduce((a, b) => a + b, 0) / n;
  const variance = sorted.reduce((a, b) => a + (b - mean) ** 2, 0) / (n - 1 || 1);
  const stdev = Math.sqrt(variance);

  // Z=1.96 for 95% CI
  const ci95Margin = 1.96 * stdev / Math.sqrt(n);

  return {
    mean,
    stdev,
    min: sorted[0],
    max: sorted[n - 1],
    p50: sorted[Math.floor(n * 0.5)],
    p95: sorted[Math.floor(n * 0.95)],
    p99: sorted[Math.floor(n * 0.99)],
    ci95Lower: mean - ci95Margin,
    ci95Upper: mean + ci95Margin,
    n,
  };
}

export function formatStats(label: string, stats: Stats, unit: string = 'ms'): string {
  const ciWidth = stats.ci95Upper - stats.ci95Lower;
  const ciPct = stats.mean > 0 ? ((ciWidth / 2) / stats.mean * 100).toFixed(1) : '0.0';
  return [
    `  ${label}:`,
    `    mean=${stats.mean.toFixed(3)}${unit}  stdev=${stats.stdev.toFixed(3)}${unit}`,
    `    min=${stats.min.toFixed(3)}  p50=${stats.p50.toFixed(3)}  p95=${stats.p95.toFixed(3)}  p99=${stats.p99.toFixed(3)}  max=${stats.max.toFixed(3)}`,
    `    95% CI=[${stats.ci95Lower.toFixed(3)}, ${stats.ci95Upper.toFixed(3)}] (+-${ciPct}% of mean)`,
    `    n=${stats.n}`,
  ].join('\n');
}
