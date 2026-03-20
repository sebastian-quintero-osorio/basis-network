/// Core types for the PLONK circuit module.
///
/// Defines migration phases, proof system identifiers, error types, and proof data
/// structures shared across the circuit, prover, and verifier submodules.
///
/// [Spec: lab/3-architect/implementation-history/prover-plonk-migration/specs/PlonkMigration.tla]
use halo2_proofs::halo2curves::bn256::Fr;
use thiserror::Error;

// ---------------------------------------------------------------------------
// Migration phase (TLA+ migrationPhase variable)
// ---------------------------------------------------------------------------

/// Migration phase state machine.
///
/// Corresponds to TLA+ `Phases == {"groth16_only", "dual", "plonk_only", "rollback"}`.
/// Transitions are guarded by the invariants defined in the specification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MigrationPhase {
    /// Only Groth16 proofs accepted. Initial state.
    Groth16Only,
    /// Both Groth16 and PLONK proofs accepted. Transition period.
    Dual,
    /// Only PLONK proofs accepted. Final state after successful migration.
    PlonkOnly,
    /// Rollback in progress. Only Groth16 accepted while queues drain.
    Rollback,
}

impl MigrationPhase {
    /// Returns the set of active verifiers for this phase.
    ///
    /// Corresponds to TLA+ `VerifiersForPhase(p)`:
    ///   groth16_only -> {groth16}
    ///   dual         -> {groth16, plonk}
    ///   plonk_only   -> {plonk}
    ///   rollback     -> {groth16}
    pub fn active_verifiers(&self) -> &[ProofSystem] {
        match self {
            MigrationPhase::Groth16Only => &[ProofSystem::Groth16],
            MigrationPhase::Dual => &[ProofSystem::Groth16, ProofSystem::Plonk],
            MigrationPhase::PlonkOnly => &[ProofSystem::Plonk],
            MigrationPhase::Rollback => &[ProofSystem::Groth16],
        }
    }

    /// Check whether a given proof system is accepted in this phase.
    ///
    /// Corresponds to TLA+ `batch.proofSystem \in activeVerifiers`.
    pub fn accepts(&self, ps: ProofSystem) -> bool {
        self.active_verifiers().contains(&ps)
    }
}

// ---------------------------------------------------------------------------
// Proof system identifier (TLA+ ProofSystems constant)
// ---------------------------------------------------------------------------

/// Proof system type.
///
/// Corresponds to TLA+ `ProofSystems == {"groth16", "plonk"}`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ProofSystem {
    Groth16,
    Plonk,
}

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

/// Errors produced by the circuit module.
#[derive(Debug, Error)]
pub enum CircuitError {
    #[error("invalid witness: {0}")]
    InvalidWitness(String),

    #[error("proof generation failed: {0}")]
    ProofGenerationFailed(String),

    #[error("proof verification failed: {0}")]
    VerificationFailed(String),

    #[error("SRS load/generation failed: {0}")]
    SrsError(String),

    #[error("invalid migration phase transition: {from:?} -> {to:?}")]
    InvalidPhaseTransition {
        from: MigrationPhase,
        to: MigrationPhase,
    },

    #[error("proof system {0:?} not accepted in phase {1:?}")]
    ProofSystemNotAccepted(ProofSystem, MigrationPhase),

    #[error("column mismatch: expected {expected}, got {got}")]
    ColumnMismatch { expected: usize, got: usize },

    #[error("keygen failed: {0}")]
    KeygenFailed(String),

    #[error("serialization error: {0}")]
    SerializationError(String),
}

/// Result type alias for circuit operations.
pub type CircuitResult<T> = Result<T, CircuitError>;

// ---------------------------------------------------------------------------
// Proof data structures
// ---------------------------------------------------------------------------

/// A generated proof with its public inputs.
///
/// Corresponds to TLA+ `ProofRecord` (without the phase stamp, which is
/// added at verification time by the on-chain contract).
#[derive(Debug, Clone)]
pub struct ProofData {
    /// Serialized proof bytes (PLONK proof encoded for halo2-KZG).
    pub proof: Vec<u8>,
    /// Public inputs: [pre_state_root, post_state_root, batch_hash].
    pub public_inputs: Vec<Fr>,
    /// Which proof system generated this proof.
    pub proof_system: ProofSystem,
}

/// Verification key data for PLONK circuits.
///
/// Wraps the halo2 verification key with metadata for migration management.
#[derive(Debug, Clone)]
pub struct VerificationKeyData {
    /// Serialized verification key bytes.
    pub vk_bytes: Vec<u8>,
    /// Circuit parameter k (log2 of number of rows).
    pub k: u32,
    /// Number of instance (public input) columns.
    pub num_instance_columns: usize,
}

// ---------------------------------------------------------------------------
// Field element conversion (ark-bn254 <-> halo2curves)
// ---------------------------------------------------------------------------

/// Convert an arkworks BN254 Fr to a halo2curves BN256 Fr.
///
/// Both represent the same mathematical field (BN254 scalar field, modulus
/// 21888242871839275222246405745257275088548364400416034343698204186575808495617).
/// Conversion is lossless via little-endian byte serialization.
pub fn ark_fr_to_halo2_fr(ark_val: ark_bn254::Fr) -> Fr {
    use ark_ff::PrimeField;
    let bigint = ark_val.into_bigint();
    let mut bytes = [0u8; 32];
    // arkworks BigInteger stores limbs in little-endian order (limb[0] = least significant)
    for (i, limb) in bigint.0.iter().enumerate() {
        let limb_bytes = limb.to_le_bytes();
        bytes[i * 8..(i + 1) * 8].copy_from_slice(&limb_bytes);
    }
    Fr::from_bytes(&bytes).expect("valid BN254 field element must convert")
}

/// Convert a halo2curves BN256 Fr to an arkworks BN254 Fr.
///
/// Inverse of `ark_fr_to_halo2_fr`. Lossless.
pub fn halo2_fr_to_ark_fr(halo2_val: Fr) -> ark_bn254::Fr {
    use ark_ff::PrimeField;
    use halo2_proofs::halo2curves::ff::PrimeField as Halo2PrimeField;
    let bytes = halo2_val.to_repr();
    let mut limbs = [0u64; 4];
    for i in 0..4 {
        limbs[i] = u64::from_le_bytes(
            bytes[i * 8..(i + 1) * 8]
                .try_into()
                .expect("8 bytes for u64"),
        );
    }
    let bigint = ark_ff::BigInteger256::new(limbs);
    ark_bn254::Fr::from_bigint(bigint).expect("valid BN254 field element must convert")
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default circuit size parameter (k = log2 rows).
/// k=14 gives 16,384 rows, sufficient for basic EVM operations.
/// Production circuits use k=20 (1,048,576 rows) for full blocks.
pub const DEFAULT_K: u32 = 14;

/// Number of advice columns in the circuit.
pub const NUM_ADVICE_COLUMNS: usize = 4;

/// Number of instance columns (public inputs).
/// [pre_state_root, post_state_root, batch_hash]
pub const NUM_INSTANCE_COLUMNS: usize = 1;

/// Number of public inputs per instance column.
pub const NUM_PUBLIC_INPUTS: usize = 3;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_phase_active_verifiers() {
        assert_eq!(
            MigrationPhase::Groth16Only.active_verifiers(),
            &[ProofSystem::Groth16]
        );
        assert_eq!(
            MigrationPhase::Dual.active_verifiers(),
            &[ProofSystem::Groth16, ProofSystem::Plonk]
        );
        assert_eq!(
            MigrationPhase::PlonkOnly.active_verifiers(),
            &[ProofSystem::Plonk]
        );
        assert_eq!(
            MigrationPhase::Rollback.active_verifiers(),
            &[ProofSystem::Groth16]
        );
    }

    #[test]
    fn migration_phase_accepts() {
        // S2: BackwardCompatibility -- Groth16 accepted in groth16_only and dual
        assert!(MigrationPhase::Groth16Only.accepts(ProofSystem::Groth16));
        assert!(MigrationPhase::Dual.accepts(ProofSystem::Groth16));
        assert!(MigrationPhase::Dual.accepts(ProofSystem::Plonk));

        // S5: NoGroth16AfterCutover -- Groth16 NOT accepted in plonk_only
        assert!(!MigrationPhase::PlonkOnly.accepts(ProofSystem::Groth16));
        assert!(MigrationPhase::PlonkOnly.accepts(ProofSystem::Plonk));

        // Rollback: only Groth16
        assert!(MigrationPhase::Rollback.accepts(ProofSystem::Groth16));
        assert!(!MigrationPhase::Rollback.accepts(ProofSystem::Plonk));
    }

    #[test]
    fn field_element_roundtrip() {
        let ark_val = ark_bn254::Fr::from(42u64);
        let halo2_val = ark_fr_to_halo2_fr(ark_val);
        let roundtrip = halo2_fr_to_ark_fr(halo2_val);
        assert_eq!(ark_val, roundtrip);
    }

    #[test]
    fn field_element_zero_roundtrip() {
        let ark_val = ark_bn254::Fr::from(0u64);
        let halo2_val = ark_fr_to_halo2_fr(ark_val);
        let roundtrip = halo2_fr_to_ark_fr(halo2_val);
        assert_eq!(ark_val, roundtrip);
    }

    #[test]
    fn field_element_large_value_roundtrip() {
        use ark_ff::PrimeField;
        // Use a value near the field modulus
        let ark_val = -ark_bn254::Fr::from(1u64); // p - 1
        let halo2_val = ark_fr_to_halo2_fr(ark_val);
        let roundtrip = halo2_fr_to_ark_fr(halo2_val);
        assert_eq!(ark_val, roundtrip);
    }
}
