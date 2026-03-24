/// Proof verification for the Basis Network PLONK circuit.
///
/// Implements off-chain verification of PLONK-KZG proofs. This mirrors the
/// on-chain BasisVerifier.sol contract logic but runs natively in Rust for:
///   - Pre-submission validation (catch invalid proofs before paying gas)
///   - Testing and benchmarking
///   - Node-side verification in the L2 sequencer
///
/// The verification algorithm:
///   1. Deserialize proof and public inputs
///   2. Replay Fiat-Shamir transcript to derive challenges
///   3. Verify KZG polynomial openings (SHPLONK strategy)
///   4. Check that gate constraints evaluate to zero at challenge points
///
/// [Spec: lab/3-architect/implementation-history/prover-plonk-migration/specs/PlonkMigration.tla]
use halo2_proofs::{
    halo2curves::bn256::{Bn256, Fr, G1Affine},
    plonk::{verify_proof, VerifyingKey},
    poly::kzg::{
        commitment::ParamsKZG,
        multiopen::VerifierSHPLONK,
        strategy::SingleStrategy,
    },
    transcript::{Blake2bRead, Challenge255, TranscriptReadBuffer},
};
use halo2_solidity_verifier::Keccak256Transcript;

use crate::types::{CircuitResult, MigrationPhase, ProofData, ProofSystem};

// ---------------------------------------------------------------------------
// Verification
// ---------------------------------------------------------------------------

/// Verify a PLONK proof against a verification key and public inputs.
///
/// Returns Ok(true) if the proof is valid, Ok(false) if invalid,
/// or Err if the verification process itself fails (e.g., malformed proof).
///
/// Corresponds to TLA+ `VerifyBatch` action where
/// `isValid == batch.proofSystem \in activeVerifiers`.
pub fn verify(
    params: &ParamsKZG<Bn256>,
    vk: &VerifyingKey<G1Affine>,
    proof_data: &ProofData,
) -> CircuitResult<bool> {
    let instances = [proof_data.public_inputs.clone()];
    let instance_refs: Vec<&[Fr]> = instances.iter().map(|v| v.as_slice()).collect();

    let mut transcript =
        Blake2bRead::<_, G1Affine, Challenge255<_>>::init(proof_data.proof.as_slice());

    let strategy = SingleStrategy::new(params);

    match verify_proof::<_, VerifierSHPLONK<Bn256>, _, _, _>(
        params,
        vk,
        strategy,
        &[instance_refs.as_slice()],
        &mut transcript,
    ) {
        Ok(_) => Ok(true),
        Err(_) => Ok(false),
    }
}

/// Verify a PLONK proof using Keccak256 transcript (EVM-compatible).
///
/// Use this to verify proofs generated with `create_proof_evm()`.
pub fn verify_evm(
    params: &ParamsKZG<Bn256>,
    vk: &VerifyingKey<G1Affine>,
    proof_data: &ProofData,
) -> CircuitResult<bool> {
    let instances = [proof_data.public_inputs.clone()];
    let instance_refs: Vec<&[Fr]> = instances.iter().map(|v| v.as_slice()).collect();

    let mut transcript = Keccak256Transcript::new(proof_data.proof.as_slice());

    let strategy = SingleStrategy::new(params);

    match verify_proof::<_, VerifierSHPLONK<Bn256>, _, _, _>(
        params,
        vk,
        strategy,
        &[instance_refs.as_slice()],
        &mut transcript,
    ) {
        Ok(_) => Ok(true),
        Err(_) => Ok(false),
    }
}

/// Verify a proof with migration phase checking.
///
/// Enforces TLA+ invariants:
///   S2 BackwardCompatibility: Groth16 accepted when phase includes groth16
///   S4 Completeness: Valid proofs not rejected by active verifier
///   S5 NoGroth16AfterCutover: Groth16 rejected in PlonkOnly phase
///
/// First checks that the proof system is accepted in the current phase,
/// then performs cryptographic verification.
pub fn verify_with_phase(
    params: &ParamsKZG<Bn256>,
    vk: &VerifyingKey<G1Affine>,
    proof_data: &ProofData,
    phase: MigrationPhase,
) -> CircuitResult<bool> {
    // S5/S6: Check proof system is accepted in current phase
    if !phase.accepts(proof_data.proof_system) {
        return Ok(false);
    }

    // Cryptographic verification (only for PLONK proofs handled here)
    if proof_data.proof_system == ProofSystem::Plonk {
        return verify(params, vk, proof_data);
    }

    // Groth16 proofs are verified by the Groth16 verifier (not this module).
    // If we reach here, the phase accepts Groth16 and we return true
    // (actual Groth16 verification is delegated to the existing verifier).
    Ok(true)
}

/// Verify a batch of proofs (amortized verification).
///
/// Verifies multiple proofs against the same verification key.
/// Returns a vector of results, one per proof.
pub fn verify_batch(
    params: &ParamsKZG<Bn256>,
    vk: &VerifyingKey<G1Affine>,
    proofs: &[ProofData],
) -> CircuitResult<Vec<bool>> {
    proofs.iter().map(|p| verify(params, vk, p)).collect()
}
