/**
 * Type definitions for the Batch Aggregation layer.
 *
 * [Spec: validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla]
 *
 * @module batch/types
 */

import type { Transaction } from "../queue/types";

// ---------------------------------------------------------------------------
// Batch
// ---------------------------------------------------------------------------

/**
 * A formed batch of transactions ready for ZK proving.
 *
 * [Spec: Element of batches sequence variable]
 */
export interface Batch {
  /** Deterministic batch identifier (SHA-256 of ordered tx hashes). */
  readonly batchId: string;
  /** Sequential batch counter (monotonically increasing). */
  readonly batchNum: number;
  /** Transactions in FIFO order. */
  readonly transactions: readonly Transaction[];
  /** Number of transactions in the batch. */
  readonly txCount: number;
  /** Timestamp when the batch was formed (Unix ms). */
  readonly formedAt: number;
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/**
 * Batch aggregator configuration.
 *
 * [Spec: BatchSizeThreshold constant maps to maxBatchSize]
 */
export interface BatchAggregatorConfig {
  /**
   * Maximum transactions per batch. Also serves as the size-based trigger threshold.
   * Must match the ZK circuit capacity.
   *
   * [Spec: BatchSizeThreshold -- ASSUME BatchSizeThreshold > 0]
   */
  readonly maxBatchSize: number;
  /**
   * Maximum wait time (ms) before forming a partial batch.
   * When elapsed with a non-empty queue, triggers time-based formation.
   *
   * [Spec: Modeled by timerExpired nondeterministic flag]
   */
  readonly maxWaitTimeMs: number;
}

// ---------------------------------------------------------------------------
// Circuit Witness
// ---------------------------------------------------------------------------

/**
 * Complete witness data for proving a batch in the ZK circuit.
 * Produced by the BatchBuilder after applying transitions to the SMT.
 */
export interface BatchBuildResult {
  /** State root before any transitions in this batch. */
  readonly prevStateRoot: string;
  /** State root after all transitions in this batch. */
  readonly newStateRoot: string;
  /** Batch identifier. */
  readonly batchId: string;
  /** Batch sequence number. */
  readonly batchNum: number;
  /** Per-transition witness data. */
  readonly transitions: readonly StateTransitionWitness[];
  /** Merkle siblings at key=0 after all transitions. Used for circuit padding. */
  readonly paddingSiblings?: readonly string[];
  /** Path bits at key=0 after all transitions. Used for circuit padding. */
  readonly paddingPathBits?: readonly number[];
}

/**
 * Witness data for a single state transition within a batch.
 * Contains the Merkle proof needed for the ZK circuit to verify the transition.
 */
export interface StateTransitionWitness {
  /** SMT key (hex-encoded). */
  readonly key: string;
  /** Previous value at key (hex-encoded). */
  readonly oldValue: string;
  /** New value at key (hex-encoded). */
  readonly newValue: string;
  /** Merkle proof siblings before transition (hex-encoded, leaf to root). */
  readonly siblings: readonly string[];
  /** Path direction bits (0=left, 1=right). */
  readonly pathBits: readonly number[];
  /** State root before this transition. */
  readonly rootBefore: string;
  /** State root after this transition. */
  readonly rootAfter: string;
}

// ---------------------------------------------------------------------------
// Error Types
// ---------------------------------------------------------------------------

/**
 * Error codes for batch operations.
 */
export enum BatchErrorCode {
  /** Attempted to process a batch out of FIFO order. */
  OUT_OF_ORDER_PROCESSING = "BATCH_OUT_OF_ORDER_PROCESSING",
  /** No pending batches to process. */
  NO_PENDING_BATCH = "BATCH_NO_PENDING_BATCH",
  /** Batch configuration is invalid. */
  INVALID_CONFIG = "BATCH_INVALID_CONFIG",
  /** Batch building failed (SMT operation error). */
  BUILD_FAILED = "BATCH_BUILD_FAILED",
}

/**
 * Structured error for batch operations.
 */
export class BatchError extends Error {
  readonly code: BatchErrorCode;

  constructor(code: BatchErrorCode, message: string) {
    super(`[${code}] ${message}`);
    this.code = code;
    this.name = "BatchError";
  }
}
