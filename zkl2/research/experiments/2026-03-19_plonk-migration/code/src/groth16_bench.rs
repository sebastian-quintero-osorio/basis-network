// Groth16 Benchmark using arkworks (ark-groth16 on BN254)
//
// Implements two circuit types:
// 1. Arithmetic chain: repeated multiply-add (simulates EVM arithmetic)
// 2. Hash chain: repeated field squaring chain (simulates Poseidon-like ops)

use ark_bn254::{Bn254, Fr};
use ark_ff::Field;
use ark_groth16::Groth16;
use ark_r1cs_std::fields::fp::FpVar;
use ark_r1cs_std::prelude::*;
use ark_relations::r1cs::{ConstraintSynthesizer, ConstraintSystemRef, SynthesisError};
use ark_serialize::CanonicalSerialize;
use ark_snark::SNARK;
use ark_std::rand::rngs::StdRng;
use ark_std::rand::SeedableRng;
use ark_std::UniformRand;
use std::time::Instant;

use crate::BenchmarkResult;

// --- Circuit 1: Arithmetic Chain ---
// Simulates EVM ADD/MUL: z = ((x * x + x) * (x * x + x) + ...) chain_length times
// Each step: one multiplication + one addition = 2 R1CS constraints
#[derive(Clone)]
struct ArithmeticChainCircuit {
    x: Option<Fr>,
    chain_length: usize,
}

impl ConstraintSynthesizer<Fr> for ArithmeticChainCircuit {
    fn generate_constraints(self, cs: ConstraintSystemRef<Fr>) -> Result<(), SynthesisError> {
        let x_val = self.x.unwrap_or(Fr::from(0u64));
        let x_var = FpVar::new_witness(cs.clone(), || Ok(x_val))?;

        let mut current = x_var.clone();

        for _ in 0..self.chain_length {
            // R1CS: current_sq = current * current (1 multiplication constraint)
            let sq = &current * &current;
            // R1CS: next = sq + current (addition is free in R1CS, but enforce via new variable)
            current = &sq + &current;
        }

        // Public output: enforce the final value equals a public input
        let output = FpVar::new_input(cs.clone(), || Ok(current.value().unwrap_or(Fr::from(0u64))))?;
        current.enforce_equal(&output)?;

        Ok(())
    }
}

// --- Circuit 2: Hash Chain ---
// Simulates Poseidon-like hash: repeated x^5 + constant chain
// Each x^5 requires: x^2 = x*x (1 constraint), x^4 = x^2*x^2 (1 constraint),
// x^5 = x^4*x (1 constraint) = 3 R1CS constraints per round
#[derive(Clone)]
struct HashChainCircuit {
    x: Option<Fr>,
    chain_length: usize,
}

impl ConstraintSynthesizer<Fr> for HashChainCircuit {
    fn generate_constraints(self, cs: ConstraintSystemRef<Fr>) -> Result<(), SynthesisError> {
        let x_val = self.x.unwrap_or(Fr::from(0u64));
        let x_var = FpVar::new_witness(cs.clone(), || Ok(x_val))?;

        // Constant for the "round constant" (simulates Poseidon round constants)
        let round_const = FpVar::new_witness(cs.clone(), || Ok(Fr::from(7u64)))?;

        let mut current = x_var;

        for _ in 0..self.chain_length {
            // S-box: x^5 (3 multiplication constraints in R1CS)
            let x2 = &current * &current;        // x^2
            let x4 = &x2 * &x2;                  // x^4
            let x5 = &x4 * &current;             // x^5

            // Add round constant (free in R1CS)
            current = &x5 + &round_const;
        }

        // Public output
        let output = FpVar::new_input(cs.clone(), || Ok(current.value().unwrap_or(Fr::from(0u64))))?;
        current.enforce_equal(&output)?;

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

pub fn bench_arithmetic_chain(
    chain_length: usize,
    num_warmup: usize,
    num_iterations: usize,
) -> BenchmarkResult {
    let mut rng = StdRng::seed_from_u64(42);

    // Setup phase (per-circuit trusted setup)
    let setup_circuit = ArithmeticChainCircuit {
        x: None,
        chain_length,
    };

    let setup_start = Instant::now();
    let (pk, vk) = Groth16::<Bn254>::circuit_specific_setup(setup_circuit, &mut rng).unwrap();
    let setup_time = setup_start.elapsed();

    // Get constraint count
    let test_circuit = ArithmeticChainCircuit {
        x: Some(Fr::from(3u64)),
        chain_length,
    };
    let cs = ark_relations::r1cs::ConstraintSystem::<Fr>::new_ref();
    test_circuit.clone().generate_constraints(cs.clone()).unwrap();
    let num_constraints = cs.num_constraints();

    // Warmup
    for _ in 0..num_warmup {
        let x = Fr::rand(&mut rng);
        let output = compute_arithmetic_chain(x, chain_length);
        let circuit = ArithmeticChainCircuit {
            x: Some(x),
            chain_length,
        };
        let proof = Groth16::<Bn254>::prove(&pk, circuit, &mut rng).unwrap();
        let _ = Groth16::<Bn254>::verify(&vk, &[output], &proof);
    }

    // Benchmark
    let mut prove_times = Vec::with_capacity(num_iterations);
    let mut verify_times = Vec::with_capacity(num_iterations);
    let mut proof_size = 0usize;

    for i in 0..num_iterations {
        let x = Fr::rand(&mut rng);
        let output = compute_arithmetic_chain(x, chain_length);
        let circuit = ArithmeticChainCircuit {
            x: Some(x),
            chain_length,
        };

        let prove_start = Instant::now();
        let proof = Groth16::<Bn254>::prove(&pk, circuit, &mut rng).unwrap();
        prove_times.push(prove_start.elapsed().as_secs_f64() * 1000.0);

        if i == 0 {
            let mut buf = Vec::new();
            proof.serialize_compressed(&mut buf).unwrap();
            proof_size = buf.len();
        }

        let verify_start = Instant::now();
        let valid = Groth16::<Bn254>::verify(&vk, &[output], &proof).unwrap();
        verify_times.push(verify_start.elapsed().as_secs_f64() * 1000.0);

        assert!(valid, "Groth16 verification failed");
    }

    let avg_prove: f64 = prove_times.iter().sum::<f64>() / num_iterations as f64;
    let avg_verify: f64 = verify_times.iter().sum::<f64>() / num_iterations as f64;

    println!("    constraints={}, prove={:.1}ms, verify={:.1}ms, proof={}B",
        num_constraints, avg_prove, avg_verify, proof_size);

    BenchmarkResult {
        system: "groth16".to_string(),
        circuit: format!("arith-{}", chain_length),
        num_constraints_or_rows: num_constraints,
        setup_time_ms: setup_time.as_secs_f64() * 1000.0,
        proving_time_ms: avg_prove,
        verification_time_ms: avg_verify,
        proof_size_bytes: proof_size,
        setup_type: "per-circuit trusted".to_string(),
        custom_gates: false,
        num_iterations,
    }
}

pub fn bench_hash_chain(
    chain_length: usize,
    num_warmup: usize,
    num_iterations: usize,
) -> BenchmarkResult {
    let mut rng = StdRng::seed_from_u64(42);

    let setup_circuit = HashChainCircuit {
        x: None,
        chain_length,
    };

    let setup_start = Instant::now();
    let (pk, vk) = Groth16::<Bn254>::circuit_specific_setup(setup_circuit, &mut rng).unwrap();
    let setup_time = setup_start.elapsed();

    let test_circuit = HashChainCircuit {
        x: Some(Fr::from(3u64)),
        chain_length,
    };
    let cs = ark_relations::r1cs::ConstraintSystem::<Fr>::new_ref();
    test_circuit.clone().generate_constraints(cs.clone()).unwrap();
    let num_constraints = cs.num_constraints();

    // Warmup
    for _ in 0..num_warmup {
        let x = Fr::rand(&mut rng);
        let output = compute_hash_chain(x, chain_length);
        let circuit = HashChainCircuit {
            x: Some(x),
            chain_length,
        };
        let proof = Groth16::<Bn254>::prove(&pk, circuit, &mut rng).unwrap();
        let _ = Groth16::<Bn254>::verify(&vk, &[output], &proof);
    }

    let mut prove_times = Vec::with_capacity(num_iterations);
    let mut verify_times = Vec::with_capacity(num_iterations);
    let mut proof_size = 0usize;

    for i in 0..num_iterations {
        let x = Fr::rand(&mut rng);
        let output = compute_hash_chain(x, chain_length);
        let circuit = HashChainCircuit {
            x: Some(x),
            chain_length,
        };

        let prove_start = Instant::now();
        let proof = Groth16::<Bn254>::prove(&pk, circuit, &mut rng).unwrap();
        prove_times.push(prove_start.elapsed().as_secs_f64() * 1000.0);

        if i == 0 {
            let mut buf = Vec::new();
            proof.serialize_compressed(&mut buf).unwrap();
            proof_size = buf.len();
        }

        let verify_start = Instant::now();
        let valid = Groth16::<Bn254>::verify(&vk, &[output], &proof).unwrap();
        verify_times.push(verify_start.elapsed().as_secs_f64() * 1000.0);

        assert!(valid, "Groth16 verification failed");
    }

    let avg_prove: f64 = prove_times.iter().sum::<f64>() / num_iterations as f64;
    let avg_verify: f64 = verify_times.iter().sum::<f64>() / num_iterations as f64;

    println!("    constraints={}, prove={:.1}ms, verify={:.1}ms, proof={}B",
        num_constraints, avg_prove, avg_verify, proof_size);

    BenchmarkResult {
        system: "groth16".to_string(),
        circuit: format!("hash-{}", chain_length),
        num_constraints_or_rows: num_constraints,
        setup_time_ms: setup_time.as_secs_f64() * 1000.0,
        proving_time_ms: avg_prove,
        verification_time_ms: avg_verify,
        proof_size_bytes: proof_size,
        setup_type: "per-circuit trusted".to_string(),
        custom_gates: false,
        num_iterations,
    }
}
