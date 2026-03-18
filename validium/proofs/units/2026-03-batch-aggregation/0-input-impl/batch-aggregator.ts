/**
 * Batch aggregator with HYBRID (size OR time) formation strategy.
 *
 * [Spec: validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla]
 *
 * Implements the FormBatch and ProcessBatch actions from the verified TLA+ spec.
 *
 * CRITICAL (v1-fix): WAL checkpoint is deferred from FormBatch to ProcessBatch.
 * In v0, checkpointSeq advanced at batch formation, creating a durability gap where
 * a crash between FormBatch and ProcessBatch caused irrecoverable transaction loss.
 * In v1-fix, checkpointSeq advances only after downstream consumption (proof generation
 * + L1 confirmation), so all uncommitted WAL entries are recoverable after crash.
 *
 * @module batch/batch-aggregator
 */

import { createHash } from "crypto";
import { TransactionQueue } from "../queue/transaction-queue";
import type { Transaction } from "../queue/types";
import type { Batch, BatchAggregatorConfig } from "./types";
import { BatchError, BatchErrorCode } from "./types";

/** Internal record tracking a formed batch pending downstream processing. */
interface PendingBatchRecord {
  readonly batchId: string;
  readonly checkpointSeq: number;
  readonly txCount: number;
}

export class BatchAggregator {
  private readonly queue: TransactionQueue;
  private readonly config: BatchAggregatorConfig;
  private readonly pendingBatches: PendingBatchRecord[] = [];
  private batchNum: number = 0;
  private lastBatchTimeMs: number;

  constructor(queue: TransactionQueue, config: BatchAggregatorConfig) {
    if (config.maxBatchSize <= 0) {
      throw new BatchError(
        BatchErrorCode.INVALID_CONFIG,
        `maxBatchSize must be > 0, got ${config.maxBatchSize}`
      );
    }
    if (config.maxWaitTimeMs <= 0) {
      throw new BatchError(
        BatchErrorCode.INVALID_CONFIG,
        `maxWaitTimeMs must be > 0, got ${config.maxWaitTimeMs}`
      );
    }

    this.queue = queue;
    this.config = config;
    this.lastBatchTimeMs = Date.now();
  }

  /**
   * Check if a batch should be formed using the HYBRID strategy.
   * Returns true when the queue reaches maxBatchSize OR maxWaitTimeMs has
   * elapsed with a non-empty queue.
   *
   * [Spec: FormBatch precondition]
   *   \/ Len(queue) >= BatchSizeThreshold
   *   \/ (timerExpired /\ Len(queue) > 0)
   */
  shouldFormBatch(): boolean {
    const sizeTriggered = this.queue.size >= this.config.maxBatchSize;
    const timeTriggered =
      this.queue.size > 0 &&
      Date.now() - this.lastBatchTimeMs >= this.config.maxWaitTimeMs;
    return sizeTriggered || timeTriggered;
  }

  /**
   * Form a batch from the queue. Returns null if no batch should be formed.
   *
   * Dequeues min(queue.size, maxBatchSize) transactions in FIFO order.
   * If the size threshold is met, takes exactly maxBatchSize.
   * If only the time threshold is met, takes all available (up to maxBatchSize).
   *
   * CRITICAL (v1-fix): Does NOT write a WAL checkpoint.
   * The batch is held in volatile memory. If the system crashes before
   * onBatchProcessed(), the batch transactions remain in the uncommitted WAL
   * segment and will be recovered by WAL replay.
   *
   * [Spec: FormBatch]
   *   batchSize == IF Len(queue) >= BatchSizeThreshold
   *                THEN BatchSizeThreshold
   *                ELSE Len(queue)
   *   batches' = Append(batches, SubSeq(queue, 1, batchSize))
   *   queue' = SubSeq(queue, batchSize + 1, Len(queue))
   *   UNCHANGED << wal, checkpointSeq >>
   */
  formBatch(): Batch | null {
    if (!this.shouldFormBatch()) return null;
    if (this.queue.size === 0) return null;

    // [Spec: batchSize determination]
    const batchSize =
      this.queue.size >= this.config.maxBatchSize
        ? this.config.maxBatchSize
        : this.queue.size;

    const { transactions, checkpointSeq } = this.queue.dequeue(batchSize);

    this.batchNum++;
    const batchId = computeBatchId(transactions);

    // Track pending batch for deferred checkpoint (v1-fix)
    this.pendingBatches.push({
      batchId,
      checkpointSeq,
      txCount: transactions.length,
    });

    // Reset timer after batch formation
    // [Spec: timerExpired' = FALSE]
    this.lastBatchTimeMs = Date.now();

    return {
      batchId,
      batchNum: this.batchNum,
      transactions,
      txCount: transactions.length,
      formedAt: Date.now(),
    };
  }

  /**
   * Notify that a batch has been fully processed by downstream.
   * Writes the WAL checkpoint, marking the batch transactions as committed.
   *
   * Batches MUST be processed in FIFO order (matching TLA+ Head(batches)).
   *
   * [Spec: ProcessBatch]
   *   processed' = Append(processed, Head(batches))
   *   batches' = Tail(batches)
   *   checkpointSeq' = checkpointSeq + Len(Head(batches))
   *
   * [v1-fix: This is the ONLY place WAL checkpoints are written.]
   */
  onBatchProcessed(batchId: string): void {
    if (this.pendingBatches.length === 0) {
      throw new BatchError(
        BatchErrorCode.NO_PENDING_BATCH,
        "No pending batches to process"
      );
    }

    const head = this.pendingBatches[0]!;
    if (head.batchId !== batchId) {
      throw new BatchError(
        BatchErrorCode.OUT_OF_ORDER_PROCESSING,
        `Expected batch ${head.batchId} but got ${batchId}. Batches must be processed in FIFO order.`
      );
    }

    // [v1-fix: Checkpoint HERE, at ProcessBatch time]
    this.queue.checkpoint(head.checkpointSeq, batchId);
    this.pendingBatches.shift();
  }

  /**
   * Force-form a batch regardless of thresholds (for graceful shutdown).
   * Returns null if the queue is empty.
   */
  forceBatch(): Batch | null {
    if (this.queue.size === 0) return null;

    const batchSize = Math.min(this.queue.size, this.config.maxBatchSize);
    const { transactions, checkpointSeq } = this.queue.dequeue(batchSize);

    this.batchNum++;
    const batchId = computeBatchId(transactions);

    this.pendingBatches.push({
      batchId,
      checkpointSeq,
      txCount: transactions.length,
    });

    this.lastBatchTimeMs = Date.now();

    return {
      batchId,
      batchNum: this.batchNum,
      transactions,
      txCount: transactions.length,
      formedAt: Date.now(),
    };
  }

  /** Number of formed batches awaiting downstream processing. */
  get pendingCount(): number {
    return this.pendingBatches.length;
  }

  /** Current batch counter value. */
  get currentBatchNum(): number {
    return this.batchNum;
  }

  /** Reset batch counter and timer (for testing only). */
  resetState(): void {
    this.batchNum = 0;
    this.pendingBatches.length = 0;
    this.lastBatchTimeMs = Date.now();
  }
}

/**
 * Compute deterministic batch ID from transaction hashes.
 * Same transactions in same order produce the same batch ID.
 *
 * [Spec: Determinism -- same input produces same output]
 */
function computeBatchId(transactions: readonly Transaction[]): string {
  const concat = transactions.map((tx) => tx.txHash).join("|");
  return createHash("sha256").update(concat).digest("hex");
}
