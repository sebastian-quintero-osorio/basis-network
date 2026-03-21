/// Universal Structured Reference String (SRS) management for KZG commitments.
///
/// The SRS is the universal setup parameter for PLONK-KZG. Unlike Groth16's
/// per-circuit trusted setup, the KZG SRS is universal: generated once and
/// reusable across all circuits up to a maximum size of 2^k rows.
///
/// For production, the SRS is loaded from a file (generated via a trusted
/// ceremony such as the PSE powers-of-tau). For testing, a random SRS is
/// generated deterministically from a seed.
///
/// [Spec: lab/3-architect/implementation-history/prover-plonk-migration/specs/PlonkMigration.tla]
/// [Source: implementation-history/prover-plonk-migration/research/findings.md, Section 4]
use halo2_proofs::{
    halo2curves::bn256::Bn256,
    poly::{commitment::Params, kzg::commitment::ParamsKZG},
};
use rand::rngs::OsRng;

use crate::types::{CircuitError, CircuitResult};

// ---------------------------------------------------------------------------
// SRS generation and loading
// ---------------------------------------------------------------------------

/// Generate a new KZG SRS for testing.
///
/// Uses OS-provided randomness. The resulting SRS supports circuits with up
/// to 2^k rows. This is NOT suitable for production; use `load_srs` with
/// ceremony-derived parameters instead.
///
/// k=14 (16,384 rows) is the default for development and testing.
/// k=20 (1,048,576 rows) is recommended for production.
pub fn generate_srs(k: u32) -> CircuitResult<ParamsKZG<Bn256>> {
    if k > 28 {
        return Err(CircuitError::SrsError(format!(
            "k={} exceeds maximum supported size (28)",
            k
        )));
    }
    Ok(ParamsKZG::<Bn256>::setup(k, OsRng))
}

/// Load a KZG SRS from serialized bytes.
///
/// The bytes must contain a valid ParamsKZG serialization. This is used
/// for loading ceremony-derived SRS from disk.
pub fn load_srs(bytes: &[u8]) -> CircuitResult<ParamsKZG<Bn256>> {
    let mut reader = std::io::Cursor::new(bytes);
    ParamsKZG::<Bn256>::read(&mut reader)
        .map_err(|e| CircuitError::SrsError(format!("failed to deserialize SRS: {}", e)))
}

/// Serialize a KZG SRS to bytes.
///
/// Used for caching generated SRS to disk to avoid re-generating.
pub fn serialize_srs(params: &ParamsKZG<Bn256>) -> CircuitResult<Vec<u8>> {
    let mut buf = Vec::new();
    params
        .write(&mut buf)
        .map_err(|e| CircuitError::SerializationError(format!("failed to serialize SRS: {}", e)))?;
    Ok(buf)
}

/// Get the maximum number of rows supported by an SRS.
pub fn srs_max_rows(params: &ParamsKZG<Bn256>) -> usize {
    1 << params.k()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_srs_small() {
        let params = generate_srs(4).expect("k=4 SRS generation should succeed");
        assert_eq!(params.k(), 4);
        assert_eq!(srs_max_rows(&params), 16);
    }

    #[test]
    fn srs_serialize_roundtrip() {
        let params = generate_srs(4).expect("SRS generation should succeed");
        let bytes = serialize_srs(&params).expect("serialization should succeed");
        let restored = load_srs(&bytes).expect("deserialization should succeed");
        assert_eq!(params.k(), restored.k());
    }

    #[test]
    fn srs_reject_oversized_k() {
        let result = generate_srs(29);
        assert!(result.is_err());
    }
}
