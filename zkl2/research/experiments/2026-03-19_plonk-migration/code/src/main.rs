// PLONK Migration Benchmark: Groth16 (arkworks) vs halo2-KZG
//
// Measures: proving time, verification time, proof size, constraint/row count
// for equivalent circuits (Poseidon-like hash chain, arithmetic operations).
//
// This benchmark validates RU-L9 hypothesis that halo2-KZG maintains verification
// feasibility while enabling custom gates and eliminating per-circuit trusted setup.

mod groth16_bench;
mod halo2_bench;

use serde::Serialize;

#[derive(Serialize, Clone)]
struct BenchmarkResult {
    system: String,
    circuit: String,
    num_constraints_or_rows: usize,
    setup_time_ms: f64,
    proving_time_ms: f64,
    verification_time_ms: f64,
    proof_size_bytes: usize,
    setup_type: String,
    custom_gates: bool,
    num_iterations: usize,
}

fn main() {
    println!("=== PLONK Migration Benchmark (RU-L9) ===");
    println!("Groth16 (arkworks/ark-bn254) vs halo2-KZG (PSE, BN254)");
    println!();

    let mut results: Vec<BenchmarkResult> = Vec::new();
    let num_warmup = 2;
    let num_iterations = 30;

    // --- Groth16 Benchmarks ---
    println!("--- Groth16 (arkworks) ---");

    // Circuit 1: Arithmetic chain (simulates EVM ADD/MUL operations)
    for &chain_length in &[10, 50, 100, 500] {
        println!("  Arithmetic chain (length={})", chain_length);
        let r = groth16_bench::bench_arithmetic_chain(chain_length, num_warmup, num_iterations);
        results.push(r);
    }

    // Circuit 2: Field hash chain (simulates Poseidon-like state root computation)
    for &chain_length in &[10, 50, 100] {
        println!("  Hash chain (length={})", chain_length);
        let r = groth16_bench::bench_hash_chain(chain_length, num_warmup, num_iterations);
        results.push(r);
    }

    println!();

    // --- halo2-KZG Benchmarks ---
    println!("--- halo2-KZG (PSE fork, BN254) ---");

    // Circuit 1: Arithmetic chain with custom gate
    for &chain_length in &[10, 50, 100, 500] {
        println!("  Arithmetic chain (length={})", chain_length);
        let r = halo2_bench::bench_arithmetic_chain(chain_length, num_warmup, num_iterations);
        results.push(r);
    }

    // Circuit 2: Field hash chain with PLONKish gates
    for &chain_length in &[10, 50, 100] {
        println!("  Hash chain (length={})", chain_length);
        let r = halo2_bench::bench_hash_chain(chain_length, num_warmup, num_iterations);
        results.push(r);
    }

    // --- Summary ---
    println!();
    println!("=== Results Summary ===");
    println!("{:<12} {:<20} {:>8} {:>10} {:>10} {:>10} {:>8}",
        "System", "Circuit", "Rows/C", "Setup(ms)", "Prove(ms)", "Verify(ms)", "Proof(B)");
    println!("{}", "-".repeat(88));

    for r in &results {
        println!("{:<12} {:<20} {:>8} {:>10.1} {:>10.1} {:>10.1} {:>8}",
            r.system, r.circuit, r.num_constraints_or_rows,
            r.setup_time_ms, r.proving_time_ms, r.verification_time_ms,
            r.proof_size_bytes);
    }

    // Write results to JSON
    let json = serde_json::to_string_pretty(&results).unwrap();
    std::fs::write("benchmark_results.json", &json).unwrap();
    println!();
    println!("Results written to benchmark_results.json");
}
