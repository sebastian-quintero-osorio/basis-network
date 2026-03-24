/**
 * Write-Ahead Log for crash-safe transaction persistence.
 *
 * [Spec: validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla]
 *
 * Design: Append-only JSON-lines file. Each line is either a WALEntry or WALCheckpoint.
 * On crash recovery, replays from last checkpoint to reconstruct queue state.
 *
 * Durability model:
 * - With fsync: each write is durable before acknowledgment (crash-safe)
 * - Without fsync: writes are buffered (faster, suitable for testing)
 *
 * [Spec: wal variable -- durable, persists across Crash/Recover]
 * [Spec: checkpointSeq variable -- encoded as WALCheckpoint markers in the log]
 *
 * @module queue/wal
 */

import {
  createHash,
  createHmac,
  createCipheriv,
  createDecipheriv,
  randomBytes,
} from "crypto";
import {
  appendFileSync,
  existsSync,
  readFileSync,
  writeFileSync,
  openSync,
  closeSync,
  fsyncSync,
  mkdirSync,
} from "fs";
import { join } from "path";
import type { Transaction, WALEntry, WALCheckpoint, WALConfig } from "./types";
import { QueueError, QueueErrorCode } from "./types";

/** WAL file name within the configured directory. */
const WAL_FILENAME = "wal.jsonl";

/**
 * Compute SHA-256 integrity checksum for a WAL entry.
 * Truncated to 16 hex characters (64 bits) for space efficiency.
 */
function computeChecksum(seq: number, timestamp: number, tx: Transaction): string {
  const data = `${seq}|${timestamp}|${tx.txHash}|${tx.key}|${tx.oldValue}|${tx.newValue}|${tx.enterpriseId}`;
  return createHash("sha256").update(data).digest("hex").slice(0, 16);
}

/**
 * Compute HMAC-SHA256 for a checkpoint marker.
 * Binds seq, batchId, and timestamp to prevent injection.
 * Truncated to 32 hex characters (128 bits) for compactness.
 */
function computeCheckpointHmac(
  seq: number,
  batchId: string,
  timestamp: number,
  key: string
): string {
  return createHmac("sha256", key)
    .update(`checkpoint|${seq}|${batchId}|${timestamp}`)
    .digest("hex")
    .slice(0, 32);
}

/**
 * Validate that a parsed object is a WAL entry with a valid checksum.
 * Returns the entry if valid, undefined otherwise.
 */
function validateEntry(record: Record<string, unknown>): WALEntry | undefined {
  if (
    typeof record["seq"] !== "number" ||
    typeof record["timestamp"] !== "number" ||
    typeof record["checksum"] !== "string" ||
    typeof record["tx"] !== "object" ||
    record["tx"] === null
  ) {
    return undefined;
  }

  const entry = record as unknown as WALEntry;
  const expected = computeChecksum(entry.seq, entry.timestamp, entry.tx);
  if (entry.checksum !== expected) {
    return undefined;
  }

  return entry;
}

/**
 * Encrypt a plaintext line with AES-256-GCM.
 * Output format: base64(iv + ciphertext + authTag) -- single line, no newlines.
 */
function encryptLine(plaintext: string, keyHex: string): string {
  const key = Buffer.from(keyHex, "hex");
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return Buffer.concat([iv, encrypted, authTag]).toString("base64");
}

/**
 * Decrypt a line encrypted by encryptLine.
 * Returns the plaintext, or undefined if decryption fails (wrong key, tampered data).
 */
function decryptLine(encoded: string, keyHex: string): string | undefined {
  try {
    const key = Buffer.from(keyHex, "hex");
    const data = Buffer.from(encoded, "base64");
    const iv = data.subarray(0, 12);
    const authTag = data.subarray(data.length - 16);
    const ciphertext = data.subarray(12, data.length - 16);
    const decipher = createDecipheriv("aes-256-gcm", key, iv);
    decipher.setAuthTag(authTag);
    return decipher.update(ciphertext) + decipher.final("utf8");
  } catch {
    return undefined;
  }
}

export class WriteAheadLog {
  private readonly walPath: string;
  private readonly fsyncOnWrite: boolean;
  private readonly hmacKey?: string;
  private readonly encryptionKey?: string;
  private seq: number;

  constructor(config: WALConfig) {
    if (!config.walDir) {
      throw new QueueError(QueueErrorCode.INVALID_CONFIG, "walDir must be specified");
    }

    this.walPath = join(config.walDir, WAL_FILENAME);
    this.fsyncOnWrite = config.fsyncOnWrite;
    this.hmacKey = config.hmacKey;
    this.encryptionKey = config.encryptionKey;

    if (!existsSync(config.walDir)) {
      mkdirSync(config.walDir, { recursive: true });
    }

    if (!existsSync(this.walPath)) {
      writeFileSync(this.walPath, "");
    }

    this.seq = this.readLastSequence();
  }

  /**
   * Append a transaction to the WAL. Returns the assigned sequence number.
   * The transaction is persisted to disk before this method returns.
   *
   * [Spec: Enqueue(tx) -- wal' = Append(wal, tx)]
   */
  append(tx: Transaction): number {
    this.seq++;
    const entry: WALEntry = {
      seq: this.seq,
      timestamp: tx.timestamp,
      tx,
      checksum: computeChecksum(this.seq, tx.timestamp, tx),
    };

    const json = JSON.stringify(entry);
    const line = (this.encryptionKey ? encryptLine(json, this.encryptionKey) : json) + "\n";

    try {
      appendFileSync(this.walPath, line);
    } catch (error) {
      this.seq--;
      throw new QueueError(
        QueueErrorCode.WAL_WRITE_FAILED,
        `Failed to append entry seq=${this.seq + 1}: ${error instanceof Error ? error.message : String(error)}`
      );
    }

    if (this.fsyncOnWrite) {
      this.fsync();
    }

    return this.seq;
  }

  /**
   * Write a checkpoint marker to the WAL.
   * Marks all entries up to committedSeq as durably consumed by downstream.
   *
   * [Spec: ProcessBatch -- checkpointSeq' = checkpointSeq + Len(Head(batches))]
   * [v1-fix: Checkpoint written at ProcessBatch time, NOT FormBatch time]
   */
  checkpoint(committedSeq: number, batchId: string): void {
    const timestamp = Date.now();
    const marker: WALCheckpoint = {
      type: "checkpoint",
      seq: committedSeq,
      batchId,
      timestamp,
      ...(this.hmacKey
        ? { hmac: computeCheckpointHmac(committedSeq, batchId, timestamp, this.hmacKey) }
        : {}),
    };

    const json = JSON.stringify(marker);
    const line = (this.encryptionKey ? encryptLine(json, this.encryptionKey) : json) + "\n";

    try {
      appendFileSync(this.walPath, line);
    } catch (error) {
      throw new QueueError(
        QueueErrorCode.WAL_CHECKPOINT_FAILED,
        `Failed to write checkpoint seq=${committedSeq}: ${error instanceof Error ? error.message : String(error)}`
      );
    }

    // Checkpoints are always fsynced for durability
    this.fsync();
  }

  /**
   * Recover uncommitted transactions from the WAL.
   * Returns all transactions with sequence numbers after the last checkpoint,
   * ordered by sequence number (FIFO).
   *
   * Corrupted entries (bad checksum or malformed JSON) are silently skipped.
   * This handles partial writes from crashes during append.
   *
   * [Spec: Recover -- queue' = SubSeq(wal, checkpointSeq + 1, Len(wal))]
   */
  recover(): { transactions: Transaction[]; lastCheckpointSeq: number; corruptedEntries: number } {
    if (!existsSync(this.walPath)) {
      return { transactions: [], lastCheckpointSeq: 0, corruptedEntries: 0 };
    }

    let content: string;
    try {
      content = readFileSync(this.walPath, "utf-8").trim();
    } catch (error) {
      throw new QueueError(
        QueueErrorCode.WAL_RECOVERY_FAILED,
        `Failed to read WAL: ${error instanceof Error ? error.message : String(error)}`
      );
    }

    if (!content) {
      return { transactions: [], lastCheckpointSeq: 0, corruptedEntries: 0 };
    }

    const rawLines = content.split("\n").filter((l) => l.length > 0);
    let lastCheckpointSeq = 0;
    const entriesBySeq = new Map<number, WALEntry>();
    let corruptedEntries = 0;

    for (const rawLine of rawLines) {
      try {
        // Decrypt if encryption is enabled; otherwise parse directly.
        const line = this.encryptionKey ? decryptLine(rawLine, this.encryptionKey) : rawLine;
        if (line === undefined) {
          corruptedEntries++;
          continue;
        }
        const parsed: unknown = JSON.parse(line);
        if (typeof parsed !== "object" || parsed === null) {
          corruptedEntries++;
          continue;
        }

        const record = parsed as Record<string, unknown>;

        if (record["type"] === "checkpoint") {
          const seq = record["seq"];
          if (typeof seq === "number") {
            // When HMAC key is configured, reject checkpoints without valid HMAC.
            // This mitigates the checkpoint injection attack (ADV-WAL-04).
            if (this.hmacKey) {
              const expectedHmac = computeCheckpointHmac(
                seq,
                String(record["batchId"] ?? ""),
                Number(record["timestamp"] ?? 0),
                this.hmacKey
              );
              if (record["hmac"] !== expectedHmac) {
                corruptedEntries++;
                continue;
              }
            }
            lastCheckpointSeq = seq;
          }
        } else {
          const entry = validateEntry(record);
          if (entry) {
            entriesBySeq.set(entry.seq, entry);
          } else {
            corruptedEntries++;
          }
        }
      } catch {
        // Malformed line (partial write during crash) -- skip
        corruptedEntries++;
      }
    }

    // Return entries after the last checkpoint, ordered by sequence (FIFO)
    const transactions: Transaction[] = [];
    const sortedSeqs = [...entriesBySeq.keys()].sort((a, b) => a - b);
    for (const seq of sortedSeqs) {
      if (seq > lastCheckpointSeq) {
        const entry = entriesBySeq.get(seq);
        if (entry) {
          transactions.push(entry.tx);
        }
      }
    }

    // Update internal sequence counter to highest seen
    if (sortedSeqs.length > 0) {
      const maxSeq = sortedSeqs[sortedSeqs.length - 1];
      if (maxSeq !== undefined) {
        this.seq = maxSeq;
      }
    }

    return { transactions, lastCheckpointSeq, corruptedEntries };
  }

  /**
   * Compact the WAL by removing committed entries.
   * Uses sequence numbers (not file position) to determine which entries to keep.
   * This is critical because entries may appear before checkpoint markers in
   * the file while having sequence numbers after the checkpoint value.
   */
  compact(): void {
    if (!existsSync(this.walPath)) return;

    let content: string;
    try {
      content = readFileSync(this.walPath, "utf-8").trim();
    } catch {
      return;
    }

    if (!content) return;

    const rawLines = content.split("\n").filter((l) => l.length > 0);
    let lastCheckpointSeq = 0;

    // Find the highest checkpoint sequence
    for (const rawLine of rawLines) {
      try {
        const line = this.encryptionKey ? decryptLine(rawLine, this.encryptionKey) : rawLine;
        if (line === undefined) continue;
        const parsed: unknown = JSON.parse(line);
        if (
          typeof parsed === "object" &&
          parsed !== null &&
          (parsed as Record<string, unknown>)["type"] === "checkpoint"
        ) {
          const seq = (parsed as Record<string, unknown>)["seq"];
          if (typeof seq === "number" && seq > lastCheckpointSeq) {
            lastCheckpointSeq = seq;
          }
        }
      } catch {
        // skip
      }
    }

    if (lastCheckpointSeq === 0) return;

    // Keep only entries with seq > lastCheckpointSeq (drop checkpoints and committed entries)
    // Remaining lines stay in their original format (encrypted or plain).
    const remaining: string[] = [];
    for (const rawLine of rawLines) {
      try {
        const line = this.encryptionKey ? decryptLine(rawLine, this.encryptionKey) : rawLine;
        if (line === undefined) continue;
        const parsed: unknown = JSON.parse(line);
        if (typeof parsed !== "object" || parsed === null) continue;
        const record = parsed as Record<string, unknown>;
        if (record["type"] === "checkpoint") continue;
        const seq = record["seq"];
        if (typeof seq === "number" && seq > lastCheckpointSeq) {
          // Re-encrypt if needed (new IV for each write)
          remaining.push(this.encryptionKey ? encryptLine(line, this.encryptionKey) : rawLine);
        }
      } catch {
        // Drop corrupt lines during compaction
      }
    }

    writeFileSync(
      this.walPath,
      remaining.length > 0 ? remaining.join("\n") + "\n" : ""
    );
    if (this.fsyncOnWrite) {
      this.fsync();
    }
  }

  /**
   * Flush pending writes to disk via fsync.
   */
  flush(): void {
    this.fsync();
  }

  /**
   * Reset the WAL (for testing only).
   */
  reset(): void {
    writeFileSync(this.walPath, "");
    this.seq = 0;
  }

  /** Current sequence number (highest assigned). */
  get currentSeq(): number {
    return this.seq;
  }

  /** Path to the WAL file. */
  get filePath(): string {
    return this.walPath;
  }

  /**
   * Read the highest sequence number from the existing WAL file.
   */
  private readLastSequence(): number {
    if (!existsSync(this.walPath)) return 0;

    let content: string;
    try {
      content = readFileSync(this.walPath, "utf-8").trim();
    } catch {
      return 0;
    }

    if (!content) return 0;

    const rawLines = content.split("\n").filter((l) => l.length > 0);
    let maxSeq = 0;

    for (const rawLine of rawLines) {
      try {
        const line = this.encryptionKey ? decryptLine(rawLine, this.encryptionKey) : rawLine;
        if (line === undefined) continue;
        const parsed: unknown = JSON.parse(line);
        if (typeof parsed === "object" && parsed !== null) {
          const seq = (parsed as Record<string, unknown>)["seq"];
          if (typeof seq === "number" && seq > maxSeq) {
            maxSeq = seq;
          }
        }
      } catch {
        // skip corrupted
      }
    }

    return maxSeq;
  }

  /**
   * Force sync WAL file to disk.
   */
  private fsync(): void {
    let fd: number | undefined;
    try {
      fd = openSync(this.walPath, "r");
      fsyncSync(fd);
    } catch {
      // fsync may not be supported on all platforms (e.g., some Windows configs).
      // In production (Linux), this should not fail on a healthy filesystem.
    } finally {
      if (fd !== undefined) {
        try {
          closeSync(fd);
        } catch {
          // Ignore close errors
        }
      }
    }
  }
}
