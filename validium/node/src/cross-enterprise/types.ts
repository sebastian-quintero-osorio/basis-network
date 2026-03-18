/**
 * Type definitions for Cross-Enterprise Verification.
 *
 * Translates the verified TLA+ specification into TypeScript domain types.
 * Each type traces to a specific TLA+ variable or derived set.
 *
 * [Spec: validium/specs/units/2026-03-cross-enterprise/1-formalization/v0-analysis/specs/CrossEnterprise/CrossEnterprise.tla]
 *
 * Verified properties (TLC, 461,529 states, 54,009 distinct):
 *   Isolation:           enterprise state roots determined solely by own batches
 *   Consistency:         cross-ref verified only when both batch proofs verified
 *   NoCrossRefSelfLoop:  src != dst structurally enforced
 *
 * @module cross-enterprise/types
 */

import type { FieldElement, MerkleProof } from "../state/types";

// ---------------------------------------------------------------------------
// Cross-Reference Identification
// ---------------------------------------------------------------------------

/**
 * Unique identifier for a cross-enterprise reference.
 * Represents an ordered pair of distinct enterprises with their batch IDs.
 *
 * [Spec: CrossRefIds == { r \in [src: Enterprises, dst: Enterprises,
 *          srcBatch: BatchIds, dstBatch: BatchIds] : r.src # r.dst }]
 */
export interface CrossReferenceId {
  /** Source enterprise identifier (address or ID). */
  readonly src: string;
  /** Destination enterprise identifier (address or ID). Must differ from src. */
  readonly dst: string;
  /** Batch ID from the source enterprise. */
  readonly srcBatch: number;
  /** Batch ID from the destination enterprise. */
  readonly dstBatch: number;
}

// ---------------------------------------------------------------------------
// Cross-Reference Status
// ---------------------------------------------------------------------------

/**
 * Status of a cross-enterprise reference through its lifecycle.
 *
 * [Spec: crossRefStatus \in [CrossRefIds -> {"none","pending","verified","rejected"}]]
 */
export enum CrossReferenceStatus {
  /** No cross-reference request exists. */
  None = "none",
  /** Cross-reference requested, awaiting verification on L1. */
  Pending = "pending",
  /** Both enterprise proofs verified and cross-reference confirmed on L1. */
  Verified = "verified",
  /** At least one enterprise proof failed; cross-reference rejected. */
  Rejected = "rejected",
}

// ---------------------------------------------------------------------------
// Batch Status (for Consistency gate)
// ---------------------------------------------------------------------------

/**
 * Status of an individual enterprise batch.
 *
 * [Spec: batchStatus \in [Enterprises -> [BatchIds -> {"idle","submitted","verified"}]]]
 */
export enum BatchVerificationStatus {
  Idle = "idle",
  Submitted = "submitted",
  Verified = "verified",
}

// ---------------------------------------------------------------------------
// Cross-Reference Evidence
// ---------------------------------------------------------------------------

/**
 * Input data for requesting a cross-enterprise verification.
 * Contains Merkle proofs from both enterprises and interaction data.
 *
 * [Spec: RequestCrossRef(src, dst, srcBatch, dstBatch) preconditions:
 *   - ref.src # ref.dst
 *   - batchStatus[src][srcBatch] \in {"submitted", "verified"}
 *   - batchStatus[dst][dstBatch] \in {"submitted", "verified"}]
 */
export interface CrossReferenceRequest {
  /** Cross-reference identifier. */
  readonly id: CrossReferenceId;
  /** Merkle proof for the source enterprise's record. */
  readonly proofA: MerkleProof;
  /** Merkle proof for the destination enterprise's record. */
  readonly proofB: MerkleProof;
  /** Source enterprise's current verified state root. */
  readonly stateRootA: FieldElement;
  /** Destination enterprise's current verified state root. */
  readonly stateRootB: FieldElement;
}

/**
 * Evidence produced by the cross-reference builder for L1 verification.
 * Contains public signals and the proofs needed for on-chain verification.
 *
 * [Spec: VerifyCrossRef -- public inputs: stateRootA, stateRootB, interactionCommitment]
 * [Spec: Private inputs: keyA, valueA, siblingsA, pathBitsA, keyB, valueB, siblingsB, pathBitsB]
 */
export interface CrossReferenceEvidence {
  /** Cross-reference identifier. */
  readonly id: CrossReferenceId;

  // -- Public signals (visible on-chain) --
  /** Source enterprise state root (already public from individual submission). */
  readonly stateRootA: FieldElement;
  /** Destination enterprise state root (already public from individual submission). */
  readonly stateRootB: FieldElement;
  /** Poseidon(keyA, leafHashA, keyB, leafHashB) -- reveals only existence, not content. */
  readonly interactionCommitment: FieldElement;

  // -- Private witness (NOT revealed on-chain, protected by Groth16 ZK property) --
  /** Source enterprise Merkle proof (private). */
  readonly proofA: MerkleProof;
  /** Destination enterprise Merkle proof (private). */
  readonly proofB: MerkleProof;

  /** Timestamp when evidence was built. */
  readonly builtAt: number;
}

/**
 * Result of cross-reference local verification (pre-flight check before L1).
 */
export interface CrossReferenceVerificationResult {
  /** Whether the cross-reference evidence is valid. */
  readonly valid: boolean;
  /** Status after verification attempt. */
  readonly status: CrossReferenceStatus;
  /** Reason for rejection, if any. */
  readonly reason?: string;
  /** Whether privacy is preserved (no private data in public signals). */
  readonly privacyPreserved: boolean;
  /** Public signals that would be submitted on-chain. */
  readonly publicSignals: readonly FieldElement[];
}

// ---------------------------------------------------------------------------
// Batch Verification Query
// ---------------------------------------------------------------------------

/**
 * Callback interface for querying batch verification status from L1.
 * Decouples cross-enterprise logic from specific L1 contract bindings.
 */
export interface BatchStatusProvider {
  /**
   * Check whether an enterprise's batch has been verified on L1.
   *
   * @param enterprise - Enterprise identifier (address)
   * @param batchId - Batch ID to check
   * @returns Whether the batch proof has been verified
   */
  isBatchVerified(enterprise: string, batchId: number): Promise<boolean>;

  /**
   * Get the current verified state root for an enterprise from L1.
   *
   * @param enterprise - Enterprise identifier (address)
   * @returns The current state root as a hex string
   */
  getCurrentRoot(enterprise: string): Promise<string>;
}

// ---------------------------------------------------------------------------
// Error Types
// ---------------------------------------------------------------------------

/**
 * Error codes for cross-enterprise verification operations.
 */
export enum CrossEnterpriseErrorCode {
  /** Source and destination enterprise are the same (NoCrossRefSelfLoop). */
  SELF_REFERENCE = "XENT_SELF_REFERENCE",
  /** Source batch has not been verified on L1 (Consistency violation). */
  SOURCE_BATCH_NOT_VERIFIED = "XENT_SOURCE_BATCH_NOT_VERIFIED",
  /** Destination batch has not been verified on L1 (Consistency violation). */
  DEST_BATCH_NOT_VERIFIED = "XENT_DEST_BATCH_NOT_VERIFIED",
  /** Merkle proof for source enterprise is invalid. */
  INVALID_PROOF_A = "XENT_INVALID_PROOF_A",
  /** Merkle proof for destination enterprise is invalid. */
  INVALID_PROOF_B = "XENT_INVALID_PROOF_B",
  /** State root mismatch between proof and L1. */
  STATE_ROOT_MISMATCH = "XENT_STATE_ROOT_MISMATCH",
  /** Interaction commitment computation failed. */
  COMMITMENT_FAILED = "XENT_COMMITMENT_FAILED",
  /** Poseidon hash initialization failed. */
  HASH_INIT_FAILED = "XENT_HASH_INIT_FAILED",
}

/**
 * Structured error for cross-enterprise operations.
 */
export class CrossEnterpriseError extends Error {
  readonly code: CrossEnterpriseErrorCode;

  constructor(code: CrossEnterpriseErrorCode, message: string) {
    super(`[${code}] ${message}`);
    this.code = code;
    this.name = "CrossEnterpriseError";
  }
}
