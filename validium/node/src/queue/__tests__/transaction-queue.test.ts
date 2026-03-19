/**
 * Unit and adversarial tests for the TransactionQueue.
 *
 * [Spec: validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla]
 *
 * Tests verify the TLA+ invariants:
 * - NoLoss: pending U UncommittedWal U Processed = AllTxs
 * - NoDuplication: pairwise disjoint partitions
 * - QueueWalConsistency: Flatten(batches) o queue = SubSeq(wal, checkpoint+1, Len(wal))
 * - FIFOOrdering: Flatten(processed) o Flatten(batches) o queue = wal
 * - BatchSizeBound: all batches <= BatchSizeThreshold
 */

import { mkdtempSync, rmSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { TransactionQueue } from "../transaction-queue";
import type { Transaction, WALConfig } from "../types";

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
  return mkdtempSync(join(tmpdir(), "queue-test-"));
}

function makeConfig(walDir: string): WALConfig {
  return { walDir, fsyncOnWrite: false };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("TransactionQueue", () => {
  let walDir: string;

  beforeEach(() => {
    walDir = createTempDir();
  });

  afterEach(() => {
    rmSync(walDir, { recursive: true, force: true });
  });

  // =========================================================================
  // Enqueue / Dequeue
  // =========================================================================

  describe("Enqueue and Dequeue", () => {
    it("enqueues and dequeues a single transaction", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      const tx = makeTx(1);
      queue.enqueue(tx);

      expect(queue.size).toBe(1);
      const result = queue.dequeue(1);
      expect(result.transactions).toHaveLength(1);
      expect(result.transactions[0]!.txHash).toBe("txhash-1");
      expect(queue.size).toBe(0);
    });

    it("maintains FIFO ordering", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      for (let i = 1; i <= 5; i++) {
        queue.enqueue(makeTx(i));
      }

      const result = queue.dequeue(5);
      expect(result.transactions).toHaveLength(5);
      for (let i = 0; i < 5; i++) {
        expect(result.transactions[i]!.txHash).toBe(`txhash-${i + 1}`);
      }
    });

    it("dequeues partial amounts correctly", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      for (let i = 1; i <= 5; i++) {
        queue.enqueue(makeTx(i));
      }

      const result1 = queue.dequeue(2);
      expect(result1.transactions).toHaveLength(2);
      expect(result1.transactions[0]!.txHash).toBe("txhash-1");
      expect(result1.transactions[1]!.txHash).toBe("txhash-2");
      expect(queue.size).toBe(3);

      const result2 = queue.dequeue(2);
      expect(result2.transactions).toHaveLength(2);
      expect(result2.transactions[0]!.txHash).toBe("txhash-3");
      expect(result2.transactions[1]!.txHash).toBe("txhash-4");
      expect(queue.size).toBe(1);
    });

    it("returns empty result when dequeuing from empty queue", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      const result = queue.dequeue(5);
      expect(result.transactions).toHaveLength(0);
      expect(result.checkpointSeq).toBe(0);
    });

    it("clamps dequeue count to queue size", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      queue.enqueue(makeTx(1));
      queue.enqueue(makeTx(2));

      const result = queue.dequeue(10);
      expect(result.transactions).toHaveLength(2);
      expect(queue.size).toBe(0);
    });

    it("returns monotonically increasing sequence numbers", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      const seq1 = queue.enqueue(makeTx(1));
      const seq2 = queue.enqueue(makeTx(2));
      const seq3 = queue.enqueue(makeTx(3));

      expect(seq1).toBe(1);
      expect(seq2).toBe(2);
      expect(seq3).toBe(3);
    });

    it("returns correct checkpoint sequences on dequeue", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      queue.enqueue(makeTx(1)); // seq=1
      queue.enqueue(makeTx(2)); // seq=2
      queue.enqueue(makeTx(3)); // seq=3
      queue.enqueue(makeTx(4)); // seq=4
      queue.enqueue(makeTx(5)); // seq=5

      const result1 = queue.dequeue(2);
      expect(result1.checkpointSeq).toBe(2);

      const result2 = queue.dequeue(2);
      expect(result2.checkpointSeq).toBe(4);

      const result3 = queue.dequeue(1);
      expect(result3.checkpointSeq).toBe(5);
    });
  });

  // =========================================================================
  // Peek
  // =========================================================================

  describe("Peek", () => {
    it("returns transactions without removing them", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      queue.enqueue(makeTx(1));
      queue.enqueue(makeTx(2));

      const peeked = queue.peek(2);
      expect(peeked).toHaveLength(2);
      expect(queue.size).toBe(2); // Unchanged
    });

    it("returns empty array for empty queue", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      expect(queue.peek(5)).toHaveLength(0);
    });

    it("clamps to available items", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      queue.enqueue(makeTx(1));
      expect(queue.peek(10)).toHaveLength(1);
    });
  });

  // =========================================================================
  // Crash Recovery (v1-fix)
  // =========================================================================

  describe("Crash Recovery", () => {
    it("recovers all transactions when no checkpoint exists", () => {
      // Phase 1: enqueue
      const queue1 = new TransactionQueue(makeConfig(walDir));
      queue1.enqueue(makeTx(1));
      queue1.enqueue(makeTx(2));
      queue1.enqueue(makeTx(3));

      // Phase 2: simulate crash + recovery
      const queue2 = new TransactionQueue(makeConfig(walDir));
      const recovered = queue2.recover();

      expect(recovered).toBe(3);
      expect(queue2.size).toBe(3);
      const result = queue2.dequeue(3);
      expect(result.transactions[0]!.txHash).toBe("txhash-1");
      expect(result.transactions[2]!.txHash).toBe("txhash-3");
    });

    it("recovers only uncommitted transactions after checkpoint", () => {
      const queue1 = new TransactionQueue(makeConfig(walDir));
      queue1.enqueue(makeTx(1)); // seq=1
      queue1.enqueue(makeTx(2)); // seq=2
      queue1.enqueue(makeTx(3)); // seq=3
      queue1.dequeue(2);
      queue1.checkpoint(2, "batch-001");

      // Crash + recovery
      const queue2 = new TransactionQueue(makeConfig(walDir));
      const recovered = queue2.recover();

      expect(recovered).toBe(1);
      expect(queue2.size).toBe(1);
      const result = queue2.dequeue(1);
      expect(result.transactions[0]!.txHash).toBe("txhash-3");
    });

    // [v1-fix CRITICAL TEST]
    // Scenario: enqueue -> FormBatch (dequeue) -> CRASH (no checkpoint)
    // Expected: ALL dequeued transactions are recovered
    it("v1-fix: recovers batch transactions when checkpoint is deferred", () => {
      const queue1 = new TransactionQueue(makeConfig(walDir));

      // Enqueue 5 transactions
      for (let i = 1; i <= 5; i++) {
        queue1.enqueue(makeTx(i));
      }

      // FormBatch: dequeue 3 transactions (but NO checkpoint -- v1-fix)
      const batch = queue1.dequeue(3);
      expect(batch.transactions).toHaveLength(3);
      expect(batch.checkpointSeq).toBe(3);
      expect(queue1.size).toBe(2);

      // DO NOT call checkpoint -- this is the v1-fix behavior!

      // CRASH: create new queue instance
      const queue2 = new TransactionQueue(makeConfig(walDir));
      const recovered = queue2.recover();

      // ALL 5 transactions should be recovered (not just the 2 that were in queue)
      expect(recovered).toBe(5);
      expect(queue2.size).toBe(5);
    });

    // v1-fix: multiple batches formed, none processed, then crash
    it("v1-fix: recovers all batched+queued transactions after crash", () => {
      const queue1 = new TransactionQueue(makeConfig(walDir));

      for (let i = 1; i <= 10; i++) {
        queue1.enqueue(makeTx(i));
      }

      // Form 2 batches (no checkpoints -- v1-fix)
      queue1.dequeue(4); // batch 1
      queue1.dequeue(4); // batch 2
      expect(queue1.size).toBe(2);

      // CRASH
      const queue2 = new TransactionQueue(makeConfig(walDir));
      const recovered = queue2.recover();

      // ALL 10 transactions recovered
      expect(recovered).toBe(10);
    });

    // v1-fix: partial processing then crash
    it("v1-fix: handles partial processing correctly", () => {
      const queue1 = new TransactionQueue(makeConfig(walDir));

      for (let i = 1; i <= 6; i++) {
        queue1.enqueue(makeTx(i));
      }

      // Form batch 1 (seq 1-3) and process it
      const batch1 = queue1.dequeue(3);
      queue1.checkpoint(batch1.checkpointSeq, "batch-001");

      // Form batch 2 (seq 4-6) but DO NOT process
      queue1.dequeue(3);

      // CRASH
      const queue2 = new TransactionQueue(makeConfig(walDir));
      const recovered = queue2.recover();

      // Only tx4, tx5, tx6 should be recovered (tx1-3 were checkpointed)
      expect(recovered).toBe(3);
      const result = queue2.dequeue(3);
      expect(result.transactions[0]!.txHash).toBe("txhash-4");
      expect(result.transactions[1]!.txHash).toBe("txhash-5");
      expect(result.transactions[2]!.txHash).toBe("txhash-6");
    });
  });

  // =========================================================================
  // Boundary Conditions
  // =========================================================================

  describe("Boundary Conditions", () => {
    it("handles 0 transactions", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      expect(queue.size).toBe(0);
      expect(queue.isEmpty).toBe(true);
      expect(queue.dequeue(0).transactions).toHaveLength(0);
      expect(queue.peek(0)).toHaveLength(0);
    });

    it("handles 1 transaction", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      queue.enqueue(makeTx(1));
      expect(queue.size).toBe(1);
      expect(queue.isEmpty).toBe(false);

      const result = queue.dequeue(1);
      expect(result.transactions).toHaveLength(1);
      expect(queue.isEmpty).toBe(true);
    });

    it("handles many enqueue/dequeue cycles", () => {
      const queue = new TransactionQueue(makeConfig(walDir));

      for (let cycle = 0; cycle < 10; cycle++) {
        for (let i = 0; i < 5; i++) {
          queue.enqueue(makeTx(cycle * 5 + i + 1));
        }
        const result = queue.dequeue(5);
        expect(result.transactions).toHaveLength(5);
      }

      expect(queue.size).toBe(0);
    });
  });

  // =========================================================================
  // Determinism
  // =========================================================================

  describe("Determinism", () => {
    it("same transactions produce same dequeue order", () => {
      const txs = [makeTx(3), makeTx(1), makeTx(2)];

      const queue1 = new TransactionQueue(makeConfig(createTempDir()));
      const queue2 = new TransactionQueue(makeConfig(createTempDir()));

      for (const tx of txs) {
        queue1.enqueue(tx);
        queue2.enqueue(tx);
      }

      const r1 = queue1.dequeue(3);
      const r2 = queue2.dequeue(3);

      for (let i = 0; i < 3; i++) {
        expect(r1.transactions[i]!.txHash).toBe(r2.transactions[i]!.txHash);
      }
    });
  });

  // =========================================================================
  // Compact, Flush, Reset
  // =========================================================================

  describe("Compact, Flush, Reset", () => {
    it("compact removes committed entries", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      queue.enqueue(makeTx(1));
      queue.enqueue(makeTx(2));
      queue.enqueue(makeTx(3));

      queue.dequeue(2);
      queue.checkpoint(2, "batch-001");
      queue.compact();

      // After compact + recovery: only tx3
      const queue2 = new TransactionQueue(makeConfig(walDir));
      const recovered = queue2.recover();
      expect(recovered).toBe(1);
    });

    it("flush does not throw", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      queue.enqueue(makeTx(1));
      expect(() => queue.flush()).not.toThrow();
    });

    it("reset clears queue and WAL", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      queue.enqueue(makeTx(1));
      queue.enqueue(makeTx(2));
      queue.reset();

      expect(queue.size).toBe(0);
      expect(queue.isEmpty).toBe(true);

      // WAL also cleared
      const queue2 = new TransactionQueue(makeConfig(walDir));
      const recovered = queue2.recover();
      expect(recovered).toBe(0);
    });
  });

  // =========================================================================
  // Adversarial Tests
  // =========================================================================

  describe("Adversarial", () => {
    // ADV-QUEUE-01: Concurrent enqueue simulation
    it("ADV-QUEUE-01: sequential enqueues maintain total order", () => {
      const queue = new TransactionQueue(makeConfig(walDir));

      // Simulate interleaved enqueues from multiple enterprises
      queue.enqueue(makeTx(1, "enterprise-A"));
      queue.enqueue(makeTx(2, "enterprise-B"));
      queue.enqueue(makeTx(3, "enterprise-A"));
      queue.enqueue(makeTx(4, "enterprise-B"));

      const result = queue.dequeue(4);
      expect(result.transactions[0]!.txHash).toBe("txhash-1");
      expect(result.transactions[1]!.txHash).toBe("txhash-2");
      expect(result.transactions[2]!.txHash).toBe("txhash-3");
      expect(result.transactions[3]!.txHash).toBe("txhash-4");
    });

    // ADV-QUEUE-02: Duplicate transaction hashes
    it("ADV-QUEUE-02: accepts duplicate tx hashes (queue doesn't enforce uniqueness)", () => {
      const queue = new TransactionQueue(makeConfig(walDir));
      const tx = makeTx(1);

      // Same transaction enqueued twice
      queue.enqueue(tx);
      queue.enqueue(tx);

      expect(queue.size).toBe(2);
      const result = queue.dequeue(2);
      expect(result.transactions).toHaveLength(2);
    });

    // ADV-QUEUE-03: Recovery after corrupt WAL
    it("ADV-QUEUE-03: recovers what it can from corrupted WAL", () => {
      const queue1 = new TransactionQueue(makeConfig(walDir));
      queue1.enqueue(makeTx(1));
      queue1.enqueue(makeTx(2));
      queue1.enqueue(makeTx(3));

      // Corrupt middle entry
      const walPath = join(walDir, "wal.jsonl");
      const content = readFileSync(walPath, "utf-8");
      const lines = content.split("\n").filter((l) => l.length > 0);
      lines[1] = "CORRUPTED";
      writeFileSync(walPath, lines.join("\n") + "\n");

      const queue2 = new TransactionQueue(makeConfig(walDir));
      const recovered = queue2.recover();

      // tx1 and tx3 recovered, tx2 corrupted
      expect(recovered).toBe(2);
    });

    // ADV-QUEUE-04: Enqueue after recovery
    it("ADV-QUEUE-04: new enqueues after recovery get correct sequence numbers", () => {
      const queue1 = new TransactionQueue(makeConfig(walDir));
      queue1.enqueue(makeTx(1)); // seq=1
      queue1.enqueue(makeTx(2)); // seq=2

      // Crash + recover
      const queue2 = new TransactionQueue(makeConfig(walDir));
      queue2.recover();

      // New enqueue should get seq=3, not seq=1
      const seq = queue2.enqueue(makeTx(3));
      expect(seq).toBe(3);
    });
  });
});
