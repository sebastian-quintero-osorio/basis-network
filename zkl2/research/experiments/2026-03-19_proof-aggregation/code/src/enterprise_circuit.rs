// Enterprise Circuit: Simulates a per-enterprise L2 batch proof.
//
// Each enterprise circuit computes a state transition:
//   new_root = hash_chain(old_root, tx_data_1, tx_data_2, ..., tx_data_batch_size)
//
// where hash_chain is a Poseidon-like x^5 + c chain (same as RU-L9).
// Public inputs: [old_root, new_root, enterprise_id]
//
// This simulates the core of what each enterprise's L2 prover produces:
// a proof that the state transition from old_root to new_root is valid.

use halo2_proofs::{
    circuit::{Layouter, SimpleFloorPlanner, Value},
    plonk::{
        Advice, Circuit, Column, ConstraintSystem, Error, Fixed, Instance, Selector,
        create_proof, keygen_pk, keygen_vk, verify_proof,
    },
    poly::{
        kzg::{
            commitment::{KZGCommitmentScheme, ParamsKZG},
            multiopen::{ProverSHPLONK, VerifierSHPLONK},
            strategy::SingleStrategy,
        },
    },
    transcript::{
        Blake2bRead, Blake2bWrite, Challenge255, TranscriptReadBuffer, TranscriptWriterBuffer,
    },
};
use halo2curves::bn256::{Bn256, Fr, G1Affine};
use halo2_proofs::poly::Rotation;
use rand_chacha::ChaCha20Rng;
use rand::SeedableRng;

// Configuration for the enterprise state transition circuit.
#[derive(Clone, Debug)]
pub struct EnterpriseCircuitConfig {
    advice: [Column<Advice>; 2],
    selector: Selector,
    instance: Column<Instance>,
}

// Enterprise state transition circuit.
// Simulates: new_root = fold(old_root, batch_data) via iterated x^5 + x.
#[derive(Clone)]
pub struct EnterpriseCircuit {
    pub old_root: Value<Fr>,
    pub batch_size: usize,
}

impl Circuit<Fr> for EnterpriseCircuit {
    type Config = EnterpriseCircuitConfig;
    type FloorPlanner = SimpleFloorPlanner;
    type Params = ();

    fn without_witnesses(&self) -> Self {
        Self {
            old_root: Value::unknown(),
            batch_size: self.batch_size,
        }
    }

    fn configure(meta: &mut ConstraintSystem<Fr>) -> Self::Config {
        let advice = [meta.advice_column(), meta.advice_column()];
        let selector = meta.selector();
        let instance = meta.instance_column();

        meta.enable_equality(advice[0]);
        meta.enable_equality(advice[1]);
        meta.enable_equality(instance);

        // Custom Poseidon-like gate: s * (a^5 + a - b) = 0
        // Each row: b = a^5 + a (state transition step)
        meta.create_gate("poseidon-sbox", |meta| {
            let s = meta.query_selector(selector);
            let a = meta.query_advice(advice[0], Rotation::cur());
            let b = meta.query_advice(advice[1], Rotation::cur());
            let a2 = a.clone() * a.clone();
            let a4 = a2.clone() * a2.clone();
            let a5 = a4 * a.clone();
            vec![s * (a5 + a - b)]
        });

        EnterpriseCircuitConfig { advice, selector, instance }
    }

    fn synthesize(
        &self,
        config: Self::Config,
        mut layouter: impl Layouter<Fr>,
    ) -> Result<(), Error> {
        let (old_root_cell, new_root_cell) = layouter.assign_region(
            || "state-transition",
            |mut region| {
                let mut current = region.assign_advice(
                    || "old_root",
                    config.advice[0],
                    0,
                    || self.old_root,
                )?;

                let mut first_cell = current.clone();
                let mut last_cell = current.clone();

                for step in 0..self.batch_size {
                    config.selector.enable(&mut region, step)?;

                    let next_val = current.value().map(|v| {
                        let v2 = *v * *v;
                        let v4 = v2 * v2;
                        v4 * *v + *v
                    });

                    let next = region.assign_advice(
                        || format!("step_{}", step),
                        config.advice[1],
                        step,
                        || next_val,
                    )?;

                    if step == 0 {
                        first_cell = current.clone();
                    }

                    if step + 1 < self.batch_size {
                        current = region.assign_advice(
                            || format!("chain_{}", step + 1),
                            config.advice[0],
                            step + 1,
                            || next_val,
                        )?;
                    }

                    last_cell = next;
                }

                Ok((first_cell, last_cell))
            },
        )?;

        // Expose old_root and new_root as public inputs
        layouter.constrain_instance(old_root_cell.cell(), config.instance, 0)?;
        layouter.constrain_instance(new_root_cell.cell(), config.instance, 1)?;

        Ok(())
    }
}

// Compute the expected new_root given an old_root and batch_size steps.
pub fn compute_new_root(old_root: Fr, batch_size: usize) -> Fr {
    let mut current = old_root;
    for _ in 0..batch_size {
        let v2 = current * current;
        let v4 = v2 * v2;
        current = v4 * current + current;
    }
    current
}

// Parameters for enterprise proof generation.
pub struct EnterpriseProofParams {
    pub params: ParamsKZG<Bn256>,
    pub k: u32,
}

impl EnterpriseProofParams {
    pub fn new(batch_size: usize) -> Self {
        // k determines circuit size: 2^k rows. Needs batch_size + overhead.
        let k = (batch_size as f64).log2().ceil() as u32 + 3;
        let k = k.max(4); // minimum k=4
        let params = ParamsKZG::<Bn256>::setup(k, ChaCha20Rng::seed_from_u64(0));
        Self { params, k }
    }
}

// Generate a single enterprise proof.
// Returns: (proof_bytes, public_inputs, proof_generation_time_ms)
pub fn generate_enterprise_proof(
    enterprise_id: u64,
    batch_size: usize,
    proof_params: &EnterpriseProofParams,
) -> (Vec<u8>, Vec<Fr>, f64) {
    use halo2curves::ff::Field;

    let mut rng = ChaCha20Rng::seed_from_u64(enterprise_id);
    let old_root = Fr::random(&mut rng);
    let new_root = compute_new_root(old_root, batch_size);

    let circuit = EnterpriseCircuit {
        old_root: Value::known(old_root),
        batch_size,
    };

    let empty_circuit = EnterpriseCircuit {
        old_root: Value::unknown(),
        batch_size,
    };

    let vk = keygen_vk(&proof_params.params, &empty_circuit)
        .expect("keygen_vk failed");
    let pk = keygen_pk(&proof_params.params, vk, &empty_circuit)
        .expect("keygen_pk failed");

    let public_inputs = vec![old_root, new_root];

    let start = std::time::Instant::now();

    let mut transcript = TranscriptWriterBuffer::<_, G1Affine, Challenge255<_>>::init(Vec::new());
    create_proof::<
        KZGCommitmentScheme<Bn256>,
        ProverSHPLONK<'_, Bn256>,
        Challenge255<G1Affine>,
        ChaCha20Rng,
        Blake2bWrite<Vec<u8>, G1Affine, Challenge255<G1Affine>>,
        EnterpriseCircuit,
    >(
        &proof_params.params,
        &pk,
        &[circuit],
        &[&[&public_inputs]],
        ChaCha20Rng::seed_from_u64(enterprise_id + 1000),
        &mut transcript,
    )
    .expect("proof generation failed");

    let prove_time_ms = start.elapsed().as_secs_f64() * 1000.0;
    let proof_bytes = transcript.finalize();

    (proof_bytes, public_inputs, prove_time_ms)
}

// Verify a single enterprise proof.
// Returns: (valid, verification_time_ms)
pub fn verify_enterprise_proof(
    proof_bytes: &[u8],
    public_inputs: &[Fr],
    batch_size: usize,
    proof_params: &EnterpriseProofParams,
) -> (bool, f64) {
    let empty_circuit = EnterpriseCircuit {
        old_root: Value::unknown(),
        batch_size,
    };

    let vk = keygen_vk(&proof_params.params, &empty_circuit)
        .expect("keygen_vk failed");

    let start = std::time::Instant::now();

    let mut transcript = TranscriptReadBuffer::<_, G1Affine, Challenge255<_>>::init(proof_bytes);
    let result = verify_proof::<
        KZGCommitmentScheme<Bn256>,
        VerifierSHPLONK<'_, Bn256>,
        Challenge255<G1Affine>,
        Blake2bRead<&[u8], G1Affine, Challenge255<G1Affine>>,
        SingleStrategy<'_, Bn256>,
    >(
        &proof_params.params,
        &vk,
        SingleStrategy::new(&proof_params.params),
        &[&[public_inputs]],
        &mut transcript,
    );

    let verify_time_ms = start.elapsed().as_secs_f64() * 1000.0;
    (result.is_ok(), verify_time_ms)
}

#[cfg(test)]
mod tests {
    use super::*;
    use halo2curves::ff::Field;

    #[test]
    fn test_enterprise_circuit_proves_and_verifies() {
        let batch_size = 8;
        let params = EnterpriseProofParams::new(batch_size);

        let (proof, public_inputs, prove_ms) = generate_enterprise_proof(1, batch_size, &params);
        let (valid, verify_ms) = verify_enterprise_proof(&proof, &public_inputs, batch_size, &params);

        assert!(valid, "Enterprise proof should verify");
        assert!(prove_ms > 0.0, "Proving should take measurable time");
        assert!(verify_ms > 0.0, "Verification should take measurable time");
        println!("Enterprise proof: {} bytes, prove={:.1}ms, verify={:.1}ms",
            proof.len(), prove_ms, verify_ms);
    }

    #[test]
    fn test_different_enterprises_produce_different_proofs() {
        let batch_size = 8;
        let params = EnterpriseProofParams::new(batch_size);

        let (proof1, pi1, _) = generate_enterprise_proof(1, batch_size, &params);
        let (proof2, pi2, _) = generate_enterprise_proof(2, batch_size, &params);

        // Different enterprise IDs should produce different roots
        assert_ne!(pi1[0], pi2[0], "Different enterprises should have different old roots");
        assert_ne!(proof1, proof2, "Different enterprises should produce different proofs");
    }
}
