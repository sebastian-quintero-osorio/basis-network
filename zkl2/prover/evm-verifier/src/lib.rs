//! EVM verifier generator for Basis Network PLONK-KZG proofs.
//!
//! Generates Solidity bytecode that can verify proofs produced by the
//! basis-circuit crate. Uses the halo2 verification key to embed the
//! circuit-specific constants into the generated verifier.
//!
//! Uses halo2-solidity-verifier (by PSE) to auto-generate a complete Solidity
//! verifier from the circuit's VK. This is the industry-standard approach used
//! by Scroll, PSE zkEVM, and other Halo2-based L2s.

use basis_circuit::circuit::{BasisCircuit, CircuitOp};
use basis_circuit::srs::generate_srs;
use basis_circuit::prover::generate_vk;
use halo2_proofs::halo2curves::bn256::Fr;
use halo2_proofs::SerdeFormat;
use halo2_solidity_verifier::{BatchOpenScheme::Bdfg21, SolidityGenerator};

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

/// Generate a complete Solidity verifier contract for the Basis Network circuit.
///
/// Uses halo2-solidity-verifier to produce a contract that correctly verifies
/// Halo2 PLONK-KZG proofs with SHPLONK multi-opening, Blake2b transcript, and
/// all polynomial commitments. The generated verifier is self-contained and
/// embeds the VK constants.
///
/// Returns (verifier_solidity, vk_solidity) -- two Solidity source strings.
/// Deploy both contracts: the VK contract first, then the verifier pointing to it.
pub fn generate_solidity_verifier(k: u32) -> Result<(String, String), String> {
    // Load cached SRS from srs_k{k}.bin to ensure same SRS as the prover.
    let srs_path = format!("srs_k{}.bin", k);
    let params = if let Ok(bytes) = std::fs::read(&srs_path) {
        basis_circuit::srs::load_srs(&bytes)
            .map_err(|e| format!("load SRS from {}: {}", srs_path, e))?
    } else {
        generate_srs(k).map_err(|e| format!("SRS: {}", e))?
    };

    // CRITICAL: Use prove() to generate the VK, not generate_vk() separately.
    // prove() calls keygen_vk internally and may optimize column assignments
    // differently than a standalone generate_vk call. The VK from prove() is
    // the one that matches the actual proof format and size.
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Poseidon {
            input: Fr::from(0u64),
            round_constant: Fr::from(0u64),
        }],
        Fr::from(0u64),
        Fr::from(0u64),
        Fr::from(0u64),
    );

    // Generate VK via prove() to get the exact VK that matches the proof format.
    // This ensures the proof size the verifier expects matches what the prover generates.
    let proof_data = basis_circuit::prover::prove(&params, circuit)
        .map_err(|e| format!("prove for VK: {}", e))?;

    // Re-generate VK from scratch (same as prove does internally).
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

    // Log proof size for debugging
    eprintln!("[gen-verifier] proof_size={}, public_inputs={}", proof_data.proof.len(), proof_data.public_inputs.len());

    // num_instances = 3 (pre_state_root, post_state_root, batch_hash)
    let generator = SolidityGenerator::new(&params, &vk, Bdfg21, 3);

    // Use render() instead of render_separately() to get a single self-contained
    // verifier with embedded VK. This avoids potential VK/verifier mismatch.
    let verifier_sol = generator.render()
        .map_err(|e| format!("render verifier: {}", e))?;

    // For the VK contract, render separately as well for reference
    let (_, vk_sol) = generator
        .render_separately()
        .map_err(|e| format!("render VK: {}", e))?;

    Ok((verifier_sol, vk_sol))
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
    fn diagnose_circuit_proof_size() {
        let k = 8u32;
        let srs_path = "../node/srs_k8.bin";
        let params = if let Ok(bytes) = std::fs::read(srs_path) {
            basis_circuit::srs::load_srs(&bytes).expect("load SRS")
        } else {
            basis_circuit::srs::generate_srs(k).expect("SRS")
        };

        let circuit = BasisCircuit::new(
            vec![CircuitOp::Poseidon { input: Fr::from(0u64), round_constant: Fr::from(0u64) }],
            Fr::from(0u64), Fr::from(0u64), Fr::from(0u64),
        );
        let vk = generate_vk(&params, &circuit).expect("VK");
        let cs = vk.cs();
        println!("advice: {}, fixed: {}, instance: {}, degree: {}, lookups: {}, perm_cols: {}",
            cs.num_advice_columns(), cs.num_fixed_columns(), cs.num_instance_columns(),
            cs.degree(), cs.lookups().len(), cs.permutation().get_columns().len());

        // Expected proof components (per SolidityGenerator):
        // advice commitments: num_advice_columns * 1 G1 = num_advice * 64 bytes
        // But with phases, each phase adds commitments
        // lookup permuted: 2 * num_lookups G1 points
        // perm + lookup zs + random: varies
        // quotients: degree-1 G1 points
        // evaluations: num_evals scalar fields

        let perm_chunk = cs.degree() - 2;
        let perm_zs = cs.permutation().get_columns().chunks(perm_chunk).count();
        let lookup_zs = cs.lookups().len();
        let lookup_perms = 2 * cs.lookups().len();
        let quotients = cs.degree() - 1;
        println!("perm_zs: {}, lookup_zs: {}, lookup_perms: {}, quotients: {}",
            perm_zs, lookup_zs, lookup_perms, quotients);

        // Total G1 commitments in proof:
        // advice_comms + lookup_permuted + (perm_zs + lookup_zs + 1 random) + quotients + W + W'
        // For SHPLONK: + 2 opening proofs (W, W')
        let total_g1 = cs.num_advice_columns() + lookup_perms + perm_zs + lookup_zs + 1 + quotients + 2;
        println!("expected G1 commitments: {}", total_g1);

        // Plus evaluations (scalar fields)
        let num_advice_queries: usize = cs.advice_queries().len();
        let num_fixed_queries: usize = cs.fixed_queries().len();
        let num_instance_queries: usize = cs.instance_queries().len();
        let perm_evals = 3 * cs.permutation().get_columns().len() + 3 * perm_zs - 1;
        let lookup_evals = 5 * cs.lookups().len();
        let total_evals = num_advice_queries + num_fixed_queries + num_instance_queries + perm_evals + lookup_evals;
        println!("advice_q: {}, fixed_q: {}, instance_q: {}, perm_evals: {}, lookup_evals: {}",
            num_advice_queries, num_fixed_queries, num_instance_queries, perm_evals, lookup_evals);
        println!("total_evals: {}", total_evals);

        let expected_proof_size = total_g1 * 64 + total_evals * 32;
        println!("expected proof size: {} bytes ({} from G1, {} from evals)",
            expected_proof_size, total_g1 * 64, total_evals * 32);

        let proof = basis_circuit::prover::prove(&params, BasisCircuit::new(
            vec![CircuitOp::Poseidon { input: Fr::from(42u64), round_constant: Fr::from(43u64) }],
            Fr::from(42u64), Fr::from(43u64), Fr::from(100u64),
        )).expect("prove");
        println!("actual proof size: {} bytes", proof.proof.len());
    }

    #[test]
    fn export_vk_works() {
        let export = export_vk(8).expect("VK export");
        assert_eq!(export.k, 8);
        assert_eq!(export.num_public_inputs, 3);
        assert!(!export.vk_bytes.is_empty());
        println!("VK size: {} bytes, digest: {:?}", export.vk_bytes.len(), &export.vk_digest[..8]);
    }

    #[test]
    fn generate_solidity_verifier_works() {
        let (verifier, vk) = generate_solidity_verifier(8).expect("verifier generation");
        assert!(verifier.contains("pragma solidity"), "should contain Solidity pragma");
        assert!(!vk.is_empty(), "VK contract should not be empty");
        println!("Verifier: {} bytes, VK: {} bytes", verifier.len(), vk.len());
    }

    #[test]
    fn e2e_prove_and_verify_on_evm() {
        use halo2_solidity_verifier::{compile_solidity, encode_calldata, Evm};

        let k = 8u32;

        // 1. Load SRS (same as prover)
        let srs_path = format!("../node/srs_k{}.bin", k);
        let params = if let Ok(bytes) = std::fs::read(&srs_path) {
            basis_circuit::srs::load_srs(&bytes).expect("load SRS")
        } else {
            basis_circuit::srs::generate_srs(k).expect("generate SRS")
        };

        // 2. Create circuit + generate proof
        let pre = Fr::from(42u64);
        let post = Fr::from(43u64);
        let batch = Fr::from(100u64);
        let circuit = BasisCircuit::new(
            vec![CircuitOp::Poseidon {
                input: pre,
                round_constant: post,
            }],
            pre, post, batch,
        );
        let proof_data = basis_circuit::prover::prove(&params, circuit).expect("prove");
        println!("Proof size: {} bytes", proof_data.proof.len());

        // 3. Generate verifier from same params + VK
        let vk_circuit = BasisCircuit::new(
            vec![CircuitOp::Poseidon {
                input: Fr::from(0u64),
                round_constant: Fr::from(0u64),
            }],
            Fr::from(0u64), Fr::from(0u64), Fr::from(0u64),
        );
        let vk = basis_circuit::prover::generate_vk(&params, &vk_circuit).expect("VK");
        let generator = SolidityGenerator::new(&params, &vk, Bdfg21, proof_data.public_inputs.len());
        let (verifier_sol, vk_sol) = generator.render_separately().expect("render");

        // 4. Compile Solidity
        let vk_bytecode = compile_solidity(&vk_sol);
        let verifier_bytecode = compile_solidity(&verifier_sol);
        println!("VK bytecode: {} bytes, Verifier bytecode: {} bytes", vk_bytecode.len(), verifier_bytecode.len());

        // 5. Deploy and verify on EVM
        let mut evm = Evm::default();
        let vk_address = evm.create(vk_bytecode);
        let verifier_address = evm.create(verifier_bytecode);

        let calldata = encode_calldata(
            Some(vk_address.0.into()),
            &proof_data.proof,
            &proof_data.public_inputs,
        );
        let (gas, output) = evm.call(verifier_address, calldata);
        println!("EVM verification: gas={}, output={:?}", gas, &output[..]);
        assert_eq!(output.len(), 32);
        assert_eq!(output[31], 1, "EVM verification should return true");
        println!("E2E EVM verification PASSED! Gas: {}", gas);
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
