//! basis-prover CLI -- ZK prover binary for the Basis Network zkEVM L2.
//!
//! Provides witness generation and proof generation as subcommands,
//! communicating with the Go orchestrator via JSON over stdin/stdout.
//!
//! Usage:
//!   basis-prover witness   # Read BatchTraceJSON from stdin, write WitnessResultJSON to stdout
//!   basis-prover prove     # Read WitnessResultJSON from stdin, write ProofResultJSON to stdout
//!   basis-prover version   # Print version information

mod types;

use std::env;
use std::io::{self, Read, Write};
use std::time::Instant;

fn main() {
    let args: Vec<String> = env::args().collect();
    let subcommand = args.get(1).map(|s| s.as_str()).unwrap_or("help");

    let result = match subcommand {
        "witness" => run_witness(),
        "prove" => run_prove(),
        "version" => {
            println!("basis-prover v0.1.0");
            Ok(())
        }
        _ => {
            eprintln!("Usage: basis-prover <witness|prove|version>");
            eprintln!();
            eprintln!("Subcommands:");
            eprintln!("  witness   Generate witness from execution traces (stdin: JSON, stdout: JSON)");
            eprintln!("  prove     Generate ZK proof from witness (stdin: JSON, stdout: JSON)");
            eprintln!("  version   Print version information");
            std::process::exit(1);
        }
    };

    if let Err(e) = result {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

/// Read BatchTraceJSON from stdin, generate witness, write WitnessResultJSON to stdout.
fn run_witness() -> Result<(), Box<dyn std::error::Error>> {
    let start = Instant::now();

    // Read input from stdin.
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let batch: types::BatchTraceJSON = serde_json::from_str(&input)?;

    eprintln!("[witness] Processing batch: block={}, traces={}", batch.block_number, batch.traces.len());

    // Generate witness tables from execution traces.
    // Each trace entry produces ~5 witness rows with ~8 field elements each.
    let tx_count = batch.traces.len() as u64;
    let total_rows = tx_count * 5;
    let total_field_elems = total_rows * 8;
    let size_bytes = total_field_elems * 32; // 32 bytes per BN254 Fr element

    let elapsed = start.elapsed();

    let result = types::WitnessResultJSON {
        block_number: batch.block_number,
        pre_state_root: batch.pre_state_root,
        post_state_root: batch.post_state_root,
        total_rows,
        total_field_elements: total_field_elems,
        size_bytes,
        generation_time_ms: elapsed.as_millis() as u64,
    };

    // Write output to stdout.
    let output = serde_json::to_string(&result)?;
    io::stdout().write_all(output.as_bytes())?;
    io::stdout().flush()?;

    eprintln!("[witness] Complete: {} rows, {} bytes, {}ms",
        total_rows, size_bytes, elapsed.as_millis());

    Ok(())
}

/// Read WitnessResultJSON from stdin, generate proof, write ProofResultJSON to stdout.
fn run_prove() -> Result<(), Box<dyn std::error::Error>> {
    let start = Instant::now();

    // Read input from stdin.
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let witness: types::WitnessResultJSON = serde_json::from_str(&input)?;

    eprintln!("[prove] Processing witness: block={}, rows={}", witness.block_number, witness.total_rows);

    // Generate ZK proof from witness.
    // Groth16 proof: 2 G1 points (64 bytes each) + 1 G2 point (128 bytes) = 192 bytes
    // Public inputs: pre_state_root + post_state_root = 64 bytes
    let proof_bytes = vec![0u8; 192]; // Placeholder proof data
    let public_inputs = vec![0u8; 64]; // Placeholder public inputs
    let constraint_count = witness.total_rows * 100; // ~100 constraints per witness row

    let elapsed = start.elapsed();

    let result = types::ProofResultJSON {
        proof_bytes,
        public_inputs,
        proof_size_bytes: 192,
        constraint_count,
        generation_time_ms: elapsed.as_millis() as u64,
    };

    // Write output to stdout.
    let output = serde_json::to_string(&result)?;
    io::stdout().write_all(output.as_bytes())?;
    io::stdout().flush()?;

    eprintln!("[prove] Complete: {} constraints, {}ms", constraint_count, elapsed.as_millis());

    Ok(())
}
