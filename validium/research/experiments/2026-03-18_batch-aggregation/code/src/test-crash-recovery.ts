import { join } from "path";
import { existsSync, mkdirSync, writeFileSync, readFileSync, appendFileSync } from "fs";
import { PersistentQueue } from "./persistent-queue.js";
import { BatchAggregator } from "./batch-aggregator.js";
import { TransactionGenerator } from "./tx-generator.js";

const RESULTS_DIR = join(import.meta.dirname, "..", "..", "results");
const WAL_DIR = join(RESULTS_DIR, "wal");

function ensureDirs(): void {
  if (!existsSync(RESULTS_DIR)) mkdirSync(RESULTS_DIR, { recursive: true });
  if (!existsSync(WAL_DIR)) mkdirSync(WAL_DIR, { recursive: true });
}

/// Crash recovery tests: simulate crashes at various points and verify zero transaction loss.
///
/// Test scenarios:
/// 1. Crash after enqueue, before batch formation -> all enqueued txs recovered
/// 2. Crash mid-batch (some tx dequeued, batch not committed) -> recovered to last checkpoint
/// 3. Crash during WAL write (partial line) -> corrupted entry skipped, others recovered
/// 4. Crash after checkpoint -> no recovery needed (clean state)
/// 5. Multiple crashes in sequence -> recovery remains correct
function testCrashRecovery(): void {
  ensureDirs();
  console.log("=== RU-V4: Crash Recovery Test ===\n");

  const results: Record<string, unknown>[] = [];
  const replications = 30;

  // Scenario 1: Crash after enqueue, before batch formation
  console.log("--- Scenario 1: Crash after enqueue (pre-batch) ---");
  {
    let passed = 0;
    for (let rep = 0; rep < replications; rep++) {
      const walPath = join(WAL_DIR, `crash1_rep${rep}.jsonl`);
      const queue = new PersistentQueue({
        walPath,
        fsyncPerEntry: true,
        groupCommitSize: 1,
      });
      queue.reset();

      const generator = new TransactionGenerator("enterprise-crash1");
      const txHashes: string[] = [];

      // Enqueue 20 transactions
      for (let i = 0; i < 20; i++) {
        const tx = generator.generate();
        txHashes.push(tx.txHash);
        queue.enqueue(tx);
      }
      queue.flush();

      // "Crash" -- create a new queue instance from the same WAL
      const recoveredQueue = new PersistentQueue({
        walPath,
        fsyncPerEntry: true,
        groupCommitSize: 1,
      });
      const recoveredCount = recoveredQueue.recover();

      if (recoveredCount === 20) {
        // Verify all transactions are present
        const recoveredTxs = [];
        while (recoveredQueue.size > 0) {
          recoveredTxs.push(...recoveredQueue.peek(recoveredQueue.size));
          break;
        }
        const recoveredHashes = recoveredTxs.map((tx) => tx.txHash);
        const allPresent = txHashes.every((h) => recoveredHashes.includes(h));
        if (allPresent) passed++;
      }

      queue.reset();
    }

    const result = {
      scenario: "crash_after_enqueue",
      replications,
      passed,
      failed: replications - passed,
      zeroLoss: passed === replications,
    };
    results.push(result);
    console.log(`  ${passed}/${replications} passed (zero-loss: ${result.zeroLoss})`);
  }

  // Scenario 2: Crash mid-batch (some txs committed, some not)
  console.log("\n--- Scenario 2: Crash mid-batch (partial commit) ---");
  {
    let passed = 0;
    for (let rep = 0; rep < replications; rep++) {
      const walPath = join(WAL_DIR, `crash2_rep${rep}.jsonl`);
      const queue = new PersistentQueue({
        walPath,
        fsyncPerEntry: true,
        groupCommitSize: 1,
      });
      queue.reset();

      const generator = new TransactionGenerator("enterprise-crash2");
      const allTxHashes: string[] = [];

      // Enqueue 30 transactions
      for (let i = 0; i < 30; i++) {
        const tx = generator.generate();
        allTxHashes.push(tx.txHash);
        queue.enqueue(tx);
      }
      queue.flush();

      // Form and commit first batch of 10
      const aggregator = new BatchAggregator(queue, {
        strategy: "SIZE",
        sizeThreshold: 10,
        timeThresholdMs: 100000,
        maxBatchSize: 64,
      });
      const batch1 = aggregator.formBatch("enterprise-crash2");
      // batch1 committed (checkpoint written)

      // "Crash" before second batch commits -- 20 transactions remain in WAL
      const uncommittedHashes = allTxHashes.slice(10); // txs 10-29

      const recoveredQueue = new PersistentQueue({
        walPath,
        fsyncPerEntry: true,
        groupCommitSize: 1,
      });
      const recoveredCount = recoveredQueue.recover();

      // Should recover exactly the 20 uncommitted transactions
      if (recoveredCount === 20) {
        const recoveredTxs = recoveredQueue.peek(recoveredQueue.size);
        const recoveredHashes = recoveredTxs.map((tx) => tx.txHash);
        const allUncommittedPresent = uncommittedHashes.every((h) =>
          recoveredHashes.includes(h)
        );
        if (allUncommittedPresent) passed++;
      }

      queue.reset();
    }

    const result = {
      scenario: "crash_mid_batch",
      replications,
      passed,
      failed: replications - passed,
      zeroLoss: passed === replications,
    };
    results.push(result);
    console.log(`  ${passed}/${replications} passed (zero-loss: ${result.zeroLoss})`);
  }

  // Scenario 3: Corrupted WAL entry (partial write)
  console.log("\n--- Scenario 3: Corrupted WAL entry (partial write simulation) ---");
  {
    let passed = 0;
    for (let rep = 0; rep < replications; rep++) {
      const walPath = join(WAL_DIR, `crash3_rep${rep}.jsonl`);
      const queue = new PersistentQueue({
        walPath,
        fsyncPerEntry: true,
        groupCommitSize: 1,
      });
      queue.reset();

      const generator = new TransactionGenerator("enterprise-crash3");

      // Enqueue 10 transactions
      for (let i = 0; i < 10; i++) {
        const tx = generator.generate();
        queue.enqueue(tx);
      }
      queue.flush();

      // Simulate corruption: append a partial JSON line to the WAL
      appendFileSync(walPath, '{"seq":11,"timestamp":99999,"tx":{"txHash":"corrupt"');
      // Also append some garbage
      appendFileSync(walPath, "\nNOT_JSON_AT_ALL\n");

      // Recover -- should get exactly 10 valid transactions
      const recoveredQueue = new PersistentQueue({
        walPath,
        fsyncPerEntry: true,
        groupCommitSize: 1,
      });
      const recoveredCount = recoveredQueue.recover();

      if (recoveredCount === 10) passed++;

      queue.reset();
    }

    const result = {
      scenario: "corrupted_wal_entry",
      replications,
      passed,
      failed: replications - passed,
      zeroLoss: passed === replications,
    };
    results.push(result);
    console.log(`  ${passed}/${replications} passed (zero-loss: ${result.zeroLoss})`);
  }

  // Scenario 4: Crash after checkpoint (clean state)
  console.log("\n--- Scenario 4: Crash after checkpoint (clean state) ---");
  {
    let passed = 0;
    for (let rep = 0; rep < replications; rep++) {
      const walPath = join(WAL_DIR, `crash4_rep${rep}.jsonl`);
      const queue = new PersistentQueue({
        walPath,
        fsyncPerEntry: true,
        groupCommitSize: 1,
      });
      queue.reset();

      const generator = new TransactionGenerator("enterprise-crash4");

      // Enqueue 16 transactions
      for (let i = 0; i < 16; i++) {
        const tx = generator.generate();
        queue.enqueue(tx);
      }
      queue.flush();

      // Form batch and checkpoint
      const aggregator = new BatchAggregator(queue, {
        strategy: "SIZE",
        sizeThreshold: 16,
        timeThresholdMs: 100000,
        maxBatchSize: 64,
      });
      aggregator.formBatch("enterprise-crash4");

      // "Crash" after checkpoint -- should recover 0 transactions
      const recoveredQueue = new PersistentQueue({
        walPath,
        fsyncPerEntry: true,
        groupCommitSize: 1,
      });
      const recoveredCount = recoveredQueue.recover();

      if (recoveredCount === 0) passed++;

      queue.reset();
    }

    const result = {
      scenario: "crash_after_checkpoint",
      replications,
      passed,
      failed: replications - passed,
      zeroLoss: passed === replications,
    };
    results.push(result);
    console.log(`  ${passed}/${replications} passed (zero-loss: ${result.zeroLoss})`);
  }

  // Scenario 5: Multiple sequential crashes
  console.log("\n--- Scenario 5: Multiple sequential crashes ---");
  {
    let passed = 0;
    for (let rep = 0; rep < replications; rep++) {
      const walPath = join(WAL_DIR, `crash5_rep${rep}.jsonl`);

      // Phase 1: Enqueue 10 txs, crash
      const q1 = new PersistentQueue({
        walPath,
        fsyncPerEntry: true,
        groupCommitSize: 1,
      });
      q1.reset();

      const generator = new TransactionGenerator("enterprise-crash5");
      for (let i = 0; i < 10; i++) {
        q1.enqueue(generator.generate());
      }
      q1.flush();

      // Phase 2: Recover, enqueue 5 more, crash again
      const q2 = new PersistentQueue({
        walPath,
        fsyncPerEntry: true,
        groupCommitSize: 1,
      });
      const recovered1 = q2.recover();
      for (let i = 0; i < 5; i++) {
        q2.enqueue(generator.generate());
      }
      q2.flush();

      // Phase 3: Recover -- should have all 15 transactions
      const q3 = new PersistentQueue({
        walPath,
        fsyncPerEntry: true,
        groupCommitSize: 1,
      });
      const recovered2 = q3.recover();

      if (recovered1 === 10 && recovered2 === 15) passed++;

      q1.reset();
    }

    const result = {
      scenario: "multiple_sequential_crashes",
      replications,
      passed,
      failed: replications - passed,
      zeroLoss: passed === replications,
    };
    results.push(result);
    console.log(`  ${passed}/${replications} passed (zero-loss: ${result.zeroLoss})`);
  }

  // Summary
  const allPassed = results.every((r: any) => r.zeroLoss);
  const summary = {
    scenarios: results,
    allPassed,
    totalTests: results.length * replications,
    totalPassed: results.reduce((sum: number, r: any) => sum + r.passed, 0),
  };

  console.log(`\n=== Summary: ${summary.totalPassed}/${summary.totalTests} tests passed ===`);
  console.log(`All scenarios zero-loss: ${allPassed}`);

  writeFileSync(
    join(RESULTS_DIR, "crash_recovery_results.json"),
    JSON.stringify(summary, null, 2)
  );
  console.log(`\nResults saved to: ${join(RESULTS_DIR, "crash_recovery_results.json")}`);
}

testCrashRecovery();
