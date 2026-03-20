// Proof Aggregation Module
//
// Implements three aggregation strategies for benchmarking:
//
// 1. **No aggregation** (baseline): Each proof verified individually on L1.
//    Gas cost = N * per_proof_gas.
//
// 2. **Sequential accumulation**: Verify proofs one-by-one in an accumulation
//    circuit. Each step takes the running accumulator + next proof and produces
//    an updated accumulator. Final proof size is O(1).
//    Simulated as: aggregation_circuit verifies N proofs sequentially.
//
// 3. **Binary tree accumulation**: Pair proofs and aggregate in a tree.
//    Depth = log2(N), each node verifies 2 child proofs.
//    Parallelizable, final proof size is O(1).
//
// Since we cannot instantiate a full snark-verifier recursive circuit without
// the snark-verifier crate (which has complex build requirements), we simulate
// the aggregation by:
// - Measuring the cost of the inner proof generation and verification
// - Computing aggregation overhead based on published circuit sizes
// - Projecting gas costs based on published verification formulas
//
// This is a valid methodology because:
// - The inner proof parameters (size, prove/verify time) are measured directly
// - The aggregation circuit size is well-characterized in literature (500K-1M constraints for 2-proof accumulation)
// - Gas costs are deterministic formulas from EVM precompile costs

use crate::enterprise_circuit::{
    EnterpriseProofParams, generate_enterprise_proof, verify_enterprise_proof,
};
use halo2curves::bn256::Fr;
use serde::Serialize;

// Published parameters from literature for aggregation cost modeling.
pub const HALO2_KZG_VERIFY_GAS: u64 = 420_000;
pub const PLONK_KZG_VERIFY_GAS: u64 = 290_000;
pub const GROTH16_VERIFY_GAS: u64 = 220_000;
pub const FFLONK_VERIFY_GAS: u64 = 201_000;

// Aggregation circuit parameters (from Axiom snark-verifier benchmarks).
pub const ACCUMULATION_CONSTRAINTS_PER_2_PROOFS: usize = 750_000;
pub const ACCUMULATION_K_PER_2_PROOFS: u32 = 21;

// Folding parameters (from Nova/ProtoGalaxy literature).
pub const FOLDING_VERIFIER_CONSTRAINTS: usize = 11_000;
pub const FOLDING_STEP_MS_ESTIMATE: f64 = 250.0;

#[derive(Serialize, Clone, Debug)]
pub struct AggregationResult {
    pub strategy: String,
    pub num_proofs: usize,
    pub individual_proof_size_bytes: usize,
    pub individual_prove_time_ms: f64,
    pub individual_verify_time_ms: f64,
    pub aggregation_time_ms: f64,
    pub total_time_ms: f64,
    pub final_proof_size_bytes: usize,
    pub l1_verification_gas: u64,
    pub l1_gas_per_enterprise: u64,
    pub gas_savings_vs_individual: f64,
    pub num_iterations: usize,
    pub std_dev_prove_ms: f64,
    pub std_dev_verify_ms: f64,
}

// Benchmark: No aggregation (baseline).
// Each enterprise proof verified individually on L1.
pub fn benchmark_no_aggregation(
    n: usize,
    batch_size: usize,
    num_warmup: usize,
    num_iterations: usize,
) -> AggregationResult {
    let params = EnterpriseProofParams::new(batch_size);

    // Warmup
    for i in 0..num_warmup {
        let _ = generate_enterprise_proof(i as u64 + 100, batch_size, &params);
    }

    let mut prove_times = Vec::with_capacity(num_iterations);
    let mut verify_times = Vec::with_capacity(num_iterations);
    let mut proof_size = 0;

    for iter in 0..num_iterations {
        let mut total_prove = 0.0;
        let mut total_verify = 0.0;

        for enterprise_id in 0..n {
            let seed = (iter * 1000 + enterprise_id) as u64;
            let (proof, pi, prove_ms) = generate_enterprise_proof(seed, batch_size, &params);

            if proof_size == 0 {
                proof_size = proof.len();
            }

            let (valid, verify_ms) = verify_enterprise_proof(&proof, &pi, batch_size, &params);
            assert!(valid, "Enterprise proof must verify");

            total_prove += prove_ms;
            total_verify += verify_ms;
        }

        prove_times.push(total_prove);
        verify_times.push(total_verify);
    }

    let mean_prove = prove_times.iter().sum::<f64>() / num_iterations as f64;
    let mean_verify = verify_times.iter().sum::<f64>() / num_iterations as f64;
    let std_prove = std_dev(&prove_times);
    let std_verify = std_dev(&verify_times);

    let total_gas = n as u64 * HALO2_KZG_VERIFY_GAS;

    AggregationResult {
        strategy: "none".to_string(),
        num_proofs: n,
        individual_proof_size_bytes: proof_size,
        individual_prove_time_ms: mean_prove / n as f64,
        individual_verify_time_ms: mean_verify / n as f64,
        aggregation_time_ms: 0.0,
        total_time_ms: mean_prove + mean_verify,
        final_proof_size_bytes: proof_size * n,
        l1_verification_gas: total_gas,
        l1_gas_per_enterprise: HALO2_KZG_VERIFY_GAS,
        gas_savings_vs_individual: 1.0,
        num_iterations,
        std_dev_prove_ms: std_prove,
        std_dev_verify_ms: std_verify,
    }
}

// Benchmark: Binary tree accumulation (halo2 snark-verifier pattern).
// Aggregation time is modeled from the number of tree levels and per-level proving cost.
// The final proof is a single halo2-KZG proof.
pub fn benchmark_binary_tree_accumulation(
    n: usize,
    batch_size: usize,
    num_warmup: usize,
    num_iterations: usize,
) -> AggregationResult {
    let params = EnterpriseProofParams::new(batch_size);

    // Warmup
    for i in 0..num_warmup {
        let _ = generate_enterprise_proof(i as u64 + 200, batch_size, &params);
    }

    let mut prove_times = Vec::with_capacity(num_iterations);
    let mut verify_times = Vec::with_capacity(num_iterations);
    let mut proof_size = 0;

    for iter in 0..num_iterations {
        let mut total_prove = 0.0;
        let mut total_verify = 0.0;

        // Generate all N enterprise proofs
        for enterprise_id in 0..n {
            let seed = (iter * 1000 + enterprise_id) as u64;
            let (proof, pi, prove_ms) = generate_enterprise_proof(seed, batch_size, &params);

            if proof_size == 0 {
                proof_size = proof.len();
            }

            // Verify each to confirm validity (in practice, aggregator checks before aggregating)
            let (valid, verify_ms) = verify_enterprise_proof(&proof, &pi, batch_size, &params);
            assert!(valid);

            total_prove += prove_ms;
            total_verify += verify_ms;
        }

        prove_times.push(total_prove);
        verify_times.push(total_verify);
    }

    let mean_prove = prove_times.iter().sum::<f64>() / num_iterations as f64;
    let mean_verify = verify_times.iter().sum::<f64>() / num_iterations as f64;
    let std_prove = std_dev(&prove_times);
    let std_verify = std_dev(&verify_times);

    // Model aggregation overhead.
    // Binary tree: depth = ceil(log2(n)), each level has n/2^level aggregation proofs.
    // Total aggregation proofs: n - 1.
    // Each aggregation proof takes ~60s for the accumulation circuit (500K-1M constraints).
    // However with parallelism, wall clock is depth * per_level_time.
    let depth = if n > 1 { (n as f64).log2().ceil() as usize } else { 0 };

    // Axiom snark-verifier: ~30-120s for 2-proof aggregation (use 60s median).
    // With GPU acceleration this drops to ~10-30s.
    // For our benchmark we model CPU-only at 60s per aggregation proof.
    let per_aggregation_ms = 60_000.0; // 60 seconds for a 2-proof accumulation circuit
    let per_aggregation_parallel_ms = 60_000.0; // one level at a time, parallelized within level

    // Wall clock with full parallelism: depth * per_aggregation_time
    let aggregation_time_ms = depth as f64 * per_aggregation_parallel_ms;

    // Final proof is a single halo2-KZG proof
    let final_proof_size = proof_size; // ~800 bytes (halo2-KZG)
    let final_gas = HALO2_KZG_VERIFY_GAS; // Single verification

    let baseline_gas = n as u64 * HALO2_KZG_VERIFY_GAS;
    let savings = baseline_gas as f64 / final_gas as f64;

    AggregationResult {
        strategy: "binary_tree_halo2".to_string(),
        num_proofs: n,
        individual_proof_size_bytes: proof_size,
        individual_prove_time_ms: mean_prove / n as f64,
        individual_verify_time_ms: mean_verify / n as f64,
        aggregation_time_ms,
        total_time_ms: mean_prove + aggregation_time_ms,
        final_proof_size_bytes: final_proof_size,
        l1_verification_gas: final_gas,
        l1_gas_per_enterprise: final_gas / n as u64,
        gas_savings_vs_individual: savings,
        num_iterations,
        std_dev_prove_ms: std_prove,
        std_dev_verify_ms: std_verify,
    }
}

// Benchmark: Folding-based aggregation (Nova/ProtoGalaxy pattern).
// Aggregation time is modeled from per-fold step cost.
// Final proof compressed to Groth16 for EVM verification.
pub fn benchmark_folding_aggregation(
    n: usize,
    batch_size: usize,
    num_warmup: usize,
    num_iterations: usize,
) -> AggregationResult {
    let params = EnterpriseProofParams::new(batch_size);

    // Warmup
    for i in 0..num_warmup {
        let _ = generate_enterprise_proof(i as u64 + 300, batch_size, &params);
    }

    let mut prove_times = Vec::with_capacity(num_iterations);
    let mut verify_times = Vec::with_capacity(num_iterations);
    let mut proof_size = 0;

    for iter in 0..num_iterations {
        let mut total_prove = 0.0;
        let mut total_verify = 0.0;

        for enterprise_id in 0..n {
            let seed = (iter * 1000 + enterprise_id) as u64;
            let (proof, pi, prove_ms) = generate_enterprise_proof(seed, batch_size, &params);

            if proof_size == 0 {
                proof_size = proof.len();
            }

            let (valid, verify_ms) = verify_enterprise_proof(&proof, &pi, batch_size, &params);
            assert!(valid);

            total_prove += prove_ms;
            total_verify += verify_ms;
        }

        prove_times.push(total_prove);
        verify_times.push(total_verify);
    }

    let mean_prove = prove_times.iter().sum::<f64>() / num_iterations as f64;
    let mean_verify = verify_times.iter().sum::<f64>() / num_iterations as f64;
    let std_prove = std_dev(&prove_times);
    let std_verify = std_dev(&verify_times);

    // Model folding aggregation overhead.
    // ProtoGalaxy/Nova: each fold step takes ~250ms (for ~10K constraint verifier circuit).
    // N-1 fold steps to accumulate N proofs.
    // Plus final Groth16 decider: ~5-15s for the compressed proof.
    let num_fold_steps = if n > 1 { n - 1 } else { 0 };
    let fold_time_ms = num_fold_steps as f64 * FOLDING_STEP_MS_ESTIMATE;

    // Groth16 decider (final SNARK compression): ~10s for moderate circuit
    let decider_time_ms = 10_000.0;
    let aggregation_time_ms = fold_time_ms + decider_time_ms;

    // Final proof is a Groth16 proof (128 bytes, ~220K gas)
    let final_proof_size = 128; // Groth16 compressed
    let final_gas = GROTH16_VERIFY_GAS;

    let baseline_gas = n as u64 * HALO2_KZG_VERIFY_GAS;
    let savings = baseline_gas as f64 / final_gas as f64;

    AggregationResult {
        strategy: "folding_groth16_decider".to_string(),
        num_proofs: n,
        individual_proof_size_bytes: proof_size,
        individual_prove_time_ms: mean_prove / n as f64,
        individual_verify_time_ms: mean_verify / n as f64,
        aggregation_time_ms,
        total_time_ms: mean_prove + aggregation_time_ms,
        final_proof_size_bytes: final_proof_size,
        l1_verification_gas: final_gas,
        l1_gas_per_enterprise: final_gas / n as u64,
        gas_savings_vs_individual: savings,
        num_iterations,
        std_dev_prove_ms: std_prove,
        std_dev_verify_ms: std_verify,
    }
}

// Benchmark: SnarkPack-style batch verification.
// All proofs aggregated via inner product argument.
// Verification cost: O(log N) pairings.
pub fn benchmark_snarkpack_aggregation(
    n: usize,
    batch_size: usize,
    num_warmup: usize,
    num_iterations: usize,
) -> AggregationResult {
    let params = EnterpriseProofParams::new(batch_size);

    for i in 0..num_warmup {
        let _ = generate_enterprise_proof(i as u64 + 400, batch_size, &params);
    }

    let mut prove_times = Vec::with_capacity(num_iterations);
    let mut verify_times = Vec::with_capacity(num_iterations);
    let mut proof_size = 0;

    for iter in 0..num_iterations {
        let mut total_prove = 0.0;
        let mut total_verify = 0.0;

        for enterprise_id in 0..n {
            let seed = (iter * 1000 + enterprise_id) as u64;
            let (proof, pi, prove_ms) = generate_enterprise_proof(seed, batch_size, &params);

            if proof_size == 0 {
                proof_size = proof.len();
            }

            let (valid, verify_ms) = verify_enterprise_proof(&proof, &pi, batch_size, &params);
            assert!(valid);

            total_prove += prove_ms;
            total_verify += verify_ms;
        }

        prove_times.push(total_prove);
        verify_times.push(total_verify);
    }

    let mean_prove = prove_times.iter().sum::<f64>() / num_iterations as f64;
    let mean_verify = verify_times.iter().sum::<f64>() / num_iterations as f64;
    let std_prove = std_dev(&prove_times);
    let std_verify = std_dev(&verify_times);

    // SnarkPack aggregation overhead (from paper benchmarks):
    // N=8: ~200ms, N=64: ~1s, N=1024: ~8s
    // Approximately: aggregation_ms = n * 25 (linear in n for small n)
    let aggregation_time_ms = n as f64 * 25.0;

    // SnarkPack proof size: O(log N) group elements
    // ~400B for N=2, ~600B for N=8, ~1KB for N=64
    let log_n = if n > 1 { (n as f64).log2().ceil() as usize } else { 1 };
    let final_proof_size = 400 + log_n * 64; // base + log(N) group elements

    // SnarkPack verification gas: ~300K + log2(N) * 50K (pairing checks)
    let final_gas = 300_000 + (log_n as u64) * 50_000;

    let baseline_gas = n as u64 * HALO2_KZG_VERIFY_GAS;
    let savings = baseline_gas as f64 / final_gas as f64;

    AggregationResult {
        strategy: "snarkpack_batch".to_string(),
        num_proofs: n,
        individual_proof_size_bytes: proof_size,
        individual_prove_time_ms: mean_prove / n as f64,
        individual_verify_time_ms: mean_verify / n as f64,
        aggregation_time_ms,
        total_time_ms: mean_prove + aggregation_time_ms,
        final_proof_size_bytes: final_proof_size,
        l1_verification_gas: final_gas,
        l1_gas_per_enterprise: final_gas / n as u64,
        gas_savings_vs_individual: savings,
        num_iterations,
        std_dev_prove_ms: std_prove,
        std_dev_verify_ms: std_verify,
    }
}

fn std_dev(values: &[f64]) -> f64 {
    let mean = values.iter().sum::<f64>() / values.len() as f64;
    let variance = values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / values.len() as f64;
    variance.sqrt()
}
