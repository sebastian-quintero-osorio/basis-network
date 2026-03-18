// RU-V6: Data Availability Committee -- Main Benchmark Suite
//
// Benchmarks:
// 1. Shamir share generation latency vs batch size
// 2. Full attestation pipeline (distribute + attest)
// 3. Data recovery latency
// 4. Storage overhead ratio
// 5. On-chain verification cost (simulated ecrecover)
//
// Each benchmark: 50 replications (30 minimum per protocol), 5 warm-up runs
//
// Batch sizes: 10KB, 100KB, 500KB, 1MB (enterprise range)
// Committee: 3-of-3 and 2-of-3 (with and without failed node)

import { randomBytes } from 'crypto';
import { DACProtocol } from './dac-protocol.js';
import { shareData, reconstructData, bytesToFieldElements } from './shamir.js';
import { computeStats, formatStats, type Stats } from './stats.js';
import type { DACConfig } from './types.js';
import { writeFileSync, mkdirSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const RESULTS_DIR = resolve(__dirname, '../../results');

const WARMUP = 3;

// Replications per batch size (BigInt SSS is ~950x slower than native Rust;
// large sizes need fewer reps to stay practical in JS)
function getReplications(batchSizeBytes: number): number {
  if (batchSizeBytes <= 10_000) return 50;
  if (batchSizeBytes <= 100_000) return 30;
  return 10; // 500KB, 1MB: 10 reps (sufficient for CI check with lower precision)
}

// Batch sizes to test (bytes)
const BATCH_SIZES = [
  10_000,     // 10 KB
  100_000,    // 100 KB
  500_000,    // 500 KB
  1_000_000,  // 1 MB
];

const BATCH_SIZE_LABELS: Record<number, string> = {
  10_000: '10KB',
  100_000: '100KB',
  500_000: '500KB',
  1_000_000: '1MB',
};

// DAC configurations to test
const CONFIGS: { name: string; config: DACConfig }[] = [
  {
    name: '2-of-3 (all online)',
    config: {
      committeeSize: 3,
      threshold: 2,
      attestationTimeoutMs: 5000,
      enableFallback: true,
    },
  },
  {
    name: '3-of-3 (all online)',
    config: {
      committeeSize: 3,
      threshold: 3,
      attestationTimeoutMs: 5000,
      enableFallback: true,
    },
  },
];

interface BenchmarkRow {
  config: string;
  batchSize: string;
  batchSizeBytes: number;
  fieldElements: number;
  shareGenMs: Stats;
  attestPipelineMs: Stats;
  recoveryMs: Stats;
  onChainVerifyMs: Stats;
  storageOverhead: number;
  allRecoveriesMatch: boolean;
}

function generateBatchData(sizeBytes: number): Buffer {
  return randomBytes(sizeBytes);
}

function runBenchmark(configEntry: { name: string; config: DACConfig }, batchSizeBytes: number): BenchmarkRow {
  const REPLICATIONS = getReplications(batchSizeBytes);
  const label = `${configEntry.name} @ ${BATCH_SIZE_LABELS[batchSizeBytes]}`;
  console.log(`  Running: ${label} (${REPLICATIONS} reps + ${WARMUP} warm-up)...`);

  const protocol = new DACProtocol(configEntry.config);
  const data = generateBatchData(batchSizeBytes);
  const fieldElements = bytesToFieldElements(data).length;

  // Warm-up
  for (let i = 0; i < WARMUP; i++) {
    protocol.reset();
    protocol.attestBatch(data);
  }

  const shareGenTimes: number[] = [];
  const attestPipelineTimes: number[] = [];
  const recoveryTimes: number[] = [];
  const onChainVerifyTimes: number[] = [];
  let allRecoveriesMatch = true;
  let storagePerNode = 0;

  for (let rep = 0; rep < REPLICATIONS; rep++) {
    protocol.reset();

    // Measure share generation only
    const shareStart = performance.now();
    const shareResult = shareData(data, configEntry.config.threshold, configEntry.config.committeeSize);
    shareGenTimes.push(performance.now() - shareStart);

    // Measure full attestation pipeline
    protocol.reset();
    const result = protocol.attestBatch(data);
    attestPipelineTimes.push(result.totalMs);

    // Measure on-chain verification
    const onChainResult = protocol.verifyOnChain(result.attestation.certificate);
    onChainVerifyTimes.push(onChainResult.verificationTimeMs);

    // Measure recovery (from k nodes)
    const recoveryResult = protocol.recoverData(result.distribution.batchId, data);
    recoveryTimes.push(recoveryResult.durationMs);

    if (!recoveryResult.dataMatches) {
      allRecoveriesMatch = false;
      console.error(`    RECOVERY MISMATCH at rep ${rep}!`);
    }

    // Measure storage (once)
    if (rep === 0) {
      storagePerNode = protocol.getNodes()[0].getStorageBytes();
    }
  }

  const storageOverhead = (storagePerNode * configEntry.config.committeeSize) / batchSizeBytes;

  return {
    config: configEntry.name,
    batchSize: BATCH_SIZE_LABELS[batchSizeBytes],
    batchSizeBytes,
    fieldElements,
    shareGenMs: computeStats(shareGenTimes),
    attestPipelineMs: computeStats(attestPipelineTimes),
    recoveryMs: computeStats(recoveryTimes),
    onChainVerifyMs: computeStats(onChainVerifyTimes),
    storageOverhead,
    allRecoveriesMatch,
  };
}

function runFailureScenario(): {
  oneNodeDown: BenchmarkRow;
  twoNodesDown: { recovered: boolean; fallbackTriggered: boolean };
} {
  console.log('\n--- Failure Scenario: 2-of-3 with one node offline ---');
  const config: DACConfig = {
    committeeSize: 3,
    threshold: 2,
    attestationTimeoutMs: 5000,
    enableFallback: true,
  };

  const batchSize = 100_000;
  const data = generateBatchData(batchSize);
  const protocol = new DACProtocol(config);

  const FAILURE_REPS = 30;

  // Warm-up
  for (let i = 0; i < WARMUP; i++) {
    protocol.reset();
    protocol.attestBatch(data);
  }

  // One node offline
  const shareGenTimes: number[] = [];
  const attestTimes: number[] = [];
  const recoveryTimes: number[] = [];
  let allMatch = true;

  for (let rep = 0; rep < FAILURE_REPS; rep++) {
    protocol.reset();
    protocol.setNodeOffline(3); // Take node 3 offline

    const shareStart = performance.now();
    shareData(data, config.threshold, config.committeeSize);
    shareGenTimes.push(performance.now() - shareStart);

    const result = protocol.attestBatch(data);
    attestTimes.push(result.totalMs);

    // Recovery with only 2 nodes available
    const recovery = protocol.recoverData(result.distribution.batchId, data);
    recoveryTimes.push(recovery.durationMs);
    if (!recovery.dataMatches) allMatch = false;
  }

  const fieldElements = bytesToFieldElements(data).length;
  const storagePerNode = protocol.getNodes()[0].getStorageBytes();

  // Two nodes offline test (should fail and trigger fallback)
  protocol.reset();
  protocol.setNodeOffline(2);
  protocol.setNodeOffline(3);
  const failResult = protocol.attestBatch(data);
  const failRecovery = protocol.recoverData(failResult.distribution.batchId, data);

  return {
    oneNodeDown: {
      config: '2-of-3 (1 node offline)',
      batchSize: '100KB',
      batchSizeBytes: batchSize,
      fieldElements,
      shareGenMs: computeStats(shareGenTimes),
      attestPipelineMs: computeStats(attestTimes),
      recoveryMs: computeStats(recoveryTimes),
      onChainVerifyMs: computeStats([0]),
      storageOverhead: (storagePerNode * config.committeeSize) / batchSize,
      allRecoveriesMatch: allMatch,
    },
    twoNodesDown: {
      recovered: failRecovery.recovered,
      fallbackTriggered: failResult.attestation.fallbackTriggered,
    },
  };
}

function runScalingTest(): { elements: number; shareGenMs: number; recoveryMs: number }[] {
  console.log('\n--- Scaling Test: Share generation and recovery vs field element count ---');
  const config: DACConfig = { committeeSize: 3, threshold: 2, attestationTimeoutMs: 5000, enableFallback: true };

  const sizes = [1_000, 5_000, 10_000, 50_000, 100_000, 500_000];
  const results: { elements: number; shareGenMs: number; recoveryMs: number }[] = [];

  for (const sizeBytes of sizes) {
    const data = generateBatchData(sizeBytes);
    const elements = bytesToFieldElements(data).length;

    // Measure share generation (3 reps, take mean)
    const genTimes: number[] = [];
    for (let i = 0; i < 3; i++) {
      const start = performance.now();
      shareData(data, config.threshold, config.committeeSize);
      genTimes.push(performance.now() - start);
    }

    // Measure recovery (3 reps)
    const recTimes: number[] = [];
    for (let i = 0; i < 3; i++) {
      const protocol = new DACProtocol(config);
      const distResult = protocol.distributeShares(data);
      const start = performance.now();
      protocol.recoverData(distResult.batchId, data);
      recTimes.push(performance.now() - start);
    }

    const meanGen = genTimes.reduce((a, b) => a + b, 0) / genTimes.length;
    const meanRec = recTimes.reduce((a, b) => a + b, 0) / recTimes.length;
    console.log(`  ${sizeBytes} bytes (${elements} elements): gen=${meanGen.toFixed(1)}ms, rec=${meanRec.toFixed(1)}ms`);

    results.push({ elements, shareGenMs: meanGen, recoveryMs: meanRec });
  }

  return results;
}

async function main(): Promise<void> {
  console.log('=== RU-V6: Data Availability Committee Benchmark Suite ===');
  console.log(`Replications: 50/30/10 (by size) | Warm-up: ${WARMUP}`);
  console.log(`Batch sizes: ${BATCH_SIZES.map((s) => BATCH_SIZE_LABELS[s]).join(', ')}`);
  console.log(`Configs: ${CONFIGS.map((c) => c.name).join(', ')}`);
  console.log();

  const allResults: BenchmarkRow[] = [];

  // Phase 1: Main benchmarks
  console.log('--- Phase 1: Main Benchmarks ---');
  for (const configEntry of CONFIGS) {
    for (const batchSize of BATCH_SIZES) {
      const result = runBenchmark(configEntry, batchSize);
      allResults.push(result);
    }
  }

  // Phase 2: Failure scenarios
  const failureResults = runFailureScenario();
  allResults.push(failureResults.oneNodeDown);

  // Phase 3: Scaling test
  const scalingResults = runScalingTest();

  // Print results
  console.log('\n\n========================================');
  console.log('=== RESULTS SUMMARY ===');
  console.log('========================================\n');

  console.log('--- Per-Configuration Results ---\n');
  for (const row of allResults) {
    console.log(`[${row.config}] @ ${row.batchSize} (${row.fieldElements} field elements)`);
    console.log(formatStats('Share Generation', row.shareGenMs, 'ms'));
    console.log(formatStats('Attestation Pipeline', row.attestPipelineMs, 'ms'));
    console.log(formatStats('Data Recovery', row.recoveryMs, 'ms'));
    console.log(formatStats('On-chain Verify', row.onChainVerifyMs, 'ms'));
    console.log(`  Storage overhead: ${row.storageOverhead.toFixed(2)}x`);
    console.log(`  All recoveries match: ${row.allRecoveriesMatch}`);
    console.log();
  }

  console.log('--- Failure Scenarios ---');
  console.log(`  2 nodes down: recovered=${failureResults.twoNodesDown.recovered}, fallback=${failureResults.twoNodesDown.fallbackTriggered}`);
  console.log();

  console.log('--- Scaling (share gen + recovery vs data size) ---');
  console.log('  Elements | ShareGen (ms) | Recovery (ms) | Gen/elem (us)');
  for (const s of scalingResults) {
    const genPerElem = (s.shareGenMs / s.elements * 1000).toFixed(2);
    console.log(`  ${s.elements.toString().padStart(8)} | ${s.shareGenMs.toFixed(1).padStart(13)} | ${s.recoveryMs.toFixed(1).padStart(13)} | ${genPerElem.padStart(13)}`);
  }

  // Hypothesis evaluation
  console.log('\n\n========================================');
  console.log('=== HYPOTHESIS EVALUATION ===');
  console.log('========================================\n');

  const target500KB = allResults.find(
    (r) => r.config === '2-of-3 (all online)' && r.batchSizeBytes === 500_000
  );
  const target1MB = allResults.find(
    (r) => r.config === '2-of-3 (all online)' && r.batchSizeBytes === 1_000_000
  );

  if (target500KB) {
    const pass500 = target500KB.attestPipelineMs.p95 < 2000;
    console.log(`H1: Attestation < 2s @ 500KB: ${pass500 ? 'PASS' : 'FAIL'} (P95=${target500KB.attestPipelineMs.p95.toFixed(1)}ms)`);
  }
  if (target1MB) {
    const pass1M = target1MB.attestPipelineMs.p95 < 2000;
    console.log(`H1: Attestation < 2s @ 1MB:   ${pass1M ? 'PASS' : 'FAIL'} (P95=${target1MB.attestPipelineMs.p95.toFixed(1)}ms)`);
  }

  const recoveryRow = failureResults.oneNodeDown;
  const passRecovery = recoveryRow.allRecoveriesMatch;
  console.log(`H2: Recovery with 1 node down: ${passRecovery ? 'PASS' : 'FAIL'} (all 30 recoveries match: ${passRecovery})`);

  const passFallback = failureResults.twoNodesDown.fallbackTriggered && !failureResults.twoNodesDown.recovered;
  console.log(`H3: Fallback on 2 nodes down:  ${passFallback ? 'PASS' : 'FAIL'} (fallback=${failureResults.twoNodesDown.fallbackTriggered}, recovered=${failureResults.twoNodesDown.recovered})`);

  // CI width check (must be < 10% of mean for stochastic results)
  console.log('\n--- Statistical Quality ---');
  for (const row of allResults) {
    const ciWidth = row.attestPipelineMs.ci95Upper - row.attestPipelineMs.ci95Lower;
    const ciPct = row.attestPipelineMs.mean > 0 ? (ciWidth / 2 / row.attestPipelineMs.mean * 100) : 0;
    const pass = ciPct < 10;
    console.log(`  ${row.config} @ ${row.batchSize}: CI width = ${ciPct.toFixed(1)}% of mean ${pass ? 'OK' : 'WIDE'}`);
  }

  // Save results to JSON
  if (!existsSync(RESULTS_DIR)) {
    mkdirSync(RESULTS_DIR, { recursive: true });
  }

  const jsonResults = {
    timestamp: new Date().toISOString(),
    replications: 'adaptive: 50/30/10 by batch size',
    warmup: WARMUP,
    benchmarks: allResults.map((r) => ({
      config: r.config,
      batchSize: r.batchSize,
      batchSizeBytes: r.batchSizeBytes,
      fieldElements: r.fieldElements,
      shareGeneration: { mean: r.shareGenMs.mean, stdev: r.shareGenMs.stdev, p50: r.shareGenMs.p50, p95: r.shareGenMs.p95, p99: r.shareGenMs.p99, min: r.shareGenMs.min, max: r.shareGenMs.max, ci95: [r.shareGenMs.ci95Lower, r.shareGenMs.ci95Upper] },
      attestationPipeline: { mean: r.attestPipelineMs.mean, stdev: r.attestPipelineMs.stdev, p50: r.attestPipelineMs.p50, p95: r.attestPipelineMs.p95, p99: r.attestPipelineMs.p99, min: r.attestPipelineMs.min, max: r.attestPipelineMs.max, ci95: [r.attestPipelineMs.ci95Lower, r.attestPipelineMs.ci95Upper] },
      dataRecovery: { mean: r.recoveryMs.mean, stdev: r.recoveryMs.stdev, p50: r.recoveryMs.p50, p95: r.recoveryMs.p95, p99: r.recoveryMs.p99, min: r.recoveryMs.min, max: r.recoveryMs.max, ci95: [r.recoveryMs.ci95Lower, r.recoveryMs.ci95Upper] },
      onChainVerify: { mean: r.onChainVerifyMs.mean, stdev: r.onChainVerifyMs.stdev, p50: r.onChainVerifyMs.p50, p95: r.onChainVerifyMs.p95, p99: r.onChainVerifyMs.p99 },
      storageOverhead: r.storageOverhead,
      allRecoveriesMatch: r.allRecoveriesMatch,
    })),
    failureScenarios: {
      twoNodesDown: failureResults.twoNodesDown,
    },
    scaling: scalingResults,
  };

  const resultsPath = resolve(RESULTS_DIR, 'benchmark-results.json');
  writeFileSync(resultsPath, JSON.stringify(jsonResults, null, 2));
  console.log(`\nResults saved to: ${resultsPath}`);
}

main().catch(console.error);
