/**
 * Cross-Enterprise Verification Module -- Public API
 *
 * Provides cross-enterprise reference building and verification for the
 * Basis Network Validium node. Implements the hub-and-spoke proof aggregation
 * model where the L1 smart contract verifies interactions between enterprises
 * without revealing private data from either party.
 *
 * [Spec: validium/specs/units/2026-03-cross-enterprise/1-formalization/v0-analysis/specs/CrossEnterprise/CrossEnterprise.tla]
 *
 * @module cross-enterprise
 */

// Types
export {
  type CrossReferenceId,
  type CrossReferenceRequest,
  type CrossReferenceEvidence,
  type CrossReferenceVerificationResult,
  type BatchStatusProvider,
  CrossReferenceStatus,
  CrossEnterpriseError,
  CrossEnterpriseErrorCode,
  BatchVerificationStatus,
} from "./types";

// Builder
export {
  buildCrossReferenceEvidence,
  verifyCrossReferenceLocally,
  formatPublicSignals,
  computeCrossRefHash,
} from "./cross-reference-builder";
