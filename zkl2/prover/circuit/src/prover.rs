/// Proof generation pipeline for the Basis Network PLONK circuit.
///
/// Implements the complete proving workflow:
///   1. Key generation (vk + pk from circuit + SRS)
///   2. Proof creation (witness assignment + PLONK proving)
///   3. Proof serialization (for submission to L1 contract)
///
/// Uses halo2-KZG with SHPLONK multiopen strategy on BN254, producing
/// proofs of 500-900 bytes verifiable on-chain via EIP-196/197 precompiles.
///
/// [Spec: lab/3-architect/implementation-history/prover-plonk-migration/specs/PlonkMigration.tla]
use halo2_proofs::{
    halo2curves::bn256::{Bn256, Fr, G1Affine},
    plonk::{self, keygen_pk, keygen_vk, ProvingKey, VerifyingKey},
    poly::kzg::{commitment::ParamsKZG, multiopen::ProverSHPLONK},
    transcript::{Blake2bWrite, Challenge255, TranscriptWriterBuffer},
};
use halo2_solidity_verifier::Keccak256Transcript;
use rand::rngs::OsRng;

use crate::circuit::BasisCircuit;
use crate::types::{CircuitError, CircuitResult, ProofData, ProofSystem};

// ---------------------------------------------------------------------------
// Key generation
// ---------------------------------------------------------------------------

/// Generate the verification key for a given circuit shape.
///
/// The verification key encodes the circuit's constraint system (gates,
/// columns, permutations) and is used by both the prover (to generate pk)
/// and the verifier (to check proofs). It is deterministic for a given
/// circuit configuration.
pub fn generate_vk(
    params: &ParamsKZG<Bn256>,
    circuit: &BasisCircuit,
) -> CircuitResult<VerifyingKey<G1Affine>> {
    keygen_vk(params, circuit)
        .map_err(|e| CircuitError::KeygenFailed(format!("vk generation failed: {}", e)))
}

/// Generate the proving key from a verification key and circuit.
///
/// The proving key contains all precomputed data needed for efficient
/// proof generation. It is large (proportional to circuit size) but
/// reusable across all proofs for the same circuit configuration.
pub fn generate_pk(
    params: &ParamsKZG<Bn256>,
    vk: VerifyingKey<G1Affine>,
    circuit: &BasisCircuit,
) -> CircuitResult<ProvingKey<G1Affine>> {
    keygen_pk(params, vk, circuit)
        .map_err(|e| CircuitError::KeygenFailed(format!("pk generation failed: {}", e)))
}

// ---------------------------------------------------------------------------
// Proof generation
// ---------------------------------------------------------------------------

/// Generate a PLONK proof for a given circuit instance.
///
/// Takes concrete witness values (in the circuit's operations) and produces
/// a serialized proof that can be verified on-chain or off-chain.
///
/// The proof includes:
/// - Polynomial commitments (KZG commitments on BN254)
/// - Opening proofs (SHPLONK multiopen)
/// - Evaluated witness polynomials at challenge points
///
/// Returns a ProofData struct containing the serialized proof, public inputs,
/// and proof system identifier.
pub fn create_proof(
    params: &ParamsKZG<Bn256>,
    pk: &ProvingKey<G1Affine>,
    circuit: BasisCircuit,
) -> CircuitResult<ProofData> {
    let public_inputs = vec![
        circuit.pre_state_root,
        circuit.post_state_root,
        circuit.batch_hash,
    ];

    // Instance: vector of vectors (one per instance column)
    let instances = [public_inputs.clone()];
    let instance_refs: Vec<&[Fr]> = instances.iter().map(|v| v.as_slice()).collect();

    // Create transcript for Fiat-Shamir
    let mut transcript = Blake2bWrite::<_, G1Affine, Challenge255<_>>::init(vec![]);

    // Generate the PLONK proof
    plonk::create_proof::<_, ProverSHPLONK<Bn256>, _, _, _, _>(
        params,
        pk,
        &[circuit],
        &[instance_refs.as_slice()],
        OsRng,
        &mut transcript,
    )
    .map_err(|e| CircuitError::ProofGenerationFailed(format!("PLONK proof failed: {}", e)))?;

    let proof_bytes = transcript.finalize();

    Ok(ProofData {
        proof: proof_bytes,
        public_inputs,
        proof_system: ProofSystem::Plonk,
    })
}

/// Generate a PLONK proof using Keccak256 transcript for EVM verification.
///
/// This produces a proof compatible with the generated Halo2Verifier.sol contract,
/// which uses Keccak256 for Fiat-Shamir challenge derivation (not Blake2b).
/// The EVM does not have a Blake2b precompile, so on-chain verifiers must use Keccak256.
pub fn create_proof_evm(
    params: &ParamsKZG<Bn256>,
    pk: &ProvingKey<G1Affine>,
    circuit: BasisCircuit,
) -> CircuitResult<ProofData> {
    let public_inputs = vec![
        circuit.pre_state_root,
        circuit.post_state_root,
        circuit.batch_hash,
    ];

    let instances = [public_inputs.clone()];
    let instance_refs: Vec<&[Fr]> = instances.iter().map(|v| v.as_slice()).collect();

    // Use Keccak256 transcript for EVM compatibility
    let mut transcript = Keccak256Transcript::new(vec![]);

    plonk::create_proof::<_, ProverSHPLONK<Bn256>, _, _, _, _>(
        params,
        pk,
        &[circuit],
        &[instance_refs.as_slice()],
        OsRng,
        &mut transcript,
    )
    .map_err(|e| CircuitError::ProofGenerationFailed(format!("PLONK-Keccak proof failed: {}", e)))?;

    let proof_bytes = transcript.finalize();

    Ok(ProofData {
        proof: proof_bytes,
        public_inputs,
        proof_system: ProofSystem::Plonk,
    })
}

/// Convenience function: keygen + prove in one step (Keccak256 transcript, EVM-compatible).
pub fn prove_evm(params: &ParamsKZG<Bn256>, circuit: BasisCircuit) -> CircuitResult<ProofData> {
    let vk = generate_vk(params, &circuit)?;
    let pk = generate_pk(params, vk, &circuit)?;
    create_proof_evm(params, &pk, circuit)
}

/// Convenience function: keygen + prove in one step.
///
/// Generates fresh keys from the SRS and circuit, then produces a proof.
/// For production use, prefer caching the keys and calling `create_proof` directly.
pub fn prove(params: &ParamsKZG<Bn256>, circuit: BasisCircuit) -> CircuitResult<ProofData> {
    let vk = generate_vk(params, &circuit)?;
    let pk = generate_pk(params, vk, &circuit)?;
    create_proof(params, &pk, circuit)
}
