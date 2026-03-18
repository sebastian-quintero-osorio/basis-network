/**
 * Unit and adversarial tests for the Write-Ahead Log.
 *
 * [Spec: validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla]
 */

import { mkdtempSync, rmSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { WriteAheadLog } from "../wal";
import { QueueError, QueueErrorCode } from "../types";
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
  return mkdtempSync(join(tmpdir(), "wal-test-"));
}

function makeConfig(walDir: string): WALConfig {
  return { walDir, fsyncOnWrite: false };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("WriteAheadLog", () => {
  let walDir: string;

  beforeEach(() => {
    walDir = createTempDir();
  });

  afterEach(() => {
    rmSync(walDir, { recursive: true, force: true });
  });

  // =========================================================================
  // Construction
  // =========================================================================

  describe("Construction", () => {
    it("creates WAL file on initialization", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      expect(wal.currentSeq).toBe(0);
      expect(wal.filePath).toBe(join(walDir, "wal.jsonl"));
    });

    it("creates directory if it does not exist", () => {
      const nested = join(walDir, "sub", "dir");
      const wal = new WriteAheadLog(makeConfig(nested));
      expect(wal.currentSeq).toBe(0);
    });

    it("rejects empty walDir", () => {
      expect(() => new WriteAheadLog({ walDir: "", fsyncOnWrite: false })).toThrow(QueueError);
    });

    it("recovers sequence counter from existing WAL", () => {
      const wal1 = new WriteAheadLog(makeConfig(walDir));
      wal1.append(makeTx(1));
      wal1.append(makeTx(2));
      wal1.append(makeTx(3));

      // New instance reads existing WAL
      const wal2 = new WriteAheadLog(makeConfig(walDir));
      expect(wal2.currentSeq).toBe(3);
    });
  });

  // =========================================================================
  // Append
  // =========================================================================

  describe("Append", () => {
    it("assigns monotonically increasing sequence numbers", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      expect(wal.append(makeTx(1))).toBe(1);
      expect(wal.append(makeTx(2))).toBe(2);
      expect(wal.append(makeTx(3))).toBe(3);
    });

    it("persists entries as JSON lines", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));

      const content = readFileSync(wal.filePath, "utf-8").trim();
      const lines = content.split("\n");
      expect(lines).toHaveLength(2);

      const entry1 = JSON.parse(lines[0]!);
      expect(entry1.seq).toBe(1);
      expect(entry1.tx.txHash).toBe("txhash-1");
      expect(entry1.checksum).toBeDefined();
    });

    it("includes integrity checksum in each entry", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));

      const content = readFileSync(wal.filePath, "utf-8").trim();
      const entry = JSON.parse(content);
      expect(typeof entry.checksum).toBe("string");
      expect(entry.checksum).toHaveLength(16);
    });
  });

  // =========================================================================
  // Checkpoint
  // =========================================================================

  describe("Checkpoint", () => {
    it("writes checkpoint marker with correct seq", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));
      wal.checkpoint(2, "batch-001");

      const content = readFileSync(wal.filePath, "utf-8").trim();
      const lines = content.split("\n");
      expect(lines).toHaveLength(3);

      const checkpoint = JSON.parse(lines[2]!);
      expect(checkpoint.type).toBe("checkpoint");
      expect(checkpoint.seq).toBe(2);
      expect(checkpoint.batchId).toBe("batch-001");
    });
  });

  // =========================================================================
  // Recovery
  // =========================================================================

  describe("Recovery", () => {
    it("returns all entries when no checkpoint exists", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));
      wal.append(makeTx(3));

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(3);
      expect(result.lastCheckpointSeq).toBe(0);
      expect(result.transactions[0]!.txHash).toBe("txhash-1");
      expect(result.transactions[2]!.txHash).toBe("txhash-3");
    });

    it("returns only uncommitted entries after checkpoint", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));
      wal.checkpoint(2, "batch-001");
      wal.append(makeTx(3));

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(1);
      expect(result.transactions[0]!.txHash).toBe("txhash-3");
      expect(result.lastCheckpointSeq).toBe(2);
    });

    it("handles multiple checkpoints correctly", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));
      wal.checkpoint(2, "batch-001");
      wal.append(makeTx(3));
      wal.append(makeTx(4));
      wal.checkpoint(4, "batch-002");
      wal.append(makeTx(5));

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(1);
      expect(result.transactions[0]!.txHash).toBe("txhash-5");
      expect(result.lastCheckpointSeq).toBe(4);
    });

    it("returns empty array for empty WAL", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      const result = wal.recover();
      expect(result.transactions).toHaveLength(0);
      expect(result.lastCheckpointSeq).toBe(0);
    });

    it("preserves FIFO ordering in recovered transactions", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      for (let i = 1; i <= 5; i++) {
        wal.append(makeTx(i));
      }

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      for (let i = 0; i < 5; i++) {
        expect(result.transactions[i]!.txHash).toBe(`txhash-${i + 1}`);
      }
    });

    // [v1-fix CRITICAL TEST] Crash between FormBatch and ProcessBatch
    it("recovers batch transactions when checkpoint is deferred (v1-fix)", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      // Enqueue 5 transactions
      for (let i = 1; i <= 5; i++) {
        wal.append(makeTx(i));
      }
      // Simulate: FormBatch dequeues tx1, tx2 into a batch
      // v1-fix: NO checkpoint written here!
      // Simulate: Crash occurs

      // Recovery should return ALL 5 transactions
      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(5);
      expect(result.lastCheckpointSeq).toBe(0);
    });

    // Contrast with what v0 would do (checkpoint at FormBatch)
    it("v0 behavior would lose batch transactions (regression proof)", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      for (let i = 1; i <= 5; i++) {
        wal.append(makeTx(i));
      }
      // v0 BUG: checkpoint at FormBatch time
      wal.checkpoint(2, "batch-001");
      // Crash occurs before ProcessBatch

      // Only tx3, tx4, tx5 recovered -- tx1, tx2 LOST!
      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(3);
      // This demonstrates the v0 bug: 2 transactions silently lost
    });
  });

  // =========================================================================
  // Compaction
  // =========================================================================

  describe("Compaction", () => {
    it("removes committed entries from WAL file", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));
      wal.checkpoint(2, "batch-001");
      wal.append(makeTx(3));
      wal.compact();

      const content = readFileSync(wal.filePath, "utf-8").trim();
      const lines = content.split("\n").filter((l) => l.length > 0);
      expect(lines).toHaveLength(1);

      const entry = JSON.parse(lines[0]!);
      expect(entry.seq).toBe(3);
    });

    it("handles empty WAL gracefully", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      expect(() => wal.compact()).not.toThrow();
    });

    it("handles WAL with no checkpoint", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.compact();

      // Nothing should change since there's no checkpoint
      const content = readFileSync(wal.filePath, "utf-8").trim();
      const lines = content.split("\n").filter((l) => l.length > 0);
      expect(lines).toHaveLength(1);
    });

    it("recovery works correctly after compaction", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));
      wal.checkpoint(2, "batch-001");
      wal.append(makeTx(3));
      wal.compact();

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(1);
      expect(result.transactions[0]!.txHash).toBe("txhash-3");
    });
  });

  // =========================================================================
  // Reset
  // =========================================================================

  describe("Reset", () => {
    it("clears WAL file and sequence counter", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));
      wal.reset();

      expect(wal.currentSeq).toBe(0);
      const content = readFileSync(wal.filePath, "utf-8");
      expect(content).toBe("");
    });
  });

  // =========================================================================
  // fsync Configuration
  // =========================================================================

  describe("fsync Configuration", () => {
    it("runs fsync on append when fsyncOnWrite is true", () => {
      const wal = new WriteAheadLog({ walDir, fsyncOnWrite: true });
      // Should not throw even though fsync may be a no-op on some platforms
      expect(() => wal.append(makeTx(1))).not.toThrow();
      expect(wal.currentSeq).toBe(1);
    });

    it("runs flush explicitly", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      expect(() => wal.flush()).not.toThrow();
    });

    it("runs fsync on compact when fsyncOnWrite is true", () => {
      const wal = new WriteAheadLog({ walDir, fsyncOnWrite: true });
      wal.append(makeTx(1));
      wal.append(makeTx(2));
      wal.checkpoint(2, "batch-001");
      expect(() => wal.compact()).not.toThrow();
    });
  });

  // =========================================================================
  // Edge Cases in Recovery
  // =========================================================================

  describe("Recovery Edge Cases", () => {
    it("handles entries with non-object JSON values", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));

      // Inject non-object JSON values
      const content = readFileSync(wal.filePath, "utf-8");
      writeFileSync(wal.filePath, content + '"just a string"\n42\nnull\ntrue\n');

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(1);
      expect(result.corruptedEntries).toBe(4);
    });

    it("handles entry with missing seq field", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));

      const content = readFileSync(wal.filePath, "utf-8");
      writeFileSync(wal.filePath, content + '{"tx": {}, "checksum": "abc"}\n');

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(1);
      expect(result.corruptedEntries).toBe(1);
    });

    it("handles checkpoint with non-numeric seq", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));

      const content = readFileSync(wal.filePath, "utf-8");
      writeFileSync(wal.filePath, content + '{"type":"checkpoint","seq":"not-a-number"}\n');

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(1);
      expect(result.lastCheckpointSeq).toBe(0); // Invalid checkpoint ignored
    });

    it("updates seq counter during recovery", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));
      wal.append(makeTx(3));

      const wal2 = new WriteAheadLog(makeConfig(walDir));
      wal2.recover();

      // Next append should continue from seq 3
      const nextSeq = wal2.append(makeTx(4));
      expect(nextSeq).toBe(4);
    });

    it("handles recovery with no sorted sequences", () => {
      // WAL with only checkpoint, no entries
      const wal = new WriteAheadLog(makeConfig(walDir));
      writeFileSync(wal.filePath, '{"type":"checkpoint","seq":0,"batchId":"b","timestamp":0}\n');

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(0);
    });
  });

  // =========================================================================
  // Compaction Edge Cases
  // =========================================================================

  describe("Compaction Edge Cases", () => {
    it("handles corrupt entries in compaction scan", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.checkpoint(1, "batch-001");
      wal.append(makeTx(2));

      // Inject corrupt line between checkpoint and entry
      const content = readFileSync(wal.filePath, "utf-8");
      const lines = content.split("\n").filter(l => l.length > 0);
      lines.push("CORRUPT");
      writeFileSync(wal.filePath, lines.join("\n") + "\n");

      expect(() => wal.compact()).not.toThrow();
    });

    it("compaction with checkpoint as last line", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.checkpoint(1, "batch-001");
      wal.compact();

      const content = readFileSync(wal.filePath, "utf-8").trim();
      expect(content).toBe(""); // No entries after checkpoint
    });

    it("compaction preserves non-existent WAL", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      const { unlinkSync } = require("fs");
      unlinkSync(wal.filePath);
      expect(() => wal.compact()).not.toThrow();
    });

    it("recovery returns empty when WAL file deleted", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));

      const { unlinkSync } = require("fs");
      unlinkSync(wal.filePath);

      const result = wal.recover();
      expect(result.transactions).toHaveLength(0);
      expect(result.lastCheckpointSeq).toBe(0);
    });

    it("compaction handles WAL with only uncommitted entries", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));
      // No checkpoint -- compact should be a no-op (lastCheckpointSeq = 0)
      wal.compact();

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(2);
    });
  });

  // =========================================================================
  // Adversarial Tests
  // =========================================================================

  describe("Adversarial", () => {
    // ADV-WAL-01: Corrupted WAL entry (tampered checksum)
    it("ADV-WAL-01: skips entries with invalid checksum", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));
      wal.append(makeTx(3));

      // Tamper with the second entry's checksum
      const content = readFileSync(wal.filePath, "utf-8");
      const lines = content.split("\n").filter((l) => l.length > 0);
      const entry2 = JSON.parse(lines[1]!);
      entry2.checksum = "deadbeefdeadbeef";
      lines[1] = JSON.stringify(entry2);
      writeFileSync(wal.filePath, lines.join("\n") + "\n");

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(2); // tx1 and tx3 recovered
      expect(result.corruptedEntries).toBe(1);
      expect(result.transactions[0]!.txHash).toBe("txhash-1");
      expect(result.transactions[1]!.txHash).toBe("txhash-3");
    });

    // ADV-WAL-02: Truncated WAL (crash during write)
    it("ADV-WAL-02: handles truncated last line", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));

      // Truncate the last line (simulate crash during write)
      const content = readFileSync(wal.filePath, "utf-8");
      const truncated = content.slice(0, -20) + "\n";
      writeFileSync(wal.filePath, truncated);

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(1); // Only tx1 recovered
      expect(result.corruptedEntries).toBeGreaterThanOrEqual(1);
    });

    // ADV-WAL-03: Completely corrupt WAL file
    it("ADV-WAL-03: handles fully corrupted WAL", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));

      writeFileSync(wal.filePath, "not json\ngarbage data\n{invalid}\n");

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(0);
      expect(result.corruptedEntries).toBe(3);
    });

    // ADV-WAL-04: Injected checkpoint with inflated sequence
    it("ADV-WAL-04: injected checkpoint causes data loss", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));
      wal.append(makeTx(3));

      // Inject a fake checkpoint after all entries
      const fakeCheckpoint = JSON.stringify({
        type: "checkpoint",
        seq: 999,
        batchId: "fake",
        timestamp: Date.now(),
      });
      const content = readFileSync(wal.filePath, "utf-8");
      writeFileSync(wal.filePath, content + fakeCheckpoint + "\n");

      // Recovery will see checkpoint at 999, skip everything
      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(0);
      expect(result.lastCheckpointSeq).toBe(999);
      // NOTE: This is a known attack vector. In production, checkpoint markers
      // should be authenticated (HMAC) to prevent injection.
    });

    // ADV-WAL-05: Duplicate sequence numbers
    it("ADV-WAL-05: handles duplicate sequence numbers via last-write-wins", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));
      wal.append(makeTx(2));

      // Inject a duplicate entry with seq=1 but different data
      const content = readFileSync(wal.filePath, "utf-8");
      const fakeTx = makeTx(99);
      const fakeEntry = {
        seq: 1,
        timestamp: fakeTx.timestamp,
        tx: fakeTx,
        checksum: "", // Will be computed below
      };
      // Compute valid checksum for the fake entry
      const { createHash } = require("crypto");
      const data = `${fakeEntry.seq}|${fakeEntry.timestamp}|${fakeTx.txHash}|${fakeTx.key}|${fakeTx.oldValue}|${fakeTx.newValue}|${fakeTx.enterpriseId}`;
      fakeEntry.checksum = createHash("sha256").update(data).digest("hex").slice(0, 16);
      writeFileSync(wal.filePath, content + JSON.stringify(fakeEntry) + "\n");

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      // Map uses last-write-wins, so the fake entry replaces the original
      expect(result.transactions).toHaveLength(2);
    });

    // ADV-WAL-06: Empty lines and whitespace
    it("ADV-WAL-06: handles empty lines in WAL", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      wal.append(makeTx(1));

      const content = readFileSync(wal.filePath, "utf-8");
      writeFileSync(wal.filePath, "\n\n" + content + "\n\n");

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(1);
    });

    // ADV-WAL-07: Very large WAL (boundary test)
    it("ADV-WAL-07: handles 1000 entries", () => {
      const wal = new WriteAheadLog(makeConfig(walDir));
      for (let i = 1; i <= 1000; i++) {
        wal.append(makeTx(i));
      }
      wal.checkpoint(500, "batch-mid");

      const result = new WriteAheadLog(makeConfig(walDir)).recover();
      expect(result.transactions).toHaveLength(500);
      expect(result.lastCheckpointSeq).toBe(500);
    });
  });
});
