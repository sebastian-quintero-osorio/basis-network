// Proof Aggregation Benchmark (RU-L10)
//
// Measures the cost-benefit of aggregating N enterprise halo2-KZG proofs
// into a single L1 verification using four strategies:
// 1. No aggregation (baseline)
// 2. Binary tree accumulation (halo2 snark-verifier pattern)
// 3. Folding-based aggregation (ProtoGalaxy/Nova + Groth16 decider)
// 4. SnarkPack-style batch verification
//
// Metrics: proof generation time, aggregation overhead, final proof size,
//          L1 verification gas, per-enterprise amortized gas cost.

mod enterprise_circuit;
mod aggregation;

use aggregation::*;
use serde::Serialize;

#[derive(Serialize)]
struct BenchmarkSuite {
    experiment: String,
    batch_size: usize,
    num_warmup: usize,
    num_iterations: usize,
    results: Vec<AggregationResult>,
}

fn main() {
    println!("=== Proof Aggregation Benchmark (RU-L10) ===");
    println!("Multi-enterprise halo2-KZG proof aggregation strategies");
    println!();

    let batch_size = 8; // 8 state transition steps per enterprise batch
    let num_warmup = 2;
    let num_iterations = 30;

    let mut all_results: Vec<AggregationResult> = Vec::new();

    // Test across different numbers of enterprises
    let enterprise_counts = [1, 2, 4, 8, 16];

    for &n in &enterprise_counts {
        println!("--- N={} enterprises ---", n);

        // Strategy 1: No aggregation (baseline)
        println!("  [1/4] No aggregation (baseline)...");
        let r = benchmark_no_aggregation(n, batch_size, num_warmup, num_iterations);
        print_result(&r);
        all_results.push(r);

        if n > 1 {
            // Strategy 2: Binary tree accumulation
            println!("  [2/4] Binary tree (halo2 accumulation)...");
            let r = benchmark_binary_tree_accumulation(n, batch_size, num_warmup, num_iterations);
            print_result(&r);
            all_results.push(r);

            // Strategy 3: Folding + Groth16 decider
            println!("  [3/4] Folding + Groth16 decider...");
            let r = benchmark_folding_aggregation(n, batch_size, num_warmup, num_iterations);
            print_result(&r);
            all_results.push(r);

            // Strategy 4: SnarkPack batch
            println!("  [4/4] SnarkPack batch verification...");
            let r = benchmark_snarkpack_aggregation(n, batch_size, num_warmup, num_iterations);
            print_result(&r);
            all_results.push(r);
        }

        println!();
    }

    // Print summary table
    println!("=== SUMMARY: Gas Savings by Strategy and N ===");
    println!();
    println!("{:<30} {:>5} {:>12} {:>12} {:>12} {:>10} {:>10}",
        "Strategy", "N", "Gas Total", "Gas/Ent", "Agg Time", "Proof(B)", "Savings");
    println!("{}", "-".repeat(101));

    for r in &all_results {
        println!("{:<30} {:>5} {:>12} {:>12} {:>10.0}ms {:>10} {:>9.1}x",
            r.strategy, r.num_proofs,
            format_gas(r.l1_verification_gas),
            format_gas(r.l1_gas_per_enterprise),
            r.aggregation_time_ms,
            r.final_proof_size_bytes,
            r.gas_savings_vs_individual);
    }

    // Print amortized cost table (the key result)
    println!();
    println!("=== KEY RESULT: Per-Enterprise L1 Verification Gas ===");
    println!();
    println!("{:<30} {:>10} {:>10} {:>10} {:>10} {:>10}",
        "Strategy", "N=1", "N=2", "N=4", "N=8", "N=16");
    println!("{}", "-".repeat(80));

    // Collect by strategy
    let strategies = ["none", "binary_tree_halo2", "folding_groth16_decider", "snarkpack_batch"];
    for strategy in &strategies {
        let mut row = format!("{:<30}", strategy);
        for &n in &enterprise_counts {
            let result = all_results.iter().find(|r| r.strategy == *strategy && r.num_proofs == n);
            match result {
                Some(r) => row.push_str(&format!(" {:>10}", format_gas(r.l1_gas_per_enterprise))),
                None => row.push_str(&format!(" {:>10}", "N/A")),
            }
        }
        println!("{}", row);
    }

    // Write results to JSON
    let suite = BenchmarkSuite {
        experiment: "proof-aggregation-ru-l10".to_string(),
        batch_size,
        num_warmup,
        num_iterations,
        results: all_results,
    };

    let json = serde_json::to_string_pretty(&suite).unwrap();
    std::fs::write("benchmark_results.json", &json).unwrap();
    println!();
    println!("Results written to benchmark_results.json");
}

fn print_result(r: &AggregationResult) {
    println!("    Proof: {} bytes | Prove: {:.1}ms/ent | Gas: {} ({}/ent) | Savings: {:.1}x",
        r.individual_proof_size_bytes,
        r.individual_prove_time_ms,
        format_gas(r.l1_verification_gas),
        format_gas(r.l1_gas_per_enterprise),
        r.gas_savings_vs_individual);
}

fn format_gas(gas: u64) -> String {
    if gas >= 1_000_000 {
        format!("{:.2}M", gas as f64 / 1_000_000.0)
    } else {
        format!("{}K", gas / 1_000)
    }
}
