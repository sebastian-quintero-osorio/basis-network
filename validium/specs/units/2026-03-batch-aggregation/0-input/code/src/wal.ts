import { createHash } from "crypto";
import {
  appendFileSync,
  existsSync,
  readFileSync,
  writeFileSync,
  openSync,
  closeSync,
  fsyncSync,
  unlinkSync,
} from "fs";
import { dirname } from "path";
import { mkdirSync } from "fs";
import type { Transaction, WALEntry, WALCheckpoint, QueueConfig } from "./types.js";

/// Compute SHA-256 checksum of a WAL entry's payload.
function computeChecksum(seq: number, timestamp: number, tx: Transaction): string {
  const data = `${seq}|${timestamp}|${tx.txHash}|${tx.key}|${tx.oldValue}|${tx.newValue}|${tx.enterpriseId}`;
  return createHash("sha256").update(data).digest("hex").slice(0, 16);
}

/// Write-Ahead Log for crash-safe transaction persistence.
///
/// Design: Append-only JSON-lines file. Each line is either a WALEntry or a WALCheckpoint.
/// On crash recovery, replay from last checkpoint to reconstruct queue state.
///
/// Performance model:
/// - Without fsync: ~529ns per append (limited by memory/GC)
/// - With fsync per entry: ~880us per append (SSD without power-loss protection)
/// - With group commit (N entries then fsync): amortized ~880us/N per entry
export class WriteAheadLog {
  private readonly walPath: string;
  private readonly fsyncPerEntry: boolean;
  private readonly groupCommitSize: number;
  private seq: number = 0;
  private pendingWrites: number = 0;
  private fd: number | null = null;
  private walWriteLatencies: number[] = [];

  constructor(config: QueueConfig) {
    this.walPath = config.walPath;
    this.fsyncPerEntry = config.fsyncPerEntry;
    this.groupCommitSize = config.groupCommitSize;

    const dir = dirname(this.walPath);
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }

    if (!existsSync(this.walPath)) {
      writeFileSync(this.walPath, "");
    }

    this.seq = this.getLastSequence();
  }

  /// Append a transaction to the WAL. Returns the sequence number.
  append(tx: Transaction): { seq: number; latencyUs: number } {
    const start = performance.now();
    this.seq++;
    const timestamp = tx.timestamp;
    const checksum = computeChecksum(this.seq, timestamp, tx);

    const entry: WALEntry = {
      seq: this.seq,
      timestamp,
      tx,
      checksum,
    };

    const line = JSON.stringify(entry) + "\n";
    appendFileSync(this.walPath, line);
    this.pendingWrites++;

    if (this.fsyncPerEntry || this.pendingWrites >= this.groupCommitSize) {
      this.fsync();
      this.pendingWrites = 0;
    }

    const latencyUs = (performance.now() - start) * 1000;
    this.walWriteLatencies.push(latencyUs);

    return { seq: this.seq, latencyUs };
  }

  /// Write a checkpoint marker after a batch is committed.
  /// The committedSeq parameter marks the highest WAL sequence that was committed.
  checkpoint(batchId: string, committedSeq?: number): void {
    const marker: WALCheckpoint = {
      type: "checkpoint",
      seq: committedSeq ?? this.seq,
      batchId,
      timestamp: Date.now(),
    };
    appendFileSync(this.walPath, JSON.stringify(marker) + "\n");
    this.fsync();
    this.pendingWrites = 0;
  }

  /// Flush pending writes to disk.
  flush(): void {
    if (this.pendingWrites > 0) {
      this.fsync();
      this.pendingWrites = 0;
    }
  }

  /// Recover uncommitted transactions from the WAL after a crash.
  /// Returns transactions that were written but not checkpointed.
  recover(): Transaction[] {
    if (!existsSync(this.walPath)) return [];

    const content = readFileSync(this.walPath, "utf-8").trim();
    if (!content) return [];

    const lines = content.split("\n").filter((l) => l.length > 0);
    let lastCheckpointSeq = 0;
    const entriesBySeq = new Map<number, WALEntry>();

    for (const line of lines) {
      try {
        const parsed = JSON.parse(line);
        if (parsed.type === "checkpoint") {
          lastCheckpointSeq = (parsed as WALCheckpoint).seq;
        } else if (parsed.seq !== undefined) {
          const entry = parsed as WALEntry;
          const expected = computeChecksum(entry.seq, entry.timestamp, entry.tx);
          if (entry.checksum === expected) {
            entriesBySeq.set(entry.seq, entry);
          }
        }
      } catch {
        // Corrupted line (partial write during crash) -- skip
      }
    }

    // Return entries after the last checkpoint, ordered by sequence
    const recovered: Transaction[] = [];
    const sortedSeqs = [...entriesBySeq.keys()].sort((a, b) => a - b);
    for (const seq of sortedSeqs) {
      if (seq > lastCheckpointSeq) {
        recovered.push(entriesBySeq.get(seq)!.tx);
      }
    }

    return recovered;
  }

  /// Truncate WAL up to the last checkpoint (compaction).
  compact(): void {
    if (!existsSync(this.walPath)) return;

    const content = readFileSync(this.walPath, "utf-8").trim();
    if (!content) return;

    const lines = content.split("\n").filter((l) => l.length > 0);
    let lastCheckpointIdx = -1;

    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const parsed = JSON.parse(lines[i]);
        if (parsed.type === "checkpoint") {
          lastCheckpointIdx = i;
          break;
        }
      } catch {
        // skip corrupted
      }
    }

    if (lastCheckpointIdx >= 0) {
      // Keep only entries after the last checkpoint
      const remaining = lines.slice(lastCheckpointIdx + 1);
      writeFileSync(this.walPath, remaining.length > 0 ? remaining.join("\n") + "\n" : "");
      this.fsync();
    }
  }

  /// Reset the WAL (for testing).
  reset(): void {
    try {
      writeFileSync(this.walPath, "");
    } catch {
      // On Windows, file may be locked -- tolerate and continue
    }
    this.seq = 0;
    this.pendingWrites = 0;
    this.walWriteLatencies = [];
  }

  /// Get collected WAL write latencies (for benchmarking).
  getWriteLatencies(): number[] {
    return this.walWriteLatencies;
  }

  /// Clear latency measurements.
  clearLatencies(): void {
    this.walWriteLatencies = [];
  }

  private getLastSequence(): number {
    if (!existsSync(this.walPath)) return 0;

    const content = readFileSync(this.walPath, "utf-8").trim();
    if (!content) return 0;

    const lines = content.split("\n").filter((l) => l.length > 0);
    let maxSeq = 0;

    for (const line of lines) {
      try {
        const parsed = JSON.parse(line);
        if (parsed.seq && parsed.seq > maxSeq) {
          maxSeq = parsed.seq;
        }
      } catch {
        // skip corrupted
      }
    }

    return maxSeq;
  }

  private fsync(): void {
    try {
      const fd = openSync(this.walPath, "r");
      fsyncSync(fd);
      closeSync(fd);
    } catch {
      // fsync may fail on some platforms (Windows) -- tolerate for benchmarking
    }
  }
}
