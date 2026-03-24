/// Witness generator: orchestrates all table generators to produce a complete
/// BatchWitness from a BatchTrace.
///
/// This is the core module implementing the TLA+ `Next` relation:
/// sequential, deterministic dispatch of each trace entry to the appropriate
/// table generator based on its operation type.
///
/// TLA+ mapping:
/// - `Init`: empty tables, globalCounter = 0
/// - `Next`: ProcessArithEntry | ProcessStorageRead | ProcessStorageWrite
///   | ProcessCallEntry | ProcessSkipEntry | Terminated
/// - `Spec`: Init /\ [][Next]_vars /\ WF_vars(Next)
///
/// Invariant I-08 (Trace-Witness Bijection): same trace -> same witness, deterministic.
/// Achieved via: BTreeMap for table ordering, sequential processing, no randomness.
///
/// [Spec: zkl2/specs/units/2026-03-witness-generation/1-formalization/v0-analysis/specs/WitnessGeneration/WitnessGeneration.tla]
use std::collections::BTreeMap;
use std::time::Instant;

use crate::arithmetic;
use crate::call_context;
use crate::error::{WitnessError, WitnessResult};
use crate::storage;
use crate::types::{
    BatchTrace, BatchWitness, ExecutionTrace, TraceEntry, TraceOp, hex_to_fr,
};

/// Configuration for witness generation.
#[derive(Debug, Clone)]
pub struct WitnessConfig {
    /// Sparse Merkle Tree depth for storage proofs.
    /// Default: 32 (matching RU-L4 State Database).
    pub smt_depth: usize,
}

impl Default for WitnessConfig {
    fn default() -> Self {
        Self {
            smt_depth: storage::DEFAULT_SMT_DEPTH,
        }
    }
}

/// Statistics for a single witness table.
#[derive(Debug, Clone)]
pub struct TableStats {
    pub row_count: usize,
    pub column_count: usize,
    pub field_element_count: usize,
}

/// Result of witness generation including timing metrics.
#[derive(Debug, Clone)]
pub struct GenerationResult {
    pub witness: BatchWitness,
    pub generation_time_ms: f64,
    pub tx_count: usize,
    pub trace_entry_count: usize,
    pub table_stats: BTreeMap<String, TableStats>,
}

/// Generate a complete witness from a batch trace.
///
/// Processing is sequential and deterministic (TLA+ `Spec`):
/// 1. Initialize all witness tables (TLA+ `Init`)
/// 2. Process each transaction in order
/// 3. Within each transaction, process each trace entry in order
/// 4. Each entry is dispatched to the appropriate table generator (TLA+ `Next`)
/// 5. A global counter ensures consistent ordering across tables (S4)
///
/// Determinism guarantee (S5 DeterminismGuard):
/// - BTreeMap for tables (sorted by name)
/// - Sequential processing preserving trace order
/// - No randomness, no hash maps
///
/// Returns `Err` if the batch is empty or any trace entry contains invalid data.
pub fn generate(batch: &BatchTrace, config: &WitnessConfig) -> WitnessResult<GenerationResult> {
    if batch.traces.is_empty() {
        return Err(WitnessError::EmptyBatch);
    }

    let start = Instant::now();

    // TLA+ Init: empty tables, globalCounter = 0
    let mut arith_table = arithmetic::new_table();
    let mut storage_table = storage::new_table(config.smt_depth);
    let mut call_table = call_context::new_table();

    // TLA+ globalCounter: monotonically increasing counter for cross-table ordering (S4)
    let mut global_counter: u64 = 0;
    let mut total_entries: usize = 0;

    // TLA+ Next: sequential processing loop (Termination guaranteed by finite trace, L1)
    for trace in &batch.traces {
        for entry in &trace.entries {
            total_entries += 1;

            // Dispatch to arithmetic table (ProcessArithEntry)
            let arith_rows = arithmetic::process_entry(entry, global_counter)?;
            for row in arith_rows {
                arith_table.add_row(row)?;
            }

            // Dispatch to storage table (ProcessStorageRead | ProcessStorageWrite)
            let storage_rows =
                storage::process_entry(entry, global_counter, config.smt_depth)?;
            for row in storage_rows {
                storage_table.add_row(row)?;
            }

            // Dispatch to call context table (ProcessCallEntry)
            let call_rows =
                call_context::process_entry(entry, global_counter, trace.success)?;
            for row in call_rows {
                call_table.add_row(row)?;
            }

            // Dispatch to extended EVM tables
            let math_rows = crate::evm::math::process_entry(entry, global_counter)?;
            for row in math_rows { arith_table.add_row(row)?; }

            let bitwise_rows = crate::evm::bitwise::process_entry(entry, global_counter)?;
            for row in bitwise_rows { arith_table.add_row(row)?; }

            let control_rows = crate::evm::control::process_entry(entry, global_counter)?;
            for row in control_rows { arith_table.add_row(row)?; }

            let crypto_rows = crate::evm::crypto::process_entry(entry, global_counter)?;
            for row in crypto_rows { arith_table.add_row(row)?; }

            let lifecycle_rows = crate::evm::lifecycle::process_entry(entry, global_counter)?;
            for row in lifecycle_rows { arith_table.add_row(row)?; }

            let stack_rows = crate::evm::stack_ops::process_entry(entry, global_counter)?;
            for row in stack_rows { arith_table.add_row(row)?; }

            // TLA+ globalCounter' = globalCounter + 1 (S4: GlobalCounterMonotonic)
            global_counter += 1;
        }
    }

    // Assemble witness with deterministic table ordering (BTreeMap)
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
        pre_state_root: hex_to_fr(&batch.pre_state_root)?,
        post_state_root: hex_to_fr(&batch.post_state_root)?,
        tables,
    };

    let elapsed = start.elapsed();

    Ok(GenerationResult {
        witness,
        generation_time_ms: elapsed.as_secs_f64() * 1000.0,
        tx_count: batch.traces.len(),
        trace_entry_count: total_entries,
        table_stats: stats,
    })
}

/// Generate a synthetic batch trace for benchmarking and testing.
///
/// Creates realistic-looking traces with a mix of operation types:
/// - 40% simple transfers (2 balance changes + 1 nonce change)
/// - 30% storage writes (1 SSTORE + 1 balance + 1 nonce)
/// - 20% storage reads + writes (2 SLOAD + 1 SSTORE + 1 balance + 1 nonce)
/// - 10% contract calls (1 CALL + 2 SLOAD + 1 SSTORE + 2 balance + 1 nonce)
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
        pre_state_root: "0x0000000000000000000000000000000000000000000000000000000000000001"
            .to_string(),
        post_state_root: "0x0000000000000000000000000000000000000000000000000000000000000002"
            .to_string(),
        traces,
    }
}

fn empty_entry() -> TraceEntry {
    TraceEntry::default_with_op(TraceOp::LOG)
}

fn simple_transfer_entries(seed: usize) -> Vec<TraceEntry> {
    vec![
        TraceEntry {
            op: TraceOp::NonceChange,
            account: format!("0x{:040x}", seed * 100),
            prev_nonce: seed as u64,
            curr_nonce: seed as u64 + 1,
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::BalanceChange,
            account: format!("0x{:040x}", seed * 100),
            prev_balance: format!("0x{:x}", 1_000_000 + seed * 1000),
            curr_balance: format!("0x{:x}", 1_000_000 + seed * 1000 - 100),
            reason: "transfer_sender".to_string(),
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::BalanceChange,
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
            op: TraceOp::NonceChange,
            account: format!("0x{:040x}", seed * 100),
            prev_nonce: seed as u64,
            curr_nonce: seed as u64 + 1,
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::BalanceChange,
            account: format!("0x{:040x}", seed * 100),
            prev_balance: format!("0x{:x}", 1_000_000),
            curr_balance: format!("0x{:x}", 999_000),
            reason: "gas".to_string(),
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::SSTORE,
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
            op: TraceOp::NonceChange,
            account: format!("0x{:040x}", seed * 100),
            prev_nonce: seed as u64,
            curr_nonce: seed as u64 + 1,
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::BalanceChange,
            account: format!("0x{:040x}", seed * 100),
            prev_balance: format!("0x{:x}", 1_000_000),
            curr_balance: format!("0x{:x}", 999_000),
            reason: "gas".to_string(),
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::SLOAD,
            account: format!("0x{:040x}", seed * 100 + 50),
            slot: format!("0x{:064x}", seed),
            value: format!("0x{:064x}", seed * 10),
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::SLOAD,
            account: format!("0x{:040x}", seed * 100 + 50),
            slot: format!("0x{:064x}", seed + 1),
            value: format!("0x{:064x}", seed * 20),
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::SSTORE,
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
            op: TraceOp::NonceChange,
            account: format!("0x{:040x}", seed * 100),
            prev_nonce: seed as u64,
            curr_nonce: seed as u64 + 1,
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::CALL,
            from: format!("0x{:040x}", seed * 100),
            to: format!("0x{:040x}", seed * 100 + 200),
            call_value: format!("0x{:x}", seed * 50),
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::BalanceChange,
            account: format!("0x{:040x}", seed * 100),
            prev_balance: format!("0x{:x}", 1_000_000),
            curr_balance: format!("0x{:x}", 1_000_000 - seed * 50),
            reason: "call_value".to_string(),
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::BalanceChange,
            account: format!("0x{:040x}", seed * 100 + 200),
            prev_balance: format!("0x{:x}", 0),
            curr_balance: format!("0x{:x}", seed * 50),
            reason: "call_value".to_string(),
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::SLOAD,
            account: format!("0x{:040x}", seed * 100 + 200),
            slot: format!("0x{:064x}", seed),
            value: format!("0x{:064x}", seed * 99),
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::SLOAD,
            account: format!("0x{:040x}", seed * 100 + 200),
            slot: format!("0x{:064x}", seed + 1),
            value: format!("0x{:064x}", seed * 88),
            ..empty_entry()
        },
        TraceEntry {
            op: TraceOp::SSTORE,
            account: format!("0x{:040x}", seed * 100 + 200),
            slot: format!("0x{:064x}", seed),
            old_value: format!("0x{:064x}", seed * 99),
            new_value: format!("0x{:064x}", seed * 99 + 1),
            ..empty_entry()
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn synthetic_batch_correct_count() {
        let batch = generate_synthetic_batch(100);
        assert_eq!(batch.traces.len(), 100);
    }

    #[test]
    fn generate_empty_batch_returns_error() {
        let batch = BatchTrace {
            block_number: 1,
            pre_state_root: "0x1".to_string(),
            post_state_root: "0x2".to_string(),
            traces: vec![],
        };
        let result = generate(&batch, &WitnessConfig::default());
        assert!(result.is_err());
    }

    #[test]
    fn generate_witness_determinism() {
        let batch = generate_synthetic_batch(50);
        let config = WitnessConfig::default();

        let result1 = generate(&batch, &config).unwrap();
        let result2 = generate(&batch, &config).unwrap();

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

        // Bit-for-bit equality of all tables
        for (name, table1) in &result1.witness.tables {
            let table2 = result2.witness.tables.get(name).unwrap();
            assert_eq!(table1.rows, table2.rows, "Table {} differs between runs", name);
        }
    }

    #[test]
    fn generate_witness_100tx() {
        let batch = generate_synthetic_batch(100);
        let config = WitnessConfig::default();
        let result = generate(&batch, &config).unwrap();

        assert_eq!(result.tx_count, 100);
        assert!(result.witness.total_field_elements() > 0);
        assert!(result.witness.total_rows() > 0);

        assert!(result.witness.tables.get("arithmetic").unwrap().row_count() > 0);
        assert!(result.witness.tables.get("storage").unwrap().row_count() > 0);
        assert!(result.witness.tables.get("call_context").unwrap().row_count() > 0);
    }

    #[test]
    fn completeness_row_counts_match_spec() {
        // TLA+ S1 (Completeness): row counts must match expected per operation type.
        //
        // MC_WitnessGeneration test case: 6 entries across 2 transactions:
        // TX1: BALANCE_CHANGE, SSTORE, CALL
        // TX2: NONCE_CHANGE, SLOAD, LOG
        // Expected: arithRows=2, storageRows=3 (SSTORE=2 + SLOAD=1), callRows=1
        let batch = BatchTrace {
            block_number: 1,
            pre_state_root: "0x1".to_string(),
            post_state_root: "0x2".to_string(),
            traces: vec![
                ExecutionTrace {
                    tx_hash: "0x01".to_string(),
                    from: "0xaaaa".to_string(),
                    to: Some("0xbbbb".to_string()),
                    value: "0x0".to_string(),
                    gas_used: 21000,
                    success: true,
                    opcode_count: 30,
                    entries: vec![
                        TraceEntry {
                            op: TraceOp::BalanceChange,
                            account: "0xaaaa".to_string(),
                            prev_balance: "0x100".to_string(),
                            curr_balance: "0x50".to_string(),
                            reason: "transfer".to_string(),
                            ..empty_entry()
                        },
                        TraceEntry {
                            op: TraceOp::SSTORE,
                            account: "0xbbbb".to_string(),
                            slot: "0x01".to_string(),
                            old_value: "0x0".to_string(),
                            new_value: "0xff".to_string(),
                            ..empty_entry()
                        },
                        TraceEntry {
                            op: TraceOp::CALL,
                            from: "0xaaaa".to_string(),
                            to: "0xcccc".to_string(),
                            call_value: "0x10".to_string(),
                            ..empty_entry()
                        },
                    ],
                },
                ExecutionTrace {
                    tx_hash: "0x02".to_string(),
                    from: "0xdddd".to_string(),
                    to: Some("0xeeee".to_string()),
                    value: "0x0".to_string(),
                    gas_used: 21000,
                    success: true,
                    opcode_count: 30,
                    entries: vec![
                        TraceEntry {
                            op: TraceOp::NonceChange,
                            account: "0xdddd".to_string(),
                            prev_nonce: 0,
                            curr_nonce: 1,
                            ..empty_entry()
                        },
                        TraceEntry {
                            op: TraceOp::SLOAD,
                            account: "0xeeee".to_string(),
                            slot: "0x02".to_string(),
                            value: "0xab".to_string(),
                            ..empty_entry()
                        },
                        TraceEntry {
                            op: TraceOp::LOG,
                            ..empty_entry()
                        },
                    ],
                },
            ],
        };

        let config = WitnessConfig::default();
        let result = generate(&batch, &config).unwrap();

        let arith = result.witness.tables.get("arithmetic").unwrap();
        let storage = result.witness.tables.get("storage").unwrap();
        let call = result.witness.tables.get("call_context").unwrap();

        assert_eq!(arith.row_count(), 2, "S1 Completeness: expected 2 arith rows");
        assert_eq!(storage.row_count(), 3, "S1 Completeness: expected 3 storage rows");
        assert_eq!(call.row_count(), 1, "S1 Completeness: expected 1 call row");
        assert_eq!(result.trace_entry_count, 6, "Total entries must be 6");
    }

    #[test]
    fn global_counter_monotonic() {
        // TLA+ S4 (GlobalCounterMonotonic): globalCounter = idx - 1
        // After processing all entries, global_counter == total_entries
        let batch = generate_synthetic_batch(10);
        let config = WitnessConfig::default();
        let result = generate(&batch, &config).unwrap();

        // Verify global counters are monotonically increasing within each table
        for (name, table) in &result.witness.tables {
            let mut prev_gc = None;
            for row in &table.rows {
                let gc = row[0]; // global_counter is always column 0
                if let Some(prev) = prev_gc {
                    assert!(gc >= prev, "Non-monotonic counter in table {}", name);
                }
                prev_gc = Some(gc);
            }
        }
    }

    #[test]
    fn witness_size_scales_linearly() {
        let config = WitnessConfig::default();

        let r100 = generate(&generate_synthetic_batch(100), &config).unwrap();
        let r500 = generate(&generate_synthetic_batch(500), &config).unwrap();
        let r1000 = generate(&generate_synthetic_batch(1000), &config).unwrap();

        let ratio_500_100 = r500.witness.total_field_elements() as f64
            / r100.witness.total_field_elements() as f64;
        let ratio_1000_100 = r1000.witness.total_field_elements() as f64
            / r100.witness.total_field_elements() as f64;

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

    #[test]
    fn log_entries_produce_no_witness_rows() {
        // TLA+ ProcessSkipEntry: LOG entries increment counter but produce no rows.
        let batch = BatchTrace {
            block_number: 1,
            pre_state_root: "0x1".to_string(),
            post_state_root: "0x2".to_string(),
            traces: vec![ExecutionTrace {
                tx_hash: "0x01".to_string(),
                from: "0xaaaa".to_string(),
                to: Some("0xbbbb".to_string()),
                value: "0x0".to_string(),
                gas_used: 21000,
                success: true,
                opcode_count: 10,
                entries: vec![
                    TraceEntry {
                        op: TraceOp::LOG,
                        ..empty_entry()
                    },
                    TraceEntry {
                        op: TraceOp::LOG,
                        ..empty_entry()
                    },
                    TraceEntry {
                        op: TraceOp::LOG,
                        ..empty_entry()
                    },
                ],
            }],
        };

        let result = generate(&batch, &WitnessConfig::default()).unwrap();
        assert_eq!(result.witness.total_rows(), 0, "LOG entries must not produce rows");
        assert_eq!(result.trace_entry_count, 3, "All entries must be counted");
    }
}
