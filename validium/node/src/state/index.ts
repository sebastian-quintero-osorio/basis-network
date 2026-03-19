/**
 * State management layer for the Basis Network Enterprise ZK Validium Node.
 *
 * Provides the Sparse Merkle Tree -- the foundational data structure for
 * all enterprise state management in the validium system.
 *
 * [Spec: validium/specs/units/2026-03-sparse-merkle-tree/SparseMerkleTree.tla]
 *
 * @module state
 */

export { SparseMerkleTree } from "./sparse-merkle-tree";

export {
  type FieldElement,
  type MerkleProof,
  type SMTStats,
  type SerializedSMT,
  BN128_PRIME,
  DEFAULT_DEPTH,
  EMPTY_VALUE,
  SMTError,
  SMTErrorCode,
  toFieldElement,
  reduceToField,
} from "./types";
