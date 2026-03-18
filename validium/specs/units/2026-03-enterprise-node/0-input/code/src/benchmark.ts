// RU-V5: Enterprise Node Orchestrator -- Benchmark Harness
// Measures orchestration overhead with mock components
// Simulated proving times calibrated to RU-V2 measurements

import { createHash } from 'crypto';
import { writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import {
  EnterpriseTransaction,
  BenchmarkResult,
  NodeConfig,
} from './types';
import {
  EnterpriseNodeOrchestrator,
  MockSMT,
  MockBatchBuilder,
  MockProver,
  MockL1Submitter,
  MockDAC,
  MockQueue,
} from './orchestrator';

// --- Transaction Generator ---

function generateTransaction(index: number, enterpriseId: string): EnterpriseTransaction {
  const hash = createHash('sha256').update(`tx-${index}-${Date.now()}`).digest('hex');
  return {
    txHash: hash,
    enterpriseId,
    type: 'plasma:work_order',
    key: createHash('sha256').update(`key-${index}`).digest('hex'),
    value: createHash('sha256').update(`value-${index}`).digest('hex'),
    timestamp: Date.now(),
    signature: '0x' + 'ab'.repeat(32),
  };
}

// --- Statistics ---

function computeStats(values: number[]): {
  mean: number;
  stddev: number;
  min: number;
  max: number;
  p95: number;
  ci95: number;
} {
  const n = values.length;
  const mean = values.reduce((a, b) => a + b, 0) / n;
  const variance = values.reduce((a, b) => a + (b - mean) ** 2, 0) / (n - 1);
  const stddev = Math.sqrt(variance);
  const sorted = [...values].sort((a, b) => a - b);
  const p95 = sorted[Math.floor(n * 0.95)];
  const ci95 = 1.96 * stddev / Math.sqrt(n);

  return { mean, stddev, min: sorted[0], max: sorted[n - 1], p95, ci95 };
}

// --- Benchmark Scenarios ---

interface Scenario {
  name: string;
  batchSize: number;
  provingTimeMs: number;
  iterations: number;
  description: string;
}

const SCENARIOS: Scenario[] = [
  {
    name: 'orchestration_overhead_only',
    batchSize: 8,
    provingTimeMs: 0, // Zero proving time to isolate orchestration
    iterations: 50,
    description: 'Measures pure orchestration overhead (state machine, batch formation, SMT updates) with zero proving time',
  },
  {
    name: 'snarkjs_d32_b8',
    batchSize: 8,
    provingTimeMs: 12757,
    iterations: 30,
    description: 'Realistic E2E with snarkjs proving time (12.8s, d32, b8, 274K constraints)',
  },
  {
    name: 'rapidsnark_d32_b8',
    batchSize: 8,
    provingTimeMs: 2500,
    iterations: 30,
    description: 'Realistic E2E with rapidsnark proving time (~2.5s estimated, d32, b8)',
  },
  {
    name: 'snarkjs_d32_b16',
    batchSize: 16,
    provingTimeMs: 28000,
    iterations: 30,
    description: 'Larger batch with snarkjs (28s estimated, d32, b16, ~548K constraints)',
  },
  {
    name: 'rapidsnark_d32_b64',
    batchSize: 64,
    provingTimeMs: 12000,
    iterations: 30,
    description: 'Target MVP: batch 64 with rapidsnark (~12s estimated, d32, b64, ~2.2M constraints)',
  },
];

// --- Run One Scenario ---

async function runScenario(scenario: Scenario): Promise<BenchmarkResult> {
  console.log(`\n  Scenario: ${scenario.name}`);
  console.log(`  ${scenario.description}`);
  console.log(`  Batch size: ${scenario.batchSize}, Proving: ${scenario.provingTimeMs}ms, Iterations: ${scenario.iterations}`);

  const phaseResults: Map<string, number[]> = new Map();
  const totalTimes: number[] = [];
  const overheadTimes: number[] = [];

  // Warm-up (3 iterations, discarded)
  for (let w = 0; w < 3; w++) {
    const orch = createOrchestrator(scenario);
    await runOneCycle(orch, scenario.batchSize);
  }

  // Measured iterations
  for (let i = 0; i < scenario.iterations; i++) {
    const orch = createOrchestrator(scenario);
    const result = await runOneCycle(orch, scenario.batchSize);

    totalTimes.push(result.totalMs);

    // Collect per-phase timings
    for (const [phase, ms] of Object.entries(result.phases)) {
      if (!phaseResults.has(phase)) {
        phaseResults.set(phase, []);
      }
      phaseResults.get(phase)!.push(ms);
    }

    // Orchestration overhead = total - proving - l1_submission - dac_attestation
    const overhead = result.totalMs
      - (result.phases['proving'] ?? 0)
      - (result.phases['l1_submission'] ?? 0)
      - (result.phases['dac_attestation'] ?? 0);
    overheadTimes.push(overhead);

    if ((i + 1) % 10 === 0) {
      process.stdout.write(`  [${i + 1}/${scenario.iterations}] `);
      process.stdout.write(`total=${result.totalMs.toFixed(0)}ms `);
      process.stdout.write(`overhead=${overhead.toFixed(1)}ms\n`);
    }
  }

  // Compute statistics
  const totalStats = computeStats(totalTimes);
  const overheadStats = computeStats(overheadTimes);

  const phases = Array.from(phaseResults.entries()).map(([name, values]) => {
    const stats = computeStats(values);
    return {
      name,
      meanMs: stats.mean,
      stddevMs: stats.stddev,
      minMs: stats.min,
      maxMs: stats.max,
      p95Ms: stats.p95,
    };
  });

  const memUsage = process.memoryUsage();

  return {
    scenario: scenario.name,
    batchSize: scenario.batchSize,
    iterations: scenario.iterations,
    phases,
    totalMeanMs: totalStats.mean,
    totalStddevMs: totalStats.stddev,
    orchestrationOverheadMs: overheadStats.mean,
    memoryMb: memUsage.heapUsed / 1024 / 1024,
  };
}

function createOrchestrator(scenario: Scenario): EnterpriseNodeOrchestrator {
  return new EnterpriseNodeOrchestrator(
    { batchSize: scenario.batchSize },
    {
      smt: new MockSMT(),
      batchBuilder: new MockBatchBuilder(),
      prover: new MockProver(scenario.provingTimeMs),
      submitter: new MockL1Submitter(),
      dac: new MockDAC(),
      queue: new MockQueue(),
    }
  );
}

async function runOneCycle(
  orch: EnterpriseNodeOrchestrator,
  batchSize: number
): Promise<{ totalMs: number; phases: Record<string, number> }> {
  // Enqueue transactions directly (bypass submitTransaction to avoid
  // auto-triggering processBatchCycle which would consume the queue)
  const enterpriseId = 'enterprise-001';
  for (let i = 0; i < batchSize; i++) {
    const tx = generateTransaction(i, enterpriseId);
    (orch as any).queue.enqueue(tx);
    (orch as any).metrics.totalTransactionsReceived++;
  }

  // Measure the full batch cycle directly
  const result = await orch.processBatchCycle();
  return { totalMs: result.totalMs, phases: result.phases };
}

// --- Main ---

async function main(): Promise<void> {
  console.log('=== RU-V5: Enterprise Node Orchestrator Benchmark ===');
  console.log(`Date: ${new Date().toISOString()}`);
  console.log(`Node.js: ${process.version}`);
  console.log(`Platform: ${process.platform} ${process.arch}`);
  console.log(`Scenarios: ${SCENARIOS.length}`);

  const results: BenchmarkResult[] = [];

  for (const scenario of SCENARIOS) {
    const result = await runScenario(scenario);
    results.push(result);

    // Print summary
    console.log(`\n  --- ${scenario.name} Results ---`);
    console.log(`  Total E2E: ${result.totalMeanMs.toFixed(1)} +/- ${result.totalStddevMs.toFixed(1)} ms`);
    console.log(`  Orchestration overhead: ${result.orchestrationOverheadMs.toFixed(2)} ms`);
    console.log(`  Memory: ${result.memoryMb.toFixed(1)} MB`);
    for (const phase of result.phases) {
      console.log(`    ${phase.name}: ${phase.meanMs.toFixed(2)} +/- ${phase.stddevMs.toFixed(2)} ms (P95: ${phase.p95Ms.toFixed(2)})`);
    }
  }

  // Save results
  const resultsDir = join(__dirname, '..', '..', 'results');
  mkdirSync(resultsDir, { recursive: true });

  writeFileSync(
    join(resultsDir, 'benchmark-orchestrator.json'),
    JSON.stringify(results, null, 2)
  );

  // Print final summary table
  console.log('\n=== SUMMARY TABLE ===\n');
  console.log('| Scenario | Batch | Total (ms) | Overhead (ms) | Proving (ms) | Memory (MB) |');
  console.log('|----------|-------|-----------|--------------|-------------|------------|');
  for (const r of results) {
    const provingPhase = r.phases.find((p) => p.name === 'proving');
    const provingMs = provingPhase ? provingPhase.meanMs.toFixed(0) : 'N/A';
    console.log(
      `| ${r.scenario.padEnd(28)} | ${String(r.batchSize).padStart(5)} | ` +
      `${r.totalMeanMs.toFixed(0).padStart(9)} | ${r.orchestrationOverheadMs.toFixed(1).padStart(12)} | ` +
      `${provingMs.padStart(11)} | ${r.memoryMb.toFixed(1).padStart(10)} |`
    );
  }

  // Hypothesis evaluation
  console.log('\n=== HYPOTHESIS EVALUATION ===\n');
  const targetScenario = results.find((r) => r.scenario === 'rapidsnark_d32_b64');
  if (targetScenario) {
    const under90s = targetScenario.totalMeanMs < 90000;
    const overheadUnder30s = targetScenario.orchestrationOverheadMs < 30000;
    console.log(`Target: batch 64 with rapidsnark`);
    console.log(`  E2E latency: ${targetScenario.totalMeanMs.toFixed(0)} ms (target: <90,000 ms) -- ${under90s ? 'PASS' : 'FAIL'}`);
    console.log(`  Overhead: ${targetScenario.orchestrationOverheadMs.toFixed(1)} ms (target: <30,000 ms) -- ${overheadUnder30s ? 'PASS' : 'FAIL'}`);
  }

  const overheadScenario = results.find((r) => r.scenario === 'orchestration_overhead_only');
  if (overheadScenario) {
    console.log(`\nPure orchestration overhead (no proving/submission/DAC):`);
    console.log(`  Mean: ${overheadScenario.orchestrationOverheadMs.toFixed(2)} ms`);
    console.log(`  This is ${(overheadScenario.orchestrationOverheadMs / 90000 * 100).toFixed(4)}% of the 90s budget`);
  }

  console.log('\n=== BENCHMARK COMPLETE ===');
}

main().catch(console.error);
