import { existsSync, mkdirSync, writeFileSync } from "fs";
import { join } from "path";
import { PersistentQueue } from "./persistent-queue.js";
import { BatchAggregator } from "./batch-aggregator.js";
import { TransactionGenerator } from "./tx-generator.js";
import { mean, stdev, percentile, ci95, ciWithinThreshold, formatNumber } from "./stats.js";
import type {
  AggregationStrategy,
  BenchmarkConfig,
  BenchmarkResult,
  Batch,
} from "./types.js";

const RESULTS_DIR = join(import.meta.dirname, "..", "..", "results");
const WAL_DIR = join(import.meta.dirname, "..", "..", "results", "wal");

function ensureDirs(): void {
  if (!existsSync(RESULTS_DIR)) mkdirSync(RESULTS_DIR, { recursive: true });
  if (!existsSync(WAL_DIR)) mkdirSync(WAL_DIR, { recursive: true });
}

/// Run a single benchmark configuration for one replication.
function runSingleBenchmark(config: BenchmarkConfig, replicationId: number, suiteId: number): BenchmarkResult {
  const walPath = join(WAL_DIR, `wal_s${suiteId}_rep${replicationId}.jsonl`);
  const queue = new PersistentQueue({
    ...config.queueConfig,
    walPath,
  });
  queue.reset();

  const aggregator = new BatchAggregator(queue, config.batchConfig);
  const generator = new TransactionGenerator("enterprise-bench");

  const batches: Batch[] = [];
  const txCount = Math.ceil((config.durationMs / 60000) * config.arrivalRate);

  // Enqueue all transactions (simulating arrival)
  const enqueueStart = performance.now();
  for (let i = 0; i < txCount; i++) {
    const tx = generator.generate();
    queue.enqueue(tx);

    // Check if batch should form after each enqueue
    const batch = aggregator.formBatch("enterprise-bench");
    if (batch) {
      batches.push(batch);
    }
  }

  // Flush remaining transactions
  let remaining = aggregator.forceBatch("enterprise-bench");
  while (remaining) {
    batches.push(remaining);
    remaining = aggregator.forceBatch("enterprise-bench");
  }

  const totalTimeMs = performance.now() - enqueueStart;

  // Discard warmup batches
  const measuredBatches = batches.slice(config.warmupBatches);

  // Collect metrics
  const walLatencies = queue.getWalWriteLatencies();
  const batchLatencies = measuredBatches.map((b) => b.formationLatencyMs);
  const totalTxProcessed = measuredBatches.reduce((sum, b) => sum + b.transactions.length, 0);
  const throughputTxPerMin = (totalTxProcessed / totalTimeMs) * 60000;

  const result: BenchmarkResult = {
    config,
    throughputTxPerMin,
    avgBatchFormationLatencyMs: mean(batchLatencies),
    p95BatchFormationLatencyMs: percentile(batchLatencies, 95),
    p99BatchFormationLatencyMs: percentile(batchLatencies, 99),
    avgWalWriteLatencyUs: mean(walLatencies),
    p95WalWriteLatencyUs: percentile(walLatencies, 95),
    batchesFormed: measuredBatches.length,
    totalTxProcessed,
    memoryUsageBytes: process.memoryUsage().heapUsed,
    txLossCount: txCount - batches.reduce((sum, b) => sum + b.transactions.length, 0),
    deterministic: true, // Will be verified separately
  };

  // Cleanup
  queue.reset();
  return result;
}

let suiteCounter = 0;

/// Run a full benchmark with multiple replications for statistical rigor.
function runBenchmarkSuite(config: BenchmarkConfig): {
  results: BenchmarkResult[];
  summary: Record<string, unknown>;
} {
  const suiteId = suiteCounter++;
  const results: BenchmarkResult[] = [];

  for (let rep = 0; rep < config.replications; rep++) {
    const result = runSingleBenchmark(config, rep, suiteId);
    results.push(result);
  }

  // Aggregate across replications
  const throughputs = results.map((r) => r.throughputTxPerMin);
  const batchLatencies = results.map((r) => r.avgBatchFormationLatencyMs);
  const walLatencies = results.map((r) => r.avgWalWriteLatencyUs);
  const txLosses = results.map((r) => r.txLossCount);

  const throughputCI = ci95(throughputs);
  const latencyCI = ci95(batchLatencies);

  const summary = {
    strategy: config.batchConfig.strategy,
    sizeThreshold: config.batchConfig.sizeThreshold,
    timeThresholdMs: config.batchConfig.timeThresholdMs,
    arrivalRate: config.arrivalRate,
    replications: config.replications,
    throughput: {
      mean: formatNumber(mean(throughputs)),
      stdev: formatNumber(stdev(throughputs)),
      ci95_lower: formatNumber(throughputCI.lower),
      ci95_upper: formatNumber(throughputCI.upper),
      ci_within_10pct: ciWithinThreshold(throughputs),
      meets_target: mean(throughputs) >= 100,
    },
    batchFormationLatencyMs: {
      mean: formatNumber(mean(batchLatencies), 4),
      stdev: formatNumber(stdev(batchLatencies), 4),
      p95: formatNumber(mean(results.map((r) => r.p95BatchFormationLatencyMs)), 4),
      p99: formatNumber(mean(results.map((r) => r.p99BatchFormationLatencyMs)), 4),
      ci95_lower: formatNumber(latencyCI.lower, 4),
      ci95_upper: formatNumber(latencyCI.upper, 4),
      meets_target: mean(batchLatencies) < 5000,
    },
    walWriteLatencyUs: {
      mean: formatNumber(mean(walLatencies), 1),
      p95: formatNumber(mean(results.map((r) => r.p95WalWriteLatencyUs)), 1),
    },
    txLoss: {
      total: txLosses.reduce((sum, v) => sum + v, 0),
      perReplication: txLosses,
      zeroLoss: txLosses.every((l) => l === 0),
    },
    batchesFormed: {
      mean: formatNumber(mean(results.map((r) => r.batchesFormed))),
      total: results.reduce((sum, r) => sum + r.batchesFormed, 0),
    },
    memoryMB: formatNumber(
      mean(results.map((r) => r.memoryUsageBytes)) / (1024 * 1024)
    ),
  };

  return { results, summary };
}

// ---- Main benchmark execution ----

function main(): void {
  ensureDirs();
  console.log("=== RU-V4: Batch Aggregation Benchmark ===\n");

  const strategies: AggregationStrategy[] = ["SIZE", "TIME", "HYBRID"];
  const sizeThresholds = [4, 8, 16, 32, 64];
  const timeThresholds = [1000, 2000, 5000];
  const arrivalRates = [50, 100, 200, 500, 1000];
  const replications = 30;

  const allSummaries: Record<string, unknown>[] = [];

  // Phase 1: Strategy comparison at fixed parameters
  console.log("--- Phase 1: Strategy Comparison ---");
  console.log("(sizeThreshold=16, timeThreshold=2000ms, arrivalRate=200 tx/min)\n");

  for (const strategy of strategies) {
    const config: BenchmarkConfig = {
      arrivalRate: 200,
      durationMs: 10000,
      warmupBatches: 2,
      replications,
      queueConfig: {
        walPath: "", // Set per replication
        fsyncPerEntry: false,
        groupCommitSize: 16,
      },
      batchConfig: {
        strategy,
        sizeThreshold: 16,
        timeThresholdMs: 2000,
        maxBatchSize: 64,
      },
    };

    const { summary } = runBenchmarkSuite(config);
    allSummaries.push(summary);

    console.log(`Strategy: ${strategy}`);
    console.log(`  Throughput: ${summary.throughput.mean} tx/min (CI: [${summary.throughput.ci95_lower}, ${summary.throughput.ci95_upper}])`);
    console.log(`  Batch latency: ${summary.batchFormationLatencyMs.mean} ms (P95: ${summary.batchFormationLatencyMs.p95} ms)`);
    console.log(`  WAL write: ${summary.walWriteLatencyUs.mean} us (P95: ${summary.walWriteLatencyUs.p95} us)`);
    console.log(`  Tx loss: ${summary.txLoss.total} | Zero-loss: ${summary.txLoss.zeroLoss}`);
    console.log(`  Memory: ${summary.memoryMB} MB`);
    console.log(`  Meets throughput target: ${summary.throughput.meets_target}`);
    console.log(`  Meets latency target: ${summary.batchFormationLatencyMs.meets_target}`);
    console.log();
  }

  // Phase 2: Batch size sweep (HYBRID strategy)
  console.log("--- Phase 2: Batch Size Sweep (HYBRID, arrivalRate=200 tx/min) ---\n");

  for (const sizeThreshold of sizeThresholds) {
    const config: BenchmarkConfig = {
      arrivalRate: 200,
      durationMs: 10000,
      warmupBatches: 2,
      replications,
      queueConfig: {
        walPath: "",
        fsyncPerEntry: false,
        groupCommitSize: sizeThreshold,
      },
      batchConfig: {
        strategy: "HYBRID",
        sizeThreshold,
        timeThresholdMs: 2000,
        maxBatchSize: 64,
      },
    };

    const { summary } = runBenchmarkSuite(config);
    allSummaries.push(summary);

    console.log(`  batch_size=${sizeThreshold}: throughput=${summary.throughput.mean} tx/min, latency=${summary.batchFormationLatencyMs.mean} ms, loss=${summary.txLoss.total}`);
  }

  // Phase 3: Arrival rate sweep (HYBRID strategy)
  console.log("\n--- Phase 3: Arrival Rate Sweep (HYBRID, sizeThreshold=16) ---\n");

  for (const rate of arrivalRates) {
    const config: BenchmarkConfig = {
      arrivalRate: rate,
      durationMs: 10000,
      warmupBatches: 2,
      replications,
      queueConfig: {
        walPath: "",
        fsyncPerEntry: false,
        groupCommitSize: 16,
      },
      batchConfig: {
        strategy: "HYBRID",
        sizeThreshold: 16,
        timeThresholdMs: 2000,
        maxBatchSize: 64,
      },
    };

    const { summary } = runBenchmarkSuite(config);
    allSummaries.push(summary);

    console.log(`  rate=${rate} tx/min: throughput=${summary.throughput.mean} tx/min, latency=${summary.batchFormationLatencyMs.mean} ms, batches=${summary.batchesFormed.mean}, loss=${summary.txLoss.total}`);
  }

  // Phase 4: Time threshold sweep (HYBRID strategy)
  console.log("\n--- Phase 4: Time Threshold Sweep (HYBRID, sizeThreshold=16, rate=200) ---\n");

  for (const timeMs of timeThresholds) {
    const config: BenchmarkConfig = {
      arrivalRate: 200,
      durationMs: 10000,
      warmupBatches: 2,
      replications,
      queueConfig: {
        walPath: "",
        fsyncPerEntry: false,
        groupCommitSize: 16,
      },
      batchConfig: {
        strategy: "HYBRID",
        sizeThreshold: 16,
        timeThresholdMs: timeMs,
        maxBatchSize: 64,
      },
    };

    const { summary } = runBenchmarkSuite(config);
    allSummaries.push(summary);

    console.log(`  time=${timeMs}ms: throughput=${summary.throughput.mean} tx/min, latency=${summary.batchFormationLatencyMs.mean} ms, loss=${summary.txLoss.total}`);
  }

  // Phase 5: fsync per entry vs group commit
  console.log("\n--- Phase 5: fsync Strategy Comparison (HYBRID, rate=200) ---\n");

  for (const fsyncPerEntry of [true, false]) {
    const config: BenchmarkConfig = {
      arrivalRate: 200,
      durationMs: 10000,
      warmupBatches: 2,
      replications,
      queueConfig: {
        walPath: "",
        fsyncPerEntry,
        groupCommitSize: 16,
      },
      batchConfig: {
        strategy: "HYBRID",
        sizeThreshold: 16,
        timeThresholdMs: 2000,
        maxBatchSize: 64,
      },
    };

    const { summary } = runBenchmarkSuite(config);
    allSummaries.push(summary);

    const label = fsyncPerEntry ? "fsync_per_entry" : "group_commit";
    console.log(`  ${label}: throughput=${summary.throughput.mean} tx/min, WAL_write=${summary.walWriteLatencyUs.mean} us (P95: ${summary.walWriteLatencyUs.p95} us), loss=${summary.txLoss.total}`);
  }

  // Save all results
  const outputPath = join(RESULTS_DIR, "benchmark_results.json");
  writeFileSync(outputPath, JSON.stringify(allSummaries, null, 2));
  console.log(`\nResults saved to: ${outputPath}`);
}

main();
