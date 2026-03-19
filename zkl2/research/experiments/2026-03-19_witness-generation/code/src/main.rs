/// Witness generation benchmark runner.
///
/// Generates synthetic batches of varying sizes and measures:
/// - Witness generation time (ms)
/// - Witness size (field elements, bytes)
/// - Per-table breakdown
/// - Determinism verification
/// - Memory usage estimation
use std::time::Instant;

use witness_gen_experiment::{generate, generate_synthetic_batch, WitnessConfig};

fn main() {
    println!("=== Basis Network zkL2 -- Witness Generation Experiment (RU-L3) ===");
    println!();

    let config = WitnessConfig::default();
    let batch_sizes = [10, 50, 100, 250, 500, 1000];

    println!(
        "{:<10} {:<12} {:<15} {:<15} {:<12} {:<12} {:<12}",
        "TX Count", "Time (ms)", "Total FE", "Size (KB)", "Arith Rows", "Storage Rows", "Call Rows"
    );
    println!("{}", "-".repeat(90));

    for &size in &batch_sizes {
        let batch = generate_synthetic_batch(size);

        // Warm-up run
        let _ = generate(&batch, &config);

        // Benchmark: 30 repetitions for statistical significance
        let mut times = Vec::with_capacity(30);
        let mut result = None;

        for _ in 0..30 {
            let start = Instant::now();
            let r = generate(&batch, &config);
            let elapsed = start.elapsed().as_secs_f64() * 1000.0;
            times.push(elapsed);
            result = Some(r);
        }

        let r = result.unwrap();
        let mean = times.iter().sum::<f64>() / times.len() as f64;
        let std_dev = (times
            .iter()
            .map(|t| (t - mean).powi(2))
            .sum::<f64>()
            / (times.len() - 1) as f64)
            .sqrt();
        let ci_95 = 1.96 * std_dev / (times.len() as f64).sqrt();

        let total_fe = r.witness.total_field_elements();
        let size_kb = r.witness.size_bytes() as f64 / 1024.0;

        let arith_rows = r
            .table_stats
            .get("arithmetic")
            .map(|s| s.row_count)
            .unwrap_or(0);
        let storage_rows = r
            .table_stats
            .get("storage")
            .map(|s| s.row_count)
            .unwrap_or(0);
        let call_rows = r
            .table_stats
            .get("call_context")
            .map(|s| s.row_count)
            .unwrap_or(0);

        println!(
            "{:<10} {:<12.2} {:<15} {:<15.1} {:<12} {:<12} {:<12}",
            size,
            mean,
            total_fe,
            size_kb,
            arith_rows,
            storage_rows,
            call_rows
        );

        // Print CI for key sizes
        if size == 100 || size == 500 || size == 1000 {
            println!(
                "           95% CI: {:.2} +/- {:.2} ms (std: {:.2}, n=30, CI/mean: {:.1}%)",
                mean,
                ci_95,
                std_dev,
                (ci_95 / mean) * 100.0
            );
        }
    }

    println!();
    println!("=== Determinism Verification ===");
    verify_determinism();

    println!();
    println!("=== Depth Sensitivity Analysis ===");
    depth_sensitivity();

    println!();
    println!("=== Per-Table Field Element Breakdown (1000 tx) ===");
    table_breakdown();
}

fn verify_determinism() {
    let batch = generate_synthetic_batch(100);
    let config = WitnessConfig::default();

    let r1 = generate(&batch, &config);
    let r2 = generate(&batch, &config);

    let mut all_match = true;
    for (name, t1) in &r1.witness.tables {
        let t2 = r2.witness.tables.get(name).unwrap();
        if t1.rows != t2.rows {
            println!("  FAIL: Table '{}' differs between runs", name);
            all_match = false;
        }
    }

    if all_match {
        println!(
            "  PASS: All {} tables produce identical output across 2 runs ({} total FE)",
            r1.witness.tables.len(),
            r1.witness.total_field_elements()
        );
    }

    // Additional: verify with different batch, then same batch again
    let batch2 = generate_synthetic_batch(100);
    let r3 = generate(&batch2, &config);
    if r1.witness.total_field_elements() == r3.witness.total_field_elements() {
        println!("  PASS: Identical synthetic batches produce identical witness sizes");
    }
}

fn depth_sensitivity() {
    let batch = generate_synthetic_batch(100);
    let depths = [16, 32, 64, 128, 160, 256];

    println!(
        "  {:<10} {:<12} {:<15} {:<15}",
        "Depth", "Time (ms)", "Total FE", "Size (KB)"
    );
    println!("  {}", "-".repeat(55));

    for &depth in &depths {
        let config = WitnessConfig { smt_depth: depth };

        // 10 reps for depth sensitivity
        let mut times = Vec::with_capacity(10);
        let mut result = None;
        for _ in 0..10 {
            let start = Instant::now();
            let r = generate(&batch, &config);
            times.push(start.elapsed().as_secs_f64() * 1000.0);
            result = Some(r);
        }

        let r = result.unwrap();
        let mean = times.iter().sum::<f64>() / times.len() as f64;

        println!(
            "  {:<10} {:<12.2} {:<15} {:<15.1}",
            depth,
            mean,
            r.witness.total_field_elements(),
            r.witness.size_bytes() as f64 / 1024.0
        );
    }
}

fn table_breakdown() {
    let batch = generate_synthetic_batch(1000);
    let config = WitnessConfig::default();
    let r = generate(&batch, &config);

    let total = r.witness.total_field_elements();
    for (name, stats) in &r.table_stats {
        let pct = stats.field_element_count as f64 / total as f64 * 100.0;
        println!(
            "  {:<15} {:>8} rows x {:>3} cols = {:>10} FE ({:>5.1}%)",
            name, stats.row_count, stats.column_count, stats.field_element_count, pct
        );
    }
    println!(
        "  {:<15} {:>42} FE (100.0%)",
        "TOTAL", total
    );
    println!(
        "  Witness size: {:.1} KB ({:.1} MB)",
        r.witness.size_bytes() as f64 / 1024.0,
        r.witness.size_bytes() as f64 / (1024.0 * 1024.0)
    );
}
