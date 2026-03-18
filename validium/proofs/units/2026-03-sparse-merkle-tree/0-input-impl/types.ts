/**
 * Type definitions for the Sparse Merkle Tree state management layer.
 *
 * [Spec: validium/specs/units/2026-03-sparse-merkle-tree/SparseMerkleTree.tla]
 *
 * All arithmetic operates over the BN128 scalar field:
 *   p = 21888242871839275222246405745257275088548364400416034343698204186575808495617
 *
 * @module state/types
 */

// ---------------------------------------------------------------------------
// Field Arithmetic
// ---------------------------------------------------------------------------

/**
 * BN128 scalar field prime.
 * All hash outputs and tree values exist in Fp where p is this constant.
 */
export const BN128_PRIME =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

/**
 * Sentinel value for empty (unoccupied) leaves.
 *
 * [Spec: EMPTY == 0]
 */
export const EMPTY_VALUE = 0n;

/**
 * Default tree depth for the enterprise validium node.
 * 2^32 = 4,294,967,296 possible leaf positions.
 */
export const DEFAULT_DEPTH = 32;

// ---------------------------------------------------------------------------
// Branded Types
// ---------------------------------------------------------------------------

/** Brand symbol for field elements (compile-time only). */
declare const FieldElementBrand: unique symbol;

/**
 * A bigint value guaranteed to be in the BN128 scalar field [0, p).
 * Branded type to prevent accidental mixing with arbitrary bigints.
 */
export type FieldElement = bigint & { readonly [FieldElementBrand]: never };

/**
 * Assert a bigint is a valid BN128 field element.
 * Throws SMTError if the value is outside [0, p).
 *
 * @param value - The bigint to validate
 * @returns The value cast as FieldElement
 */
export function toFieldElement(value: bigint): FieldElement {
  if (value < 0n || value >= BN128_PRIME) {
    throw new SMTError(
      SMTErrorCode.INVALID_FIELD_ELEMENT,
      `Value ${value} is outside BN128 field [0, ${BN128_PRIME})`
    );
  }
  return value as FieldElement;
}

/**
 * Reduce an arbitrary bigint to the BN128 field.
 *
 * @param value - Any bigint
 * @returns The value modulo p, as a FieldElement
 */
export function reduceToField(value: bigint): FieldElement {
  return (((value % BN128_PRIME) + BN128_PRIME) % BN128_PRIME) as FieldElement;
}

// ---------------------------------------------------------------------------
// Merkle Proof
// ---------------------------------------------------------------------------

/**
 * Merkle inclusion/non-membership proof for a single key in the SMT.
 *
 * [Spec: ProofSiblings(e, k) produces siblings; PathBitsForKey(k) produces pathBits]
 * [Spec: VerifyProofOp(expectedRoot, leafHash, siblings, pathBits) verifies]
 */
export interface MerkleProof {
  /** Sibling hashes along the path from leaf (level 0) to root (level depth-1). */
  readonly siblings: readonly FieldElement[];

  /** Direction bits per level: 0 = current node is left child, 1 = right child. */
  readonly pathBits: readonly number[];

  /** The key whose membership/non-membership is proved. */
  readonly key: FieldElement;

  /** The leaf hash at proof generation time (0n for non-membership). */
  readonly leafHash: FieldElement;

  /** The root hash at proof generation time. */
  readonly root: FieldElement;
}

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

/**
 * Tree statistics for observability and benchmarking.
 */
export interface SMTStats {
  /** Number of non-zero entries (occupied leaves). */
  readonly entryCount: number;

  /** Number of nodes stored in the sparse map. */
  readonly nodeCount: number;

  /** Tree depth (levels from root to leaves). */
  readonly depth: number;

  /** Estimated memory consumption in bytes. */
  readonly memoryEstimateBytes: number;
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

/**
 * Serialized form of the Sparse Merkle Tree for persistence.
 * All bigints are stored as hex strings for JSON compatibility.
 */
export interface SerializedSMT {
  readonly version: 1;
  readonly depth: number;
  readonly entryCount: number;
  /** Sparse node map: key is "level:index", value is hex-encoded field element. */
  readonly nodes: Record<string, string>;
  /** Default hashes per level, hex-encoded. */
  readonly defaultHashes: readonly string[];
}

// ---------------------------------------------------------------------------
// Error Types
// ---------------------------------------------------------------------------

/**
 * Error codes for Sparse Merkle Tree operations.
 */
export enum SMTErrorCode {
  /** Poseidon hash function failed to initialize. */
  HASH_INIT_FAILED = "SMT_HASH_INIT_FAILED",
  /** Value is outside the BN128 scalar field. */
  INVALID_FIELD_ELEMENT = "SMT_INVALID_FIELD_ELEMENT",
  /** Tree depth is invalid (must be > 0). */
  INVALID_DEPTH = "SMT_INVALID_DEPTH",
  /** Proof structure is malformed. */
  INVALID_PROOF = "SMT_INVALID_PROOF",
  /** Serialized data is corrupt or incompatible. */
  DESERIALIZATION_FAILED = "SMT_DESERIALIZATION_FAILED",
}

/**
 * Structured error type for all SMT operations.
 */
export class SMTError extends Error {
  readonly code: SMTErrorCode;

  constructor(code: SMTErrorCode, message: string) {
    super(`[${code}] ${message}`);
    this.code = code;
    this.name = "SMTError";
  }
}
