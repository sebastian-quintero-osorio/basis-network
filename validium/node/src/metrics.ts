/**
 * Prometheus metrics for the Enterprise Node.
 *
 * Exports a shared Registry and typed metric instances for use across
 * the node's modules (orchestrator, API server, etc.).
 *
 * Metrics follow the `validium_` namespace convention. All counters,
 * gauges, and histograms are registered on a single Registry that is
 * served at GET /metrics.
 *
 * @module metrics
 */

import {
  Registry,
  Counter,
  Histogram,
  Gauge,
  collectDefaultMetrics,
} from "prom-client";

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

/** Shared Prometheus registry for all validium metrics. */
export const registry = new Registry();

registry.setDefaultLabels({ service: "validium-node" });

/** Collect default Node.js process metrics (CPU, memory, event loop, etc.). */
collectDefaultMetrics({ register: registry });

// ---------------------------------------------------------------------------
// Counters
// ---------------------------------------------------------------------------

/** Total transactions submitted to the node. */
export const transactionsTotal = new Counter({
  name: "validium_transactions_total",
  help: "Total transactions submitted to the node",
  labelNames: ["enterprise_id"] as const,
  registers: [registry],
});

/** Total batches by processing status. */
export const batchesTotal = new Counter({
  name: "validium_batches_total",
  help: "Total batches by processing status",
  labelNames: ["status"] as const,
  registers: [registry],
});

/** Total ZK proof generation attempts by outcome. */
export const proofsTotal = new Counter({
  name: "validium_proofs_total",
  help: "Total ZK proof generation attempts by outcome",
  labelNames: ["status"] as const,
  registers: [registry],
});

/** Total L1 submission attempts by outcome. */
export const l1SubmissionsTotal = new Counter({
  name: "validium_l1_submissions_total",
  help: "Total L1 submission attempts by outcome",
  labelNames: ["status"] as const,
  registers: [registry],
});

/** Total API requests by method, path, and status code. */
export const apiRequestsTotal = new Counter({
  name: "validium_api_requests_total",
  help: "Total API requests by method, path, and status code",
  labelNames: ["method", "path", "status_code"] as const,
  registers: [registry],
});

// ---------------------------------------------------------------------------
// Histograms
// ---------------------------------------------------------------------------

/** ZK proof generation duration in seconds. */
export const proofDuration = new Histogram({
  name: "validium_proof_duration_seconds",
  help: "ZK proof generation duration in seconds",
  buckets: [1, 5, 10, 15, 20, 30, 60],
  registers: [registry],
});

/** L1 submission duration in seconds. */
export const l1SubmissionDuration = new Histogram({
  name: "validium_l1_submission_duration_seconds",
  help: "L1 submission duration in seconds",
  buckets: [1, 5, 10, 30, 60, 120],
  registers: [registry],
});

/** Number of transactions per batch. */
export const batchSize = new Histogram({
  name: "validium_batch_size",
  help: "Number of transactions per batch",
  buckets: [1, 2, 4, 8, 16, 32, 64],
  registers: [registry],
});

// ---------------------------------------------------------------------------
// Gauges
// ---------------------------------------------------------------------------

/** Current transaction queue depth. */
export const queueDepth = new Gauge({
  name: "validium_queue_depth",
  help: "Current transaction queue depth",
  registers: [registry],
});

/**
 * Current node state as a numeric value.
 *
 * 0=Idle, 1=Receiving, 2=Batching, 3=Proving, 4=Submitting, 5=Error
 */
export const nodeState = new Gauge({
  name: "validium_node_state",
  help: "Current node state (0=Idle, 1=Receiving, 2=Batching, 3=Proving, 4=Submitting, 5=Error)",
  registers: [registry],
});

/** Node uptime in seconds. */
export const uptimeSeconds = new Gauge({
  name: "validium_uptime_seconds",
  help: "Node uptime in seconds",
  registers: [registry],
});

/** Total crash/recovery cycles since startup. */
export const crashCount = new Gauge({
  name: "validium_crash_count",
  help: "Total crash/recovery cycles since startup",
  registers: [registry],
});

// ---------------------------------------------------------------------------
// State Mapping Helper
// ---------------------------------------------------------------------------

/** Map NodeState string to its numeric gauge value. */
const STATE_TO_NUMBER: Record<string, number> = {
  Idle: 0,
  Receiving: 1,
  Batching: 2,
  Proving: 3,
  Submitting: 4,
  Error: 5,
};

/**
 * Convert a NodeState string to its numeric representation for the gauge.
 *
 * @param state - NodeState enum value
 * @returns Numeric state value (0-5)
 */
export function stateToNumber(state: string): number {
  return STATE_TO_NUMBER[state] ?? 5;
}
