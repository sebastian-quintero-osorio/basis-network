import { join } from "path";
import { existsSync, mkdirSync, writeFileSync } from "fs";
import { PersistentQueue } from "./persistent-queue.js";
import { BatchAggregator } from "./batch-aggregator.js";
import { TransactionGenerator } from "./tx-generator.js";
import type { Batch, AggregationStrategy } from "./types.js";

const RESULTS_DIR = join(import.meta.dirname, "..", "..", "results");
const WAL_DIR = join(RESULTS_DIR, "wal");

function ensureDirs(): void {
  if (!existsSync(RESULTS_DIR)) mkdirSync(RESULTS_DIR, { recursive: true });
  if (!existsSync(WAL_DIR)) mkdirSync(WAL_DIR, { recursive: true });
}

/// Determinism test: same transactions fed twice must produce identical batches.
///
/// This validates the determinism contract:
/// - Same transactions in same order -> same batch IDs
/// - Same transactions in same order -> same batch contents
/// - Repeated across multiple runs -> identical results
function testDeterminism(): void {
  ensureDirs();
  console.log("=== RU-V4: Batch Determinism Test ===\n");

  const strategies: AggregationStrategy[] = ["SIZE", "TIME", "HYBRID"];
  const testSizes = [4, 8, 16, 32, 64];
  const replications = 30;

  let totalTests = 0;
  let passedTests = 0;
  const failures: string[] = [];

  for (const strategy of strategies) {
    for (const batchSize of testSizes) {
      console.log(`Testing: strategy=${strategy}, batchSize=${batchSize}`);

      for (let rep = 0; rep < replications; rep++) {
        const generator = new TransactionGenerator("enterprise-det");
        const txs = generator.generateDeterministic(batchSize * 3, 1000000, `seed-${rep}`);

        // Run 1
        const batches1 = runDeterministicBatch(txs, strategy, batchSize, `det_run1_rep${rep}`);
        // Run 2 (same transactions)
        const batches2 = runDeterministicBatch(txs, strategy, batchSize, `det_run2_rep${rep}`);

        totalTests++;

        // Compare batch IDs
        if (batches1.length !== batches2.length) {
          failures.push(
            `${strategy}/${batchSize}/rep${rep}: batch count mismatch (${batches1.length} vs ${batches2.length})`
          );
          continue;
        }

        let allMatch = true;
        for (let i = 0; i < batches1.length; i++) {
          if (batches1[i].batchId !== batches2[i].batchId) {
            failures.push(
              `${strategy}/${batchSize}/rep${rep}: batch ${i} ID mismatch`
            );
            allMatch = false;
            break;
          }
          if (batches1[i].transactions.length !== batches2[i].transactions.length) {
            failures.push(
              `${strategy}/${batchSize}/rep${rep}: batch ${i} tx count mismatch`
            );
            allMatch = false;
            break;
          }
          for (let j = 0; j < batches1[i].transactions.length; j++) {
            if (batches1[i].transactions[j].txHash !== batches2[i].transactions[j].txHash) {
              failures.push(
                `${strategy}/${batchSize}/rep${rep}: batch ${i}, tx ${j} hash mismatch`
              );
              allMatch = false;
              break;
            }
          }
          if (!allMatch) break;
        }

        if (allMatch) passedTests++;
      }
    }
  }

  const result = {
    totalTests,
    passedTests,
    failedTests: totalTests - passedTests,
    failures,
    deterministic: failures.length === 0,
  };

  console.log(`\nResults: ${passedTests}/${totalTests} passed`);
  if (failures.length > 0) {
    console.log("Failures:");
    for (const f of failures) {
      console.log(`  - ${f}`);
    }
  } else {
    console.log("All determinism tests PASSED");
  }

  writeFileSync(
    join(RESULTS_DIR, "determinism_results.json"),
    JSON.stringify(result, null, 2)
  );
  console.log(`\nResults saved to: ${join(RESULTS_DIR, "determinism_results.json")}`);
}

function runDeterministicBatch(
  txs: ReturnType<TransactionGenerator["generateDeterministic"]>,
  strategy: AggregationStrategy,
  batchSize: number,
  label: string
): Batch[] {
  const walPath = join(WAL_DIR, `${label}.jsonl`);
  const queue = new PersistentQueue({
    walPath,
    fsyncPerEntry: false,
    groupCommitSize: batchSize,
  });
  queue.reset();

  const aggregator = new BatchAggregator(queue, {
    strategy,
    sizeThreshold: batchSize,
    timeThresholdMs: 100000, // Large timeout so SIZE triggers for determinism
    maxBatchSize: 64,
  });

  const batches: Batch[] = [];

  for (const tx of txs) {
    queue.enqueue(tx);
    const batch = aggregator.formBatch("enterprise-det");
    if (batch) batches.push(batch);
  }

  // Flush remaining
  let remaining = aggregator.forceBatch("enterprise-det");
  while (remaining) {
    batches.push(remaining);
    remaining = aggregator.forceBatch("enterprise-det");
  }

  queue.reset();
  return batches;
}

testDeterminism();
