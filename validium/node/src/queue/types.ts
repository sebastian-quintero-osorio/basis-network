/**
 * Type definitions for the Transaction Queue and Write-Ahead Log.
 *
 * [Spec: validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla]
 *
 * @module queue/types
 */

// ---------------------------------------------------------------------------
// Transaction
// ---------------------------------------------------------------------------

/**
 * Enterprise transaction representing a state transition in the Sparse Merkle Tree.
 *
 * [Spec: Element of AllTxs set]
 */
export interface Transaction {
  /** Unique transaction identifier (SHA-256 hash). */
  readonly txHash: string;
  /** SMT key (hex-encoded field element). */
  readonly key: string;
  /** Previous value at key (hex-encoded field element). */
  readonly oldValue: string;
  /** New value at key (hex-encoded field element). */
  readonly newValue: string;
  /** Enterprise that submitted this transaction. */
  readonly enterpriseId: string;
  /** Submission timestamp (Unix ms). */
  readonly timestamp: number;
}

// ---------------------------------------------------------------------------
// WAL Types
// ---------------------------------------------------------------------------

/**
 * WAL entry: a transaction with sequencing metadata and integrity checksum.
 * Persisted as a JSON line in the WAL file.
 *
 * [Spec: Element of wal sequence variable]
 */
export interface WALEntry {
  /** Monotonically increasing sequence number. */
  readonly seq: number;
  /** Entry timestamp (Unix ms). */
  readonly timestamp: number;
  /** The transaction payload. */
  readonly tx: Transaction;
  /** SHA-256 integrity checksum (truncated to 16 hex chars). */
  readonly checksum: string;
}

/**
 * WAL checkpoint marker indicating all entries up to seq have been durably
 * consumed by downstream (proof generated + L1 confirmed).
 *
 * [Spec: checkpointSeq variable -- advances at ProcessBatch, NOT FormBatch (v1-fix)]
 */
export interface WALCheckpoint {
  /** Discriminator for checkpoint vs entry. */
  readonly type: "checkpoint";
  /** Highest committed WAL sequence number. */
  readonly seq: number;
  /** Batch ID that triggered this checkpoint. */
  readonly batchId: string;
  /** Checkpoint timestamp (Unix ms). */
  readonly timestamp: number;
  /** HMAC-SHA256 authentication tag (present when WAL_HMAC_KEY is configured). */
  readonly hmac?: string;
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/**
 * Write-Ahead Log configuration.
 */
export interface WALConfig {
  /** Directory for the WAL file. */
  readonly walDir: string;
  /** If true, fsync after every write for maximum durability. */
  readonly fsyncOnWrite: boolean;
  /** HMAC key for checkpoint authentication. When set, rejects tampered checkpoints. */
  readonly hmacKey?: string;
  /** AES-256-GCM encryption key (hex, 64 chars = 32 bytes). Encrypts WAL entries at rest. */
  readonly encryptionKey?: string;
}

// ---------------------------------------------------------------------------
// Dequeue Result
// ---------------------------------------------------------------------------

/**
 * Result of dequeuing transactions from the queue.
 * Includes the checkpoint sequence for deferred checkpointing (v1-fix).
 */
export interface DequeueResult {
  /** Dequeued transactions in FIFO order. */
  readonly transactions: readonly Transaction[];
  /** Highest WAL sequence number among dequeued transactions. */
  readonly checkpointSeq: number;
}

// ---------------------------------------------------------------------------
// Error Types
// ---------------------------------------------------------------------------

/**
 * Error codes for queue and WAL operations.
 */
export enum QueueErrorCode {
  /** WAL file write failed. */
  WAL_WRITE_FAILED = "QUEUE_WAL_WRITE_FAILED",
  /** WAL recovery encountered unrecoverable corruption. */
  WAL_RECOVERY_FAILED = "QUEUE_WAL_RECOVERY_FAILED",
  /** WAL checkpoint write failed. */
  WAL_CHECKPOINT_FAILED = "QUEUE_WAL_CHECKPOINT_FAILED",
  /** Configuration validation failed. */
  INVALID_CONFIG = "QUEUE_INVALID_CONFIG",
}

/**
 * Structured error for queue and WAL operations.
 */
export class QueueError extends Error {
  readonly code: QueueErrorCode;

  constructor(code: QueueErrorCode, message: string) {
    super(`[${code}] ${message}`);
    this.code = code;
    this.name = "QueueError";
  }
}
