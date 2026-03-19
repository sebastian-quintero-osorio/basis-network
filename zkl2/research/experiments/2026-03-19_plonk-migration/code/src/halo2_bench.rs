// halo2-KZG Benchmark using PSE halo2 fork (KZG on BN254)
//
// Implements two circuit types with PLONKish custom gates:
// 1. Arithmetic chain: custom multiply-add gate (simulates EVM arithmetic)
// 2. Hash chain: custom x^5 + c gate (simulates Poseidon S-box)
//
// Demonstrates custom gate constraint reduction vs R1CS.

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
use rand_chacha::ChaCha20Rng;
use rand::SeedableRng;
use std::time::Instant;

use crate::BenchmarkResult;

// --- Circuit 1: Arithmetic Chain with Custom Gate ---
// Custom gate: s * (a * b + a - c) = 0
// One PLONKish row captures multiply-add: c = a * a + a
// Compared to R1CS which needs 2 constraints for the same operation.
#[derive(Clone, Debug)]
struct ArithChainConfig {
    advice: [Column<Advice>; 2],
    selector: Selector,
    instance: Column<Instance>,
}

#[derive(Clone)]
struct ArithChainCircuit {
    x: Value<Fr>,
    chain_length: usize,
}

impl Circuit<Fr> for ArithChainCircuit {
    type Config = ArithChainConfig;
    type FloorPlanner = SimpleFloorPlanner;
    type Params = ();

    fn without_witnesses(&self) -> Self {
        Self {
            x: Value::unknown(),
            chain_length: self.chain_length,
        }
    }

    fn configure(meta: &mut ConstraintSystem<Fr>) -> Self::Config {
        let advice = [meta.advice_column(), meta.advice_column()];
        let selector = meta.selector();
        let instance = meta.instance_column();

        meta.enable_equality(advice[0]);
        meta.enable_equality(advice[1]);
        meta.enable_equality(instance);

        // Custom gate: s * (a[0] * a[0] + a[0] - a[1]) = 0
        // This captures "next = current^2 + current" in a SINGLE row.
        // In R1CS, this requires 2 constraints (1 mul + 1 add enforcement).
        meta.create_gate("multiply-add", |meta| {
            let s = meta.query_selector(selector);
            let a = meta.query_advice(advice[0], halo2_proofs::poly::Rotation::cur());
            let b = meta.query_advice(advice[1], halo2_proofs::poly::Rotation::cur());
            // Constraint: a * a + a = b
            vec![s * (a.clone() * a.clone() + a - b)]
        });

        ArithChainConfig {
            advice,
            selector,
            instance,
        }
    }

    fn synthesize(
        &self,
        config: Self::Config,
        mut layouter: impl Layouter<Fr>,
    ) -> Result<(), Error> {
        let out = layouter.assign_region(
            || "arithmetic chain",
            |mut region| {
                let mut current = region.assign_advice(
                    || "x",
                    config.advice[0],
                    0,
                    || self.x,
                )?;

                for i in 0..self.chain_length {
                    config.selector.enable(&mut region, i)?;

                    let next_val = current.value().map(|v| *v * *v + *v);
                    let next = region.assign_advice(
                        || format!("step-{}", i),
                        config.advice[1],
                        i,
                        || next_val,
                    )?;

                    if i + 1 < self.chain_length {
                        // Copy next -> current for the next iteration
                        let copied = region.assign_advice(
                            || format!("copy-{}", i + 1),
                            config.advice[0],
                            i + 1,
                            || next_val,
                        )?;
                        region.constrain_equal(next.cell(), copied.cell())?;
                    }

                    current = next;
                }

                Ok(current)
            },
        )?;

        // Expose the final output as a public instance
        layouter.constrain_instance(out.cell(), config.instance, 0)?;

        Ok(())
    }
}

// --- Circuit 2: Hash Chain with Custom Gate ---
// Custom gate: s * (a^5 + c - b) = 0
// This captures the Poseidon S-box (x^5 + round_constant) in effectively
// fewer constraints than R1CS (which needs 3 multiplication constraints for x^5).
//
// In halo2, we use a degree-5 gate. The quotient polynomial increases in degree
// but we save rows (and thus FFT size).
#[derive(Clone, Debug)]
struct HashChainConfig {
    advice: [Column<Advice>; 2],
    fixed: Column<Fixed>,
    selector: Selector,
    instance: Column<Instance>,
}

#[derive(Clone)]
struct HashChainCircuit {
    x: Value<Fr>,
    chain_length: usize,
}

impl Circuit<Fr> for HashChainCircuit {
    type Config = HashChainConfig;
    type FloorPlanner = SimpleFloorPlanner;
    type Params = ();

    fn without_witnesses(&self) -> Self {
        Self {
            x: Value::unknown(),
            chain_length: self.chain_length,
        }
    }

    fn configure(meta: &mut ConstraintSystem<Fr>) -> Self::Config {
        let advice = [meta.advice_column(), meta.advice_column()];
        let fixed = meta.fixed_column();
        let selector = meta.selector();
        let instance = meta.instance_column();

        meta.enable_equality(advice[0]);
        meta.enable_equality(advice[1]);
        meta.enable_equality(instance);

        // Custom gate for x^5 + c:
        // We decompose into two rows to keep degree manageable:
        // Row i: a[0] = x, a[1] = x^2 (intermediate)
        // Then: s * (a[0] * a[0] - a[1]) = 0  [x^2 check]
        // We use a simpler approach: a[0]=input, a[1]=output
        // Constraint: a[0]^5 + fixed_const - a[1] = 0
        // This is a degree-5 gate (higher degree = fewer rows, more prover work per row)
        meta.create_gate("sbox-round", |meta| {
            let s = meta.query_selector(selector);
            let input = meta.query_advice(advice[0], halo2_proofs::poly::Rotation::cur());
            let output = meta.query_advice(advice[1], halo2_proofs::poly::Rotation::cur());
            let round_const = meta.query_fixed(fixed, halo2_proofs::poly::Rotation::cur());
            // x^5 = x * x * x * x * x
            let x2 = input.clone() * input.clone();
            let x4 = x2.clone() * x2;
            let x5 = x4 * input;
            vec![s * (x5 + round_const - output)]
        });

        HashChainConfig {
            advice,
            fixed,
            selector,
            instance,
        }
    }

    fn synthesize(
        &self,
        config: Self::Config,
        mut layouter: impl Layouter<Fr>,
    ) -> Result<(), Error> {
        let round_const = Fr::from(7u64);

        let out = layouter.assign_region(
            || "hash chain",
            |mut region| {
                let mut current = region.assign_advice(
                    || "x",
                    config.advice[0],
                    0,
                    || self.x,
                )?;

                for i in 0..self.chain_length {
                    config.selector.enable(&mut region, i)?;

                    // Assign round constant
                    region.assign_fixed(
                        || format!("rc-{}", i),
                        config.fixed,
                        i,
                        || Value::known(round_const),
                    )?;

                    // Compute x^5 + c
                    let next_val = current.value().map(|v| {
                        let x2 = *v * *v;
                        let x4 = x2 * x2;
                        let x5 = x4 * *v;
                        x5 + round_const
                    });

                    let next = region.assign_advice(
                        || format!("out-{}", i),
                        config.advice[1],
                        i,
                        || next_val,
                    )?;

                    if i + 1 < self.chain_length {
                        let copied = region.assign_advice(
                            || format!("copy-{}", i + 1),
                            config.advice[0],
                            i + 1,
                            || next_val,
                        )?;
                        region.constrain_equal(next.cell(), copied.cell())?;
                    }

                    current = next;
                }

                Ok(current)
            },
        )?;

        layouter.constrain_instance(out.cell(), config.instance, 0)?;

        Ok(())
    }
}

fn compute_arithmetic_chain(x: Fr, chain_length: usize) -> Fr {
    let mut current = x;
    for _ in 0..chain_length {
        current = current * current + current;
    }
    current
}

fn compute_hash_chain(x: Fr, chain_length: usize) -> Fr {
    let round_const = Fr::from(7u64);
    let mut current = x;
    for _ in 0..chain_length {
        let x2 = current * current;
        let x4 = x2 * x2;
        let x5 = x4 * current;
        current = x5 + round_const;
    }
    current
}

fn determine_k(chain_length: usize) -> u32 {
    // k determines the circuit size: 2^k rows
    // Need at least chain_length + some overhead for blinding rows
    let min_rows = chain_length + 10; // padding + blinding
    let mut k = 4u32;
    while (1usize << k) < min_rows {
        k += 1;
    }
    k.max(4) // minimum k=4
}

pub fn bench_arithmetic_chain(
    chain_length: usize,
    num_warmup: usize,
    num_iterations: usize,
) -> BenchmarkResult {
    let k = determine_k(chain_length);
    let mut rng = ChaCha20Rng::seed_from_u64(42);

    // Setup: generate universal SRS (reusable across circuits)
    let setup_start = Instant::now();
    let params: ParamsKZG<Bn256> = ParamsKZG::setup(k, &mut rng);
    let setup_srs_time = setup_start.elapsed();

    // Keygen (circuit-specific but uses universal SRS)
    let empty_circuit = ArithChainCircuit {
        x: Value::unknown(),
        chain_length,
    };
    let keygen_start = Instant::now();
    let vk = keygen_vk(&params, &empty_circuit).expect("keygen_vk failed");
    let pk = keygen_pk(&params, vk.clone(), &empty_circuit).expect("keygen_pk failed");
    let keygen_time = keygen_start.elapsed();

    let total_setup_ms = (setup_srs_time + keygen_time).as_secs_f64() * 1000.0;
    let num_rows = 1usize << k;

    // Warmup
    for _ in 0..num_warmup {
        let x = Fr::from(rand::random::<u64>());
        let output = compute_arithmetic_chain(x, chain_length);
        let circuit = ArithChainCircuit {
            x: Value::known(x),
            chain_length,
        };

        let mut transcript = Blake2bWrite::<Vec<u8>, G1Affine, Challenge255<_>>::init(Vec::new());
        create_proof::<KZGCommitmentScheme<Bn256>, ProverSHPLONK<Bn256>, _, _, _, _>(
            &params, &pk, &[circuit], &[&[&[output]]], &mut rng, &mut transcript,
        ).unwrap();
    }

    // Benchmark
    let mut prove_times = Vec::with_capacity(num_iterations);
    let mut verify_times = Vec::with_capacity(num_iterations);
    let mut proof_size = 0usize;

    for i in 0..num_iterations {
        let x = Fr::from(rand::random::<u64>());
        let output = compute_arithmetic_chain(x, chain_length);
        let circuit = ArithChainCircuit {
            x: Value::known(x),
            chain_length,
        };

        let prove_start = Instant::now();
        let mut transcript = Blake2bWrite::<Vec<u8>, G1Affine, Challenge255<_>>::init(Vec::new());
        create_proof::<KZGCommitmentScheme<Bn256>, ProverSHPLONK<Bn256>, _, _, _, _>(
            &params, &pk, &[circuit], &[&[&[output]]], &mut rng, &mut transcript,
        ).unwrap();
        let proof = transcript.finalize();
        prove_times.push(prove_start.elapsed().as_secs_f64() * 1000.0);

        if i == 0 {
            proof_size = proof.len();
        }

        let verify_start = Instant::now();
        let mut transcript = Blake2bRead::<&[u8], G1Affine, Challenge255<_>>::init(&proof[..]);
        let strategy = SingleStrategy::new(&params);
        verify_proof::<KZGCommitmentScheme<Bn256>, VerifierSHPLONK<Bn256>, _, _, _>(
            &params, &vk, strategy, &[&[&[output]]], &mut transcript,
        ).unwrap();
        verify_times.push(verify_start.elapsed().as_secs_f64() * 1000.0);
    }

    let avg_prove: f64 = prove_times.iter().sum::<f64>() / num_iterations as f64;
    let avg_verify: f64 = verify_times.iter().sum::<f64>() / num_iterations as f64;

    println!("    k={}, rows={}, prove={:.1}ms, verify={:.1}ms, proof={}B",
        k, num_rows, avg_prove, avg_verify, proof_size);

    BenchmarkResult {
        system: "halo2-kzg".to_string(),
        circuit: format!("arith-{}", chain_length),
        num_constraints_or_rows: num_rows,
        setup_time_ms: total_setup_ms,
        proving_time_ms: avg_prove,
        verification_time_ms: avg_verify,
        proof_size_bytes: proof_size,
        setup_type: "universal SRS".to_string(),
        custom_gates: true,
        num_iterations,
    }
}

pub fn bench_hash_chain(
    chain_length: usize,
    num_warmup: usize,
    num_iterations: usize,
) -> BenchmarkResult {
    let k = determine_k(chain_length);
    let mut rng = ChaCha20Rng::seed_from_u64(42);

    let setup_start = Instant::now();
    let params: ParamsKZG<Bn256> = ParamsKZG::setup(k, &mut rng);
    let setup_srs_time = setup_start.elapsed();

    let empty_circuit = HashChainCircuit {
        x: Value::unknown(),
        chain_length,
    };
    let keygen_start = Instant::now();
    let vk = keygen_vk(&params, &empty_circuit).expect("keygen_vk failed");
    let pk = keygen_pk(&params, vk.clone(), &empty_circuit).expect("keygen_pk failed");
    let keygen_time = keygen_start.elapsed();

    let total_setup_ms = (setup_srs_time + keygen_time).as_secs_f64() * 1000.0;
    let num_rows = 1usize << k;

    // Warmup
    for _ in 0..num_warmup {
        let x = Fr::from(rand::random::<u64>());
        let output = compute_hash_chain(x, chain_length);
        let circuit = HashChainCircuit {
            x: Value::known(x),
            chain_length,
        };

        let mut transcript = Blake2bWrite::<Vec<u8>, G1Affine, Challenge255<_>>::init(Vec::new());
        create_proof::<KZGCommitmentScheme<Bn256>, ProverSHPLONK<Bn256>, _, _, _, _>(
            &params, &pk, &[circuit], &[&[&[output]]], &mut rng, &mut transcript,
        ).unwrap();
    }

    let mut prove_times = Vec::with_capacity(num_iterations);
    let mut verify_times = Vec::with_capacity(num_iterations);
    let mut proof_size = 0usize;

    for i in 0..num_iterations {
        let x = Fr::from(rand::random::<u64>());
        let output = compute_hash_chain(x, chain_length);
        let circuit = HashChainCircuit {
            x: Value::known(x),
            chain_length,
        };

        let prove_start = Instant::now();
        let mut transcript = Blake2bWrite::<Vec<u8>, G1Affine, Challenge255<_>>::init(Vec::new());
        create_proof::<KZGCommitmentScheme<Bn256>, ProverSHPLONK<Bn256>, _, _, _, _>(
            &params, &pk, &[circuit], &[&[&[output]]], &mut rng, &mut transcript,
        ).unwrap();
        let proof = transcript.finalize();
        prove_times.push(prove_start.elapsed().as_secs_f64() * 1000.0);

        if i == 0 {
            proof_size = proof.len();
        }

        let verify_start = Instant::now();
        let mut transcript = Blake2bRead::<&[u8], G1Affine, Challenge255<_>>::init(&proof[..]);
        let strategy = SingleStrategy::new(&params);
        verify_proof::<KZGCommitmentScheme<Bn256>, VerifierSHPLONK<Bn256>, _, _, _>(
            &params, &vk, strategy, &[&[&[output]]], &mut transcript,
        ).unwrap();
        verify_times.push(verify_start.elapsed().as_secs_f64() * 1000.0);
    }

    let avg_prove: f64 = prove_times.iter().sum::<f64>() / num_iterations as f64;
    let avg_verify: f64 = verify_times.iter().sum::<f64>() / num_iterations as f64;

    println!("    k={}, rows={}, prove={:.1}ms, verify={:.1}ms, proof={}B",
        k, num_rows, avg_prove, avg_verify, proof_size);

    BenchmarkResult {
        system: "halo2-kzg".to_string(),
        circuit: format!("hash-{}", chain_length),
        num_constraints_or_rows: num_rows,
        setup_time_ms: total_setup_ms,
        proving_time_ms: avg_prove,
        verification_time_ms: avg_verify,
        proof_size_bytes: proof_size,
        setup_type: "universal SRS".to_string(),
        custom_gates: true,
        num_iterations,
    }
}
