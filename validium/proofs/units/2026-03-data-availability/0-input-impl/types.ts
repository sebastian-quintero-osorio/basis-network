/**
 * Type definitions for the Data Availability Committee (DAC) protocol.
 *
 * [Spec: validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/specs/DataAvailability/DataAvailability.tla]
 *
 * All Shamir secret sharing operates over the BN128 scalar field:
 *   p = 21888242871839275222246405745257275088548364400416034343698204186575808495617
 *
 * @module da/types
 */

// ---------------------------------------------------------------------------
// Field Constants
// ---------------------------------------------------------------------------

/**
 * BN128 scalar field prime.
 * Shared with the Sparse Merkle Tree and ZK circuit layers.
 */
export const BN128_PRIME =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

/** Field element size in bytes (254-bit prime -> 32 bytes). */
export const FIELD_ELEMENT_BYTES = 32;

/** Byte packing chunk size (31 bytes < 254 bits, guaranteed to fit in field). */
export const CHUNK_SIZE = 31;

// ---------------------------------------------------------------------------
// Shamir Secret Sharing Types
// ---------------------------------------------------------------------------

/**
 * A single share produced by Shamir's (k,n) Secret Sharing Scheme.
 *
 * [Spec: shareHolders variable -- each node in shareHolders[b] implicitly holds a Share]
 */
export interface Share {
  /** Evaluation point x (1-indexed, corresponds to DAC node ID). */
  readonly index: number;
  /** Evaluation result y = f(index) mod p. */
  readonly value: bigint;
}

/**
 * A complete set of shares for one field element, distributed to n parties.
 */
export interface ShareSet {
  /** Reconstruction threshold k. */
  readonly threshold: number;
  /** Total number of shares n. */
  readonly total: number;
  /** One share per party. */
  readonly shares: readonly Share[];
}

// ---------------------------------------------------------------------------
// DAC Node Types
// ---------------------------------------------------------------------------

/**
 * Internal state held by a DAC node for a single batch.
 *
 * [Spec: nodeOnline, shareHolders, attested variables per-node per-batch]
 */
export interface DACNodeState {
  /** Node identifier (1-indexed). */
  readonly nodeId: number;
  /** Share values for each field element of the batch data. */
  readonly shares: readonly bigint[];
  /** SHA-256 commitment of the original batch data. */
  readonly dataCommitment: string;
  /** Timestamp when shares were received (Unix ms). */
  readonly receivedAt: number;
  /** Whether this node has attested availability for this batch. */
  attested: boolean;
}

// ---------------------------------------------------------------------------
// Attestation and Certificate Types
// ---------------------------------------------------------------------------

/**
 * An attestation signed by a single DAC node, certifying it holds shares.
 *
 * [Spec: NodeAttest(n, b) action -- node n attests for batch b]
 */
export interface Attestation {
  /** Attesting node identifier. */
  readonly nodeId: number;
  /** SHA-256 commitment of the original batch data. */
  readonly dataCommitment: string;
  /** Batch identifier. */
  readonly batchId: string;
  /** Attestation timestamp (Unix ms). */
  readonly timestamp: number;
  /** Cryptographic signature (simulated: SHA-256 HMAC in development). */
  readonly signature: string;
}

/**
 * Certificate state as defined in the TLA+ specification.
 *
 * [Spec: certState \in [Batches -> {"none", "valid", "fallback"}]]
 */
export enum CertificateState {
  /** No certificate produced yet. */
  NONE = "none",
  /** Valid certificate: threshold attestations collected. */
  VALID = "valid",
  /** Fallback: data posted on-chain (validium -> rollup mode). */
  FALLBACK = "fallback",
}

/**
 * Recovery outcome as defined in the TLA+ specification.
 *
 * [Spec: recoverState \in [Batches -> {"none", "success", "corrupted", "failed"}]]
 */
export enum RecoveryState {
  /** No recovery attempted. */
  NONE = "none",
  /** Successful: k honest shares reconstructed original data. */
  SUCCESS = "success",
  /** Corrupted: malicious node provided altered shares, commitment mismatch. */
  CORRUPTED = "corrupted",
  /** Failed: fewer than k shares available, underdetermined interpolation. */
  FAILED = "failed",
}

/**
 * Aggregated attestation certificate for on-chain submission.
 *
 * [Spec: ProduceCertificate(b) action -- certState[b] = "valid" when threshold met]
 */
export interface DACCertificate {
  /** Batch identifier. */
  readonly batchId: string;
  /** SHA-256 commitment of the original batch data. */
  readonly dataCommitment: string;
  /** Valid attestations included in the certificate. */
  readonly attestations: readonly Attestation[];
  /** Number of valid attestations (must be >= threshold for valid cert). */
  readonly signatureCount: number;
  /** Certificate state. */
  readonly state: CertificateState;
  /** Certificate creation timestamp (Unix ms). */
  readonly createdAt: number;
}

/**
 * DAC protocol configuration.
 *
 * [Spec: Nodes, Threshold, Malicious constants]
 */
export interface DACConfig {
  /** Number of committee members (n). */
  readonly committeeSize: number;
  /** Reconstruction and attestation threshold (k). */
  readonly threshold: number;
  /** Whether to fall back to on-chain DA if threshold is structurally unreachable. */
  readonly enableFallback: boolean;
}

// ---------------------------------------------------------------------------
// Result Types
// ---------------------------------------------------------------------------

/**
 * Result of Phase 1: share distribution to DAC nodes.
 *
 * [Spec: DistributeShares(b) action]
 */
export interface DistributionResult {
  /** Batch identifier (deterministic, SHA-256 of random nonce + data). */
  readonly batchId: string;
  /** SHA-256 commitment of original data. */
  readonly commitment: string;
  /** Number of field elements produced from data. */
  readonly fieldElementCount: number;
  /** Per-node delivery status (true = node received shares). */
  readonly shareSent: readonly boolean[];
  /** Duration in milliseconds. */
  readonly durationMs: number;
}

/**
 * Result of Phase 2: attestation collection and certificate production.
 *
 * [Spec: NodeAttest(n, b), ProduceCertificate(b), TriggerFallback(b) actions]
 */
export interface AttestationResult {
  /** Produced certificate (may be valid or fallback). */
  readonly certificate: DACCertificate;
  /** Per-node attestation results (null if node failed to attest). */
  readonly attestations: readonly (Attestation | null)[];
  /** Duration in milliseconds. */
  readonly durationMs: number;
  /** Whether fallback to on-chain DA was triggered. */
  readonly fallbackTriggered: boolean;
}

/**
 * Result of Phase 3: data recovery via Lagrange interpolation.
 *
 * [Spec: RecoverData(b, S) action]
 */
export interface RecoveryResult {
  /** Whether reconstruction was attempted (enough nodes available). */
  readonly recovered: boolean;
  /** Recovered data buffer (null if recovery failed). */
  readonly data: Buffer | null;
  /** Node IDs used for recovery. */
  readonly nodesUsed: readonly number[];
  /** Duration in milliseconds. */
  readonly durationMs: number;
  /** Whether recovered data matches original commitment. */
  readonly dataMatches: boolean;
  /** Recovery state classification. */
  readonly state: RecoveryState;
}

/**
 * Result of on-chain certificate verification simulation.
 */
export interface VerificationResult {
  /** Whether the certificate passed all checks. */
  readonly valid: boolean;
  /** Number of ecrecover operations performed. */
  readonly ecrecoverCount: number;
  /** Duration in milliseconds. */
  readonly durationMs: number;
}

// ---------------------------------------------------------------------------
// Error Types
// ---------------------------------------------------------------------------

/**
 * Error codes for DAC operations.
 */
export enum DACErrorCode {
  /** Shamir threshold parameters invalid (k < 2 or k > n). */
  INVALID_THRESHOLD = "DAC_INVALID_THRESHOLD",
  /** Secret value outside BN128 field range [0, p). */
  INVALID_FIELD_ELEMENT = "DAC_INVALID_FIELD_ELEMENT",
  /** Insufficient shares for Lagrange reconstruction. */
  INSUFFICIENT_SHARES = "DAC_INSUFFICIENT_SHARES",
  /** Field element overflow during byte packing. */
  FIELD_OVERFLOW = "DAC_FIELD_OVERFLOW",
  /** Node is offline and cannot perform the requested operation. */
  NODE_OFFLINE = "DAC_NODE_OFFLINE",
  /** Requested batch not found in node storage. */
  BATCH_NOT_FOUND = "DAC_BATCH_NOT_FOUND",
  /** Node has already attested for this batch. */
  ALREADY_ATTESTED = "DAC_ALREADY_ATTESTED",
  /** Certificate threshold not met. */
  THRESHOLD_NOT_MET = "DAC_THRESHOLD_NOT_MET",
  /** Data recovery failed (insufficient available nodes). */
  RECOVERY_FAILED = "DAC_RECOVERY_FAILED",
  /** Recovered data does not match commitment (corruption detected). */
  COMMITMENT_MISMATCH = "DAC_COMMITMENT_MISMATCH",
  /** DAC configuration is invalid. */
  INVALID_CONFIG = "DAC_INVALID_CONFIG",
}

/**
 * Structured error type for all DAC operations.
 */
export class DACError extends Error {
  readonly code: DACErrorCode;

  constructor(code: DACErrorCode, message: string) {
    super(`[${code}] ${message}`);
    this.code = code;
    this.name = "DACError";
  }
}
