/**
 * Unit and adversarial tests for the BatchAggregator.
 *
 * [Spec: validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla]
 *
 * Tests verify:
 * - HYBRID strategy: size OR time triggers
 * - v1-fix: checkpoint deferred to onBatchProcessed
 * - BatchSizeBound invariant
 * - FIFO processing order
 * - Crash recovery correctness
 * - Deterministic batch IDs
 */

import { mkdtempSync, rmSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { TransactionQueue } from "../../queue/transaction-queue";
import { BatchAggregator } from "../batch-aggregator";
import { BatchError, BatchErrorCode } from "../types";
import type { Transaction, WALConfig } from "../../queue/types";
import type { BatchAggregatorConfig } from "../types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeTx(n: number, enterpriseId = "enterprise-1"): Transaction {
  return {
    txHash: `txhash-${n}`,
    key: n.toString(16).padStart(4, "0"),
    oldValue: "0",
    newValue: n.toString(16).padStart(4, "0"),
    enterpriseId,
    timestamp: 1700000000000 + n,
  };
}

function createTempDir(): string {
  return mkdtempSync(join(tmpdir(), "batch-test-"));
}

function makeQueueConfig(walDir: string): WALConfig {
  return { walDir, fsyncOnWrite: false };
}

function makeBatchConfig(
  maxBatchSize = 4,
  maxWaitTimeMs = 1000
): BatchAggregatorConfig {
  return { maxBatchSize, maxWaitTimeMs };
}

function setupAggregator(
  walDir: string,
  maxBatchSize = 4,
  maxWaitTimeMs = 1000
): { queue: TransactionQueue; aggregator: BatchAggregator } {
  const queue = new TransactionQueue(makeQueueConfig(walDir));
  const aggregator = new BatchAggregator(queue, makeBatchConfig(maxBatchSize, maxWaitTimeMs));
  return { queue, aggregator };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("BatchAggregator", () => {
  let walDir: string;

  beforeEach(() => {
    walDir = createTempDir();
  });

  afterEach(() => {
    rmSync(walDir, { recursive: true, force: true });
  });

  // =========================================================================
  // Configuration Validation
  // =========================================================================

  describe("Configuration", () => {
    it("rejects maxBatchSize <= 0", () => {
      const queue = new TransactionQueue(makeQueueConfig(walDir));
      expect(() => new BatchAggregator(queue, makeBatchConfig(0))).toThrow(BatchError);
      expect(() => new BatchAggregator(queue, makeBatchConfig(-1))).toThrow(BatchError);
    });

    it("rejects maxWaitTimeMs <= 0", () => {
      const queue = new TransactionQueue(makeQueueConfig(walDir));
      expect(() => new BatchAggregator(queue, makeBatchConfig(4, 0))).toThrow(BatchError);
      expect(() => new BatchAggregator(queue, makeBatchConfig(4, -1))).toThrow(BatchError);
    });
  });

  // =========================================================================
  // Size-Based Trigger
  // =========================================================================

  describe("Size-Based Trigger", () => {
    it("forms batch when queue reaches maxBatchSize", () => {
      const { queue, aggregator } = setupAggregator(walDir, 3);
      queue.enqueue(makeTx(1));
      queue.enqueue(makeTx(2));
      expect(aggregator.shouldFormBatch()).toBe(false);

      queue.enqueue(makeTx(3));
      expect(aggregator.shouldFormBatch()).toBe(true);

      const batch = aggregator.formBatch();
      expect(batch).not.toBeNull();
      expect(batch!.txCount).toBe(3);
      expect(queue.size).toBe(0);
    });

    it("takes exactly maxBatchSize transactions", () => {
      const { queue, aggregator } = setupAggregator(walDir, 3);
      for (let i = 1; i <= 5; i++) {
        queue.enqueue(makeTx(i));
      }

      const batch = aggregator.formBatch();
      expect(batch!.txCount).toBe(3);
      expect(queue.size).toBe(2); // 2 remaining
    });

    // [Spec: BatchSizeBound invariant]
    it("never exceeds maxBatchSize", () => {
      const { queue, aggregator } = setupAggregator(walDir, 2);
      for (let i = 1; i <= 10; i++) {
        queue.enqueue(makeTx(i));
      }

      for (let b = 0; b < 5; b++) {
        const batch = aggregator.formBatch();
        expect(batch).not.toBeNull();
        expect(batch!.txCount).toBeLessThanOrEqual(2);
        aggregator.onBatchProcessed(batch!.batchId);
      }
    });
  });

  // =========================================================================
  // Time-Based Trigger
  // =========================================================================

  describe("Time-Based Trigger", () => {
    it("forms batch when maxWaitTimeMs elapses with non-empty queue", () => {
      const { queue, aggregator } = setupAggregator(walDir, 100, 50);
      queue.enqueue(makeTx(1));

      // Not enough time elapsed
      expect(aggregator.shouldFormBatch()).toBe(false);

      // Wait for time threshold
      const start = Date.now();
      while (Date.now() - start < 60) {
        // busy wait
      }

      expect(aggregator.shouldFormBatch()).toBe(true);
      const batch = aggregator.formBatch();
      expect(batch).not.toBeNull();
      expect(batch!.txCount).toBe(1);
    });

    it("does not trigger time-based batch on empty queue", () => {
      const { aggregator } = setupAggregator(walDir, 100, 50);

      const start = Date.now();
      while (Date.now() - start < 60) {
        // busy wait
      }

      expect(aggregator.shouldFormBatch()).toBe(false);
      expect(aggregator.formBatch()).toBeNull();
    });
  });

  // =========================================================================
  // HYBRID Strategy
  // =========================================================================

  describe("HYBRID Strategy", () => {
    it("triggers on size OR time (whichever first)", () => {
      const { queue, aggregator } = setupAggregator(walDir, 3, 50);

      // Size trigger: add 3 txs
      for (let i = 1; i <= 3; i++) {
        queue.enqueue(makeTx(i));
      }
      expect(aggregator.shouldFormBatch()).toBe(true);

      const batch = aggregator.formBatch();
      expect(batch!.txCount).toBe(3);
    });

    it("takes all available when time-triggered (up to maxBatchSize)", () => {
      const { queue, aggregator } = setupAggregator(walDir, 10, 50);
      queue.enqueue(makeTx(1));
      queue.enqueue(makeTx(2));

      const start = Date.now();
      while (Date.now() - start < 60) {
        // busy wait
      }

      const batch = aggregator.formBatch();
      expect(batch).not.toBeNull();
      expect(batch!.txCount).toBe(2); // Takes all available
    });
  });

  // =========================================================================
  // v1-fix: Deferred Checkpoint
  // =========================================================================

  describe("Deferred Checkpoint (v1-fix)", () => {
    // [v1-fix CRITICAL TEST]
    it("formBatch does NOT write a checkpoint", () => {
      const { queue, aggregator } = setupAggregator(walDir, 3);
      for (let i = 1; i <= 3; i++) {
        queue.enqueue(makeTx(i));
      }

      aggregator.formBatch();

      // Crash + recover: all transactions should be available
      const queue2 = new TransactionQueue(makeQueueConfig(walDir));
      const recovered = queue2.recover();
      expect(recovered).toBe(3); // All recovered because no checkpoint!
    });

    it("onBatchProcessed writes the checkpoint", () => {
      const { queue, aggregator } = setupAggregator(walDir, 3);
      for (let i = 1; i <= 5; i++) {
        queue.enqueue(makeTx(i));
      }

      const batch = aggregator.formBatch();
      expect(batch).not.toBeNull();

      // Process the batch (writes checkpoint)
      aggregator.onBatchProcessed(batch!.batchId);

      // Crash + recover: only uncommitted txs recovered
      const queue2 = new TransactionQueue(makeQueueConfig(walDir));
      const recovered = queue2.recover();
      expect(recovered).toBe(2); // tx4, tx5
    });

    it("crash after FormBatch, before ProcessBatch: zero loss", () => {
      const { queue, aggregator } = setupAggregator(walDir, 2);

      // Enqueue 5 transactions
      for (let i = 1; i <= 5; i++) {
        queue.enqueue(makeTx(i));
      }

      // Form two batches (no processing)
      aggregator.formBatch(); // batch 1: tx1, tx2
      aggregator.formBatch(); // batch 2: tx3, tx4

      expect(queue.size).toBe(1); // tx5 remains in queue

      // CRASH: volatile state (queue, pending batches) lost
      const queue2 = new TransactionQueue(makeQueueConfig(walDir));
      const recovered = queue2.recover();

      // ALL 5 transactions recovered
      expect(recovered).toBe(5);

      // Verify FIFO order preserved
      const result = queue2.dequeue(5);
      for (let i = 0; i < 5; i++) {
        expect(result.transactions[i]!.txHash).toBe(`txhash-${i + 1}`);
      }
    });
  });

  // =========================================================================
  // FIFO Processing Order
  // =========================================================================

  describe("FIFO Processing Order", () => {
    it("enforces FIFO order in onBatchProcessed", () => {
      const { queue, aggregator } = setupAggregator(walDir, 2);
      for (let i = 1; i <= 4; i++) {
        queue.enqueue(makeTx(i));
      }

      const batch1 = aggregator.formBatch()!;
      const batch2 = aggregator.formBatch()!;

      // Process batch2 before batch1: should fail
      expect(() => aggregator.onBatchProcessed(batch2.batchId)).toThrow(BatchError);
      expect(() => aggregator.onBatchProcessed(batch2.batchId)).toThrow(
        /FIFO order/
      );
    });

    it("allows processing in correct FIFO order", () => {
      const { queue, aggregator } = setupAggregator(walDir, 2);
      for (let i = 1; i <= 4; i++) {
        queue.enqueue(makeTx(i));
      }

      const batch1 = aggregator.formBatch()!;
      const batch2 = aggregator.formBatch()!;

      expect(() => aggregator.onBatchProcessed(batch1.batchId)).not.toThrow();
      expect(() => aggregator.onBatchProcessed(batch2.batchId)).not.toThrow();
      expect(aggregator.pendingCount).toBe(0);
    });

    it("throws on processing with no pending batches", () => {
      const { aggregator } = setupAggregator(walDir);
      expect(() => aggregator.onBatchProcessed("nonexistent")).toThrow(BatchError);
    });
  });

  // =========================================================================
  // Batch Numbering
  // =========================================================================

  describe("Batch Numbering", () => {
    it("assigns monotonically increasing batch numbers", () => {
      const { queue, aggregator } = setupAggregator(walDir, 2);
      for (let i = 1; i <= 6; i++) {
        queue.enqueue(makeTx(i));
      }

      const batch1 = aggregator.formBatch()!;
      const batch2 = aggregator.formBatch()!;
      const batch3 = aggregator.formBatch()!;

      expect(batch1.batchNum).toBe(1);
      expect(batch2.batchNum).toBe(2);
      expect(batch3.batchNum).toBe(3);
    });
  });

  // =========================================================================
  // Determinism
  // =========================================================================

  describe("Determinism", () => {
    it("same transactions produce same batch ID", () => {
      const txs = [makeTx(1), makeTx(2), makeTx(3)];

      const dir1 = createTempDir();
      const dir2 = createTempDir();

      const { queue: q1, aggregator: a1 } = setupAggregator(dir1, 3);
      const { queue: q2, aggregator: a2 } = setupAggregator(dir2, 3);

      for (const tx of txs) {
        q1.enqueue(tx);
        q2.enqueue(tx);
      }

      const batch1 = a1.formBatch()!;
      const batch2 = a2.formBatch()!;

      expect(batch1.batchId).toBe(batch2.batchId);

      rmSync(dir1, { recursive: true, force: true });
      rmSync(dir2, { recursive: true, force: true });
    });

    it("different transaction order produces different batch ID", () => {
      const dir1 = createTempDir();
      const dir2 = createTempDir();

      const { queue: q1, aggregator: a1 } = setupAggregator(dir1, 3);
      const { queue: q2, aggregator: a2 } = setupAggregator(dir2, 3);

      q1.enqueue(makeTx(1));
      q1.enqueue(makeTx(2));
      q1.enqueue(makeTx(3));

      q2.enqueue(makeTx(3));
      q2.enqueue(makeTx(2));
      q2.enqueue(makeTx(1));

      const batch1 = a1.formBatch()!;
      const batch2 = a2.formBatch()!;

      expect(batch1.batchId).not.toBe(batch2.batchId);

      rmSync(dir1, { recursive: true, force: true });
      rmSync(dir2, { recursive: true, force: true });
    });
  });

  // =========================================================================
  // State Management
  // =========================================================================

  describe("State Management", () => {
    it("tracks currentBatchNum", () => {
      const { queue, aggregator } = setupAggregator(walDir, 2);
      expect(aggregator.currentBatchNum).toBe(0);

      queue.enqueue(makeTx(1));
      queue.enqueue(makeTx(2));
      aggregator.formBatch();
      expect(aggregator.currentBatchNum).toBe(1);
    });

    it("resetState clears batch counter and pending batches", () => {
      const { queue, aggregator } = setupAggregator(walDir, 2);
      queue.enqueue(makeTx(1));
      queue.enqueue(makeTx(2));
      aggregator.formBatch();

      expect(aggregator.currentBatchNum).toBe(1);
      expect(aggregator.pendingCount).toBe(1);

      aggregator.resetState();
      expect(aggregator.currentBatchNum).toBe(0);
      expect(aggregator.pendingCount).toBe(0);
    });
  });

  // =========================================================================
  // Force Batch
  // =========================================================================

  describe("Force Batch", () => {
    it("forms batch regardless of thresholds", () => {
      const { queue, aggregator } = setupAggregator(walDir, 100, 99999);
      queue.enqueue(makeTx(1));

      expect(aggregator.shouldFormBatch()).toBe(false);
      const batch = aggregator.forceBatch();
      expect(batch).not.toBeNull();
      expect(batch!.txCount).toBe(1);
    });

    it("returns null for empty queue", () => {
      const { aggregator } = setupAggregator(walDir);
      expect(aggregator.forceBatch()).toBeNull();
    });

    it("respects maxBatchSize", () => {
      const { queue, aggregator } = setupAggregator(walDir, 2);
      for (let i = 1; i <= 5; i++) {
        queue.enqueue(makeTx(i));
      }

      const batch = aggregator.forceBatch();
      expect(batch!.txCount).toBe(2);
    });
  });

  // =========================================================================
  // Adversarial Tests
  // =========================================================================

  describe("Adversarial", () => {
    // ADV-BATCH-01: Rapid formation without processing
    it("ADV-BATCH-01: handles many unprocessed batches", () => {
      const { queue, aggregator } = setupAggregator(walDir, 1);
      for (let i = 1; i <= 20; i++) {
        queue.enqueue(makeTx(i));
      }

      const batches = [];
      for (let i = 0; i < 20; i++) {
        const batch = aggregator.formBatch();
        expect(batch).not.toBeNull();
        batches.push(batch!);
      }

      expect(aggregator.pendingCount).toBe(20);

      // Process all in order
      for (const batch of batches) {
        aggregator.onBatchProcessed(batch.batchId);
      }

      expect(aggregator.pendingCount).toBe(0);
    });

    // ADV-BATCH-02: Double processing same batch
    it("ADV-BATCH-02: rejects double processing of same batch", () => {
      const { queue, aggregator } = setupAggregator(walDir, 2);
      queue.enqueue(makeTx(1));
      queue.enqueue(makeTx(2));

      const batch = aggregator.formBatch()!;
      aggregator.onBatchProcessed(batch.batchId);

      // Second processing should fail
      expect(() => aggregator.onBatchProcessed(batch.batchId)).toThrow(
        BatchErrorCode.NO_PENDING_BATCH
      );
    });

    // ADV-BATCH-03: formBatch returns null when not triggered
    it("ADV-BATCH-03: formBatch returns null when thresholds not met", () => {
      const { queue, aggregator } = setupAggregator(walDir, 10, 99999);
      queue.enqueue(makeTx(1));

      expect(aggregator.formBatch()).toBeNull();
    });

    // ADV-BATCH-04: Boundary -- exactly maxBatchSize
    it("ADV-BATCH-04: boundary at exactly maxBatchSize", () => {
      const { queue, aggregator } = setupAggregator(walDir, 4);
      for (let i = 1; i <= 4; i++) {
        queue.enqueue(makeTx(i));
      }

      const batch = aggregator.formBatch();
      expect(batch).not.toBeNull();
      expect(batch!.txCount).toBe(4);
      expect(queue.size).toBe(0);
    });

    // ADV-BATCH-05: maxBatchSize + 1 transactions
    it("ADV-BATCH-05: maxBatchSize + 1 leaves 1 in queue", () => {
      const { queue, aggregator } = setupAggregator(walDir, 4);
      for (let i = 1; i <= 5; i++) {
        queue.enqueue(makeTx(i));
      }

      const batch = aggregator.formBatch();
      expect(batch!.txCount).toBe(4);
      expect(queue.size).toBe(1);
    });

    // ADV-BATCH-06: Interleaved enqueue and formBatch
    it("ADV-BATCH-06: interleaved enqueue and batch formation", () => {
      const { queue, aggregator } = setupAggregator(walDir, 2);

      queue.enqueue(makeTx(1));
      queue.enqueue(makeTx(2));
      const batch1 = aggregator.formBatch()!;
      expect(batch1.transactions[0]!.txHash).toBe("txhash-1");

      queue.enqueue(makeTx(3));
      queue.enqueue(makeTx(4));
      const batch2 = aggregator.formBatch()!;
      expect(batch2.transactions[0]!.txHash).toBe("txhash-3");

      aggregator.onBatchProcessed(batch1.batchId);
      aggregator.onBatchProcessed(batch2.batchId);
    });
  });
});
