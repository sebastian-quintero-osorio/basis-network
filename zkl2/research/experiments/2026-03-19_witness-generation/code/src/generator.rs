/// Witness generator: orchestrates all table generators to produce a complete
/// BatchWitness from a BatchTrace.
///
/// This is the core module that the Architect (RU-L3, item [15]) will implement
/// in production. The design follows the multi-table architecture observed in
/// Polygon zkEVM (13 state machines), Scroll (bus-mapping + circuit-per-table),
/// and zkSync Era (Boojum multi-circuit).
///
/// Invariant I-08 (Trace-Witness Bijection): same trace -> same witness, deterministic.
use std::collections::BTreeMap;
use std::time::Instant;

use crate::arithmetic;
use crate::call_context;
use crate::storage;
use crate::types::{BatchTrace, BatchWitness, ExecutionTrace, TraceEntry, hex_to_fr};

/// Configuration for witness generation.
#[derive(Debug, Clone)]
pub struct WitnessConfig {
    /// Sparse Merkle Tree depth for storage proofs.
    pub smt_depth: usize,
}

impl Default for WitnessConfig {
    fn default() -> Self {
        Self {
            smt_depth: storage::DEFAULT_SMT_DEPTH,
        }
    }
}

/// Result of witness generation including timing metrics.
#[derive(Debug, Clone)]
pub struct WitnessResult {
    pub witness: BatchWitness,
    pub generation_time_ms: f64,
    pub tx_count: usize,
    pub trace_entry_count: usize,
    pub table_stats: BTreeMap<String, TableStats>,
}

#[derive(Debug, Clone)]
pub struct TableStats {
    pub row_count: usize,
    pub column_count: usize,
    pub field_element_count: usize,
}

/// Generate a complete witness from a batch trace.
///
/// Processing is sequential and deterministic:
/// 1. Initialize all witness tables
/// 2. Process each transaction in order
/// 3. Within each transaction, process each trace entry in order
/// 4. Each entry is dispatched to the appropriate table generator
/// 5. A global counter ensures consistent ordering across tables
///
/// Determinism guarantee: BTreeMap for tables (sorted by name),
/// sequential processing preserving trace order, no randomness.
pub fn generate(batch: &BatchTrace, config: &WitnessConfig) -> WitnessResult {
    let start = Instant::now();

    // Initialize tables
    let mut arith_table = arithmetic::new_table();
    let mut storage_table = storage::new_table(config.smt_depth);
    let mut call_table = call_context::new_table();

    // Global counter for cross-table ordering (like Scroll's GlobalCounter)
    let mut global_counter: u64 = 0;
    let mut total_entries: usize = 0;

    // Process each transaction sequentially (deterministic order)
    for trace in &batch.traces {
        for entry in &trace.entries {
            total_entries += 1;

            // Dispatch to appropriate table generator
            // Each generator returns rows only for its operation types
            let arith_rows = arithmetic::process_entry(entry, global_counter);
            for row in arith_rows {
                arith_table.add_row(row);
            }

            let storage_rows =
                storage::process_entry(entry, global_counter, config.smt_depth);
            for row in storage_rows {
                storage_table.add_row(row);
            }

            let call_rows = call_context::process_entry(entry, global_counter, trace.success);
            for row in call_rows {
                call_table.add_row(row);
            }

            global_counter += 1;
        }
    }

    // Assemble witness
    let mut tables = BTreeMap::new();

    let mut stats = BTreeMap::new();
    for table in [&arith_table, &storage_table, &call_table] {
        stats.insert(
            table.name.clone(),
            TableStats {
                row_count: table.row_count(),
                column_count: table.columns.len(),
                field_element_count: table.field_element_count(),
            },
        );
    }

    tables.insert(arith_table.name.clone(), arith_table);
    tables.insert(storage_table.name.clone(), storage_table);
    tables.insert(call_table.name.clone(), call_table);

    let witness = BatchWitness {
        block_number: batch.block_number,
        pre_state_root: hex_to_fr(&batch.pre_state_root),
        post_state_root: hex_to_fr(&batch.post_state_root),
        tables,
    };

    let elapsed = start.elapsed();

    WitnessResult {
        witness,
        generation_time_ms: elapsed.as_secs_f64() * 1000.0,
        tx_count: batch.traces.len(),
        trace_entry_count: total_entries,
        table_stats: stats,
    }
}

/// Generate a synthetic batch trace for benchmarking.
/// Creates realistic-looking traces with a mix of operation types.
///
/// Transaction profile (based on enterprise workload analysis):
/// - 40% simple transfers (2 balance changes, 1 nonce change)
/// - 30% storage writes (1 SSTORE, 1 balance change, 1 nonce change)
/// - 20% storage reads + writes (2 SLOAD, 1 SSTORE, 1 balance, 1 nonce)
/// - 10% contract calls (1 CALL, 2 SLOAD, 1 SSTORE, 2 balance, 1 nonce)
pub fn generate_synthetic_batch(tx_count: usize) -> BatchTrace {
    let mut traces = Vec::with_capacity(tx_count);

    for i in 0..tx_count {
        let tx_type = i % 10;
        let entries = match tx_type {
            0..=3 => simple_transfer_entries(i),
            4..=6 => storage_write_entries(i),
            7..=8 => storage_read_write_entries(i),
            _ => contract_call_entries(i),
        };

        traces.push(ExecutionTrace {
            tx_hash: format!("0x{:064x}", i),
            from: format!("0x{:040x}", i * 100),
            to: Some(format!("0x{:040x}", i * 100 + 1)),
            value: format!("0x{:x}", i * 1000),
            gas_used: 21000 + (entries.len() as u64 * 5000),
            success: true,
            opcode_count: entries.len() * 10,
            entries,
        });
    }

    BatchTrace {
        block_number: 1,
        pre_state_root: "0x0000000000000000000000000000000000000000000000000000000000000001".to_string(),
        post_state_root: "0x0000000000000000000000000000000000000000000000000000000000000002".to_string(),
        traces,
    }
}

fn simple_transfer_entries(seed: usize) -> Vec<TraceEntry> {
    vec![
        TraceEntry {
            op: crate::types::TraceOp::NONCE_CHANGE,
            account: format!("0x{:040x}", seed * 100),
            prev_nonce: seed as u64,
            curr_nonce: seed as u64 + 1,
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::BALANCE_CHANGE,
            account: format!("0x{:040x}", seed * 100),
            prev_balance: format!("0x{:x}", 1_000_000 + seed * 1000),
            curr_balance: format!("0x{:x}", 1_000_000 + seed * 1000 - 100),
            reason: "transfer_sender".to_string(),
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::BALANCE_CHANGE,
            account: format!("0x{:040x}", seed * 100 + 1),
            prev_balance: format!("0x{:x}", 500_000 + seed * 500),
            curr_balance: format!("0x{:x}", 500_000 + seed * 500 + 100),
            reason: "transfer_recipient".to_string(),
            ..empty_entry()
        },
    ]
}

fn storage_write_entries(seed: usize) -> Vec<TraceEntry> {
    vec![
        TraceEntry {
            op: crate::types::TraceOp::NONCE_CHANGE,
            account: format!("0x{:040x}", seed * 100),
            prev_nonce: seed as u64,
            curr_nonce: seed as u64 + 1,
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::BALANCE_CHANGE,
            account: format!("0x{:040x}", seed * 100),
            prev_balance: format!("0x{:x}", 1_000_000),
            curr_balance: format!("0x{:x}", 999_000),
            reason: "gas".to_string(),
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::SSTORE,
            account: format!("0x{:040x}", seed * 100 + 50),
            slot: format!("0x{:064x}", seed),
            old_value: format!("0x{:064x}", 0),
            new_value: format!("0x{:064x}", seed * 42),
            ..empty_entry()
        },
    ]
}

fn storage_read_write_entries(seed: usize) -> Vec<TraceEntry> {
    vec![
        TraceEntry {
            op: crate::types::TraceOp::NONCE_CHANGE,
            account: format!("0x{:040x}", seed * 100),
            prev_nonce: seed as u64,
            curr_nonce: seed as u64 + 1,
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::BALANCE_CHANGE,
            account: format!("0x{:040x}", seed * 100),
            prev_balance: format!("0x{:x}", 1_000_000),
            curr_balance: format!("0x{:x}", 999_000),
            reason: "gas".to_string(),
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::SLOAD,
            account: format!("0x{:040x}", seed * 100 + 50),
            slot: format!("0x{:064x}", seed),
            value: format!("0x{:064x}", seed * 10),
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::SLOAD,
            account: format!("0x{:040x}", seed * 100 + 50),
            slot: format!("0x{:064x}", seed + 1),
            value: format!("0x{:064x}", seed * 20),
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::SSTORE,
            account: format!("0x{:040x}", seed * 100 + 50),
            slot: format!("0x{:064x}", seed),
            old_value: format!("0x{:064x}", seed * 10),
            new_value: format!("0x{:064x}", seed * 10 + 1),
            ..empty_entry()
        },
    ]
}

fn contract_call_entries(seed: usize) -> Vec<TraceEntry> {
    vec![
        TraceEntry {
            op: crate::types::TraceOp::NONCE_CHANGE,
            account: format!("0x{:040x}", seed * 100),
            prev_nonce: seed as u64,
            curr_nonce: seed as u64 + 1,
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::CALL,
            from: format!("0x{:040x}", seed * 100),
            to: format!("0x{:040x}", seed * 100 + 200),
            call_value: format!("0x{:x}", seed * 50),
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::BALANCE_CHANGE,
            account: format!("0x{:040x}", seed * 100),
            prev_balance: format!("0x{:x}", 1_000_000),
            curr_balance: format!("0x{:x}", 1_000_000 - seed * 50),
            reason: "call_value".to_string(),
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::BALANCE_CHANGE,
            account: format!("0x{:040x}", seed * 100 + 200),
            prev_balance: format!("0x{:x}", 0),
            curr_balance: format!("0x{:x}", seed * 50),
            reason: "call_value".to_string(),
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::SLOAD,
            account: format!("0x{:040x}", seed * 100 + 200),
            slot: format!("0x{:064x}", seed),
            value: format!("0x{:064x}", seed * 99),
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::SLOAD,
            account: format!("0x{:040x}", seed * 100 + 200),
            slot: format!("0x{:064x}", seed + 1),
            value: format!("0x{:064x}", seed * 88),
            ..empty_entry()
        },
        TraceEntry {
            op: crate::types::TraceOp::SSTORE,
            account: format!("0x{:040x}", seed * 100 + 200),
            slot: format!("0x{:064x}", seed),
            old_value: format!("0x{:064x}", seed * 99),
            new_value: format!("0x{:064x}", seed * 99 + 1),
            ..empty_entry()
        },
    ]
}

fn empty_entry() -> TraceEntry {
    TraceEntry {
        op: crate::types::TraceOp::LOG,
        account: String::new(),
        slot: String::new(),
        value: String::new(),
        old_value: String::new(),
        new_value: String::new(),
        from: String::new(),
        to: String::new(),
        call_value: String::new(),
        prev_balance: String::new(),
        curr_balance: String::new(),
        reason: String::new(),
        prev_nonce: 0,
        curr_nonce: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_synthetic_batch() {
        let batch = generate_synthetic_batch(100);
        assert_eq!(batch.traces.len(), 100);
    }

    #[test]
    fn test_generate_witness_determinism() {
        let batch = generate_synthetic_batch(50);
        let config = WitnessConfig::default();

        let result1 = generate(&batch, &config);
        let result2 = generate(&batch, &config);

        assert_eq!(
            result1.witness.total_field_elements(),
            result2.witness.total_field_elements(),
            "Determinism violated: field element counts differ"
        );
        assert_eq!(
            result1.witness.total_rows(),
            result2.witness.total_rows(),
            "Determinism violated: row counts differ"
        );

        // Verify bit-for-bit equality of all tables
        for (name, table1) in &result1.witness.tables {
            let table2 = result2.witness.tables.get(name).unwrap();
            assert_eq!(table1.rows, table2.rows, "Table {} differs between runs", name);
        }
    }

    #[test]
    fn test_generate_witness_100tx() {
        let batch = generate_synthetic_batch(100);
        let config = WitnessConfig::default();
        let result = generate(&batch, &config);

        assert_eq!(result.tx_count, 100);
        assert!(result.witness.total_field_elements() > 0);
        assert!(result.witness.total_rows() > 0);

        // Verify all tables have rows
        assert!(result.witness.tables.get("arithmetic").unwrap().row_count() > 0);
        assert!(result.witness.tables.get("storage").unwrap().row_count() > 0);
        assert!(result.witness.tables.get("call_context").unwrap().row_count() > 0);
    }

    #[test]
    fn test_witness_size_scaling() {
        let config = WitnessConfig::default();

        let r100 = generate(&generate_synthetic_batch(100), &config);
        let r500 = generate(&generate_synthetic_batch(500), &config);
        let r1000 = generate(&generate_synthetic_batch(1000), &config);

        // Witness size should scale roughly linearly with tx count
        let ratio_500_100 = r500.witness.total_field_elements() as f64
            / r100.witness.total_field_elements() as f64;
        let ratio_1000_100 = r1000.witness.total_field_elements() as f64
            / r100.witness.total_field_elements() as f64;

        // Should be approximately 5x and 10x (within 20% tolerance)
        assert!(
            ratio_500_100 > 4.0 && ratio_500_100 < 6.0,
            "Non-linear scaling: 500/100 ratio = {:.2}",
            ratio_500_100
        );
        assert!(
            ratio_1000_100 > 8.0 && ratio_1000_100 < 12.0,
            "Non-linear scaling: 1000/100 ratio = {:.2}",
            ratio_1000_100
        );
    }
}
