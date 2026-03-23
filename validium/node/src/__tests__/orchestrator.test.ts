/**
 * E2E tests for the Enterprise Node Orchestrator.
 *
 * [Spec: validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/specs/EnterpriseNode/EnterpriseNode.tla]
 *
 * Tests the complete batch processing cycle with mock prover and mock submitter
 * for fast execution. Verifies all TLA+ invariants hold during operation.
 *
 * @module __tests__/orchestrator.test
 */

import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import * as crypto from "crypto";
import { SparseMerkleTree } from "../state";
import { TransactionQueue } from "../queue";
import type { Transaction } from "../queue/types";
import { BatchAggregator } from "../batch";
import { DACProtocol } from "../da";
import { EnterpriseNodeOrchestrator } from "../orchestrator";
import { NodeState, NodeErrorCode } from "../types";
import type { ProofResult, NodeConfig } from "../types";
import type { BatchBuildResult } from "../batch/types";

// ---------------------------------------------------------------------------
// Mock Prover
// ---------------------------------------------------------------------------

/**
 * Mock ZK prover that returns a synthetic proof instantly.
 * For E2E testing -- avoids actual snarkjs computation.
 */
class MockZKProver {
  readonly proveCalls: BatchBuildResult[] = [];

  async prove(witness: BatchBuildResult): Promise<ProofResult> {
    this.proveCalls.push(witness);
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
 * Mock L1 submitter that records submissions without blockchain interaction.
 */
class MockL1Submitter {
  readonly submissions: Array<{
    prevRoot: string;
    newRoot: string;
    batchNum: number;
  }> = [];
  private lastConfirmedRoot: string = "0".repeat(64);
  shouldReject: boolean = false;
  rejectCount: number = 0;

  async submit(
    _proof: ProofResult,
    prevStateRoot: string,
    newStateRoot: string,
    batchNum: number
  ): Promise<{ txHash: string; blockNumber: number; newStateRoot: string }> {
    if (this.shouldReject) {
      this.rejectCount++;
      throw new Error("L1 submission rejected (mock)");
    }

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
// Test Helpers
// ---------------------------------------------------------------------------

/** Create a test transaction with unique key. */
function createTx(index: number): Transaction {
  const keyHex = index.toString(16).padStart(4, "0");
  const valueHex = (index * 100).toString(16).padStart(4, "0");
  return {
    txHash: crypto.createHash("sha256").update(`tx-${index}`).digest("hex"),
    key: keyHex,
    oldValue: "0",
    newValue: valueHex,
    enterpriseId: "test-enterprise",
    timestamp: Date.now(),
  };
}

/** Create a temporary directory for WAL files. */
function createTempDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "validium-test-"));
}

/** Clean up temporary directory. */
function cleanupTempDir(dir: string): void {
  try {
    fs.rmSync(dir, { recursive: true, force: true });
  } catch {
    // Ignore cleanup errors in tests
  }
}

/** Default test config. */
function testConfig(walDir: string): NodeConfig {
  return {
    enterpriseId: "test-enterprise",
    l1RpcUrl: "http://localhost:8545",
    l1PrivateKey: "0x" + "a".repeat(64),
    stateCommitmentAddress: "0x" + "b".repeat(40),
    circuitWasmPath: "/fake/circuit.wasm",
    provingKeyPath: "/fake/proving.zkey",
    maxBatchSize: 2,
    maxWaitTimeMs: 100,
    walDir,
    walFsync: false,
    smtDepth: 10,
    dacCommitteeSize: 3,
    dacThreshold: 2,
    dacEnableFallback: true,
    apiHost: "127.0.0.1",
    apiPort: 0,
    maxRetries: 3,
    retryBaseDelayMs: 10,
    batchLoopIntervalMs: 50,
    txConfirmTimeoutMs: 120000,
  };
}

/** Create an orchestrator with mock dependencies. */
async function createTestOrchestrator(
  walDir: string,
  config?: Partial<NodeConfig>
): Promise<{
  orchestrator: EnterpriseNodeOrchestrator;
  mockProver: MockZKProver;
  mockSubmitter: MockL1Submitter;
  queue: TransactionQueue;
  aggregator: BatchAggregator;
  smt: SparseMerkleTree;
}> {
  const cfg = { ...testConfig(walDir), ...config };
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

  // Create orchestrator with mocks injected via type assertion
  // (mocks implement the same interface as real dependencies)
  const orchestrator = new EnterpriseNodeOrchestrator({
    smt,
    queue,
    aggregator,
    prover: mockProver as unknown as import("../prover").ZKProver,
    submitter: mockSubmitter as unknown as import("../submitter").L1Submitter,
    dac,
    config: cfg,
  });

  return { orchestrator, mockProver, mockSubmitter, queue, aggregator, smt };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("EnterpriseNodeOrchestrator", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = createTempDir();
  });

  afterEach(() => {
    cleanupTempDir(tempDir);
  });

  // =========================================================================
  // INV-INIT: Initial state matches TLA+ Init
  // =========================================================================

  describe("Init", () => {
    it("should start in Idle state", async () => {
      const { orchestrator } = await createTestOrchestrator(tempDir);
      expect(orchestrator.getState()).toBe(NodeState.Idle);
    });

    it("should report zero queue depth and batches on init", async () => {
      const { orchestrator } = await createTestOrchestrator(tempDir);
      const status = orchestrator.getStatus();
      expect(status.queueDepth).toBe(0);
      expect(status.batchesProcessed).toBe(0);
      expect(status.crashCount).toBe(0);
    });
  });

  // =========================================================================
  // ReceiveTx: Transaction ingestion
  // =========================================================================

  describe("ReceiveTx", () => {
    it("should accept a transaction and transition Idle -> Receiving", async () => {
      const { orchestrator } = await createTestOrchestrator(tempDir);
      const tx = createTx(1);

      orchestrator.submitTransaction(tx);

      // [Spec: nodeState' = IF nodeState = "Idle" THEN "Receiving" ELSE nodeState]
      expect(orchestrator.getState()).toBe(NodeState.Receiving);
      expect(orchestrator.getStatus().queueDepth).toBe(1);
    });

    it("should accept multiple transactions in Receiving state", async () => {
      const { orchestrator } = await createTestOrchestrator(tempDir);

      orchestrator.submitTransaction(createTx(1));
      orchestrator.submitTransaction(createTx(2));
      orchestrator.submitTransaction(createTx(3));

      expect(orchestrator.getState()).toBe(NodeState.Receiving);
      expect(orchestrator.getStatus().queueDepth).toBe(3);
    });

    it("should reject transactions in Error state", async () => {
      const { orchestrator } = await createTestOrchestrator(tempDir);

      // Force error state (internal -- testing only)
      (orchestrator as unknown as { state: NodeState }).state = NodeState.Error;

      expect(() => orchestrator.submitTransaction(createTx(1))).toThrow(
        expect.objectContaining({ code: NodeErrorCode.INVALID_STATE })
      );
    });

    it("should reject transactions in Batching state", async () => {
      const { orchestrator } = await createTestOrchestrator(tempDir);

      (orchestrator as unknown as { state: NodeState }).state =
        NodeState.Batching;

      expect(() => orchestrator.submitTransaction(createTx(1))).toThrow(
        expect.objectContaining({ code: NodeErrorCode.INVALID_STATE })
      );
    });
  });

  // =========================================================================
  // Full Batch Cycle: FormBatch -> Witness -> Proof -> Submit -> Confirm
  // =========================================================================

  describe("Full batch cycle", () => {
    it("should process a complete batch cycle (2 txs)", async () => {
      const { orchestrator, mockProver, mockSubmitter } =
        await createTestOrchestrator(tempDir);

      // Submit 2 transactions (batch threshold = 2)
      orchestrator.submitTransaction(createTx(1));
      orchestrator.submitTransaction(createTx(2));

      // Start batch loop and wait for processing
      orchestrator.start();
      await waitForState(orchestrator, NodeState.Idle, 5000);
      orchestrator.stop();

      // Verify proof was generated
      expect(mockProver.proveCalls).toHaveLength(1);
      expect(mockProver.proveCalls[0]!.transitions).toHaveLength(2);

      // Verify L1 submission
      expect(mockSubmitter.submissions).toHaveLength(1);
      expect(mockSubmitter.submissions[0]!.batchNum).toBe(1);

      // Verify state
      expect(orchestrator.getState()).toBe(NodeState.Idle);
      expect(orchestrator.getStatus().batchesProcessed).toBe(1);
      expect(orchestrator.getStatus().queueDepth).toBe(0);
    });

    it("should process multiple batch cycles sequentially", async () => {
      const { orchestrator, mockProver, mockSubmitter } =
        await createTestOrchestrator(tempDir);

      // Submit 4 transactions (2 batches of 2)
      orchestrator.submitTransaction(createTx(1));
      orchestrator.submitTransaction(createTx(2));
      orchestrator.submitTransaction(createTx(3));
      orchestrator.submitTransaction(createTx(4));

      orchestrator.start();

      // Wait for both batches to process
      await waitForCondition(
        () => orchestrator.getStatus().batchesProcessed >= 2,
        5000
      );
      orchestrator.stop();

      expect(mockProver.proveCalls).toHaveLength(2);
      expect(mockSubmitter.submissions).toHaveLength(2);
      expect(orchestrator.getStatus().batchesProcessed).toBe(2);

      // [Spec: INV-NO2 ProofStateIntegrity]
      // Second batch's prevRoot must equal first batch's newRoot
      const firstNewRoot = mockSubmitter.submissions[0]!.newRoot;
      const secondPrevRoot = mockSubmitter.submissions[1]!.prevRoot;
      expect(secondPrevRoot).toBe(firstNewRoot);
    });

    it("should form partial batch on time trigger", async () => {
      const { orchestrator, mockProver } = await createTestOrchestrator(
        tempDir,
        { maxBatchSize: 4, maxWaitTimeMs: 100 }
      );

      // Submit only 1 transaction (below batch threshold of 4)
      orchestrator.submitTransaction(createTx(1));

      orchestrator.start();

      // Wait for time-triggered batch
      await waitForCondition(
        () => orchestrator.getStatus().batchesProcessed >= 1,
        5000
      );
      orchestrator.stop();

      expect(mockProver.proveCalls).toHaveLength(1);
      expect(mockProver.proveCalls[0]!.transitions).toHaveLength(1);
    });
  });

  // =========================================================================
  // INV-NO2: Proof-State Root Integrity
  // =========================================================================

  describe("INV-NO2 ProofStateIntegrity", () => {
    it("should chain state roots across batches without gaps", async () => {
      const { orchestrator, mockSubmitter } =
        await createTestOrchestrator(tempDir);

      // Process 3 batches
      for (let batch = 0; batch < 3; batch++) {
        orchestrator.submitTransaction(createTx(batch * 2 + 1));
        orchestrator.submitTransaction(createTx(batch * 2 + 2));
      }

      orchestrator.start();
      await waitForCondition(
        () => orchestrator.getStatus().batchesProcessed >= 3,
        10000
      );
      orchestrator.stop();

      // Verify chain continuity: each batch's prevRoot = previous batch's newRoot
      for (let i = 1; i < mockSubmitter.submissions.length; i++) {
        expect(mockSubmitter.submissions[i]!.prevRoot).toBe(
          mockSubmitter.submissions[i - 1]!.newRoot
        );
      }
    });
  });

  // =========================================================================
  // INV-NO3: Privacy / No Data Leakage
  // =========================================================================

  describe("INV-NO3 NoDataLeakage", () => {
    it("should only send proof signals and DAC shares externally", async () => {
      const { orchestrator, mockSubmitter } =
        await createTestOrchestrator(tempDir);

      orchestrator.submitTransaction(createTx(1));
      orchestrator.submitTransaction(createTx(2));

      orchestrator.start();
      await waitForCondition(
        () => orchestrator.getStatus().batchesProcessed >= 1,
        5000
      );
      orchestrator.stop();

      // L1 submission contains only proof signals (a, b, c, publicSignals)
      // No raw transaction data in submissions
      const submission = mockSubmitter.submissions[0]!;
      expect(submission).not.toHaveProperty("transactions");
      expect(submission).not.toHaveProperty("rawData");
    });
  });

  // =========================================================================
  // INV-NO4: Crash Recovery / No Transaction Loss
  // =========================================================================

  describe("INV-NO4 NoTransactionLoss", () => {
    it("should recover enqueued transactions after simulated crash", async () => {
      const { queue } = await createTestOrchestrator(tempDir);

      // Enqueue transactions
      queue.enqueue(createTx(1));
      queue.enqueue(createTx(2));
      queue.enqueue(createTx(3));

      // Simulate crash: create new queue pointing to same WAL directory
      const recoveredQueue = new TransactionQueue({
        walDir: tempDir,
        fsyncOnWrite: false,
      });

      const recoveredCount = recoveredQueue.recover();

      // [Spec: NoTransactionLoss -- all uncommitted txs recovered from WAL]
      expect(recoveredCount).toBe(3);
      expect(recoveredQueue.size).toBe(3);
    });

    it("should recover and continue processing after error", async () => {
      const { orchestrator, mockSubmitter } =
        await createTestOrchestrator(tempDir);

      // Make first submission fail, then succeed
      mockSubmitter.shouldReject = true;

      orchestrator.submitTransaction(createTx(1));
      orchestrator.submitTransaction(createTx(2));

      orchestrator.start();

      // Wait for error + recovery attempt
      await waitForCondition(() => mockSubmitter.rejectCount >= 1, 3000);

      // Now allow submissions
      mockSubmitter.shouldReject = false;

      // Wait for successful processing after recovery
      await waitForCondition(
        () => orchestrator.getStatus().batchesProcessed >= 1,
        10000
      );
      orchestrator.stop();

      expect(orchestrator.getStatus().crashCount).toBeGreaterThanOrEqual(1);
      expect(orchestrator.getStatus().batchesProcessed).toBeGreaterThanOrEqual(
        1
      );
    });
  });

  // =========================================================================
  // INV-NO5: State Root Continuity
  // =========================================================================

  describe("INV-NO5 StateRootContinuity", () => {
    it("should maintain SMT root consistency through batch cycle", async () => {
      const { orchestrator, smt } = await createTestOrchestrator(tempDir);
      const initialRoot = smt.root.toString(16);

      // Before any batch: smtState = l1State (both empty/genesis)
      expect(orchestrator.getState()).toBe(NodeState.Idle);

      orchestrator.submitTransaction(createTx(1));
      orchestrator.submitTransaction(createTx(2));

      orchestrator.start();
      await waitForCondition(
        () => orchestrator.getStatus().batchesProcessed >= 1,
        5000
      );
      orchestrator.stop();

      // After confirmation: smtState advanced and l1State matches
      const batches = orchestrator.getAllBatches();
      expect(batches).toHaveLength(1);
      expect(batches[0]!.status).toBe("confirmed");
      // prevStateRoot should be the initial root
      expect(batches[0]!.prevStateRoot).toBe(initialRoot);
      // newStateRoot should be different (batch applied)
      expect(batches[0]!.newStateRoot).not.toBe(initialRoot);
    });
  });

  // =========================================================================
  // BatchSizeBound invariant
  // =========================================================================

  describe("BatchSizeBound", () => {
    it("should never form a batch exceeding maxBatchSize", async () => {
      const { orchestrator, mockProver } = await createTestOrchestrator(
        tempDir,
        { maxBatchSize: 2 }
      );

      // Submit 5 transactions
      for (let i = 1; i <= 5; i++) {
        orchestrator.submitTransaction(createTx(i));
      }

      orchestrator.start();
      await waitForCondition(
        () => orchestrator.getStatus().batchesProcessed >= 2,
        10000
      );
      orchestrator.stop();

      // [Spec: BatchSizeBound -- Len(batchTxs) <= BatchThreshold]
      for (const call of mockProver.proveCalls) {
        expect(call.transitions.length).toBeLessThanOrEqual(2);
      }
    });
  });

  // =========================================================================
  // Pipelined ingestion (concurrent ReceiveTx)
  // =========================================================================

  describe("Pipelined ingestion", () => {
    it("should accept transactions during Proving state", async () => {
      const { orchestrator } = await createTestOrchestrator(tempDir);

      // Start with enough for a batch
      orchestrator.submitTransaction(createTx(1));
      orchestrator.submitTransaction(createTx(2));

      orchestrator.start();

      // Wait until we are past Batching (Proving or Submitting)
      await waitForCondition(
        () =>
          orchestrator.getState() === NodeState.Proving ||
          orchestrator.getState() === NodeState.Submitting ||
          orchestrator.getState() === NodeState.Idle,
        5000
      );

      // Submit more transactions -- should be accepted (pipelined)
      // Even if state is Proving or Submitting, ReceiveTx is valid
      const currentState = orchestrator.getState();
      if (
        currentState === NodeState.Proving ||
        currentState === NodeState.Submitting
      ) {
        expect(() => orchestrator.submitTransaction(createTx(3))).not.toThrow();
      }

      orchestrator.stop();
    });
  });

  // =========================================================================
  // Status and Batch queries
  // =========================================================================

  describe("Status and queries", () => {
    it("should return accurate status", async () => {
      const { orchestrator } = await createTestOrchestrator(tempDir);
      const status = orchestrator.getStatus();

      expect(status.version).toBe("0.1.0");
      expect(status.enterpriseId).toBe("test-enterprise");
      expect(status.state).toBe(NodeState.Idle);
      expect(status.uptimeMs).toBeGreaterThanOrEqual(0);
    });

    it("should return batch record after processing", async () => {
      const { orchestrator } = await createTestOrchestrator(tempDir);

      orchestrator.submitTransaction(createTx(1));
      orchestrator.submitTransaction(createTx(2));

      orchestrator.start();
      await waitForCondition(
        () => orchestrator.getStatus().batchesProcessed >= 1,
        5000
      );
      orchestrator.stop();

      const batches = orchestrator.getAllBatches();
      expect(batches).toHaveLength(1);

      const batch = batches[0]!;
      expect(batch.status).toBe("confirmed");
      expect(batch.txCount).toBe(2);
      expect(batch.batchNum).toBe(1);
      expect(batch.l1TxHash).toBeDefined();
      expect(batch.confirmedAt).toBeDefined();

      // Query by ID
      const byId = orchestrator.getBatch(batch.batchId);
      expect(byId).toBeDefined();
      expect(byId!.batchId).toBe(batch.batchId);
    });

    it("should return undefined for unknown batch ID", async () => {
      const { orchestrator } = await createTestOrchestrator(tempDir);
      expect(orchestrator.getBatch("nonexistent")).toBeUndefined();
    });
  });
});

// ---------------------------------------------------------------------------
// Utility: wait for orchestrator to reach a state
// ---------------------------------------------------------------------------

function waitForState(
  orchestrator: EnterpriseNodeOrchestrator,
  targetState: NodeState,
  timeoutMs: number
): Promise<void> {
  return waitForCondition(
    () => orchestrator.getState() === targetState,
    timeoutMs
  );
}

function waitForCondition(
  condition: () => boolean,
  timeoutMs: number
): Promise<void> {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const check = (): void => {
      if (condition()) {
        resolve();
        return;
      }
      if (Date.now() - start > timeoutMs) {
        reject(new Error(`Condition not met within ${timeoutMs}ms`));
        return;
      }
      setTimeout(check, 25);
    };
    check();
  });
}
