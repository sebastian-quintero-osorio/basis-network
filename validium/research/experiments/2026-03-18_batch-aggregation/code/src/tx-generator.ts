import { createHash, randomBytes } from "crypto";
import type { Transaction } from "./types.js";

/// Generate synthetic transactions for benchmarking.
/// Simulates enterprise state transitions (key-value updates in the SMT).
export class TransactionGenerator {
  private seq: number = 0;
  private readonly enterpriseId: string;

  constructor(enterpriseId: string = "enterprise-001") {
    this.enterpriseId = enterpriseId;
  }

  /// Generate a single transaction with a random key and value.
  generate(): Transaction {
    this.seq++;
    const key = randomBytes(16).toString("hex");
    const oldValue = randomBytes(16).toString("hex");
    const newValue = randomBytes(16).toString("hex");
    const txHash = createHash("sha256")
      .update(`${this.seq}|${key}|${oldValue}|${newValue}|${Date.now()}`)
      .digest("hex");

    return {
      txHash,
      key,
      oldValue,
      newValue,
      enterpriseId: this.enterpriseId,
      timestamp: Date.now(),
    };
  }

  /// Generate N transactions with controlled timestamps for determinism testing.
  /// All transactions get sequential timestamps starting from `baseTimestamp`.
  generateDeterministic(n: number, baseTimestamp: number, seed: string): Transaction[] {
    const txs: Transaction[] = [];
    for (let i = 0; i < n; i++) {
      const key = createHash("sha256").update(`${seed}-key-${i}`).digest("hex").slice(0, 32);
      const oldValue = createHash("sha256")
        .update(`${seed}-old-${i}`)
        .digest("hex")
        .slice(0, 32);
      const newValue = createHash("sha256")
        .update(`${seed}-new-${i}`)
        .digest("hex")
        .slice(0, 32);
      const txHash = createHash("sha256")
        .update(`${seed}-hash-${i}`)
        .digest("hex");

      txs.push({
        txHash,
        key,
        oldValue,
        newValue,
        enterpriseId: this.enterpriseId,
        timestamp: baseTimestamp + i,
      });
    }
    return txs;
  }

  /// Generate transactions at a specified rate (tx/min) for a duration (ms).
  /// Returns an array of (transaction, delayMs) pairs for replay.
  generateWithTiming(
    ratePerMin: number,
    durationMs: number
  ): Array<{ tx: Transaction; delayMs: number }> {
    const intervalMs = 60000 / ratePerMin;
    const count = Math.ceil((durationMs / 60000) * ratePerMin);
    const result: Array<{ tx: Transaction; delayMs: number }> = [];

    for (let i = 0; i < count; i++) {
      // Add Poisson-like jitter: exponential distribution around the mean interval
      const jitter = -intervalMs * Math.log(1 - Math.random() * 0.99);
      const delayMs = Math.max(0, jitter);

      result.push({
        tx: this.generate(),
        delayMs,
      });
    }

    return result;
  }

  reset(): void {
    this.seq = 0;
  }
}
