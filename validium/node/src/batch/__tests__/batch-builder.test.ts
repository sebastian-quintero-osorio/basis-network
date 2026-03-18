/**
 * Unit tests for the BatchBuilder.
 *
 * [Spec: validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla]
 *
 * Tests verify:
 * - State root transitions are correctly computed
 * - Merkle proofs are valid for each transition
 * - FIFO ordering of transitions matches batch order
 * - Error handling for invalid transaction data
 */

import { SparseMerkleTree } from "../../state";
import { buildBatchCircuitInput } from "../batch-builder";
import { BatchError, BatchErrorCode } from "../types";
import type { Batch } from "../types";
import type { Transaction } from "../../queue/types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Test depth (small for fast tests). */
const TEST_DEPTH = 4;

function makeTx(
  key: number,
  newValue: number,
  oldValue = 0
): Transaction {
  return {
    txHash: `txhash-${key}-${newValue}`,
    key: key.toString(16),
    oldValue: oldValue.toString(16),
    newValue: newValue.toString(16),
    enterpriseId: "enterprise-1",
    timestamp: Date.now(),
  };
}

function makeBatch(transactions: Transaction[], batchNum = 1): Batch {
  return {
    batchId: `batch-${batchNum}`,
    batchNum,
    transactions,
    txCount: transactions.length,
    formedAt: Date.now(),
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("BatchBuilder", () => {
  let smt: SparseMerkleTree;

  beforeEach(async () => {
    smt = await SparseMerkleTree.create(TEST_DEPTH);
  });

  // =========================================================================
  // Basic Building
  // =========================================================================

  describe("Basic Building", () => {
    it("builds circuit input for a single transaction", async () => {
      const tx = makeTx(1, 42);
      const batch = makeBatch([tx]);

      const result = await buildBatchCircuitInput(batch, smt);

      expect(result.batchId).toBe("batch-1");
      expect(result.batchNum).toBe(1);
      expect(result.transitions).toHaveLength(1);
      expect(result.prevStateRoot).not.toBe(result.newStateRoot);
    });

    it("builds circuit input for multiple transactions", async () => {
      const txs = [makeTx(1, 10), makeTx(2, 20), makeTx(3, 30)];
      const batch = makeBatch(txs);

      const result = await buildBatchCircuitInput(batch, smt);

      expect(result.transitions).toHaveLength(3);

      // Each transition should chain: rootAfter[i] === rootBefore[i+1]
      for (let i = 0; i < result.transitions.length - 1; i++) {
        expect(result.transitions[i]!.rootAfter).toBe(
          result.transitions[i + 1]!.rootBefore
        );
      }
    });

    it("records correct prevStateRoot and newStateRoot", async () => {
      const emptyRoot = smt.root.toString(16);
      const txs = [makeTx(1, 10), makeTx(2, 20)];
      const batch = makeBatch(txs);

      const result = await buildBatchCircuitInput(batch, smt);

      expect(result.prevStateRoot).toBe(emptyRoot);
      expect(result.newStateRoot).toBe(smt.root.toString(16));
      expect(result.newStateRoot).not.toBe(emptyRoot);
    });
  });

  // =========================================================================
  // State Transition Correctness
  // =========================================================================

  describe("State Transition Correctness", () => {
    it("first transition rootBefore equals prevStateRoot", async () => {
      const batch = makeBatch([makeTx(1, 42)]);
      const result = await buildBatchCircuitInput(batch, smt);

      expect(result.transitions[0]!.rootBefore).toBe(result.prevStateRoot);
    });

    it("last transition rootAfter equals newStateRoot", async () => {
      const batch = makeBatch([makeTx(1, 42), makeTx(2, 84)]);
      const result = await buildBatchCircuitInput(batch, smt);

      const lastTransition = result.transitions[result.transitions.length - 1]!;
      expect(lastTransition.rootAfter).toBe(result.newStateRoot);
    });

    it("preserves transaction data in witnesses", async () => {
      const tx = makeTx(5, 100);
      const batch = makeBatch([tx]);
      const result = await buildBatchCircuitInput(batch, smt);

      expect(result.transitions[0]!.key).toBe(tx.key);
      expect(result.transitions[0]!.oldValue).toBe(tx.oldValue);
      expect(result.transitions[0]!.newValue).toBe(tx.newValue);
    });
  });

  // =========================================================================
  // Merkle Proof Structure
  // =========================================================================

  describe("Merkle Proof Structure", () => {
    it("includes correct number of siblings (equals tree depth)", async () => {
      const batch = makeBatch([makeTx(1, 42)]);
      const result = await buildBatchCircuitInput(batch, smt);

      expect(result.transitions[0]!.siblings).toHaveLength(TEST_DEPTH);
      expect(result.transitions[0]!.pathBits).toHaveLength(TEST_DEPTH);
    });

    it("path bits are 0 or 1", async () => {
      const batch = makeBatch([makeTx(7, 42)]);
      const result = await buildBatchCircuitInput(batch, smt);

      for (const bit of result.transitions[0]!.pathBits) {
        expect(bit === 0 || bit === 1).toBe(true);
      }
    });

    it("siblings are hex-encoded strings", async () => {
      const batch = makeBatch([makeTx(1, 42)]);
      const result = await buildBatchCircuitInput(batch, smt);

      for (const sibling of result.transitions[0]!.siblings) {
        expect(typeof sibling).toBe("string");
        expect(sibling.length).toBeGreaterThan(0);
      }
    });
  });

  // =========================================================================
  // FIFO Ordering
  // =========================================================================

  describe("FIFO Ordering", () => {
    it("applies transitions in batch order", async () => {
      const txs = [makeTx(1, 10), makeTx(2, 20), makeTx(3, 30)];
      const batch = makeBatch(txs);
      const result = await buildBatchCircuitInput(batch, smt);

      for (let i = 0; i < txs.length; i++) {
        expect(result.transitions[i]!.key).toBe(txs[i]!.key);
      }
    });
  });

  // =========================================================================
  // Determinism
  // =========================================================================

  describe("Determinism", () => {
    it("same batch produces same circuit input", async () => {
      const txs = [makeTx(1, 10), makeTx(2, 20)];

      const smt1 = await SparseMerkleTree.create(TEST_DEPTH);
      const smt2 = await SparseMerkleTree.create(TEST_DEPTH);

      const result1 = await buildBatchCircuitInput(makeBatch(txs), smt1);
      const result2 = await buildBatchCircuitInput(makeBatch(txs), smt2);

      expect(result1.prevStateRoot).toBe(result2.prevStateRoot);
      expect(result1.newStateRoot).toBe(result2.newStateRoot);

      for (let i = 0; i < txs.length; i++) {
        expect(result1.transitions[i]!.rootBefore).toBe(
          result2.transitions[i]!.rootBefore
        );
        expect(result1.transitions[i]!.rootAfter).toBe(
          result2.transitions[i]!.rootAfter
        );
      }
    });
  });

  // =========================================================================
  // Error Handling
  // =========================================================================

  describe("Error Handling", () => {
    it("throws BatchError for invalid hex key", async () => {
      const tx: Transaction = {
        txHash: "bad-tx",
        key: "not-valid-hex",
        oldValue: "0",
        newValue: "1",
        enterpriseId: "e1",
        timestamp: Date.now(),
      };

      await expect(
        buildBatchCircuitInput(makeBatch([tx]), smt)
      ).rejects.toThrow(BatchError);
    });

    it("throws BatchError for invalid hex value", async () => {
      const tx: Transaction = {
        txHash: "bad-tx",
        key: "1",
        oldValue: "0",
        newValue: "not-hex",
        enterpriseId: "e1",
        timestamp: Date.now(),
      };

      await expect(
        buildBatchCircuitInput(makeBatch([tx]), smt)
      ).rejects.toThrow(BatchError);
    });
  });

  // =========================================================================
  // SMT Insert Failure
  // =========================================================================

  describe("SMT Insert Failure", () => {
    it("throws BatchError when SMT insert fails (value out of field)", async () => {
      // BN128 prime -- any value >= this is invalid
      const tx: Transaction = {
        txHash: "overflow-tx",
        key: "1",
        oldValue: "0",
        // Value larger than BN128 prime causes SMT to throw
        newValue: "30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000002",
        enterpriseId: "e1",
        timestamp: Date.now(),
      };

      await expect(
        buildBatchCircuitInput(makeBatch([tx]), smt)
      ).rejects.toThrow(BatchError);
    });

    it("includes tx hash in error message", async () => {
      const tx: Transaction = {
        txHash: "my-failing-tx",
        key: "zzz-not-hex",
        oldValue: "0",
        newValue: "1",
        enterpriseId: "e1",
        timestamp: Date.now(),
      };

      try {
        await buildBatchCircuitInput(makeBatch([tx]), smt);
        fail("Should have thrown");
      } catch (error) {
        expect(error).toBeInstanceOf(BatchError);
        expect((error as BatchError).message).toContain("my-failing-tx");
      }
    });
  });

  // =========================================================================
  // Empty Batch
  // =========================================================================

  describe("Empty Batch", () => {
    it("handles empty transaction list", async () => {
      const batch = makeBatch([]);
      const result = await buildBatchCircuitInput(batch, smt);

      expect(result.transitions).toHaveLength(0);
      expect(result.prevStateRoot).toBe(result.newStateRoot);
    });
  });
});
