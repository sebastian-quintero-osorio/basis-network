/**
 * Integration test: exercises the real cross-module pipeline without mocks.
 *
 * This test verifies that all modules, built by separate agent sessions,
 * work together as a single coherent system. No mocks are used -- every
 * component is real except the ZK prover and L1 submitter (which require
 * external infrastructure).
 *
 * Pipeline under test:
 *   submitTransaction() -> WAL append + queue push
 *   formBatch()         -> dequeue + deterministic batch ID
 *   buildBatchCircuitInput() -> apply to SMT, collect Merkle proofs
 *   (prover + submitter verified separately via E2E tests)
 *
 * @module __tests__/integration
 */

import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as crypto from "crypto";
import { SparseMerkleTree } from "../state";
import { TransactionQueue } from "../queue";
import { BatchAggregator, buildBatchCircuitInput } from "../batch";
import type { Transaction } from "../queue/types";
import type { BatchBuildResult } from "../batch/types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeTempDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "validium-integration-"));
}

function createTransaction(
  index: number,
  enterpriseId: string = "enterprise-001"
): Transaction {
  const keyHex = (index + 1).toString(16).padStart(4, "0");
  const valueHex = (index * 100 + 42).toString(16).padStart(4, "0");
  return {
    txHash: crypto
      .createHash("sha256")
      .update(`tx-${index}-${Date.now()}`)
      .digest("hex"),
    key: keyHex,
    oldValue: "0",
    newValue: valueHex,
    enterpriseId,
    timestamp: Date.now(),
  };
}

// ---------------------------------------------------------------------------
// Test Suite
// ---------------------------------------------------------------------------

describe("Integration: Cross-Module Pipeline", () => {
  let walDir: string;

  beforeEach(() => {
    walDir = makeTempDir();
  });

  afterEach(() => {
    fs.rmSync(walDir, { recursive: true, force: true });
  });

  // -------------------------------------------------------------------------
  // 1. Full pipeline: enqueue -> batch -> witness
  // -------------------------------------------------------------------------

  it("should process transactions through the full pipeline: enqueue -> form batch -> build witness", async () => {
    // -- Initialize modules (real, no mocks) --
    const smt = await SparseMerkleTree.create(10);
    const queue = new TransactionQueue({ walDir, fsyncOnWrite: false });
    const aggregator = new BatchAggregator(queue, {
      maxBatchSize: 4,
      maxWaitTimeMs: 60000,
    });

    const emptyRoot = smt.root;

    // -- Step 1: Enqueue transactions --
    const txCount = 4;
    const transactions: Transaction[] = [];
    for (let i = 0; i < txCount; i++) {
      const tx = createTransaction(i);
      transactions.push(tx);
      const seq = queue.enqueue(tx);
      expect(seq).toBe(i + 1);
    }

    expect(queue.size).toBe(txCount);

    // -- Step 2: Form batch --
    expect(aggregator.shouldFormBatch()).toBe(true);
    const batch = aggregator.formBatch();
    expect(batch).not.toBeNull();
    expect(batch!.txCount).toBe(txCount);
    expect(batch!.batchNum).toBe(1);
    expect(batch!.transactions).toHaveLength(txCount);

    // Verify deterministic batch ID (SHA-256 of ordered tx hashes)
    const expectedBatchId = crypto
      .createHash("sha256")
      .update(transactions.map((tx) => tx.txHash).join("|"))
      .digest("hex");
    expect(batch!.batchId).toBe(expectedBatchId);

    // -- Step 3: Build circuit witness (applies transactions to SMT) --
    const witness: BatchBuildResult = await buildBatchCircuitInput(
      batch!,
      smt
    );

    // Verify witness structure
    expect(witness.prevStateRoot).toBeDefined();
    expect(witness.newStateRoot).toBeDefined();
    expect(witness.prevStateRoot).not.toBe(witness.newStateRoot);
    expect(witness.transitions).toHaveLength(txCount);
    expect(witness.batchId).toBe(batch!.batchId);
    expect(witness.batchNum).toBe(1);

    // Verify prevStateRoot matches the empty tree root
    expect(witness.prevStateRoot).toBe(emptyRoot.toString(16));

    // Verify SMT was actually modified
    expect(smt.root).not.toBe(emptyRoot);
    expect(smt.root.toString(16)).toBe(witness.newStateRoot);

    // -- Step 4: Verify each transition has valid Merkle proofs --
    for (let i = 0; i < txCount; i++) {
      const t = witness.transitions[i]!;

      // Each transition has siblings (Merkle proof path)
      expect(t.siblings.length).toBe(10); // SMT depth = 10
      expect(t.pathBits.length).toBe(10);

      // Keys match the input transactions
      expect(t.key).toBe(transactions[i]!.key);
      expect(t.newValue).toBe(transactions[i]!.newValue);

      // Root chain: each rootAfter becomes the next rootBefore
      if (i > 0) {
        expect(t.rootBefore).toBe(witness.transitions[i - 1]!.rootAfter);
      }
    }

    // First rootBefore = prevStateRoot, last rootAfter = newStateRoot
    expect(witness.transitions[0]!.rootBefore).toBe(witness.prevStateRoot);
    expect(witness.transitions[txCount - 1]!.rootAfter).toBe(
      witness.newStateRoot
    );

    // -- Step 5: Verify deferred checkpoint (v1-fix) --
    // At this point the batch is formed but NOT checkpointed.
    // Calling onBatchProcessed completes the deferred checkpoint.
    expect(aggregator.pendingCount).toBe(1);
    aggregator.onBatchProcessed(batch!.batchId);
    expect(aggregator.pendingCount).toBe(0);
  }, 30000);

  // -------------------------------------------------------------------------
  // 2. Multiple sequential batches with state continuity
  // -------------------------------------------------------------------------

  it("should maintain state continuity across multiple batches", async () => {
    const smt = await SparseMerkleTree.create(10);
    const queue = new TransactionQueue({ walDir, fsyncOnWrite: false });
    const aggregator = new BatchAggregator(queue, {
      maxBatchSize: 2,
      maxWaitTimeMs: 60000,
    });

    // Enqueue 4 transactions (will form 2 batches of size 2)
    for (let i = 0; i < 4; i++) {
      queue.enqueue(createTransaction(i));
    }

    // -- Batch 1 --
    const batch1 = aggregator.formBatch();
    expect(batch1).not.toBeNull();
    expect(batch1!.txCount).toBe(2);

    const witness1 = await buildBatchCircuitInput(batch1!, smt);
    aggregator.onBatchProcessed(batch1!.batchId);

    // -- Batch 2 --
    const batch2 = aggregator.formBatch();
    expect(batch2).not.toBeNull();
    expect(batch2!.txCount).toBe(2);
    expect(batch2!.batchNum).toBe(2);

    const witness2 = await buildBatchCircuitInput(batch2!, smt);
    aggregator.onBatchProcessed(batch2!.batchId);

    // State continuity: batch2's prevStateRoot = batch1's newStateRoot
    expect(witness2.prevStateRoot).toBe(witness1.newStateRoot);

    // Final SMT root matches batch2's newStateRoot
    expect(smt.root.toString(16)).toBe(witness2.newStateRoot);

    // Queue is empty
    expect(queue.size).toBe(0);
    expect(aggregator.pendingCount).toBe(0);
  }, 30000);

  // -------------------------------------------------------------------------
  // 3. Partial batch (time-triggered, fewer than maxBatchSize)
  // -------------------------------------------------------------------------

  it("should handle partial batches correctly", async () => {
    const smt = await SparseMerkleTree.create(10);
    const queue = new TransactionQueue({ walDir, fsyncOnWrite: false });
    const aggregator = new BatchAggregator(queue, {
      maxBatchSize: 8,
      maxWaitTimeMs: 1, // 1ms: triggers immediately
    });

    // Enqueue only 3 transactions (less than maxBatchSize=8)
    for (let i = 0; i < 3; i++) {
      queue.enqueue(createTransaction(i));
    }

    // Wait for timer to expire
    await new Promise((resolve) => setTimeout(resolve, 10));

    // Time trigger should fire
    expect(aggregator.shouldFormBatch()).toBe(true);

    const batch = aggregator.formBatch();
    expect(batch).not.toBeNull();
    expect(batch!.txCount).toBe(3); // Partial batch, not padded

    const witness = await buildBatchCircuitInput(batch!, smt);
    expect(witness.transitions).toHaveLength(3);

    // The ZK prover would pad remaining slots with identity transitions
    // (key=0, old=0, new=0), but that is the prover's responsibility
    aggregator.onBatchProcessed(batch!.batchId);
  }, 30000);

  // -------------------------------------------------------------------------
  // 4. WAL crash recovery preserves uncommitted transactions
  // -------------------------------------------------------------------------

  it("should recover uncommitted transactions from WAL after simulated crash", async () => {
    // -- Phase 1: Write transactions and form batch (but don't checkpoint) --
    const smt1 = await SparseMerkleTree.create(10);
    const queue1 = new TransactionQueue({ walDir, fsyncOnWrite: false });
    const aggregator1 = new BatchAggregator(queue1, {
      maxBatchSize: 2,
      maxWaitTimeMs: 60000,
    });

    // Enqueue 4 transactions
    for (let i = 0; i < 4; i++) {
      queue1.enqueue(createTransaction(i));
    }

    // Process first batch (with checkpoint)
    const batch1 = aggregator1.formBatch();
    expect(batch1).not.toBeNull();
    await buildBatchCircuitInput(batch1!, smt1);
    aggregator1.onBatchProcessed(batch1!.batchId);

    // Second batch is formed but NOT checkpointed (simulates crash during proving)
    const batch2 = aggregator1.formBatch();
    expect(batch2).not.toBeNull();
    // Do NOT call onBatchProcessed -- this simulates a crash

    // -- Phase 2: "Crash" and recover --
    // Create new queue from same WAL directory (simulates node restart)
    const queue2 = new TransactionQueue({ walDir, fsyncOnWrite: false });
    const recovered = queue2.recover();

    // The 2 transactions from batch2 should be recovered
    // (they were not checkpointed)
    expect(recovered).toBe(2);
    expect(queue2.size).toBe(2);
  }, 30000);

  // -------------------------------------------------------------------------
  // 5. SMT checkpoint persistence and restore
  // -------------------------------------------------------------------------

  it("should persist and restore SMT state via serialization", async () => {
    const smt = await SparseMerkleTree.create(10);

    // Insert some values
    await smt.insert(1n, 42n);
    await smt.insert(2n, 99n);
    await smt.insert(3n, 7n);

    const rootBefore = smt.root;

    // Serialize
    const serialized = smt.serialize();

    // Write to disk (as the orchestrator does)
    const checkpointPath = path.join(walDir, "smt-checkpoint.json");
    fs.writeFileSync(checkpointPath, JSON.stringify(serialized), "utf-8");

    // Read back and deserialize
    const raw = fs.readFileSync(checkpointPath, "utf-8");
    const loaded = JSON.parse(raw);
    const restored = await SparseMerkleTree.deserialize(loaded);

    // Root must match exactly
    expect(restored.root).toBe(rootBefore);

    // Proofs from restored tree must be valid (leafHash != 0 means membership)
    const proof = restored.getProof(1n);
    expect(proof.leafHash).not.toBe(0n);
  }, 30000);

  // -------------------------------------------------------------------------
  // 6. Cross-module type compatibility
  // -------------------------------------------------------------------------

  it("should pass Transaction objects seamlessly between queue, aggregator, and builder", async () => {
    const smt = await SparseMerkleTree.create(10);
    const queue = new TransactionQueue({ walDir, fsyncOnWrite: false });
    const aggregator = new BatchAggregator(queue, {
      maxBatchSize: 1,
      maxWaitTimeMs: 60000,
    });

    // Create a transaction with specific values
    const tx: Transaction = {
      txHash: crypto.createHash("sha256").update("test-tx").digest("hex"),
      key: "abcd",
      oldValue: "0",
      newValue: "ff",
      enterpriseId: "ent-test",
      timestamp: Date.now(),
    };

    queue.enqueue(tx);
    const batch = aggregator.formBatch();
    expect(batch).not.toBeNull();

    // The same Transaction object flows through to the builder
    expect(batch!.transactions[0]).toEqual(tx);

    const witness = await buildBatchCircuitInput(batch!, smt);

    // Builder uses tx.key and tx.newValue directly
    expect(witness.transitions[0]!.key).toBe("abcd");
    expect(witness.transitions[0]!.newValue).toBe("ff");
    expect(witness.transitions[0]!.oldValue).toBe("0");

    aggregator.onBatchProcessed(batch!.batchId);
  }, 30000);

  // -------------------------------------------------------------------------
  // 7. Witness format validation for ZK prover consumption
  // -------------------------------------------------------------------------

  it("should produce witness data in the format expected by ZKProver", async () => {
    const smtDepth = 10;
    const batchSize = 4;
    const smt = await SparseMerkleTree.create(smtDepth);
    const queue = new TransactionQueue({ walDir, fsyncOnWrite: false });
    const aggregator = new BatchAggregator(queue, {
      maxBatchSize: batchSize,
      maxWaitTimeMs: 60000,
    });

    for (let i = 0; i < batchSize; i++) {
      queue.enqueue(createTransaction(i));
    }

    const batch = aggregator.formBatch()!;
    const witness = await buildBatchCircuitInput(batch, smt);

    // Validate the format that ZKProver.formatCircuitInput expects:
    // - prevStateRoot, newStateRoot: hex strings
    // - transitions[].key: hex string (parseable as BigInt("0x" + key))
    // - transitions[].siblings: array of hex strings, length = smtDepth
    // - transitions[].pathBits: array of 0|1, length = smtDepth

    expect(typeof witness.prevStateRoot).toBe("string");
    expect(typeof witness.newStateRoot).toBe("string");

    for (const t of witness.transitions) {
      // Key must be valid hex
      expect(() => BigInt("0x" + t.key)).not.toThrow();

      // Values must be valid hex
      expect(() => BigInt("0x" + t.newValue)).not.toThrow();

      // Siblings must be smtDepth elements of valid hex
      expect(t.siblings).toHaveLength(smtDepth);
      for (const s of t.siblings) {
        expect(typeof s).toBe("string");
        expect(() => BigInt("0x" + s)).not.toThrow();
      }

      // Path bits must be smtDepth elements of 0 or 1
      expect(t.pathBits).toHaveLength(smtDepth);
      for (const b of t.pathBits) {
        expect(b === 0 || b === 1).toBe(true);
      }

      // Root continuity
      expect(typeof t.rootBefore).toBe("string");
      expect(typeof t.rootAfter).toBe("string");
    }

    aggregator.onBatchProcessed(batch.batchId);
  }, 30000);
});
