/// Comprehensive test suite for the Basis Network PLONK circuit.
///
/// Tests are organized by category:
///   - Circuit construction and constraint satisfaction
///   - Custom gate verification (Add, Mul, Poseidon, Memory, Stack)
///   - Proof generation and verification (end-to-end)
///   - Migration phase verification (dual period, cutover, rollback)
///   - Adversarial tests (invalid proofs, malformed data, replay)
///
/// [Spec: lab/3-architect/implementation-history/prover-plonk-migration/specs/PlonkMigration.tla]
use halo2_proofs::{
    arithmetic::Field,
    dev::MockProver,
    halo2curves::bn256::Fr,
};

use crate::circuit::{BasisCircuit, CircuitOp};
use crate::prover;
use crate::srs;
use crate::types::{MigrationPhase, ProofData, ProofSystem};
use crate::verifier;

/// Test circuit size parameter. k=8 (256 rows) is sufficient for unit tests.
const TEST_K: u32 = 8;

// ===================================================================
// Circuit Construction Tests
// ===================================================================

#[test]
fn trivial_circuit_mock_verify() {
    let circuit = BasisCircuit::trivial();
    let public_inputs = vec![
        circuit.pre_state_root,
        circuit.post_state_root,
        circuit.batch_hash,
    ];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

#[test]
fn empty_circuit_mock_verify() {
    let circuit = BasisCircuit::new(vec![], Fr::from(1u64), Fr::from(2u64), Fr::from(3u64));
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

// ===================================================================
// AddGate Tests
// ===================================================================

#[test]
fn add_gate_simple() {
    let a = Fr::from(3u64);
    let b = Fr::from(5u64);
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Add { a, b }],
        Fr::from(100u64),
        Fr::from(200u64),
        Fr::from(300u64),
    );
    let public_inputs = vec![Fr::from(100u64), Fr::from(200u64), Fr::from(300u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

#[test]
fn add_gate_zero() {
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Add {
            a: Fr::ZERO,
            b: Fr::ZERO,
        }],
        Fr::from(1u64),
        Fr::from(2u64),
        Fr::from(3u64),
    );
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

#[test]
fn add_gate_large_values() {
    let a = Fr::from(u64::MAX);
    let b = Fr::from(u64::MAX);
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Add { a, b }],
        Fr::from(1u64),
        Fr::from(2u64),
        Fr::from(3u64),
    );
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

#[test]
fn add_gate_multiple_operations() {
    let ops = vec![
        CircuitOp::Add {
            a: Fr::from(1u64),
            b: Fr::from(2u64),
        },
        CircuitOp::Add {
            a: Fr::from(10u64),
            b: Fr::from(20u64),
        },
        CircuitOp::Add {
            a: Fr::from(100u64),
            b: Fr::from(200u64),
        },
    ];
    let circuit = BasisCircuit::new(ops, Fr::from(1u64), Fr::from(2u64), Fr::from(3u64));
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

// ===================================================================
// MulGate Tests
// ===================================================================

#[test]
fn mul_gate_simple() {
    let a = Fr::from(3u64);
    let b = Fr::from(7u64);
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Mul { a, b }],
        Fr::from(1u64),
        Fr::from(2u64),
        Fr::from(3u64),
    );
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

#[test]
fn mul_gate_by_zero() {
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Mul {
            a: Fr::from(42u64),
            b: Fr::ZERO,
        }],
        Fr::from(1u64),
        Fr::from(2u64),
        Fr::from(3u64),
    );
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

#[test]
fn mul_gate_by_one() {
    let a = Fr::from(99u64);
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Mul { a, b: Fr::ONE }],
        Fr::from(1u64),
        Fr::from(2u64),
        Fr::from(3u64),
    );
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

// ===================================================================
// PoseidonGate Tests
// ===================================================================

#[test]
fn poseidon_gate_simple() {
    let input = Fr::from(2u64);
    let round_constant = Fr::from(5u64);
    // Expected: 2^5 + 5 = 32 + 5 = 37
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Poseidon {
            input,
            round_constant,
        }],
        Fr::from(1u64),
        Fr::from(2u64),
        Fr::from(3u64),
    );
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

#[test]
fn poseidon_gate_zero_input() {
    // 0^5 + 7 = 7
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Poseidon {
            input: Fr::ZERO,
            round_constant: Fr::from(7u64),
        }],
        Fr::from(1u64),
        Fr::from(2u64),
        Fr::from(3u64),
    );
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

#[test]
fn poseidon_gate_chain() {
    // Chain two Poseidon rounds: x -> x^5+c1 -> (x^5+c1)^5+c2
    let x = Fr::from(2u64);
    let c1 = Fr::from(1u64);
    let x5_c1 = {
        let x2 = x * x;
        let x4 = x2 * x2;
        x4 * x + c1
    }; // 2^5 + 1 = 33
    let c2 = Fr::from(3u64);

    let ops = vec![
        CircuitOp::Poseidon {
            input: x,
            round_constant: c1,
        },
        CircuitOp::Poseidon {
            input: x5_c1,
            round_constant: c2,
        },
    ];
    let circuit = BasisCircuit::new(ops, Fr::from(1u64), Fr::from(2u64), Fr::from(3u64));
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

// ===================================================================
// MemoryGate Tests
// ===================================================================

#[test]
fn memory_gate_same_address_same_value() {
    // Two consecutive memory ops at the same address with same value: OK
    let addr = Fr::from(0x1000u64);
    let val = Fr::from(42u64);
    let ops = vec![
        CircuitOp::Memory {
            address: addr,
            value: val,
        },
        CircuitOp::Memory {
            address: addr,
            value: val,
        },
    ];
    let circuit = BasisCircuit::new(ops, Fr::from(1u64), Fr::from(2u64), Fr::from(3u64));
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

#[test]
fn memory_gate_different_address_different_value() {
    // Different addresses: values can differ freely
    let ops = vec![
        CircuitOp::Memory {
            address: Fr::from(0x1000u64),
            value: Fr::from(42u64),
        },
        CircuitOp::Memory {
            address: Fr::from(0x2000u64),
            value: Fr::from(99u64),
        },
    ];
    let circuit = BasisCircuit::new(ops, Fr::from(1u64), Fr::from(2u64), Fr::from(3u64));
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

// ===================================================================
// Mixed Operation Tests
// ===================================================================

#[test]
fn mixed_add_and_mul() {
    let ops = vec![
        CircuitOp::Add {
            a: Fr::from(3u64),
            b: Fr::from(4u64),
        },
        CircuitOp::Mul {
            a: Fr::from(5u64),
            b: Fr::from(6u64),
        },
        CircuitOp::Add {
            a: Fr::from(7u64),
            b: Fr::from(8u64),
        },
    ];
    let circuit = BasisCircuit::new(ops, Fr::from(1u64), Fr::from(2u64), Fr::from(3u64));
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

#[test]
fn all_operation_types() {
    let ops = vec![
        CircuitOp::Add {
            a: Fr::from(1u64),
            b: Fr::from(2u64),
        },
        CircuitOp::Mul {
            a: Fr::from(3u64),
            b: Fr::from(4u64),
        },
        CircuitOp::Poseidon {
            input: Fr::from(2u64),
            round_constant: Fr::from(5u64),
        },
        CircuitOp::Memory {
            address: Fr::from(0x100u64),
            value: Fr::from(42u64),
        },
        CircuitOp::Memory {
            address: Fr::from(0x200u64),
            value: Fr::from(99u64),
        },
    ];
    let circuit = BasisCircuit::new(ops, Fr::from(10u64), Fr::from(20u64), Fr::from(30u64));
    let public_inputs = vec![Fr::from(10u64), Fr::from(20u64), Fr::from(30u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

// ===================================================================
// Proof Generation & Verification (End-to-End)
// ===================================================================

#[test]
fn prove_and_verify_trivial() {
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();

    let proof_data = prover::prove(&params, circuit.clone()).expect("proof generation");
    assert_eq!(proof_data.proof_system, ProofSystem::Plonk);
    assert!(!proof_data.proof.is_empty());

    // Verify
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");
    let valid = verifier::verify(&params, &vk, &proof_data).expect("verification");
    assert!(valid, "valid proof must verify");
}

#[test]
fn prove_and_verify_add() {
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Add {
            a: Fr::from(100u64),
            b: Fr::from(200u64),
        }],
        Fr::from(1u64),
        Fr::from(2u64),
        Fr::from(3u64),
    );

    let proof_data = prover::prove(&params, circuit.clone()).expect("proof generation");
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");
    let valid = verifier::verify(&params, &vk, &proof_data).expect("verification");
    assert!(valid);
}

#[test]
fn prove_and_verify_mul() {
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Mul {
            a: Fr::from(7u64),
            b: Fr::from(11u64),
        }],
        Fr::from(1u64),
        Fr::from(2u64),
        Fr::from(3u64),
    );

    let proof_data = prover::prove(&params, circuit.clone()).expect("proof generation");
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");
    let valid = verifier::verify(&params, &vk, &proof_data).expect("verification");
    assert!(valid);
}

#[test]
fn prove_and_verify_poseidon() {
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Poseidon {
            input: Fr::from(3u64),
            round_constant: Fr::from(7u64),
        }],
        Fr::from(1u64),
        Fr::from(2u64),
        Fr::from(3u64),
    );

    let proof_data = prover::prove(&params, circuit.clone()).expect("proof generation");
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");
    let valid = verifier::verify(&params, &vk, &proof_data).expect("verification");
    assert!(valid);
}

#[test]
fn prove_and_verify_mixed_operations() {
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::new(
        vec![
            CircuitOp::Add {
                a: Fr::from(10u64),
                b: Fr::from(20u64),
            },
            CircuitOp::Mul {
                a: Fr::from(5u64),
                b: Fr::from(6u64),
            },
            CircuitOp::Poseidon {
                input: Fr::from(2u64),
                round_constant: Fr::from(1u64),
            },
        ],
        Fr::from(100u64),
        Fr::from(200u64),
        Fr::from(300u64),
    );

    let proof_data = prover::prove(&params, circuit.clone()).expect("proof generation");
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");
    let valid = verifier::verify(&params, &vk, &proof_data).expect("verification");
    assert!(valid);
}

// ===================================================================
// Migration Phase Tests (TLA+ Invariants)
// ===================================================================

#[test]
fn s2_backward_compatibility_groth16_in_dual() {
    // S2: Groth16 proofs accepted during dual phase
    let groth16_proof = ProofData {
        proof: vec![0u8; 128], // Placeholder Groth16 proof
        public_inputs: vec![Fr::from(1u64)],
        proof_system: ProofSystem::Groth16,
    };

    // In Dual phase, Groth16 should be accepted (phase check)
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");

    let result = verifier::verify_with_phase(&params, &vk, &groth16_proof, MigrationPhase::Dual);
    assert!(result.is_ok());
    assert!(result.unwrap(), "Groth16 must be accepted in Dual phase");
}

#[test]
fn s2_backward_compatibility_groth16_in_groth16_only() {
    // S2: Groth16 proofs accepted during groth16_only phase
    let groth16_proof = ProofData {
        proof: vec![0u8; 128],
        public_inputs: vec![Fr::from(1u64)],
        proof_system: ProofSystem::Groth16,
    };

    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");

    let result =
        verifier::verify_with_phase(&params, &vk, &groth16_proof, MigrationPhase::Groth16Only);
    assert!(result.is_ok());
    assert!(
        result.unwrap(),
        "Groth16 must be accepted in Groth16Only phase"
    );
}

#[test]
fn s5_no_groth16_after_cutover() {
    // S5: Groth16 proofs rejected after cutover to PlonkOnly
    let groth16_proof = ProofData {
        proof: vec![0u8; 128],
        public_inputs: vec![Fr::from(1u64)],
        proof_system: ProofSystem::Groth16,
    };

    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");

    let result =
        verifier::verify_with_phase(&params, &vk, &groth16_proof, MigrationPhase::PlonkOnly);
    assert!(result.is_ok());
    assert!(
        !result.unwrap(),
        "Groth16 must be REJECTED in PlonkOnly phase"
    );
}

#[test]
fn plonk_accepted_in_dual_phase() {
    // PLONK proofs accepted during dual phase
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();
    let proof_data = prover::prove(&params, circuit.clone()).expect("proof generation");
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");

    let result = verifier::verify_with_phase(&params, &vk, &proof_data, MigrationPhase::Dual);
    assert!(result.is_ok());
    assert!(result.unwrap(), "PLONK must be accepted in Dual phase");
}

#[test]
fn plonk_accepted_in_plonk_only_phase() {
    // PLONK proofs accepted in PlonkOnly phase
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();
    let proof_data = prover::prove(&params, circuit.clone()).expect("proof generation");
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");

    let result =
        verifier::verify_with_phase(&params, &vk, &proof_data, MigrationPhase::PlonkOnly);
    assert!(result.is_ok());
    assert!(
        result.unwrap(),
        "PLONK must be accepted in PlonkOnly phase"
    );
}

#[test]
fn plonk_rejected_in_groth16_only_phase() {
    // PLONK proofs rejected in Groth16Only phase
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();
    let proof_data = prover::prove(&params, circuit.clone()).expect("proof generation");
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");

    let result =
        verifier::verify_with_phase(&params, &vk, &proof_data, MigrationPhase::Groth16Only);
    assert!(result.is_ok());
    assert!(
        !result.unwrap(),
        "PLONK must be REJECTED in Groth16Only phase"
    );
}

#[test]
fn groth16_accepted_in_rollback_phase() {
    // During rollback, Groth16 is still accepted
    let groth16_proof = ProofData {
        proof: vec![0u8; 128],
        public_inputs: vec![Fr::from(1u64)],
        proof_system: ProofSystem::Groth16,
    };

    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");

    let result =
        verifier::verify_with_phase(&params, &vk, &groth16_proof, MigrationPhase::Rollback);
    assert!(result.is_ok());
    assert!(
        result.unwrap(),
        "Groth16 must be accepted in Rollback phase"
    );
}

#[test]
fn plonk_rejected_in_rollback_phase() {
    // During rollback, PLONK is rejected (activeVerifiers = {groth16})
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();
    let proof_data = prover::prove(&params, circuit.clone()).expect("proof generation");
    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");

    let result =
        verifier::verify_with_phase(&params, &vk, &proof_data, MigrationPhase::Rollback);
    assert!(result.is_ok());
    assert!(
        !result.unwrap(),
        "PLONK must be REJECTED in Rollback phase"
    );
}

// ===================================================================
// Adversarial Tests (S3 Soundness)
// ===================================================================

#[test]
fn adversarial_wrong_public_inputs() {
    // S3 Soundness: proof with wrong public inputs must fail
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();
    let mut proof_data = prover::prove(&params, circuit.clone()).expect("proof generation");

    // Tamper with public inputs
    proof_data.public_inputs[0] = Fr::from(999u64);

    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");
    let valid = verifier::verify(&params, &vk, &proof_data).expect("verification");
    assert!(!valid, "tampered public inputs must cause verification failure");
}

#[test]
fn adversarial_truncated_proof() {
    // Malformed proof: truncated bytes
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();
    let mut proof_data = prover::prove(&params, circuit.clone()).expect("proof generation");

    // Truncate proof to half its length
    let half = proof_data.proof.len() / 2;
    proof_data.proof.truncate(half);

    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");
    let result = verifier::verify(&params, &vk, &proof_data);
    // Either returns Ok(false) or Err -- both acceptable for malformed proof
    match result {
        Ok(valid) => assert!(!valid, "truncated proof must not verify"),
        Err(_) => {} // Malformed proof causes verification error -- acceptable
    }
}

#[test]
fn adversarial_zero_proof() {
    // All-zero proof bytes
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();

    let proof_data = ProofData {
        proof: vec![0u8; 256],
        public_inputs: vec![Fr::from(100u64), Fr::from(200u64), Fr::from(300u64)],
        proof_system: ProofSystem::Plonk,
    };

    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");
    let result = verifier::verify(&params, &vk, &proof_data);
    match result {
        Ok(valid) => assert!(!valid, "zero proof must not verify"),
        Err(_) => {} // Expected for malformed proof
    }
}

#[test]
fn adversarial_random_proof() {
    // Random bytes as proof
    use rand::RngCore;
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();

    let mut rng = rand::thread_rng();
    let mut random_proof = vec![0u8; 512];
    rng.fill_bytes(&mut random_proof);

    let proof_data = ProofData {
        proof: random_proof,
        public_inputs: vec![Fr::from(100u64), Fr::from(200u64), Fr::from(300u64)],
        proof_system: ProofSystem::Plonk,
    };

    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");
    let result = verifier::verify(&params, &vk, &proof_data);
    match result {
        Ok(valid) => assert!(!valid, "random proof must not verify"),
        Err(_) => {} // Expected for random bytes
    }
}

#[test]
fn adversarial_proof_replay_different_inputs() {
    // Replay attack: use proof from one set of public inputs with different inputs
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");

    let circuit1 = BasisCircuit::new(
        vec![CircuitOp::Add {
            a: Fr::from(1u64),
            b: Fr::from(2u64),
        }],
        Fr::from(10u64),
        Fr::from(20u64),
        Fr::from(30u64),
    );
    let proof_data = prover::prove(&params, circuit1.clone()).expect("proof generation");
    let vk = prover::generate_vk(&params, &circuit1).expect("vk generation");

    // Valid with original inputs
    let valid = verifier::verify(&params, &vk, &proof_data).expect("verification");
    assert!(valid, "original proof must verify");

    // Replay with different public inputs
    let replayed = ProofData {
        proof: proof_data.proof.clone(),
        public_inputs: vec![Fr::from(99u64), Fr::from(88u64), Fr::from(77u64)],
        proof_system: ProofSystem::Plonk,
    };
    let valid = verifier::verify(&params, &vk, &replayed).expect("verification");
    assert!(!valid, "replayed proof with different inputs must fail");
}

#[test]
fn adversarial_bit_flip_in_proof() {
    // Single bit flip in proof should invalidate it
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");
    let circuit = BasisCircuit::trivial();
    let mut proof_data = prover::prove(&params, circuit.clone()).expect("proof generation");

    // Flip one bit in the middle of the proof
    if proof_data.proof.len() > 10 {
        proof_data.proof[10] ^= 0x01;
    }

    let vk = prover::generate_vk(&params, &circuit).expect("vk generation");
    let result = verifier::verify(&params, &vk, &proof_data);
    match result {
        Ok(valid) => assert!(!valid, "bit-flipped proof must not verify"),
        Err(_) => {} // Acceptable for corrupted proof
    }
}

// ===================================================================
// Batch Verification Tests
// ===================================================================

#[test]
fn batch_verify_multiple_proofs() {
    let k = TEST_K;
    let params = srs::generate_srs(k).expect("SRS generation");

    // Both circuits use the same operation type (Add) so they share the same
    // selector pattern and therefore the same vk (fixed column commitments).
    let circuit1 = BasisCircuit::new(
        vec![CircuitOp::Add {
            a: Fr::from(1u64),
            b: Fr::from(2u64),
        }],
        Fr::from(10u64),
        Fr::from(20u64),
        Fr::from(30u64),
    );
    let circuit2 = BasisCircuit::new(
        vec![CircuitOp::Add {
            a: Fr::from(100u64),
            b: Fr::from(200u64),
        }],
        Fr::from(40u64),
        Fr::from(50u64),
        Fr::from(60u64),
    );

    let proof1 = prover::prove(&params, circuit1.clone()).expect("proof1");
    let proof2 = prover::prove(&params, circuit2.clone()).expect("proof2");

    // Same operation type -> same selector pattern -> same vk
    let vk = prover::generate_vk(&params, &circuit1).expect("vk");

    let results = verifier::verify_batch(&params, &vk, &[proof1, proof2]).expect("batch verify");
    assert_eq!(results.len(), 2);
    assert!(results[0], "proof1 must verify");
    assert!(results[1], "proof2 must verify");
}

// ===================================================================
// CircuitOp expected_output Tests
// ===================================================================

#[test]
fn circuit_op_expected_output() {
    let add = CircuitOp::Add {
        a: Fr::from(3u64),
        b: Fr::from(5u64),
    };
    assert_eq!(add.expected_output(), Fr::from(8u64));

    let mul = CircuitOp::Mul {
        a: Fr::from(4u64),
        b: Fr::from(7u64),
    };
    assert_eq!(mul.expected_output(), Fr::from(28u64));

    let poseidon = CircuitOp::Poseidon {
        input: Fr::from(2u64),
        round_constant: Fr::from(5u64),
    };
    assert_eq!(poseidon.expected_output(), Fr::from(37u64)); // 2^5 + 5 = 37
}

// ===================================================================
// Field Conversion Integration
// ===================================================================

#[test]
fn ark_halo2_fr_interop() {
    use crate::types::{ark_fr_to_halo2_fr, halo2_fr_to_ark_fr};

    // Test with values from witness generator domain
    let ark_val = ark_bn254::Fr::from(0xDEADBEEFu64);
    let halo2_val = ark_fr_to_halo2_fr(ark_val);
    let back = halo2_fr_to_ark_fr(halo2_val);
    assert_eq!(ark_val, back);

    // Verify the halo2 Fr can be used in circuit
    let circuit = BasisCircuit::new(
        vec![CircuitOp::Add {
            a: halo2_val,
            b: Fr::from(1u64),
        }],
        Fr::from(1u64),
        Fr::from(2u64),
        Fr::from(3u64),
    );
    let public_inputs = vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)];
    let prover = MockProver::run(TEST_K, &circuit, vec![public_inputs]).unwrap();
    prover.assert_satisfied();
}

// ===================================================================
// EVM Gate Tests -- All 21 new gates verified with MockProver
// ===================================================================

fn run_gate_test(ops: Vec<CircuitOp>) {
    let circuit = BasisCircuit::new(ops, Fr::ZERO, Fr::ZERO, Fr::ZERO);
    let pi = vec![circuit.pre_state_root, circuit.post_state_root, circuit.batch_hash];
    MockProver::run(TEST_K, &circuit, vec![pi]).unwrap().assert_satisfied();
}

#[test] fn gate_sub() { run_gate_test(vec![CircuitOp::Sub { a: Fr::from(100u64), b: Fr::from(30u64) }]); }
#[test] fn gate_div() { run_gate_test(vec![CircuitOp::Div { a: Fr::from(100u64), b: Fr::from(5u64) }]); }
#[test] fn gate_mod() { run_gate_test(vec![CircuitOp::Mod { a: Fr::from(17u64), b: Fr::from(5u64) }]); }
#[test] fn gate_lt_true() { run_gate_test(vec![CircuitOp::Lt { a: Fr::from(3u64), b: Fr::from(10u64) }]); }
#[test] fn gate_lt_false() { run_gate_test(vec![CircuitOp::Lt { a: Fr::from(10u64), b: Fr::from(3u64) }]); }
#[test] fn gate_eq_yes() { run_gate_test(vec![CircuitOp::Eq { a: Fr::from(42u64), b: Fr::from(42u64) }]); }
#[test] fn gate_eq_no() { run_gate_test(vec![CircuitOp::Eq { a: Fr::from(1u64), b: Fr::from(2u64) }]); }
#[test] fn gate_iszero_yes() { run_gate_test(vec![CircuitOp::IsZero { a: Fr::ZERO }]); }
#[test] fn gate_iszero_no() { run_gate_test(vec![CircuitOp::IsZero { a: Fr::from(99u64) }]); }
#[test] fn gate_and_tt() { run_gate_test(vec![CircuitOp::And { a: Fr::from(1u64), b: Fr::from(1u64) }]); }
#[test] fn gate_and_tf() { run_gate_test(vec![CircuitOp::And { a: Fr::from(1u64), b: Fr::ZERO }]); }
#[test] fn gate_or_ft() { run_gate_test(vec![CircuitOp::Or { a: Fr::ZERO, b: Fr::from(1u64) }]); }
#[test] fn gate_not_0() { run_gate_test(vec![CircuitOp::Not { a: Fr::ZERO }]); }
#[test] fn gate_not_1() { run_gate_test(vec![CircuitOp::Not { a: Fr::from(1u64) }]); }
#[test] fn gate_sload() { run_gate_test(vec![CircuitOp::Sload { slot: Fr::from(1u64), value: Fr::from(42u64) }]); }
#[test] fn gate_sstore() { run_gate_test(vec![CircuitOp::Sstore { slot: Fr::from(1u64), old_value: Fr::ZERO, new_value: Fr::from(99u64) }]); }
#[test] fn gate_sstore_id() { run_gate_test(vec![CircuitOp::Sstore { slot: Fr::from(1u64), old_value: Fr::from(5u64), new_value: Fr::from(5u64) }]); }
#[test] fn gate_mload() { run_gate_test(vec![CircuitOp::Mload { address: Fr::from(0x20u64), value: Fr::from(0xffu64) }]); }
#[test] fn gate_mstore() { run_gate_test(vec![CircuitOp::Mstore { address: Fr::from(0x40u64), value: Fr::from(123u64) }]); }
#[test] fn gate_hash() { run_gate_test(vec![CircuitOp::Hash { left: Fr::from(2u64), right: Fr::from(3u64) }]); }
#[test] fn gate_jump_t() { run_gate_test(vec![CircuitOp::Jump { destination: Fr::from(100u64), condition: Fr::from(1u64) }]); }
#[test] fn gate_jump_f() { run_gate_test(vec![CircuitOp::Jump { destination: Fr::from(100u64), condition: Fr::ZERO }]); }
#[test] fn gate_push() { run_gate_test(vec![CircuitOp::Push { value: Fr::from(0xdeadu64) }]); }
#[test] fn gate_pop() { run_gate_test(vec![CircuitOp::Pop { value: Fr::from(42u64) }]); }
#[test] fn gate_dup() { run_gate_test(vec![CircuitOp::Dup { value: Fr::from(77u64) }]); }
#[test] fn gate_swap() { run_gate_test(vec![CircuitOp::Swap { first: Fr::from(1u64), second: Fr::from(2u64) }]); }
#[test] fn gate_call_ok() { run_gate_test(vec![CircuitOp::Call { gas: Fr::from(21000u64), target: Fr::from(2u64), value: Fr::ZERO, success: true }]); }
#[test] fn gate_call_fail() { run_gate_test(vec![CircuitOp::Call { gas: Fr::from(21000u64), target: Fr::from(2u64), value: Fr::ZERO, success: false }]); }
#[test] fn gate_return() { run_gate_test(vec![CircuitOp::Return { offset: Fr::ZERO, size: Fr::from(32u64), is_revert: false }]); }
#[test] fn gate_revert() { run_gate_test(vec![CircuitOp::Return { offset: Fr::ZERO, size: Fr::from(64u64), is_revert: true }]); }

#[test]
fn combined_evm_transaction() {
    run_gate_test(vec![
        CircuitOp::Push { value: Fr::from(10u64) },
        CircuitOp::Push { value: Fr::from(3u64) },
        CircuitOp::Add { a: Fr::from(10u64), b: Fr::from(3u64) },
        CircuitOp::Sub { a: Fr::from(13u64), b: Fr::from(3u64) },
        CircuitOp::Mul { a: Fr::from(10u64), b: Fr::from(2u64) },
        CircuitOp::Eq { a: Fr::from(20u64), b: Fr::from(20u64) },
        CircuitOp::Sstore { slot: Fr::from(1u64), old_value: Fr::ZERO, new_value: Fr::from(20u64) },
        CircuitOp::Return { offset: Fr::ZERO, size: Fr::ZERO, is_revert: false },
    ]);
}

// ===================================================================
// Extended EVM Gate Tests (10 gates from evm_gates.rs)
// ===================================================================

#[test] fn gate_shl() { run_gate_test(vec![CircuitOp::Shl { a: Fr::from(5u64), shift_pow: Fr::from(4u64) }]); }
#[test] fn gate_shr() { run_gate_test(vec![CircuitOp::Shr { a: Fr::from(20u64), shift_pow: Fr::from(4u64) }]); }
#[test] fn gate_byte_op() { run_gate_test(vec![CircuitOp::Byte { word: Fr::from(0xffu64), index: Fr::from(31u64), result: Fr::from(0xffu64) }]); }
#[test] fn gate_exp_op() { run_gate_test(vec![CircuitOp::Exp { base: Fr::from(2u64), result: Fr::from(2u64) }]); } // d=1 means b=1, so result=base
#[test] fn gate_sha3_op() { run_gate_test(vec![CircuitOp::Sha3 { offset: Fr::ZERO, size: Fr::from(32u64), hash: Fr::from(0xabcdu64) }]); }
#[test] fn gate_calldataload() { run_gate_test(vec![CircuitOp::CalldataLoad { offset: Fr::ZERO, value: Fr::from(42u64) }]); }
#[test] fn gate_env_op() { run_gate_test(vec![CircuitOp::Env { value: Fr::from(0x1234u64) }]); }
#[test] fn gate_block_op() { run_gate_test(vec![CircuitOp::Block { value: Fr::from(100u64) }]); }
#[test] fn gate_log_op() { run_gate_test(vec![CircuitOp::Log { offset: Fr::from(0x80u64), topic_count: Fr::from(2u64) }]); }
#[test] fn gate_create_op() { run_gate_test(vec![CircuitOp::Create { value: Fr::ZERO, salt: Fr::from(42u64), address: Fr::from(0xdeadu64), success: true }]); }
