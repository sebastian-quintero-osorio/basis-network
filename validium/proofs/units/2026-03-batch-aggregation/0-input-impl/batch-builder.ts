/**
 * Batch builder: constructs ZK circuit witness data from a batch of transactions.
 *
 * [Spec: validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla]
 *
 * Takes a formed Batch and applies each transaction's state transition to the
 * Sparse Merkle Tree, collecting Merkle proofs for each step. The resulting
 * BatchBuildResult contains all witness data needed by the ZK circuit to verify
 * the batch transition from prevStateRoot to newStateRoot.
 *
 * @module batch/batch-builder
 */

import { SparseMerkleTree } from "../state";
import type { Batch, BatchBuildResult, StateTransitionWitness } from "./types";
import { BatchError, BatchErrorCode } from "./types";

/**
 * Build ZK circuit witness data by applying a batch of transactions to the SMT.
 *
 * For each transaction in the batch (FIFO order):
 * 1. Record the current root (rootBefore).
 * 2. Get Merkle proof at the key (siblings + pathBits).
 * 3. Apply the state transition: insert(key, newValue).
 * 4. Record the new root (rootAfter).
 *
 * The circuit can then verify each transition independently and chain them
 * from prevStateRoot to newStateRoot.
 *
 * [Spec: FIFOOrdering invariant -- transitions applied in WAL sequence order]
 */
export async function buildBatchCircuitInput(
  batch: Batch,
  smt: SparseMerkleTree
): Promise<BatchBuildResult> {
  const prevStateRoot = smt.root.toString(16);
  const transitions: StateTransitionWitness[] = [];

  for (const tx of batch.transactions) {
    let key: bigint;
    let newValue: bigint;

    try {
      key = BigInt(`0x${tx.key}`);
    } catch (error) {
      throw new BatchError(
        BatchErrorCode.BUILD_FAILED,
        `Invalid hex key in transaction ${tx.txHash}: ${String(error)}`
      );
    }

    try {
      newValue = BigInt(`0x${tx.newValue}`);
    } catch (error) {
      throw new BatchError(
        BatchErrorCode.BUILD_FAILED,
        `Invalid hex value in transaction ${tx.txHash}: ${String(error)}`
      );
    }

    const rootBefore = smt.root.toString(16);
    const proof = smt.getProof(key);

    try {
      await smt.insert(key, newValue);
    } catch (error) {
      throw new BatchError(
        BatchErrorCode.BUILD_FAILED,
        `SMT insert failed for tx ${tx.txHash}: ${String(error)}`
      );
    }

    const rootAfter = smt.root.toString(16);

    transitions.push({
      key: tx.key,
      oldValue: tx.oldValue,
      newValue: tx.newValue,
      siblings: proof.siblings.map((s) => s.toString(16)),
      pathBits: [...proof.pathBits],
      rootBefore,
      rootAfter,
    });
  }

  const newStateRoot = smt.root.toString(16);

  return {
    prevStateRoot,
    newStateRoot,
    batchId: batch.batchId,
    batchNum: batch.batchNum,
    transitions,
  };
}
