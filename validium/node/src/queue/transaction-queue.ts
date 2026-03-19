/**
 * Persistent FIFO transaction queue with write-ahead logging.
 *
 * [Spec: validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla]
 *
 * Guarantees:
 * - Total ordering: transactions ordered by WAL sequence number (FIFO).
 * - Persistence: every enqueued transaction is WAL-written before acknowledgment.
 * - Crash recovery: on restart, replays WAL from last checkpoint to reconstruct state.
 * - No premature checkpoint: checkpoint is called externally after downstream processing (v1-fix).
 *
 * [Spec: queue variable -- volatile, cleared on Crash, rebuilt on Recover]
 * [Spec: wal variable -- durable, persists across Crash/Recover]
 *
 * @module queue/transaction-queue
 */

import { WriteAheadLog } from "./wal";
import type { Transaction, WALConfig, DequeueResult } from "./types";
import { QueueError, QueueErrorCode } from "./types";

/** Internal queue item: transaction paired with its WAL sequence number. */
interface QueueItem {
  readonly tx: Transaction;
  readonly seq: number;
}

export class TransactionQueue {
  private items: QueueItem[] = [];
  private readonly wal: WriteAheadLog;

  constructor(config: WALConfig) {
    this.wal = new WriteAheadLog(config);
  }

  /**
   * Enqueue a transaction. Persisted to WAL before returning.
   * Returns the assigned WAL sequence number.
   *
   * [Spec: Enqueue(tx)]
   *   wal' = Append(wal, tx)
   *   queue' = Append(queue, tx)
   */
  enqueue(tx: Transaction): number {
    const seq = this.wal.append(tx);
    this.items.push({ tx, seq });
    return seq;
  }

  /**
   * Dequeue up to n transactions in FIFO order.
   * Returns the transactions and the checkpoint sequence for deferred checkpointing.
   *
   * Does NOT write a checkpoint. The caller must call checkpoint() after
   * downstream processing is complete (v1-fix).
   *
   * [Spec: FormBatch]
   *   queue' = SubSeq(queue, batchSize + 1, Len(queue))
   *   UNCHANGED << wal, checkpointSeq >>   -- NO checkpoint at formation!
   */
  dequeue(n: number): DequeueResult {
    const count = Math.min(n, this.items.length);
    if (count === 0) {
      return { transactions: [], checkpointSeq: 0 };
    }

    const removed = this.items.splice(0, count);
    const lastItem = removed[removed.length - 1]!;

    return {
      transactions: removed.map((item) => item.tx),
      checkpointSeq: lastItem.seq,
    };
  }

  /**
   * Peek at the next n transactions without removing them.
   */
  peek(n: number): readonly Transaction[] {
    return this.items.slice(0, Math.min(n, this.items.length)).map((item) => item.tx);
  }

  /**
   * Write a checkpoint to the WAL marking all entries up to checkpointSeq as committed.
   * Called by the BatchAggregator after downstream processing is complete.
   *
   * [Spec: ProcessBatch]
   *   checkpointSeq' = checkpointSeq + Len(Head(batches))
   *
   * [v1-fix: This is the ONLY place checkpoints are written.]
   */
  checkpoint(checkpointSeq: number, batchId: string): void {
    this.wal.checkpoint(checkpointSeq, batchId);
  }

  /**
   * Recover from crash: replay WAL and reconstruct the queue.
   * Returns the number of recovered transactions.
   *
   * [Spec: Recover]
   *   queue' = SubSeq(wal, checkpointSeq + 1, Len(wal))
   *
   * After recovery, the queue contains ALL uncommitted transactions,
   * including those that were in formed-but-unprocessed batches (v1-fix).
   */
  recover(): number {
    const result = this.wal.recover();
    this.items = result.transactions.map((tx, i) => ({
      tx,
      seq: result.lastCheckpointSeq + i + 1,
    }));
    return result.transactions.length;
  }

  /**
   * Compact the WAL by removing committed entries.
   */
  compact(): void {
    this.wal.compact();
  }

  /**
   * Flush any pending WAL writes to disk.
   */
  flush(): void {
    this.wal.flush();
  }

  /**
   * Reset queue and WAL (for testing only).
   */
  reset(): void {
    this.items = [];
    this.wal.reset();
  }

  /** Number of transactions currently in the queue. */
  get size(): number {
    return this.items.length;
  }

  /** Whether the queue is empty. */
  get isEmpty(): boolean {
    return this.items.length === 0;
  }
}
