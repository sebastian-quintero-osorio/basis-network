import type { Transaction, QueueConfig } from "./types.js";
import { WriteAheadLog } from "./wal.js";

/// Internal queue item: transaction paired with its WAL sequence number.
interface QueueItem {
  tx: Transaction;
  seq: number;
}

/// Persistent FIFO transaction queue with write-ahead logging.
///
/// Guarantees:
/// - Total ordering: Transactions are ordered by (timestamp, sequence number).
/// - Persistence: Every enqueued transaction is WAL-written before acknowledgment.
/// - Crash recovery: On restart, replays WAL to reconstruct queue state.
/// - Determinism: Same transactions produce same ordering (stable sort by timestamp).
///
/// Design reference: PostgreSQL WAL, Kafka append-only log, ARIES crash recovery.
export class PersistentQueue {
  private queue: QueueItem[] = [];
  private readonly wal: WriteAheadLog;
  private enqueuedCount: number = 0;
  private dequeuedCount: number = 0;
  private lastDequeuedSeq: number = 0;

  constructor(config: QueueConfig) {
    this.wal = new WriteAheadLog(config);
  }

  /// Enqueue a transaction. Persisted to WAL before returning.
  enqueue(tx: Transaction): { seq: number; walLatencyUs: number } {
    const result = this.wal.append(tx);
    this.queue.push({ tx, seq: result.seq });
    this.enqueuedCount++;
    return result;
  }

  /// Dequeue up to N transactions in FIFO order.
  /// Does NOT remove from WAL -- call checkpoint() after batch is committed.
  dequeue(n: number): Transaction[] {
    const count = Math.min(n, this.queue.length);
    if (count === 0) return [];

    const items = this.queue.splice(0, count);
    this.dequeuedCount += items.length;

    // Track the highest dequeued sequence number for checkpoint
    if (items.length > 0) {
      this.lastDequeuedSeq = items[items.length - 1].seq;
    }

    return items.map((item) => item.tx);
  }

  /// Peek at the next N transactions without removing them.
  peek(n: number): Transaction[] {
    return this.queue.slice(0, Math.min(n, this.queue.length)).map((item) => item.tx);
  }

  /// Write a checkpoint to the WAL (called after batch is committed).
  /// Marks all transactions up to lastDequeuedSeq as committed.
  checkpoint(batchId: string): void {
    this.wal.checkpoint(batchId, this.lastDequeuedSeq);
  }

  /// Recover from crash: replay WAL and reconstruct queue.
  recover(): number {
    const recovered = this.wal.recover();
    this.queue = recovered.map((tx, i) => ({ tx, seq: i + 1 }));
    this.enqueuedCount = recovered.length;
    return recovered.length;
  }

  /// Compact the WAL (remove checkpointed entries).
  compact(): void {
    this.wal.compact();
  }

  /// Flush any pending WAL writes to disk.
  flush(): void {
    this.wal.flush();
  }

  /// Reset queue and WAL (for testing).
  reset(): void {
    this.queue = [];
    this.enqueuedCount = 0;
    this.dequeuedCount = 0;
    this.lastDequeuedSeq = 0;
    this.wal.reset();
  }

  get size(): number {
    return this.queue.length;
  }

  get totalEnqueued(): number {
    return this.enqueuedCount;
  }

  get totalDequeued(): number {
    return this.dequeuedCount;
  }

  /// Get WAL write latencies for benchmarking.
  getWalWriteLatencies(): number[] {
    return this.wal.getWriteLatencies();
  }

  /// Clear latency measurements.
  clearLatencies(): void {
    this.wal.clearLatencies();
  }
}
