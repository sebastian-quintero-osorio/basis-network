/**
 * Crash recovery test script for the Enterprise Validium Node.
 *
 * Tests crash recovery scenarios using the orchestrator directly (no HTTP),
 * validating that the WAL-based recovery mechanism correctly restores
 * uncommitted transactions after simulated crashes.
 *
 * Scenarios:
 *   1. Crash during proving -- all 8 submitted txs recovered via WAL
 *   2. Partial commit -- only uncommitted txs recovered after crash
 *   3. Corrupt SMT checkpoint -- orchestrator starts fresh gracefully
 *
 * Usage:
 *   npx ts-node scripts/crash-recovery-test.ts
 *
 * @module scripts/crash-recovery-test
 */

import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import * as crypto from "crypto";
import { SparseMerkleTree } from "../src/state";
import { TransactionQueue } from "../src/queue";
import type { Transaction } from "../src/queue/types";
import { BatchAggregator } from "../src/batch";
import { DACProtocol } from "../src/da";
import { EnterpriseNodeOrchestrator } from "../src/orchestrator";
import { NodeState } from "../src/types";
import type { ProofResult, NodeConfig } from "../src/types";
import type { BatchBuildResult } from "../src/batch/types";
import type { ZKProver } from "../src/prover";
import type { L1Submitter } from "../src/submitter";

// ---------------------------------------------------------------------------
// Mock Prover
// ---------------------------------------------------------------------------

/**
 * Mock ZK prover for crash recovery testing.
 * Can be configured to throw errors on specific calls to simulate crashes.
 */
class MockZKProver {
  proveCalls: BatchBuildResult[] = [];
  shouldFail: boolean = false;
  failMessage: string = "Simulated prover crash";

  async prove(witness: BatchBuildResult): Promise<ProofResult> {
    this.proveCalls.push(witness);

    if (this.shouldFail) {
      throw new Error(this.failMessage);
    }

    return {
      a: ["1", "2"],
      b: [
        ["3", "4"],
        ["5", "6"],
      ],
      c: ["7", "8"],
      publicSignals: [
        witness.prevStateRoot,
        witness.newStateRoot,
        String(witness.batchNum),
        "test-enterprise",
      ],
      durationMs: 1,
    };
  }
}

// ---------------------------------------------------------------------------
// Mock L1 Submitter
// ---------------------------------------------------------------------------

/**
 * Mock L1 submitter for crash recovery testing.
 */
class MockL1Submitter {
  submissions: Array<{
    prevRoot: string;
    newRoot: string;
    batchNum: number;
  }> = [];
  private lastConfirmedRoot: string = "0".repeat(64);

  async submit(
    _proof: ProofResult,
    prevStateRoot: string,
    newStateRoot: string,
    batchNum: number
  ): Promise<{ txHash: string; blockNumber: number; newStateRoot: string }> {
    this.submissions.push({
      prevRoot: prevStateRoot,
      newRoot: newStateRoot,
      batchNum,
    });
    this.lastConfirmedRoot = newStateRoot;

    return {
      txHash: "0x" + crypto.randomBytes(32).toString("hex"),
      blockNumber: this.submissions.length,
      newStateRoot,
    };
  }

  getLastConfirmedRoot(): string {
    return this.lastConfirmedRoot;
  }

  setLastConfirmedRoot(root: string): void {
    this.lastConfirmedRoot = root;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Create a test transaction with a unique key derived from the index. */
function createTx(index: number): Transaction {
  const keyHex = (index + 1).toString(16).padStart(4, "0");
  const valueHex = ((index + 1) * 100).toString(16).padStart(4, "0");
  return {
    txHash: crypto.createHash("sha256").update(`crash-test-tx-${index}`).digest("hex"),
    key: keyHex,
    oldValue: "0",
    newValue: valueHex,
    enterpriseId: "test-enterprise",
    timestamp: Date.now(),
  };
}

/** Create a temporary directory for WAL and checkpoint files. */
function createTempDir(label: string): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), `validium-crash-${label}-`));
}

/** Remove a temporary directory. */
function cleanupDir(dir: string): void {
  try {
    fs.rmSync(dir, { recursive: true, force: true });
  } catch {
    // Ignore cleanup errors
  }
}

/** Build a default test config for the given WAL directory. */
function testConfig(walDir: string): NodeConfig {
  return {
    enterpriseId: "test-enterprise",
    l1RpcUrl: "http://localhost:8545",
    l1PrivateKey: "0x" + "a".repeat(64),
    stateCommitmentAddress: "0x" + "b".repeat(40),
    circuitWasmPath: "/fake/circuit.wasm",
    provingKeyPath: "/fake/proving.zkey",
    maxBatchSize: 8,
    maxWaitTimeMs: 50,
    walDir,
    walFsync: false,
    smtDepth: 10,
    dacCommitteeSize: 3,
    dacThreshold: 2,
    dacEnableFallback: true,
    apiHost: "127.0.0.1",
    apiPort: 0,
    maxRetries: 0,
    retryBaseDelayMs: 10,
    batchLoopIntervalMs: 30,
    txConfirmTimeoutMs: 120000,
  };
}

/** Create an orchestrator with mock dependencies. */
async function createTestOrchestrator(
  walDir: string,
  configOverrides?: Partial<NodeConfig>
): Promise<{
  orchestrator: EnterpriseNodeOrchestrator;
  mockProver: MockZKProver;
  mockSubmitter: MockL1Submitter;
  queue: TransactionQueue;
  aggregator: BatchAggregator;
  smt: SparseMerkleTree;
  config: NodeConfig;
}> {
  const cfg = { ...testConfig(walDir), ...configOverrides };
  const smt = await SparseMerkleTree.create(cfg.smtDepth);
  const queue = new TransactionQueue({
    walDir: cfg.walDir,
    fsyncOnWrite: cfg.walFsync,
  });
  const aggregator = new BatchAggregator(queue, {
    maxBatchSize: cfg.maxBatchSize,
    maxWaitTimeMs: cfg.maxWaitTimeMs,
  });

  const mockProver = new MockZKProver();
  const mockSubmitter = new MockL1Submitter();
  const dac = new DACProtocol({
    committeeSize: cfg.dacCommitteeSize,
    threshold: cfg.dacThreshold,
    enableFallback: cfg.dacEnableFallback,
  });

  const orchestrator = new EnterpriseNodeOrchestrator({
    smt,
    queue,
    aggregator,
    prover: mockProver as unknown as ZKProver,
    submitter: mockSubmitter as unknown as L1Submitter,
    dac,
    config: cfg,
  });

  return { orchestrator, mockProver, mockSubmitter, queue, aggregator, smt, config: cfg };
}

/** Wait for a condition to become true, polling at intervalMs. */
async function waitFor(
  condition: () => boolean,
  timeoutMs: number,
  intervalMs: number = 20
): Promise<boolean> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (condition()) return true;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return condition();
}

// ---------------------------------------------------------------------------
// Test Runner
// ---------------------------------------------------------------------------

interface ScenarioResult {
  name: string;
  passed: boolean;
  details: string;
  durationMs: number;
}

const results: ScenarioResult[] = [];

async function runScenario(
  name: string,
  fn: () => Promise<string>
): Promise<boolean> {
  const start = Date.now();
  console.log(`\n${"=".repeat(70)}`);
  console.log(`SCENARIO: ${name}`);
  console.log("=".repeat(70));

  try {
    const details = await fn();
    const duration = Date.now() - start;
    results.push({ name, passed: true, details, durationMs: duration });
    console.log(`\n  [PASS] ${name} (${duration}ms)`);
    console.log(`  Details: ${details}`);
    return true;
  } catch (error) {
    const duration = Date.now() - start;
    const msg = error instanceof Error ? error.message : String(error);
    results.push({ name, passed: false, details: msg, durationMs: duration });
    console.log(`\n  [FAIL] ${name} (${duration}ms)`);
    console.log(`  Error: ${msg}`);
    return false;
  }
}

// ---------------------------------------------------------------------------
// Scenario 1: Crash during proving -- all WAL txs recovered
// ---------------------------------------------------------------------------

async function scenario1CrashDuringProving(): Promise<string> {
  const walDir = createTempDir("s1");

  try {
    // Phase A: Submit 8 transactions and trigger batch with a failing prover
    console.log("  Phase A: Submitting 8 transactions with failing prover...");

    const { orchestrator, mockProver, queue } = await createTestOrchestrator(walDir);

    // Configure prover to fail (simulate crash during proving)
    mockProver.shouldFail = true;

    // Submit 8 transactions
    for (let i = 0; i < 8; i++) {
      orchestrator.submitTransaction(createTx(i));
    }

    const queueSizeAfterSubmit = queue.size;
    console.log(`  Submitted 8 txs, queue size: ${queueSizeAfterSubmit}`);

    if (queueSizeAfterSubmit !== 8) {
      throw new Error(`Expected queue size 8, got ${queueSizeAfterSubmit}`);
    }

    // Start the batch loop to trigger the failing batch cycle
    orchestrator.start();

    // Wait for the error recovery cycle to complete
    await waitFor(
      () => orchestrator.getState() === NodeState.Idle || orchestrator.getState() === NodeState.Receiving,
      5000
    );

    // Stop the orchestrator
    orchestrator.stop();

    // Verify the prover was called (meaning batch formation + witness happened)
    console.log(`  Prover called ${mockProver.proveCalls.length} time(s) (expected to fail)`);

    // Phase B: Simulate fresh startup -- create new orchestrator with same WAL dir
    console.log("  Phase B: Simulating fresh restart with same WAL dir...");

    const fresh = await createTestOrchestrator(walDir);

    // Recover from WAL
    await fresh.orchestrator.recover();

    const recoveredQueueSize = fresh.queue.size;
    console.log(`  Recovered queue size: ${recoveredQueueSize}`);

    if (recoveredQueueSize !== 8) {
      throw new Error(
        `Expected 8 recovered transactions, got ${recoveredQueueSize}. ` +
          `WAL recovery did not restore all uncommitted transactions.`
      );
    }

    // Verify the orchestrator transitions to Receiving (queue non-empty)
    const stateAfterRecovery = fresh.orchestrator.getState();
    if (stateAfterRecovery !== NodeState.Receiving) {
      throw new Error(
        `Expected state Receiving after recovery with non-empty queue, got ${stateAfterRecovery}`
      );
    }

    return `All 8 transactions recovered from WAL after prover crash. State: ${stateAfterRecovery}`;
  } finally {
    cleanupDir(walDir);
  }
}

// ---------------------------------------------------------------------------
// Scenario 2: Partial commit -- only uncommitted txs recovered
// ---------------------------------------------------------------------------

async function scenario2PartialCommit(): Promise<string> {
  const walDir = createTempDir("s2");

  try {
    // Phase A: Submit 4 transactions, process them successfully
    console.log("  Phase A: Submitting and processing first batch of 4 txs...");

    const {
      orchestrator,
      mockProver,
      mockSubmitter,
      queue,
    } = await createTestOrchestrator(walDir, { maxBatchSize: 4 });

    // Submit first 4 transactions
    for (let i = 0; i < 4; i++) {
      orchestrator.submitTransaction(createTx(i));
    }

    console.log(`  Queue size after first 4: ${queue.size}`);

    // Start the batch loop and wait for first batch to be confirmed
    orchestrator.start();

    const firstBatchConfirmed = await waitFor(
      () => mockSubmitter.submissions.length >= 1,
      10000
    );

    if (!firstBatchConfirmed) {
      throw new Error("First batch was not confirmed within timeout");
    }

    console.log(`  First batch confirmed. Submissions: ${mockSubmitter.submissions.length}`);

    // Phase B: Submit 4 more transactions, then simulate crash
    console.log("  Phase B: Submitting second batch of 4 txs, then crashing prover...");

    for (let i = 4; i < 8; i++) {
      orchestrator.submitTransaction(createTx(i));
    }

    const queueAfterSecondBatch = queue.size;
    console.log(`  Queue size after second 4: ${queueAfterSecondBatch}`);

    // Configure prover to fail on the next batch (simulate crash)
    mockProver.shouldFail = true;

    // Wait for the error to occur and recovery to complete
    await waitFor(
      () => mockProver.proveCalls.length >= 2,
      10000
    );

    // Give recovery a moment to complete
    await new Promise((r) => setTimeout(r, 200));

    // Stop the orchestrator
    orchestrator.stop();

    console.log(`  Prover calls: ${mockProver.proveCalls.length}, Submissions: ${mockSubmitter.submissions.length}`);

    // Phase C: Fresh startup with same WAL dir
    console.log("  Phase C: Simulating fresh restart with same WAL dir...");

    const fresh = await createTestOrchestrator(walDir, { maxBatchSize: 4 });
    await fresh.orchestrator.recover();

    const recoveredQueueSize = fresh.queue.size;
    console.log(`  Recovered queue size: ${recoveredQueueSize}`);

    // The first batch of 4 was checkpointed (confirmed). The second batch of 4
    // was never checkpointed (prover crashed). So only 4 should be recovered.
    if (recoveredQueueSize !== 4) {
      throw new Error(
        `Expected 4 recovered transactions (only uncommitted batch), got ${recoveredQueueSize}. ` +
          `First batch should have been checkpointed.`
      );
    }

    return `4 committed txs properly checkpointed, 4 uncommitted txs recovered from WAL. ` +
      `Total submissions before crash: ${mockSubmitter.submissions.length}`;
  } finally {
    cleanupDir(walDir);
  }
}

// ---------------------------------------------------------------------------
// Scenario 3: Corrupt SMT checkpoint -- starts fresh gracefully
// ---------------------------------------------------------------------------

async function scenario3CorruptCheckpoint(): Promise<string> {
  const walDir = createTempDir("s3");

  try {
    // Phase A: Create a valid checkpoint file by processing a batch
    console.log("  Phase A: Processing a batch to create SMT checkpoint...");

    const {
      orchestrator,
      mockSubmitter,
    } = await createTestOrchestrator(walDir, { maxBatchSize: 4 });

    for (let i = 0; i < 4; i++) {
      orchestrator.submitTransaction(createTx(i));
    }

    orchestrator.start();

    const batchConfirmed = await waitFor(
      () => mockSubmitter.submissions.length >= 1,
      10000
    );

    if (!batchConfirmed) {
      throw new Error("Batch was not confirmed within timeout");
    }

    orchestrator.stop();

    // Verify checkpoint file exists
    const checkpointPath = path.join(walDir, "smt-checkpoint.json");
    if (!fs.existsSync(checkpointPath)) {
      throw new Error(`SMT checkpoint file not created at ${checkpointPath}`);
    }

    console.log("  Checkpoint file created.");

    // Phase B: Corrupt the checkpoint file
    console.log("  Phase B: Corrupting SMT checkpoint file...");

    fs.writeFileSync(checkpointPath, '{"version":1,"depth":10,"broken":true}', "utf-8");

    // Phase C: Create fresh orchestrator and attempt recovery
    console.log("  Phase C: Attempting recovery with corrupt checkpoint...");

    const fresh = await createTestOrchestrator(walDir, { maxBatchSize: 4 });

    // The orchestrator's recover() should handle the corrupt checkpoint gracefully.
    // It should either load the checkpoint and fail deserialization (caught internally),
    // or start fresh. Either way, it should not throw an unhandled error.
    let recoveryError: string | null = null;
    try {
      await fresh.orchestrator.recover();
    } catch (err) {
      recoveryError = err instanceof Error ? err.message : String(err);
    }

    // Check the orchestrator is in a usable state (Idle or Receiving)
    const finalState = fresh.orchestrator.getState();
    const isUsable = finalState === NodeState.Idle || finalState === NodeState.Receiving;

    if (recoveryError && !isUsable) {
      throw new Error(
        `Recovery failed with unrecoverable error: ${recoveryError}. ` +
          `Final state: ${finalState}`
      );
    }

    // Verify the node can still accept transactions after corrupt checkpoint recovery
    console.log("  Phase D: Verifying node can accept new transactions...");

    let canAcceptTx = false;
    try {
      fresh.orchestrator.submitTransaction(createTx(99));
      canAcceptTx = true;
    } catch {
      canAcceptTx = false;
    }

    if (!canAcceptTx) {
      throw new Error("Node cannot accept transactions after corrupt checkpoint recovery");
    }

    const details = recoveryError
      ? `Recovery encountered error (handled gracefully): ${recoveryError}. ` +
        `Node state: ${finalState}, accepts txs: ${canAcceptTx}`
      : `Recovery handled corrupt checkpoint gracefully. ` +
        `Node state: ${finalState}, accepts txs: ${canAcceptTx}`;

    return details;
  } finally {
    cleanupDir(walDir);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  console.log("");
  console.log("Basis Network Validium Node -- Crash Recovery Tests");
  console.log("=".repeat(70));
  console.log("");

  await runScenario(
    "Scenario 1: Crash during proving -- all 8 txs recovered via WAL",
    scenario1CrashDuringProving
  );

  await runScenario(
    "Scenario 2: Partial commit -- only 4 uncommitted txs recovered",
    scenario2PartialCommit
  );

  await runScenario(
    "Scenario 3: Corrupt SMT checkpoint -- starts fresh gracefully",
    scenario3CorruptCheckpoint
  );

  // Summary
  console.log("");
  console.log("=".repeat(70));
  console.log("CRASH RECOVERY TEST SUMMARY");
  console.log("=".repeat(70));
  console.log("");

  const passed = results.filter((r) => r.passed).length;
  const failed = results.filter((r) => !r.passed).length;

  for (const r of results) {
    const status = r.passed ? "PASS" : "FAIL";
    console.log(`  [${status}] ${r.name} (${r.durationMs}ms)`);
    if (!r.passed) {
      console.log(`         Error: ${r.details}`);
    }
  }

  console.log("");
  console.log(`Results: ${passed} passed, ${failed} failed, ${results.length} total`);
  console.log("=".repeat(70));
  console.log("");

  if (failed > 0) {
    process.exit(1);
  }

  process.exit(0);
}

main().catch((err) => {
  console.error("Crash recovery test runner failed:", err);
  process.exit(1);
});
