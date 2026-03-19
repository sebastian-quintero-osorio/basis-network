/**
 * Data Availability Committee (DAC) module.
 *
 * Exports the complete DAC protocol stack:
 *   - Shamir Secret Sharing primitives
 *   - DAC Node (enterprise-managed storage + attestation)
 *   - DAC Protocol orchestrator (distribute, attest, recover, verify)
 *   - All types, error codes, and enums
 *
 * @module da
 */

export {
  split,
  recover,
  bytesToFieldElements,
  fieldElementsToBytes,
  shareData,
  reconstructData,
  verifyShareConsistency,
} from "./shamir";

export { DACNode } from "./dac-node";

export { DACProtocol } from "./dac-protocol";

export {
  BN128_PRIME,
  FIELD_ELEMENT_BYTES,
  CHUNK_SIZE,
  CertificateState,
  RecoveryState,
  DACErrorCode,
  DACError,
  type Share,
  type ShareSet,
  type DACNodeState,
  type Attestation,
  type DACCertificate,
  type DACConfig,
  type DistributionResult,
  type AttestationResult,
  type RecoveryResult,
  type VerificationResult,
} from "./types";
