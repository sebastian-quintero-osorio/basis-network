// RU-V5: Enterprise Node Orchestrator -- Pipeline Benchmark
// Compares sequential vs pipelined architecture throughput
// Measures how much overlap is possible between ingestion and proving

import { createHash } from 'crypto';
import { writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { EnterpriseTransaction } from './types';

// --- Simulated Component Latencies (from prior RU measurements) ---

const LATENCIES = {
  smtInsertPerTx: 1.8,      // ms, from RU-V1
  walWritePerTx: 0.149,     // ms, from RU-V4
  batchFormation: 0.02,     // ms, from RU-V4
  witnessGenPerTx: 72,      // ms, from RU-V2 (578ms / 8 txs)
  dacAttestation: 163,      // ms, from RU-V6 (JS, 500KB)
  l1Submission: 2000,       // ms, estimated Avalanche Fuji
};

const PROVING_TIMES: Record<string, number> = {
  'snarkjs_d32_b8': 12757,
  'snarkjs_d32_b16': 28000,
  'snarkjs_d32_b64': 150000,
  'rapidsnark_d32_b8': 2500,
  'rapidsnark_d32_b16': 5000,
  'rapidsnark_d32_b64': 12000,
};

// --- Simulation ---

function generateTx(i: number): EnterpriseTransaction {
  return {
    txHash: createHash('sha256').update(`tx-${i}`).digest('hex'),
    enterpriseId: 'enterprise-001',
    type: 'plasma:work_order',
    key: `key-${i}`,
    value: `val-${i}`,
    timestamp: Date.now(),
    signature: '0xsig',
  };
}

interface PipelineResult {
  mode: string;
  proverBackend: string;
  batchSize: number;
  totalBatches: number;
  totalTransactions: number;
  totalTimeMs: number;
  throughputTxPerSec: number;
  batchLatencies: number[];
  avgBatchLatencyMs: number;
}

// --- Sequential Mode ---
// Each batch is fully processed (receive -> batch -> prove -> submit)
// before the next batch begins. No overlap.

function simulateSequential(
  batchSize: number,
  numBatches: number,
  provingKey: string
): PipelineResult {
  const provingTime = PROVING_TIMES[provingKey] ?? 12757;
  const batchLatencies: number[] = [];

  let totalTime = 0;

  for (let b = 0; b < numBatches; b++) {
    // Phase 1: Receive transactions (sequential arrival)
    const receiveTime = batchSize * (LATENCIES.smtInsertPerTx + LATENCIES.walWritePerTx);

    // Phase 2: Batch formation
    const batchTime = LATENCIES.batchFormation;

    // Phase 3: Witness generation
    const witnessTime = batchSize * LATENCIES.witnessGenPerTx;

    // Phase 4: Proving
    const proveTime = provingTime;

    // Phase 5: DAC attestation
    const dacTime = LATENCIES.dacAttestation;

    // Phase 6: L1 submission
    const submitTime = LATENCIES.l1Submission;

    const batchTotal = receiveTime + batchTime + witnessTime + proveTime + dacTime + submitTime;
    batchLatencies.push(batchTotal);
    totalTime += batchTotal;
  }

  const totalTx = batchSize * numBatches;
  return {
    mode: 'sequential',
    proverBackend: provingKey,
    batchSize,
    totalBatches: numBatches,
    totalTransactions: totalTx,
    totalTimeMs: totalTime,
    throughputTxPerSec: (totalTx / totalTime) * 1000,
    batchLatencies,
    avgBatchLatencyMs: totalTime / numBatches,
  };
}

// --- Pipelined Mode ---
// Three concurrent loops:
// 1. Ingestion loop: always accepting transactions
// 2. Batch loop: forms batches and generates witnesses
// 3. Proving/Submission loop: proves and submits
//
// Overlap: while batch N is being proved, batch N+1 can be formed.

function simulatePipelined(
  batchSize: number,
  numBatches: number,
  provingKey: string
): PipelineResult {
  const provingTime = PROVING_TIMES[provingKey] ?? 12757;
  const batchLatencies: number[] = [];

  // Per-batch non-proving time
  const receiveTime = batchSize * (LATENCIES.smtInsertPerTx + LATENCIES.walWritePerTx);
  const batchTime = LATENCIES.batchFormation;
  const witnessTime = batchSize * LATENCIES.witnessGenPerTx;
  const dacTime = LATENCIES.dacAttestation;
  const submitTime = LATENCIES.l1Submission;

  // In pipelined mode:
  // - First batch: full sequential latency (no overlap yet)
  // - Subsequent batches: overlap receive+batch+witness with previous proving+dac+submit
  // - Pipeline throughput = max(proving_phase, preparation_phase) per batch

  const preparationTime = receiveTime + batchTime + witnessTime;
  const provingPhaseTime = provingTime + dacTime + submitTime;

  // First batch latency (cold start)
  const firstBatchLatency = preparationTime + provingPhaseTime;
  batchLatencies.push(firstBatchLatency);

  // Subsequent batches: pipelined
  const pipelinedBatchTime = Math.max(preparationTime, provingPhaseTime);
  for (let b = 1; b < numBatches; b++) {
    batchLatencies.push(pipelinedBatchTime);
  }

  const totalTime = firstBatchLatency + (numBatches - 1) * pipelinedBatchTime;
  const totalTx = batchSize * numBatches;

  return {
    mode: 'pipelined',
    proverBackend: provingKey,
    batchSize,
    totalBatches: numBatches,
    totalTransactions: totalTx,
    totalTimeMs: totalTime,
    throughputTxPerSec: (totalTx / totalTime) * 1000,
    batchLatencies,
    avgBatchLatencyMs: totalTime / numBatches,
  };
}

// --- Main ---

function main(): void {
  console.log('=== RU-V5: Pipeline Architecture Comparison ===\n');

  const scenarios = [
    { batchSize: 8, numBatches: 10, provingKey: 'snarkjs_d32_b8' },
    { batchSize: 8, numBatches: 10, provingKey: 'rapidsnark_d32_b8' },
    { batchSize: 16, numBatches: 10, provingKey: 'snarkjs_d32_b16' },
    { batchSize: 16, numBatches: 10, provingKey: 'rapidsnark_d32_b16' },
    { batchSize: 64, numBatches: 10, provingKey: 'rapidsnark_d32_b64' },
    { batchSize: 64, numBatches: 10, provingKey: 'snarkjs_d32_b64' },
  ];

  const results: Array<{ sequential: PipelineResult; pipelined: PipelineResult; speedup: number }> = [];

  console.log('| Prover/Batch | Mode | Total (s) | Throughput (tx/s) | Avg Batch (s) |');
  console.log('|-------------|------|----------|------------------|--------------|');

  for (const s of scenarios) {
    const seq = simulateSequential(s.batchSize, s.numBatches, s.provingKey);
    const pip = simulatePipelined(s.batchSize, s.numBatches, s.provingKey);
    const speedup = seq.totalTimeMs / pip.totalTimeMs;

    results.push({ sequential: seq, pipelined: pip, speedup });

    const label = `${s.provingKey} (b${s.batchSize})`;
    console.log(
      `| ${label.padEnd(27)} | seq  | ${(seq.totalTimeMs / 1000).toFixed(1).padStart(8)} | ` +
      `${seq.throughputTxPerSec.toFixed(2).padStart(16)} | ${(seq.avgBatchLatencyMs / 1000).toFixed(2).padStart(12)} |`
    );
    console.log(
      `| ${''.padEnd(27)} | pipe | ${(pip.totalTimeMs / 1000).toFixed(1).padStart(8)} | ` +
      `${pip.throughputTxPerSec.toFixed(2).padStart(16)} | ${(pip.avgBatchLatencyMs / 1000).toFixed(2).padStart(12)} |`
    );
    console.log(
      `| ${''.padEnd(27)} | **${speedup.toFixed(2)}x** | ${''.padStart(8)} | ${''.padStart(16)} | ${''.padStart(12)} |`
    );
  }

  // Component latency breakdown
  console.log('\n=== Component Latency Breakdown (per batch) ===\n');
  for (const batchSize of [8, 16, 64]) {
    const receiveMs = batchSize * (LATENCIES.smtInsertPerTx + LATENCIES.walWritePerTx);
    const witnessMs = batchSize * LATENCIES.witnessGenPerTx;
    console.log(`Batch size ${batchSize}:`);
    console.log(`  Receive + WAL: ${receiveMs.toFixed(1)} ms`);
    console.log(`  Batch formation: ${LATENCIES.batchFormation.toFixed(3)} ms`);
    console.log(`  Witness generation: ${witnessMs.toFixed(0)} ms`);
    console.log(`  DAC attestation: ${LATENCIES.dacAttestation} ms`);
    console.log(`  L1 submission: ${LATENCIES.l1Submission} ms`);
    console.log(`  Preparation total: ${(receiveMs + LATENCIES.batchFormation + witnessMs).toFixed(1)} ms`);
    console.log('');
  }

  // Hypothesis check
  console.log('=== HYPOTHESIS CHECK ===\n');
  const targetResult = results.find(
    (r) => r.pipelined.proverBackend === 'rapidsnark_d32_b64'
  );
  if (targetResult) {
    const latency = targetResult.pipelined.avgBatchLatencyMs;
    console.log(`Target: batch 64, rapidsnark, pipelined`);
    console.log(`  Average batch latency: ${(latency / 1000).toFixed(2)} s`);
    console.log(`  Under 90s target: ${latency < 90000 ? 'PASS' : 'FAIL'}`);
    console.log(`  Throughput: ${targetResult.pipelined.throughputTxPerSec.toFixed(2)} tx/s`);
    console.log(`  Pipeline speedup: ${targetResult.speedup.toFixed(2)}x over sequential`);
  }

  // Save results
  const resultsDir = join(__dirname, '..', '..', 'results');
  mkdirSync(resultsDir, { recursive: true });
  writeFileSync(
    join(resultsDir, 'benchmark-pipeline.json'),
    JSON.stringify(results, null, 2)
  );

  console.log('\nResults saved to results/benchmark-pipeline.json');
}

main();
