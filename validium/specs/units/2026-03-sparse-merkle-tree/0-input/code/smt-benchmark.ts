/**
 * SMT Benchmark Suite -- RU-V1 Experiment
 *
 * Measures insert latency, proof generation time, proof verification time,
 * and memory usage for a depth-32 Sparse Merkle Tree with Poseidon hash.
 *
 * Test configurations: 100, 1,000, 10,000, 100,000 entries
 * Repetitions: 50 per measurement (after 10 warmup iterations)
 */

import { SparseMerkleTree } from "./smt-implementation.js";
import { writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const RESULTS_DIR = join(__dirname, "..", "results");

// Configuration
const TREE_DEPTH = 32;
const ENTRY_COUNTS = [100, 1_000, 10_000, 100_000];
const MEASUREMENT_REPS = 50;
const WARMUP_REPS = 10;

interface BenchmarkResult {
  entryCount: number;
  insertLatency: StatSummary;
  proofGeneration: StatSummary;
  proofVerification: StatSummary;
  memoryUsageMB: number;
  nodeCount: number;
  totalInsertTimeMs: number;
}

interface StatSummary {
  mean: number;
  stddev: number;
  min: number;
  max: number;
  p50: number;
  p95: number;
  p99: number;
  unit: string;
  samples: number;
}

function computeStats(values: number[], unit: string): StatSummary {
  const sorted = [...values].sort((a, b) => a - b);
  const n = sorted.length;
  const mean = sorted.reduce((a, b) => a + b, 0) / n;
  const variance = sorted.reduce((sum, v) => sum + (v - mean) ** 2, 0) / (n - 1);
  const stddev = Math.sqrt(variance);

  return {
    mean: Number(mean.toFixed(4)),
    stddev: Number(stddev.toFixed(4)),
    min: Number(sorted[0].toFixed(4)),
    max: Number(sorted[n - 1].toFixed(4)),
    p50: Number(sorted[Math.floor(n * 0.5)].toFixed(4)),
    p95: Number(sorted[Math.floor(n * 0.95)].toFixed(4)),
    p99: Number(sorted[Math.floor(n * 0.99)].toFixed(4)),
    unit,
    samples: n,
  };
}

/** Generate a deterministic "random" key from a seed */
function generateKey(seed: number): bigint {
  // Simple deterministic key generation using seed
  // This avoids needing a Poseidon hash per key generation during benchmarking
  const a = BigInt(seed) * 6364136223846793005n + 1442695040888963407n;
  return a & ((1n << 32n) - 1n); // Keep lower 32 bits for depth-32 tree
}

/** Generate a deterministic value from a seed */
function generateValue(seed: number): bigint {
  return BigInt(seed + 1) * 1000000007n + 999999937n;
}

async function benchmarkTreeSize(entryCount: number): Promise<BenchmarkResult> {
  console.log(`\n--- Benchmarking ${entryCount.toLocaleString()} entries ---`);

  const smt = await SparseMerkleTree.create(TREE_DEPTH);

  // Phase 1: Insert all entries and measure insert latency
  console.log(`  Inserting ${entryCount.toLocaleString()} entries...`);
  const insertLatencies: number[] = [];
  const totalInsertStart = performance.now();

  for (let i = 0; i < entryCount; i++) {
    const key = generateKey(i);
    const value = generateValue(i);

    const start = performance.now();
    smt.insert(key, value);
    const elapsed = performance.now() - start;

    // Collect samples: first WARMUP_REPS are warmup, then every Nth to get MEASUREMENT_REPS
    if (i >= WARMUP_REPS) {
      // Sample uniformly across all insertions after warmup
      const step = Math.max(1, Math.floor((entryCount - WARMUP_REPS) / MEASUREMENT_REPS));
      if ((i - WARMUP_REPS) % step === 0 && insertLatencies.length < MEASUREMENT_REPS) {
        insertLatencies.push(elapsed);
      }
    }

    // Progress logging
    if (entryCount >= 10000 && i > 0 && i % 10000 === 0) {
      console.log(`    ${i.toLocaleString()} / ${entryCount.toLocaleString()} inserted...`);
    }
  }

  const totalInsertTime = performance.now() - totalInsertStart;
  console.log(`  Total insert time: ${(totalInsertTime / 1000).toFixed(2)}s`);

  // Collect memory info
  const memBefore = process.memoryUsage();
  const stats = smt.getStats();

  // Phase 2: Measure proof generation time
  console.log(`  Benchmarking proof generation (${MEASUREMENT_REPS} reps)...`);
  const proofGenTimes: number[] = [];

  // Warmup
  for (let i = 0; i < WARMUP_REPS; i++) {
    const key = generateKey(i);
    smt.getProof(key);
  }

  // Measure
  for (let i = 0; i < MEASUREMENT_REPS; i++) {
    const key = generateKey(i * Math.floor(entryCount / MEASUREMENT_REPS));
    const start = performance.now();
    smt.getProof(key);
    const elapsed = performance.now() - start;
    proofGenTimes.push(elapsed);
  }

  // Phase 3: Measure proof verification time
  console.log(`  Benchmarking proof verification (${MEASUREMENT_REPS} reps)...`);
  const proofVerifyTimes: number[] = [];

  // Generate proofs first
  const proofs = [];
  for (let i = 0; i < MEASUREMENT_REPS + WARMUP_REPS; i++) {
    const key = generateKey(i);
    proofs.push({
      key,
      leafHash: smt.getLeafHash(key),
      proof: smt.getProof(key),
    });
  }

  const currentRoot = smt.root;

  // Warmup
  for (let i = 0; i < WARMUP_REPS; i++) {
    const { key, leafHash, proof } = proofs[i];
    smt.verifyProof(currentRoot, key, leafHash, proof);
  }

  // Measure
  for (let i = WARMUP_REPS; i < WARMUP_REPS + MEASUREMENT_REPS; i++) {
    const { key, leafHash, proof } = proofs[i];
    const start = performance.now();
    const valid = smt.verifyProof(currentRoot, key, leafHash, proof);
    const elapsed = performance.now() - start;
    proofVerifyTimes.push(elapsed);

    if (!valid) {
      console.error(`  ERROR: Proof verification failed for key ${key}`);
    }
  }

  // Phase 4: Verify correctness -- non-membership proof
  console.log(`  Verifying non-membership proofs...`);
  const unusedKey = generateKey(entryCount + 1000);
  const nonMemberProof = smt.getProof(unusedKey);
  const nonMemberLeaf = smt.getLeafHash(unusedKey);
  const nonMemberValid = smt.verifyProof(currentRoot, unusedKey, nonMemberLeaf, nonMemberProof);
  console.log(`  Non-membership proof valid: ${nonMemberValid}`);

  const memoryMB = memBefore.heapUsed / (1024 * 1024);

  const result: BenchmarkResult = {
    entryCount,
    insertLatency: computeStats(insertLatencies, "ms"),
    proofGeneration: computeStats(proofGenTimes, "ms"),
    proofVerification: computeStats(proofVerifyTimes, "ms"),
    memoryUsageMB: Number(memoryMB.toFixed(2)),
    nodeCount: stats.nodeCount,
    totalInsertTimeMs: Number(totalInsertTime.toFixed(2)),
  };

  // Print summary
  console.log(`  Results:`);
  console.log(`    Insert latency:  mean=${result.insertLatency.mean.toFixed(3)}ms, p95=${result.insertLatency.p95.toFixed(3)}ms`);
  console.log(`    Proof gen:       mean=${result.proofGeneration.mean.toFixed(3)}ms, p95=${result.proofGeneration.p95.toFixed(3)}ms`);
  console.log(`    Proof verify:    mean=${result.proofVerification.mean.toFixed(3)}ms, p95=${result.proofVerification.p95.toFixed(3)}ms`);
  console.log(`    Memory:          ${result.memoryUsageMB.toFixed(1)} MB`);
  console.log(`    Nodes stored:    ${result.nodeCount.toLocaleString()}`);

  return result;
}

async function main() {
  console.log("=== Sparse Merkle Tree Benchmark Suite ===");
  console.log(`Tree depth: ${TREE_DEPTH}`);
  console.log(`Hash function: Poseidon (circomlibjs, BN128)`);
  console.log(`Measurement repetitions: ${MEASUREMENT_REPS}`);
  console.log(`Warmup iterations: ${WARMUP_REPS}`);
  console.log(`Entry counts: ${ENTRY_COUNTS.map(n => n.toLocaleString()).join(", ")}`);
  console.log(`Node.js: ${process.version}`);
  console.log(`Platform: ${process.platform} ${process.arch}`);
  console.log(`Date: ${new Date().toISOString()}`);

  const results: BenchmarkResult[] = [];

  for (const count of ENTRY_COUNTS) {
    // Force GC between runs if available
    if (global.gc) {
      global.gc();
    }

    const result = await benchmarkTreeSize(count);
    results.push(result);
  }

  // Hypothesis evaluation
  console.log("\n=== Hypothesis Evaluation ===");
  const largestResult = results[results.length - 1];
  const targets = {
    insertLatency: 10, // < 10ms
    proofGeneration: 5, // < 5ms
    proofVerification: 2, // < 2ms
  };

  console.log(`\nTarget: ${largestResult.entryCount.toLocaleString()} entries`);
  console.log(`  Insert latency:    ${largestResult.insertLatency.mean.toFixed(3)}ms (target: <${targets.insertLatency}ms) -- ${largestResult.insertLatency.mean < targets.insertLatency ? "PASS" : "FAIL"}`);
  console.log(`  Proof generation:  ${largestResult.proofGeneration.mean.toFixed(3)}ms (target: <${targets.proofGeneration}ms) -- ${largestResult.proofGeneration.mean < targets.proofGeneration ? "PASS" : "FAIL"}`);
  console.log(`  Proof verification: ${largestResult.proofVerification.mean.toFixed(3)}ms (target: <${targets.proofVerification}ms) -- ${largestResult.proofVerification.mean < targets.proofVerification ? "PASS" : "FAIL"}`);

  // Save results
  const output = {
    experiment: "sparse-merkle-tree",
    target: "validium",
    treeDepth: TREE_DEPTH,
    hashFunction: "Poseidon (circomlibjs 0.1.7, BN128)",
    measurementReps: MEASUREMENT_REPS,
    warmupReps: WARMUP_REPS,
    nodeVersion: process.version,
    platform: `${process.platform} ${process.arch}`,
    timestamp: new Date().toISOString(),
    hypothesisTargets: targets,
    results,
  };

  try {
    writeFileSync(
      join(RESULTS_DIR, "smt-benchmark-results.json"),
      JSON.stringify(output, null, 2)
    );
    console.log(`\nResults saved to results/smt-benchmark-results.json`);
  } catch (err) {
    // Results dir might not exist from dist/
    const altPath = join(__dirname, "smt-benchmark-results.json");
    writeFileSync(altPath, JSON.stringify(output, null, 2));
    console.log(`\nResults saved to ${altPath}`);
  }
}

main().catch(console.error);
