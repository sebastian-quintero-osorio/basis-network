/**
 * Core type definitions for the Enterprise Node Orchestrator.
 *
 * [Spec: validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/specs/EnterpriseNode/EnterpriseNode.tla]
 *
 * @module types
 */

// ---------------------------------------------------------------------------
// Node State
// ---------------------------------------------------------------------------

/**
 * Enterprise node state machine states.
 * Direct mapping from TLA+ States enumeration.
 *
 * [Spec: States == {"Idle", "Receiving", "Batching", "Proving", "Submitting", "Error"}]
 */
export enum NodeState {
  Idle = "Idle",
  Receiving = "Receiving",
  Batching = "Batching",
  Proving = "Proving",
  Submitting = "Submitting",
  Error = "Error",
}

/**
 * States in which the node can accept new transactions (pipelined ingestion).
 *
 * [Spec: ReceiveTx precondition: nodeState \in {"Idle", "Receiving", "Proving", "Submitting"}]
 */
export const RECEIVING_STATES: ReadonlySet<NodeState> = new Set([
  NodeState.Idle,
  NodeState.Receiving,
  NodeState.Proving,
  NodeState.Submitting,
]);

/**
 * Data categories for privacy boundary tracking.
 *
 * [Spec: DataKinds == AllowedExternalData \cup {"raw_data"}]
 * [Spec: AllowedExternalData == {"proof_signals", "dac_shares"}]
 */
export enum DataKind {
  ProofSignals = "proof_signals",
  DACShares = "dac_shares",
  RawData = "raw_data",
}

/**
 * Allowed external data categories (privacy boundary).
 *
 * [Spec: AllowedExternalData == {"proof_signals", "dac_shares"}]
 */
export const ALLOWED_EXTERNAL_DATA: ReadonlySet<DataKind> = new Set([
  DataKind.ProofSignals,
  DataKind.DACShares,
]);

// ---------------------------------------------------------------------------
// Proof Result
// ---------------------------------------------------------------------------

/**
 * Result of ZK proof generation (Groth16).
 *
 * [Spec: GenerateProof action -- proof contains (a, b, c) + publicSignals]
 */
export interface ProofResult {
  /** Groth16 proof component a (2 field elements). */
  readonly a: readonly string[];
  /** Groth16 proof component b (2x2 field elements). */
  readonly b: readonly (readonly string[])[];
  /** Groth16 proof component c (2 field elements). */
  readonly c: readonly string[];
  /** Public signals from the circuit (prevRoot, newRoot, batchNum, enterpriseId). */
  readonly publicSignals: readonly string[];
  /** Proof generation duration in milliseconds. */
  readonly durationMs: number;
}

// ---------------------------------------------------------------------------
// Submission Result
// ---------------------------------------------------------------------------

/**
 * Result of L1 batch submission.
 *
 * [Spec: ConfirmBatch action -- l1State' = smtState, walCheckpoint advances]
 */
export interface SubmissionResult {
  /** L1 transaction hash. */
  readonly txHash: string;
  /** Block number where the batch was confirmed. */
  readonly blockNumber: number;
  /** New state root confirmed on L1. */
  readonly newStateRoot: string;
}

// ---------------------------------------------------------------------------
// Batch Record
// ---------------------------------------------------------------------------

/**
 * Historical record of a processed batch for observability.
 */
export interface BatchRecord {
  /** Batch identifier (SHA-256 of ordered tx hashes). */
  readonly batchId: string;
  /** Sequential batch number. */
  readonly batchNum: number;
  /** Number of transactions in the batch. */
  readonly txCount: number;
  /** State root before batch application. */
  prevStateRoot: string;
  /** State root after batch application. */
  newStateRoot: string;
  /** Current processing status. */
  status: "forming" | "proving" | "submitting" | "confirmed" | "failed";
  /** L1 transaction hash (set after confirmation). */
  l1TxHash?: string;
  /** Timestamp when the batch was formed (Unix ms). */
  readonly formedAt: number;
  /** Timestamp when the batch was confirmed (Unix ms). */
  confirmedAt?: number;
}

// ---------------------------------------------------------------------------
// Node Status
// ---------------------------------------------------------------------------

/**
 * Current node status for health check and monitoring.
 */
export interface NodeStatus {
  /** Current state machine state. */
  readonly state: NodeState;
  /** Number of transactions in the queue. */
  readonly queueDepth: number;
  /** Number of batches confirmed on L1. */
  readonly batchesProcessed: number;
  /** Last confirmed state root on L1 (hex). */
  readonly lastConfirmedRoot: string;
  /** Node uptime in milliseconds. */
  readonly uptimeMs: number;
  /** Number of crash/recovery cycles. */
  readonly crashCount: number;
  /** Enterprise ID this node serves. */
  readonly enterpriseId: string;
  /** Node version. */
  readonly version: string;
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/**
 * Enterprise node configuration.
 */
export interface NodeConfig {
  /** Enterprise identifier. */
  readonly enterpriseId: string;

  // -- Network --
  /** L1 RPC URL (Avalanche Subnet-EVM). */
  readonly l1RpcUrl: string;
  /** Private key for L1 transactions (hex, with 0x prefix). */
  readonly l1PrivateKey: string;
  /** StateCommitment contract address. */
  readonly stateCommitmentAddress: string;

  // -- ZK --
  /** Path to compiled circuit WASM file. */
  readonly circuitWasmPath: string;
  /** Path to Groth16 proving key (zkey). */
  readonly provingKeyPath: string;

  // -- Batch --
  /** Maximum transactions per batch (must match circuit capacity). */
  readonly maxBatchSize: number;
  /** Maximum wait time (ms) before forming a partial batch. */
  readonly maxWaitTimeMs: number;

  // -- Queue --
  /** Directory for WAL file storage. */
  readonly walDir: string;
  /** Fsync WAL writes for maximum durability. */
  readonly walFsync: boolean;

  // -- SMT --
  /** Sparse Merkle Tree depth (2^depth leaf positions). */
  readonly smtDepth: number;

  // -- DAC --
  /** Number of DAC committee members. */
  readonly dacCommitteeSize: number;
  /** Reconstruction and attestation threshold. */
  readonly dacThreshold: number;
  /** Enable fallback to on-chain DA. */
  readonly dacEnableFallback: boolean;

  // -- API --
  /** API server host. */
  readonly apiHost: string;
  /** API server port. */
  readonly apiPort: number;

  // -- Retry --
  /** Maximum retry attempts for L1 submission. */
  readonly maxRetries: number;
  /** Base delay (ms) for exponential backoff. */
  readonly retryBaseDelayMs: number;

  // -- Batch loop --
  /** Interval (ms) for the batch monitoring loop. */
  readonly batchLoopIntervalMs: number;

  // -- L1 submission --
  /** Timeout (ms) for L1 tx confirmation. Default: 120000 (2 min). */
  readonly txConfirmTimeoutMs: number;

  // -- Security --
  /** HMAC key for WAL checkpoint authentication. Mitigates checkpoint injection (ADV-WAL-04). */
  readonly walHmacKey?: string;
  /** AES-256-GCM key for WAL encryption at rest (hex, 64 chars = 32 bytes). */
  readonly walEncryptionKey?: string;
}

// ---------------------------------------------------------------------------
// Error Types
// ---------------------------------------------------------------------------

/**
 * Error codes for orchestrator operations.
 */
export enum NodeErrorCode {
  /** Node is in a state that cannot accept this operation. */
  INVALID_STATE = "NODE_INVALID_STATE",
  /** ZK proof generation failed. */
  PROOF_FAILED = "NODE_PROOF_FAILED",
  /** L1 submission failed after all retries. */
  SUBMISSION_FAILED = "NODE_SUBMISSION_FAILED",
  /** L1 rejected the batch (state root mismatch, invalid proof). */
  L1_REJECTED = "NODE_L1_REJECTED",
  /** Configuration validation failed. */
  INVALID_CONFIG = "NODE_INVALID_CONFIG",
  /** Recovery from error state failed. */
  RECOVERY_FAILED = "NODE_RECOVERY_FAILED",
  /** Graceful shutdown timeout exceeded. */
  SHUTDOWN_TIMEOUT = "NODE_SHUTDOWN_TIMEOUT",
}

/**
 * Structured error for orchestrator operations.
 */
export class NodeError extends Error {
  readonly code: NodeErrorCode;

  constructor(code: NodeErrorCode, message: string) {
    super(`[${code}] ${message}`);
    this.code = code;
    this.name = "NodeError";
  }
}
