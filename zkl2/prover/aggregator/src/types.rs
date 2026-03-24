//! Core types for the proof aggregation pipeline.
//!
//! Maps TLA+ domain definitions to Rust types:
//!   ProofIds   == Enterprises x (1..MaxProofsPerEnt)  ->  ProofId { enterprise, sequence }
//!   AggStatuses == {"aggregated", "l1_verified", "l1_rejected"}  ->  AggregationStatus enum
//!   AggRecord  == [components, valid, status]  ->  AggregationRecord struct
//!
//! [Spec: lab/3-architect/implementation-history/prover-aggregation/specs/ProofAggregation.tla]

use std::collections::BTreeSet;
use thiserror::Error;

// ---------------------------------------------------------------------------
// Gas constants (TLA+ CONSTANTS: BaseGasPerProof, AggregatedGasCost)
// [Source: implementation-history/prover-aggregation/research/findings.md, Section 3.2]
// ---------------------------------------------------------------------------

/// L1 gas cost for individual halo2-KZG proof verification.
/// [Spec: ProofAggregation.tla, line 12 -- BaseGasPerProof]
pub const BASE_GAS_PER_PROOF: u64 = 420_000;

/// L1 gas cost for aggregated proof verification (Groth16 decider).
/// [Spec: ProofAggregation.tla, line 13 -- AggregatedGasCost]
pub const AGGREGATED_GAS_COST: u64 = 220_000;

/// Minimum proofs required for aggregation to be beneficial.
/// [Spec: ProofAggregation.tla, line 175 -- Cardinality(S) >= 2]
pub const MIN_AGGREGATION_SIZE: usize = 2;

// ---------------------------------------------------------------------------
// Enterprise identity
// ---------------------------------------------------------------------------

/// Enterprise identifier (Ethereum address).
/// Typed wrapper to prevent accidental misuse of raw byte arrays.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EnterpriseId(pub [u8; 20]);

impl EnterpriseId {
    /// Create from a raw 20-byte address.
    pub fn from_bytes(bytes: [u8; 20]) -> Self {
        Self(bytes)
    }

    /// Create from a u64 (for testing). Pads with zeros.
    pub fn from_u64(val: u64) -> Self {
        let mut bytes = [0u8; 20];
        bytes[12..20].copy_from_slice(&val.to_be_bytes());
        Self(bytes)
    }
}

// ---------------------------------------------------------------------------
// Proof identity
// [Spec: ProofAggregation.tla, line 22 -- ProofIds == Enterprises x (1..MaxProofsPerEnt)]
// ---------------------------------------------------------------------------

/// Unique proof identifier: (enterprise, sequence_number).
///
/// Each enterprise generates proofs sequentially numbered starting from 1.
/// The pair (enterprise, sequence) uniquely identifies a proof across the system.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ProofId {
    pub enterprise: EnterpriseId,
    pub sequence: u64,
}

impl ProofId {
    pub fn new(enterprise: EnterpriseId, sequence: u64) -> Self {
        Self {
            enterprise,
            sequence,
        }
    }
}

// ---------------------------------------------------------------------------
// Proof entry (pool element)
// ---------------------------------------------------------------------------

/// A proof submitted to the aggregation pool.
///
/// Contains the proof data and its cryptographic validity status.
/// Validity is intrinsic and immutable: determined at generation time,
/// never altered by aggregation or verification.
/// [Spec: ProofAggregation.tla, lines 93-98 -- Proof Soundness axiom]
#[derive(Debug, Clone)]
pub struct ProofEntry {
    pub id: ProofId,
    /// Serialized proof bytes (halo2-KZG proof, ~640 bytes).
    pub proof_data: Vec<u8>,
    /// Public inputs: [pre_state_root, post_state_root, batch_hash] as 32-byte field elements.
    pub public_inputs: Vec<[u8; 32]>,
    /// Cryptographic validity. Determined at generation time, immutable thereafter.
    pub valid: bool,
}

// ---------------------------------------------------------------------------
// Aggregation identity
// ---------------------------------------------------------------------------

/// Unique identifier for an aggregation record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct AggregationId(pub u64);

// ---------------------------------------------------------------------------
// Aggregation status
// [Spec: ProofAggregation.tla, lines 25-28 -- AggStatuses]
// ---------------------------------------------------------------------------

/// Lifecycle state of an aggregated proof.
///
/// Maps to TLA+ `AggStatuses == {"aggregated", "l1_verified", "l1_rejected"}`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AggregationStatus {
    /// Folding complete, awaiting L1 submission.
    Aggregated,
    /// L1 accepted the aggregated proof.
    L1Verified,
    /// L1 rejected the aggregated proof (invalid component detected).
    L1Rejected,
}

// ---------------------------------------------------------------------------
// Aggregation record
// [Spec: ProofAggregation.tla, lines 47-55 -- aggregation record domain]
// ---------------------------------------------------------------------------

/// An aggregation record capturing the result of folding a set of proofs.
///
/// The `components` field is a BTreeSet (ordered set) to enforce deterministic
/// ordering. This structurally enforces OrderIndependence: the aggregation
/// result depends only on set membership, never on presentation order.
///
/// [Spec: ProofAggregation.tla, lines 47-55]
#[derive(Debug, Clone)]
pub struct AggregationRecord {
    /// Unique identifier for this aggregation.
    pub id: AggregationId,
    /// The set of proof IDs that were folded together.
    /// BTreeSet ensures deterministic iteration order (OrderIndependence).
    pub components: BTreeSet<ProofId>,
    /// TRUE iff all component proofs are cryptographically valid.
    /// [Spec: ProofAggregation.tla, line 176 -- allValid == (S ⊆ proofValidity)]
    pub valid: bool,
    /// Lifecycle state.
    pub status: AggregationStatus,
    /// Serialized aggregated proof (Groth16 decider output, ~128 bytes).
    /// None if aggregation simulation produces no proof bytes.
    pub aggregated_proof: Option<Vec<u8>>,
}

// ---------------------------------------------------------------------------
// Folded instance (recursive verifier output)
// ---------------------------------------------------------------------------

/// Represents the output of ProtoGalaxy folding.
///
/// In production, this would contain the accumulated PLONKish instance.
/// Currently models the folding result with validity tracking that
/// faithfully implements the Aggregation Soundness axiom.
#[derive(Debug, Clone)]
pub struct FoldedInstance {
    /// Whether the folded instance is satisfiable (all components valid).
    pub satisfiable: bool,
    /// Number of component proofs folded into this instance.
    pub num_components: usize,
    /// Serialized folded state (for tree-level chaining).
    pub state: Vec<u8>,
}

/// Output of the Groth16 decider applied to a folded instance.
#[derive(Debug, Clone)]
pub struct DeciderProof {
    /// Serialized Groth16 proof (~128 bytes in production).
    pub proof_bytes: Vec<u8>,
    /// Whether the proof is valid (mirrors folded instance satisfiability).
    pub valid: bool,
}

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

/// Errors produced by the aggregation pipeline.
#[derive(Debug, Error)]
pub enum AggregatorError {
    #[error("proof {0:?} not found in pool")]
    ProofNotInPool(ProofId),

    #[error("proof {0:?} already submitted to pool")]
    DuplicateProof(ProofId),

    #[error("proof {0:?} is currently in aggregation {1:?}, cannot submit")]
    ProofInAggregation(ProofId, AggregationId),

    #[error("aggregation requires at least {MIN_AGGREGATION_SIZE} proofs, got {0}")]
    InsufficientProofs(usize),

    #[error("aggregation {0:?} not found")]
    AggregationNotFound(AggregationId),

    #[error("aggregation {0:?} is in status {1:?}, expected {2:?}")]
    InvalidAggregationStatus(AggregationId, AggregationStatus, AggregationStatus),

    #[error("proof sequence {sequence} exceeds counter {counter} for enterprise {enterprise:?}")]
    SequenceExceedsCounter {
        enterprise: EnterpriseId,
        sequence: u64,
        counter: u64,
    },

    #[error("invariant violation: {0}")]
    InvariantViolation(String),

    #[error("folding failed: {0}")]
    FoldingFailed(String),
}

/// Result type alias for aggregation operations.
pub type AggregatorResult<T> = Result<T, AggregatorError>;
