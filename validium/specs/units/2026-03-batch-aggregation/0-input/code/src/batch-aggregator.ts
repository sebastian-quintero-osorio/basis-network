import { createHash } from "crypto";
import type {
  Transaction,
  Batch,
  BatchAggregatorConfig,
  AggregationStrategy,
} from "./types.js";
import { PersistentQueue } from "./persistent-queue.js";

/// Batch aggregator with configurable formation strategies.
///
/// Strategies:
/// - SIZE: Form batch when queue reaches sizeThreshold transactions.
/// - TIME: Form batch every timeThresholdMs milliseconds.
/// - HYBRID: Form batch on whichever trigger fires first (size OR time).
///
/// Production reference: All major ZK-rollups (zkSync Era, Polygon zkEVM, Scroll)
/// use hybrid strategies. Pure size-based has unbounded latency; pure time-based
/// produces variable-size batches that may not match circuit capacity.
///
/// Determinism contract: Given the same set of transactions in the same order,
/// the batch ID and contents are identical. Batch ID = SHA-256(tx hashes in order).
export class BatchAggregator {
  private readonly queue: PersistentQueue;
  private readonly config: BatchAggregatorConfig;
  private batchNum: number = 0;
  private lastBatchTime: number = 0;
  private batchFormationLatencies: number[] = [];

  constructor(queue: PersistentQueue, config: BatchAggregatorConfig) {
    this.queue = queue;
    this.config = config;
    this.lastBatchTime = performance.now();
  }

  /// Check if a batch should be formed based on the current strategy.
  shouldFormBatch(): boolean {
    const elapsed = performance.now() - this.lastBatchTime;

    switch (this.config.strategy) {
      case "SIZE":
        return this.queue.size >= this.config.sizeThreshold;

      case "TIME":
        return elapsed >= this.config.timeThresholdMs;

      case "HYBRID":
        return (
          this.queue.size >= this.config.sizeThreshold ||
          (elapsed >= this.config.timeThresholdMs && this.queue.size > 0)
        );
    }
  }

  /// Form a batch from the queue. Returns null if no batch should be formed.
  formBatch(enterpriseId: string): Batch | null {
    if (!this.shouldFormBatch()) return null;
    if (this.queue.size === 0) return null;

    const formStart = performance.now();

    // Determine batch size: min(available, sizeThreshold, maxBatchSize)
    const batchSize = Math.min(
      this.queue.size,
      this.config.sizeThreshold,
      this.config.maxBatchSize
    );

    const transactions = this.queue.dequeue(batchSize);
    if (transactions.length === 0) return null;

    this.batchNum++;
    const batchId = this.computeBatchId(transactions);
    const formationLatencyMs = performance.now() - formStart;

    this.batchFormationLatencies.push(formationLatencyMs);
    this.lastBatchTime = performance.now();

    // Checkpoint the WAL after forming the batch
    this.queue.checkpoint(batchId);

    return {
      batchId,
      batchNum: this.batchNum,
      enterpriseId,
      transactions,
      formedAt: Date.now(),
      formationLatencyMs,
      strategy: this.config.strategy,
    };
  }

  /// Force-form a batch regardless of thresholds (for flush/shutdown).
  forceBatch(enterpriseId: string): Batch | null {
    if (this.queue.size === 0) return null;

    const formStart = performance.now();
    const batchSize = Math.min(this.queue.size, this.config.maxBatchSize);
    const transactions = this.queue.dequeue(batchSize);
    if (transactions.length === 0) return null;

    this.batchNum++;
    const batchId = this.computeBatchId(transactions);
    const formationLatencyMs = performance.now() - formStart;

    this.batchFormationLatencies.push(formationLatencyMs);
    this.lastBatchTime = performance.now();

    this.queue.checkpoint(batchId);

    return {
      batchId,
      batchNum: this.batchNum,
      enterpriseId,
      transactions,
      formedAt: Date.now(),
      formationLatencyMs,
      strategy: this.config.strategy,
    };
  }

  /// Compute deterministic batch ID from transaction hashes.
  /// Same transactions in same order -> same batch ID.
  private computeBatchId(transactions: Transaction[]): string {
    const concat = transactions.map((tx) => tx.txHash).join("|");
    return createHash("sha256").update(concat).digest("hex");
  }

  /// Get batch formation latencies for benchmarking.
  getBatchFormationLatencies(): number[] {
    return this.batchFormationLatencies;
  }

  /// Get current batch number.
  get currentBatchNum(): number {
    return this.batchNum;
  }

  /// Reset batch counter and timing (for testing).
  reset(): void {
    this.batchNum = 0;
    this.lastBatchTime = performance.now();
    this.batchFormationLatencies = [];
  }
}
