/**
 * Load test script for the Enterprise Validium Node REST API.
 *
 * Sends transactions at a configurable rate and reports throughput,
 * latency percentiles (P50/P95/P99), and error rates.
 *
 * Usage:
 *   npx ts-node scripts/load-test.ts --rate 10 --duration 60 --host http://localhost:3000
 *
 * CLI arguments:
 *   --rate      Transactions per second (default: 10)
 *   --duration  Test duration in seconds (default: 60)
 *   --host      Node base URL (default: http://localhost:3000)
 *
 * @module scripts/load-test
 */

import * as http from "http";
import * as https from "https";
import * as crypto from "crypto";
import { URL } from "url";

// ---------------------------------------------------------------------------
// CLI Argument Parsing
// ---------------------------------------------------------------------------

interface LoadTestConfig {
  rate: number;
  duration: number;
  host: string;
}

function parseArgs(): LoadTestConfig {
  const args = process.argv.slice(2);
  const config: LoadTestConfig = {
    rate: 10,
    duration: 60,
    host: "http://localhost:3000",
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const next = args[i + 1];

    if (arg === "--rate" && next !== undefined) {
      config.rate = parseInt(next, 10);
      if (isNaN(config.rate) || config.rate <= 0) {
        console.error("Error: --rate must be a positive integer");
        process.exit(1);
      }
      i++;
    } else if (arg === "--duration" && next !== undefined) {
      config.duration = parseInt(next, 10);
      if (isNaN(config.duration) || config.duration <= 0) {
        console.error("Error: --duration must be a positive integer");
        process.exit(1);
      }
      i++;
    } else if (arg === "--host" && next !== undefined) {
      config.host = next;
      i++;
    } else if (arg === "--help" || arg === "-h") {
      console.log("Usage: npx ts-node scripts/load-test.ts [options]");
      console.log("");
      console.log("Options:");
      console.log("  --rate <n>        Transactions per second (default: 10)");
      console.log("  --duration <s>    Test duration in seconds (default: 60)");
      console.log("  --host <url>      Node base URL (default: http://localhost:3000)");
      console.log("  --help, -h        Show this help message");
      process.exit(0);
    }
  }

  return config;
}

// ---------------------------------------------------------------------------
// Transaction Generator
// ---------------------------------------------------------------------------

function randomHex(bytes: number): string {
  return crypto.randomBytes(bytes).toString("hex");
}

function generateTransaction(): Record<string, string | number> {
  return {
    txHash: crypto.createHash("sha256").update(crypto.randomBytes(32)).digest("hex"),
    key: randomHex(16),
    oldValue: "0",
    newValue: randomHex(16),
    enterpriseId: "test-enterprise",
    timestamp: Date.now(),
  };
}

// ---------------------------------------------------------------------------
// HTTP Client (built-in, no external deps)
// ---------------------------------------------------------------------------

interface RequestResult {
  statusCode: number;
  latencyMs: number;
  error?: string;
}

function sendTransaction(
  baseUrl: string,
  tx: Record<string, string | number>
): Promise<RequestResult> {
  return new Promise((resolve) => {
    const start = process.hrtime.bigint();
    const url = new URL("/v1/transactions", baseUrl);
    const body = JSON.stringify(tx);
    const isHttps = url.protocol === "https:";
    const transport = isHttps ? https : http;

    const options: http.RequestOptions = {
      hostname: url.hostname,
      port: url.port || (isHttps ? 443 : 80),
      path: url.pathname,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(body),
      },
      timeout: 30000,
    };

    const req = transport.request(options, (res) => {
      // Consume response body to free up the socket
      const chunks: Buffer[] = [];
      res.on("data", (chunk: Buffer) => chunks.push(chunk));
      res.on("end", () => {
        const elapsed = Number(process.hrtime.bigint() - start) / 1e6;
        resolve({
          statusCode: res.statusCode ?? 0,
          latencyMs: elapsed,
        });
      });
    });

    req.on("error", (err) => {
      const elapsed = Number(process.hrtime.bigint() - start) / 1e6;
      resolve({
        statusCode: 0,
        latencyMs: elapsed,
        error: err.message,
      });
    });

    req.on("timeout", () => {
      req.destroy();
      const elapsed = Number(process.hrtime.bigint() - start) / 1e6;
      resolve({
        statusCode: 0,
        latencyMs: elapsed,
        error: "Request timeout",
      });
    });

    req.write(body);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Latency Percentile Calculation
// ---------------------------------------------------------------------------

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const index = Math.ceil((p / 100) * sorted.length) - 1;
  return sorted[Math.max(0, Math.min(index, sorted.length - 1))]!;
}

// ---------------------------------------------------------------------------
// Metrics Tracking
// ---------------------------------------------------------------------------

interface Metrics {
  totalSent: number;
  totalAccepted: number;
  totalRejected: number;
  totalErrors: number;
  latencies: number[];
  statusCodes: Map<number, number>;
}

function createMetrics(): Metrics {
  return {
    totalSent: 0,
    totalAccepted: 0,
    totalRejected: 0,
    totalErrors: 0,
    latencies: [],
    statusCodes: new Map(),
  };
}

function recordResult(metrics: Metrics, result: RequestResult): void {
  metrics.totalSent++;
  metrics.latencies.push(result.latencyMs);

  const count = metrics.statusCodes.get(result.statusCode) ?? 0;
  metrics.statusCodes.set(result.statusCode, count + 1);

  if (result.statusCode === 202) {
    metrics.totalAccepted++;
  } else if (result.error || result.statusCode === 0) {
    metrics.totalErrors++;
  } else {
    metrics.totalRejected++;
  }
}

function printStatusLine(metrics: Metrics, elapsedSec: number): void {
  const sorted = [...metrics.latencies].sort((a, b) => a - b);
  const p50 = percentile(sorted, 50);
  const p95 = percentile(sorted, 95);
  const p99 = percentile(sorted, 99);
  const throughput = metrics.totalSent / Math.max(elapsedSec, 0.001);
  const errorRate =
    metrics.totalSent > 0
      ? ((metrics.totalRejected + metrics.totalErrors) / metrics.totalSent) * 100
      : 0;

  console.log(
    `  [${Math.floor(elapsedSec)}s] ` +
      `sent=${metrics.totalSent} ` +
      `accepted=${metrics.totalAccepted} ` +
      `rejected=${metrics.totalRejected} ` +
      `errors=${metrics.totalErrors} ` +
      `throughput=${throughput.toFixed(1)} tx/s ` +
      `P50=${p50.toFixed(1)}ms P95=${p95.toFixed(1)}ms P99=${p99.toFixed(1)}ms ` +
      `err=${errorRate.toFixed(1)}%`
  );
}

function printSummary(metrics: Metrics, config: LoadTestConfig, actualDurationSec: number): void {
  const sorted = [...metrics.latencies].sort((a, b) => a - b);
  const p50 = percentile(sorted, 50);
  const p95 = percentile(sorted, 95);
  const p99 = percentile(sorted, 99);
  const min = sorted.length > 0 ? sorted[0]! : 0;
  const max = sorted.length > 0 ? sorted[sorted.length - 1]! : 0;
  const mean =
    sorted.length > 0 ? sorted.reduce((a, b) => a + b, 0) / sorted.length : 0;
  const throughput = metrics.totalSent / Math.max(actualDurationSec, 0.001);
  const errorRate =
    metrics.totalSent > 0
      ? ((metrics.totalRejected + metrics.totalErrors) / metrics.totalSent) * 100
      : 0;

  const memUsage = process.memoryUsage();

  console.log("");
  console.log("=".repeat(70));
  console.log("LOAD TEST SUMMARY");
  console.log("=".repeat(70));
  console.log("");
  console.log("Configuration:");
  console.log(`  Target host:      ${config.host}`);
  console.log(`  Target rate:      ${config.rate} tx/s`);
  console.log(`  Duration:         ${config.duration}s (actual: ${actualDurationSec.toFixed(1)}s)`);
  console.log("");
  console.log("Throughput:");
  console.log(`  Total sent:       ${metrics.totalSent}`);
  console.log(`  Total accepted:   ${metrics.totalAccepted} (HTTP 202)`);
  console.log(`  Total rejected:   ${metrics.totalRejected}`);
  console.log(`  Total errors:     ${metrics.totalErrors} (connection/timeout)`);
  console.log(`  Actual rate:      ${throughput.toFixed(1)} tx/s`);
  console.log(`  Error rate:       ${errorRate.toFixed(2)}%`);
  console.log("");
  console.log("Latency (ms):");
  console.log(`  Min:              ${min.toFixed(1)}`);
  console.log(`  Mean:             ${mean.toFixed(1)}`);
  console.log(`  P50:              ${p50.toFixed(1)}`);
  console.log(`  P95:              ${p95.toFixed(1)}`);
  console.log(`  P99:              ${p99.toFixed(1)}`);
  console.log(`  Max:              ${max.toFixed(1)}`);
  console.log("");
  console.log("Status code distribution:");
  const sortedCodes = [...metrics.statusCodes.entries()].sort((a, b) => a[0] - b[0]);
  for (const [code, count] of sortedCodes) {
    const label = code === 0 ? "ERR" : String(code);
    console.log(`  ${label}: ${count}`);
  }
  console.log("");
  console.log("Memory usage:");
  console.log(`  RSS:              ${(memUsage.rss / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  Heap used:        ${(memUsage.heapUsed / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  Heap total:       ${(memUsage.heapTotal / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  External:         ${(memUsage.external / 1024 / 1024).toFixed(1)} MB`);
  console.log("");
  console.log("=".repeat(70));
}

// ---------------------------------------------------------------------------
// Main Load Test Loop
// ---------------------------------------------------------------------------

async function run(): Promise<void> {
  const config = parseArgs();

  console.log("");
  console.log("Basis Network Validium Node -- Load Test");
  console.log("-".repeat(50));
  console.log(`  Host:     ${config.host}`);
  console.log(`  Rate:     ${config.rate} tx/s`);
  console.log(`  Duration: ${config.duration}s`);
  console.log("-".repeat(50));
  console.log("");

  // Verify connectivity before starting
  console.log("Verifying connectivity...");
  try {
    const healthResult = await sendTransaction(config.host, generateTransaction());
    if (healthResult.error) {
      console.error(`Connection failed: ${healthResult.error}`);
      console.error(`Ensure the node is running at ${config.host}`);
      process.exit(1);
    }
    console.log(`  Connected (HTTP ${healthResult.statusCode}, ${healthResult.latencyMs.toFixed(1)}ms)`);
    console.log("");
  } catch (err) {
    console.error(`Connection failed: ${String(err)}`);
    process.exit(1);
  }

  const metrics = createMetrics();
  const intervalMs = 1000 / config.rate;
  const startTime = Date.now();
  const endTime = startTime + config.duration * 1000;
  let lastStatusTime = startTime;
  const STATUS_INTERVAL_MS = 10000;

  // Track in-flight requests so we can await them at the end
  const inflight: Promise<void>[] = [];

  console.log("Starting load test...");
  console.log("");

  while (Date.now() < endTime) {
    const txStartTime = Date.now();

    const tx = generateTransaction();
    const promise = sendTransaction(config.host, tx).then((result) => {
      recordResult(metrics, result);
    });
    inflight.push(promise);

    // Print status line every 10 seconds
    const now = Date.now();
    if (now - lastStatusTime >= STATUS_INTERVAL_MS) {
      const elapsedSec = (now - startTime) / 1000;
      printStatusLine(metrics, elapsedSec);
      lastStatusTime = now;
    }

    // Throttle to maintain target rate.
    // Calculate how long to sleep until the next send.
    const elapsed = Date.now() - txStartTime;
    const sleepMs = Math.max(0, intervalMs - elapsed);
    if (sleepMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, sleepMs));
    }
  }

  // Wait for all in-flight requests to complete
  console.log("");
  console.log(`Waiting for ${inflight.length - metrics.totalSent} in-flight requests...`);
  await Promise.all(inflight);

  const actualDurationSec = (Date.now() - startTime) / 1000;
  printSummary(metrics, config, actualDurationSec);
}

// ---------------------------------------------------------------------------
// Entry Point
// ---------------------------------------------------------------------------

run().catch((err) => {
  console.error("Load test failed:", err);
  process.exit(1);
});
