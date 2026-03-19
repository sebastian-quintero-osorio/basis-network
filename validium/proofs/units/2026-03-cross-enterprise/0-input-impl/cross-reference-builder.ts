/**
 * Cross-Reference Builder -- Constructs and validates cross-enterprise evidence.
 *
 * Translates the verified TLA+ actions (RequestCrossRef, VerifyCrossRef,
 * RejectCrossRef) into production-grade TypeScript. Each function enforces
 * the safety invariants proven by TLC model checking.
 *
 * [Spec: validium/specs/units/2026-03-cross-enterprise/1-formalization/v0-analysis/specs/CrossEnterprise/CrossEnterprise.tla]
 *
 * Safety invariants enforced:
 *   Isolation:           no enterprise state root is modified by cross-ref operations
 *   Consistency:         cross-ref verified only when BOTH batch proofs are verified
 *   NoCrossRefSelfLoop:  src != dst checked at request time
 *
 * @module cross-enterprise/cross-reference-builder
 */

// @ts-expect-error -- circomlibjs does not ship proper TS types
import { buildPoseidon } from "circomlibjs";

import type { FieldElement, MerkleProof } from "../state/types";
import { createLogger } from "../logger";

import {
  type CrossReferenceId,
  type CrossReferenceRequest,
  type CrossReferenceEvidence,
  type CrossReferenceVerificationResult,
  type BatchStatusProvider,
  CrossReferenceStatus,
  CrossEnterpriseError,
  CrossEnterpriseErrorCode,
} from "./types";

// ---------------------------------------------------------------------------
// Logger
// ---------------------------------------------------------------------------

const log = createLogger("cross-enterprise");

// ---------------------------------------------------------------------------
// Poseidon Helper
// ---------------------------------------------------------------------------

/** Poseidon hash function instance (lazy-initialized). */
let poseidonInstance: unknown = null;
let poseidonF: { toObject(el: unknown): bigint } | null = null;

/**
 * Get or initialize the Poseidon hash function.
 * Cached across calls for performance.
 */
async function getPoseidon(): Promise<{
  poseidon: (inputs: bigint[]) => unknown;
  F: { toObject(el: unknown): bigint };
}> {
  if (poseidonInstance !== null && poseidonF !== null) {
    return {
      poseidon: poseidonInstance as (inputs: bigint[]) => unknown,
      F: poseidonF,
    };
  }

  try {
    poseidonInstance = await buildPoseidon();
    poseidonF = (poseidonInstance as { F: { toObject(el: unknown): bigint } }).F;
    return {
      poseidon: poseidonInstance as (inputs: bigint[]) => unknown,
      F: poseidonF,
    };
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new CrossEnterpriseError(
      CrossEnterpriseErrorCode.HASH_INIT_FAILED,
      `Failed to initialize Poseidon: ${msg}`
    );
  }
}

/**
 * Compute Poseidon hash of two field elements.
 */
async function poseidonHash2(a: bigint, b: bigint): Promise<bigint> {
  const { poseidon, F } = await getPoseidon();
  return F.toObject(poseidon([a, b]));
}

/**
 * Compute Poseidon hash of four field elements (interaction commitment).
 *
 * [Spec: interactionCommitment = Poseidon(keyA, leafHashA, keyB, leafHashB)]
 */
async function poseidonHash4(
  a: bigint,
  b: bigint,
  c: bigint,
  d: bigint
): Promise<bigint> {
  const { poseidon, F } = await getPoseidon();
  return F.toObject(poseidon([a, b, c, d]));
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/**
 * Validate a cross-reference ID enforces NoCrossRefSelfLoop.
 *
 * [Spec: CrossRefIds construction: r.src # r.dst]
 *
 * @param id - Cross-reference identifier to validate
 * @throws CrossEnterpriseError if src === dst
 */
function validateCrossRefId(id: CrossReferenceId): void {
  if (id.src === id.dst) {
    throw new CrossEnterpriseError(
      CrossEnterpriseErrorCode.SELF_REFERENCE,
      `Cross-reference self-loop: src and dst are both "${id.src}"`
    );
  }
}

/**
 * Verify a Merkle proof against an expected root.
 * Iterative walk-up from leaf to root using Poseidon hash.
 *
 * [Spec: VerifyProofOp(expectedRoot, leafHash, siblings, pathBits)]
 */
async function verifyMerkleProof(
  expectedRoot: FieldElement,
  proof: MerkleProof
): Promise<boolean> {
  if (proof.siblings.length !== proof.pathBits.length) {
    return false;
  }
  if (proof.siblings.length === 0) {
    return false;
  }

  let currentHash: bigint = proof.leafHash;
  for (let level = 0; level < proof.siblings.length; level++) {
    const sibling = proof.siblings[level];
    const bit = proof.pathBits[level];
    if (sibling === undefined || bit === undefined) {
      return false;
    }

    currentHash =
      bit === 0
        ? await poseidonHash2(currentHash, sibling)
        : await poseidonHash2(sibling, currentHash);
  }

  return currentHash === (expectedRoot as bigint);
}

// ---------------------------------------------------------------------------
// Build Cross-Reference Evidence
// ---------------------------------------------------------------------------

/**
 * Build cross-reference evidence from two enterprise Merkle proofs.
 *
 * Implements the off-chain portion of RequestCrossRef: validates preconditions,
 * computes the interaction commitment, and packages evidence for L1 submission.
 *
 * [Spec: RequestCrossRef(src, dst, srcBatch, dstBatch)]
 *   Guard: ref \in CrossRefIds (src # dst)
 *   Guard: batchStatus[src][srcBatch] \in {"submitted", "verified"}
 *   Guard: batchStatus[dst][dstBatch] \in {"submitted", "verified"}
 *
 * Privacy guarantee:
 *   Public signals: stateRootA, stateRootB, interactionCommitment
 *   Private inputs: keyA, leafHashA, siblingsA, pathBitsA, keyB, leafHashB, siblingsB, pathBitsB
 *   Leakage: 1 bit per interaction (existence only)
 *
 * @param request - Cross-reference request with proofs from both enterprises
 * @returns Cross-reference evidence ready for L1 verification
 * @throws CrossEnterpriseError on validation failure
 */
export async function buildCrossReferenceEvidence(
  request: CrossReferenceRequest
): Promise<CrossReferenceEvidence> {
  // [Spec: NoCrossRefSelfLoop -- structural enforcement]
  validateCrossRefId(request.id);

  log.info("Building cross-reference evidence", {
    src: request.id.src,
    dst: request.id.dst,
    srcBatch: request.id.srcBatch,
    dstBatch: request.id.dstBatch,
  });

  // Validate Merkle proof A against stateRootA
  const validA = await verifyMerkleProof(request.stateRootA, request.proofA);
  if (!validA) {
    throw new CrossEnterpriseError(
      CrossEnterpriseErrorCode.INVALID_PROOF_A,
      "Merkle proof for source enterprise does not verify against stateRootA"
    );
  }

  // Validate Merkle proof B against stateRootB
  const validB = await verifyMerkleProof(request.stateRootB, request.proofB);
  if (!validB) {
    throw new CrossEnterpriseError(
      CrossEnterpriseErrorCode.INVALID_PROOF_B,
      "Merkle proof for destination enterprise does not verify against stateRootB"
    );
  }

  // [Spec: interactionCommitment = Poseidon(keyA, leafHashA, keyB, leafHashB)]
  // This commitment binds both enterprises' records without revealing content.
  // Privacy: Poseidon preimage resistance (128-bit) prevents extraction of
  // keys or values from the commitment.
  let commitment: bigint;
  try {
    commitment = await poseidonHash4(
      request.proofA.key,
      request.proofA.leafHash,
      request.proofB.key,
      request.proofB.leafHash
    );
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new CrossEnterpriseError(
      CrossEnterpriseErrorCode.COMMITMENT_FAILED,
      `Failed to compute interaction commitment: ${msg}`
    );
  }

  const evidence: CrossReferenceEvidence = {
    id: request.id,
    stateRootA: request.stateRootA,
    stateRootB: request.stateRootB,
    interactionCommitment: commitment as FieldElement,
    proofA: request.proofA,
    proofB: request.proofB,
    builtAt: Date.now(),
  };

  log.info("Cross-reference evidence built", {
    src: request.id.src,
    dst: request.id.dst,
    commitment: commitment.toString(16).slice(0, 16) + "...",
  });

  return evidence;
}

// ---------------------------------------------------------------------------
// Verify Cross-Reference Locally (Pre-flight)
// ---------------------------------------------------------------------------

/**
 * Verify cross-reference evidence locally before L1 submission.
 *
 * Implements the full VerifyCrossRef precondition checks:
 * 1. NoCrossRefSelfLoop: src != dst
 * 2. Consistency: both enterprise batch proofs must be verified on L1
 * 3. Merkle proofs verify against respective state roots
 * 4. Interaction commitment is correctly computed
 * 5. Privacy check: no private data leaked in public signals
 *
 * [Spec: VerifyCrossRef(src, dst, srcBatch, dstBatch)]
 *   Guard: crossRefStatus[ref] = "pending"
 *   Guard: batchStatus[src][srcBatch] = "verified"
 *   Guard: batchStatus[dst][dstBatch] = "verified"
 *   Effect: crossRefStatus' = "verified"
 *   ISOLATION: UNCHANGED << currentRoot, batchStatus, batchNewRoot >>
 *
 * @param evidence - Cross-reference evidence to verify
 * @param batchProvider - Callback for querying L1 batch verification status
 * @returns Verification result with status and public signals
 */
export async function verifyCrossReferenceLocally(
  evidence: CrossReferenceEvidence,
  batchProvider: BatchStatusProvider
): Promise<CrossReferenceVerificationResult> {
  const publicSignals: FieldElement[] = [
    evidence.stateRootA,
    evidence.stateRootB,
    evidence.interactionCommitment,
  ];

  // [Spec: NoCrossRefSelfLoop]
  try {
    validateCrossRefId(evidence.id);
  } catch {
    return {
      valid: false,
      status: CrossReferenceStatus.Rejected,
      reason: "Self-reference: source and destination enterprise are the same",
      privacyPreserved: true,
      publicSignals,
    };
  }

  // [Spec: Consistency -- batchStatus[src][srcBatch] = "verified"]
  const srcVerified = await batchProvider.isBatchVerified(
    evidence.id.src,
    evidence.id.srcBatch
  );
  if (!srcVerified) {
    log.warn("Source batch not verified on L1", {
      enterprise: evidence.id.src,
      batchId: evidence.id.srcBatch,
    });
    return {
      valid: false,
      status: CrossReferenceStatus.Rejected,
      reason: `Source batch ${evidence.id.srcBatch} for enterprise ${evidence.id.src} not verified on L1`,
      privacyPreserved: true,
      publicSignals,
    };
  }

  // [Spec: Consistency -- batchStatus[dst][dstBatch] = "verified"]
  const dstVerified = await batchProvider.isBatchVerified(
    evidence.id.dst,
    evidence.id.dstBatch
  );
  if (!dstVerified) {
    log.warn("Destination batch not verified on L1", {
      enterprise: evidence.id.dst,
      batchId: evidence.id.dstBatch,
    });
    return {
      valid: false,
      status: CrossReferenceStatus.Rejected,
      reason: `Destination batch ${evidence.id.dstBatch} for enterprise ${evidence.id.dst} not verified on L1`,
      privacyPreserved: true,
      publicSignals,
    };
  }

  // Verify Merkle proof A
  const validA = await verifyMerkleProof(evidence.stateRootA, evidence.proofA);
  if (!validA) {
    return {
      valid: false,
      status: CrossReferenceStatus.Rejected,
      reason: "Source enterprise Merkle proof invalid",
      privacyPreserved: true,
      publicSignals,
    };
  }

  // Verify Merkle proof B
  const validB = await verifyMerkleProof(evidence.stateRootB, evidence.proofB);
  if (!validB) {
    return {
      valid: false,
      status: CrossReferenceStatus.Rejected,
      reason: "Destination enterprise Merkle proof invalid",
      privacyPreserved: true,
      publicSignals,
    };
  }

  // Verify interaction commitment
  const expectedCommitment = await poseidonHash4(
    evidence.proofA.key,
    evidence.proofA.leafHash,
    evidence.proofB.key,
    evidence.proofB.leafHash
  );

  if (expectedCommitment !== (evidence.interactionCommitment as bigint)) {
    return {
      valid: false,
      status: CrossReferenceStatus.Rejected,
      reason: "Interaction commitment mismatch",
      privacyPreserved: true,
      publicSignals,
    };
  }

  // Privacy check: verify no private data appears in public signals.
  // Private data: keys and leaf hashes from both enterprises.
  // Public signals: stateRootA, stateRootB, interactionCommitment.
  const privateData: bigint[] = [
    evidence.proofA.key,
    evidence.proofA.leafHash,
    evidence.proofB.key,
    evidence.proofB.leafHash,
  ];

  const publicBigints = new Set(publicSignals.map((s) => s as bigint));
  const privacyPreserved = privateData.every((d) => !publicBigints.has(d));

  log.info("Cross-reference locally verified", {
    src: evidence.id.src,
    dst: evidence.id.dst,
    status: "verified",
    privacyPreserved,
  });

  return {
    valid: true,
    status: CrossReferenceStatus.Verified,
    privacyPreserved,
    publicSignals,
  };
}

/**
 * Format cross-reference evidence as public signals for L1 contract submission.
 * Returns the three public inputs expected by CrossEnterpriseVerifier.sol.
 *
 * @param evidence - Verified cross-reference evidence
 * @returns Array of [stateRootA, stateRootB, interactionCommitment] as hex strings
 */
export function formatPublicSignals(
  evidence: CrossReferenceEvidence
): readonly string[] {
  return [
    "0x" + (evidence.stateRootA as bigint).toString(16).padStart(64, "0"),
    "0x" + (evidence.stateRootB as bigint).toString(16).padStart(64, "0"),
    "0x" + (evidence.interactionCommitment as bigint).toString(16).padStart(64, "0"),
  ];
}

/**
 * Compute the cross-reference identifier hash matching the Solidity contract.
 * keccak256(abi.encode(enterpriseA, enterpriseB, batchIdA, batchIdB))
 *
 * @param id - Cross-reference identifier
 * @returns Hex string matching the Solidity-side refId computation
 */
export function computeCrossRefHash(id: CrossReferenceId): string {
  // Use ethers.js ABI encoding to match Solidity keccak256(abi.encode(...))
  // This is computed off-chain for reference/lookup purposes.
  const { keccak256, AbiCoder } = require("ethers") as typeof import("ethers");
  const coder = new AbiCoder();
  const encoded = coder.encode(
    ["address", "address", "uint256", "uint256"],
    [id.src, id.dst, id.srcBatch, id.dstBatch]
  );
  return keccak256(encoded);
}
