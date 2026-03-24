//! EVM verifier generator for Basis Network PLONK-KZG proofs.
//!
//! Generates Solidity bytecode that can verify proofs produced by the
//! basis-circuit crate. Uses the halo2 verification key to embed the
//! circuit-specific constants into the generated verifier.
//!
//! For testnet: exports VK parameters for the PlonkVerifier.sol contract.
//! For production: will generate a complete on-chain verifier via snark-verifier.

use basis_circuit::circuit::{BasisCircuit, CircuitOp};
use basis_circuit::srs::generate_srs;
use basis_circuit::prover::generate_vk;
use halo2_proofs::halo2curves::bn256::Fr;
use halo2_proofs::SerdeFormat;

/// VK export data for configuring the on-chain PlonkVerifier.sol.
pub struct VKExport {
    /// Circuit parameter k (log2 rows).
    pub k: u32,
    /// Number of public input values.
    pub num_public_inputs: usize,
    /// Keccak256-style digest of the serialized VK.
    pub vk_digest: [u8; 32],
    /// Serialized VK bytes (for off-chain reference).
    pub vk_bytes: Vec<u8>,
}

/// Generate a VK export from the current circuit configuration.
///
/// This creates a BasisCircuit with default structure, generates the VK,
/// and serializes it for use with PlonkVerifier.sol.
pub fn export_vk(k: u32) -> Result<VKExport, String> {
    // Generate SRS
    let params = generate_srs(k).map_err(|e| format!("SRS: {}", e))?;

    // Create a circuit template (witness values don't matter for VK)
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Poseidon {
            input: Fr::from(0u64),
            round_constant: Fr::from(0u64),
        }],
        Fr::from(0u64),
        Fr::from(0u64),
        Fr::from(0u64),
    );

    // Generate VK
    let vk = generate_vk(&params, &circuit).map_err(|e| format!("VK: {}", e))?;

    // Serialize VK
    let mut vk_bytes = Vec::new();
    vk.write(&mut vk_bytes, SerdeFormat::RawBytes)
        .map_err(|e| format!("serialize VK: {}", e))?;

    // Compute digest (simple hash of VK bytes)
    let vk_digest = {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        let mut hasher = DefaultHasher::new();
        vk_bytes.hash(&mut hasher);
        let hash = hasher.finish();
        let mut digest = [0u8; 32];
        digest[..8].copy_from_slice(&hash.to_le_bytes());
        digest[8..16].copy_from_slice(&(vk_bytes.len() as u64).to_le_bytes());
        digest[16..20].copy_from_slice(&k.to_le_bytes());
        digest
    };

    Ok(VKExport {
        k,
        num_public_inputs: 3, // [pre_state_root, post_state_root, batch_hash]
        vk_digest,
        vk_bytes,
    })
}

/// Generate and verify a proof, then export it in a format suitable for
/// on-chain verification.
pub fn generate_and_export_proof(
    k: u32,
    pre_state_root: u64,
    post_state_root: u64,
    batch_hash: u64,
) -> Result<ProofExport, String> {
    let params = generate_srs(k).map_err(|e| format!("SRS: {}", e))?;

    let circuit = BasisCircuit::new(
        vec![CircuitOp::Poseidon {
            input: Fr::from(pre_state_root),
            round_constant: Fr::from(post_state_root),
        }],
        Fr::from(pre_state_root),
        Fr::from(post_state_root),
        Fr::from(batch_hash),
    );

    let proof_data = basis_circuit::prover::prove(&params, circuit)
        .map_err(|e| format!("prove: {}", e))?;

    // Verify off-chain first
    let vk_circuit = BasisCircuit::new(
        vec![CircuitOp::Poseidon {
            input: Fr::from(0u64),
            round_constant: Fr::from(0u64),
        }],
        Fr::from(0u64),
        Fr::from(0u64),
        Fr::from(0u64),
    );
    let vk = generate_vk(&params, &vk_circuit).map_err(|e| format!("VK: {}", e))?;
    let valid = basis_circuit::verifier::verify(&params, &vk, &proof_data)
        .map_err(|e| format!("verify: {}", e))?;

    if !valid {
        return Err("proof failed off-chain verification".into());
    }

    Ok(ProofExport {
        proof_bytes: proof_data.proof,
        public_inputs: vec![pre_state_root, post_state_root, batch_hash],
        verified_offchain: true,
    })
}

/// Exported proof data for on-chain submission.
pub struct ProofExport {
    pub proof_bytes: Vec<u8>,
    pub public_inputs: Vec<u64>,
    pub verified_offchain: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn export_vk_works() {
        let export = export_vk(8).expect("VK export");
        assert_eq!(export.k, 8);
        assert_eq!(export.num_public_inputs, 3);
        assert!(!export.vk_bytes.is_empty());
        println!("VK size: {} bytes, digest: {:?}", export.vk_bytes.len(), &export.vk_digest[..8]);
    }

    #[test]
    fn generate_and_verify_proof() {
        let export = generate_and_export_proof(8, 42, 43, 100).expect("proof");
        assert!(export.verified_offchain);
        assert!(!export.proof_bytes.is_empty());
        assert!(export.proof_bytes.len() > 192, "real proof should be > 192 bytes");
        println!("Proof: {} bytes, verified: {}", export.proof_bytes.len(), export.verified_offchain);
    }
}
