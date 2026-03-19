/// Adversarial test suite for the witness generator.
///
/// Goal: DESTRUCTION. Every test attempts to break the implementation through
/// malformed inputs, edge cases, and violation of assumed invariants.
///
/// Attack vectors:
/// - Invalid hex values (non-hex characters, overflow, empty)
/// - Malformed trace entries (missing fields, wrong op types)
/// - Boundary conditions (empty batches, single entry, massive batches)
/// - Determinism attacks (timing, ordering sensitivity)
/// - Row width consistency attacks (table corruption)
/// - Global counter monotonicity violations
///
/// [Spec: zkl2/specs/units/2026-03-witness-generation/1-formalization/v0-analysis/specs/WitnessGeneration/WitnessGeneration.tla]
use basis_witness::error::WitnessError;
use basis_witness::generator::{generate, generate_synthetic_batch, WitnessConfig};
use basis_witness::types::{
    BatchTrace, ExecutionTrace, TraceEntry, TraceOp, WitnessTable, hex_to_fr,
};

// ---------------------------------------------------------------------------
// A-01: Empty batch rejection
// ---------------------------------------------------------------------------

#[test]
fn adversarial_empty_batch_rejected() {
    let batch = BatchTrace {
        block_number: 1,
        pre_state_root: "0x1".to_string(),
        post_state_root: "0x2".to_string(),
        traces: vec![],
    };
    let result = generate(&batch, &WitnessConfig::default());
    assert!(
        matches!(result, Err(WitnessError::EmptyBatch)),
        "Empty batch must be rejected, not silently produce empty witness"
    );
}

// ---------------------------------------------------------------------------
// A-02: Invalid hex in state roots
// ---------------------------------------------------------------------------

#[test]
fn adversarial_invalid_hex_state_root() {
    let batch = BatchTrace {
        block_number: 1,
        pre_state_root: "0xGGGG_NOT_HEX".to_string(),
        post_state_root: "0x2".to_string(),
        traces: vec![make_minimal_trace()],
    };
    let result = generate(&batch, &WitnessConfig::default());
    assert!(result.is_err(), "Invalid hex in state root must produce error");
}

// ---------------------------------------------------------------------------
// A-03: Invalid hex in balance fields
// ---------------------------------------------------------------------------

#[test]
fn adversarial_invalid_hex_balance() {
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
            opcode_count: 1,
            entries: vec![TraceEntry {
                op: TraceOp::BalanceChange,
                account: "0xaaaa".to_string(),
                prev_balance: "ZZZZNOTAHEXVALUE".to_string(),
                curr_balance: "0x100".to_string(),
                ..TraceEntry::default_with_op(TraceOp::BalanceChange)
            }],
        }],
    };
    let result = generate(&batch, &WitnessConfig::default());
    assert!(result.is_err(), "Invalid hex in balance must produce error");
}

// ---------------------------------------------------------------------------
// A-04: Invalid hex in storage slot
// ---------------------------------------------------------------------------

#[test]
fn adversarial_invalid_hex_storage_slot() {
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
            opcode_count: 1,
            entries: vec![TraceEntry {
                op: TraceOp::SLOAD,
                account: "0xabc".to_string(),
                slot: "NOT_HEX!!".to_string(),
                value: "0xff".to_string(),
                ..TraceEntry::default_with_op(TraceOp::SLOAD)
            }],
        }],
    };
    let result = generate(&batch, &WitnessConfig::default());
    assert!(result.is_err(), "Invalid hex in slot must produce error");
}

// ---------------------------------------------------------------------------
// A-05: Invalid hex in call value
// ---------------------------------------------------------------------------

#[test]
fn adversarial_invalid_hex_call_value() {
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
            opcode_count: 1,
            entries: vec![TraceEntry {
                op: TraceOp::CALL,
                from: "0xaaaa".to_string(),
                to: "0xbbbb".to_string(),
                call_value: "DEADBEEF_BUT_WITH_G".to_string(),
                ..TraceEntry::default_with_op(TraceOp::CALL)
            }],
        }],
    };
    let result = generate(&batch, &WitnessConfig::default());
    assert!(result.is_err(), "Invalid hex in call_value must produce error");
}

// ---------------------------------------------------------------------------
// A-06: Determinism under repeated execution (100 iterations)
// ---------------------------------------------------------------------------

#[test]
fn adversarial_determinism_100_iterations() {
    let batch = generate_synthetic_batch(100);
    let config = WitnessConfig::default();
    let reference = generate(&batch, &config).unwrap();

    for i in 0..100 {
        let result = generate(&batch, &config).unwrap();
        for (name, ref_table) in &reference.witness.tables {
            let test_table = result.witness.tables.get(name).unwrap();
            assert_eq!(
                ref_table.rows, test_table.rows,
                "Determinism violated on iteration {} in table {}",
                i, name
            );
        }
    }
}

// ---------------------------------------------------------------------------
// A-07: Single-entry traces (boundary)
// ---------------------------------------------------------------------------

#[test]
fn adversarial_single_balance_entry() {
    let batch = BatchTrace {
        block_number: 1,
        pre_state_root: "0x1".to_string(),
        post_state_root: "0x2".to_string(),
        traces: vec![ExecutionTrace {
            tx_hash: "0x01".to_string(),
            from: "0xaa".to_string(),
            to: Some("0xbb".to_string()),
            value: "0x0".to_string(),
            gas_used: 21000,
            success: true,
            opcode_count: 1,
            entries: vec![TraceEntry {
                op: TraceOp::BalanceChange,
                prev_balance: "0x100".to_string(),
                curr_balance: "0x200".to_string(),
                ..TraceEntry::default_with_op(TraceOp::BalanceChange)
            }],
        }],
    };
    let result = generate(&batch, &WitnessConfig::default()).unwrap();
    assert_eq!(result.witness.tables.get("arithmetic").unwrap().row_count(), 1);
    assert_eq!(result.witness.tables.get("storage").unwrap().row_count(), 0);
    assert_eq!(result.witness.tables.get("call_context").unwrap().row_count(), 0);
}

#[test]
fn adversarial_single_sload_entry() {
    let batch = BatchTrace {
        block_number: 1,
        pre_state_root: "0x1".to_string(),
        post_state_root: "0x2".to_string(),
        traces: vec![ExecutionTrace {
            tx_hash: "0x01".to_string(),
            from: "0xaa".to_string(),
            to: Some("0xbb".to_string()),
            value: "0x0".to_string(),
            gas_used: 21000,
            success: true,
            opcode_count: 1,
            entries: vec![TraceEntry {
                op: TraceOp::SLOAD,
                account: "0xabc".to_string(),
                slot: "0x01".to_string(),
                value: "0xff".to_string(),
                ..TraceEntry::default_with_op(TraceOp::SLOAD)
            }],
        }],
    };
    let result = generate(&batch, &WitnessConfig::default()).unwrap();
    assert_eq!(result.witness.tables.get("arithmetic").unwrap().row_count(), 0);
    assert_eq!(result.witness.tables.get("storage").unwrap().row_count(), 1);
    assert_eq!(result.witness.tables.get("call_context").unwrap().row_count(), 0);
}

// ---------------------------------------------------------------------------
// A-08: All-LOG trace (no witness rows produced)
// ---------------------------------------------------------------------------

#[test]
fn adversarial_all_log_entries() {
    let batch = BatchTrace {
        block_number: 1,
        pre_state_root: "0x1".to_string(),
        post_state_root: "0x2".to_string(),
        traces: vec![ExecutionTrace {
            tx_hash: "0x01".to_string(),
            from: "0xaa".to_string(),
            to: Some("0xbb".to_string()),
            value: "0x0".to_string(),
            gas_used: 21000,
            success: true,
            opcode_count: 100,
            entries: (0..100)
                .map(|_| TraceEntry::default_with_op(TraceOp::LOG))
                .collect(),
        }],
    };
    let result = generate(&batch, &WitnessConfig::default()).unwrap();
    assert_eq!(result.witness.total_rows(), 0);
    assert_eq!(result.trace_entry_count, 100);
}

// ---------------------------------------------------------------------------
// A-09: Row width consistency (S3) -- table construction prevents mismatched rows
// ---------------------------------------------------------------------------

#[test]
fn adversarial_row_width_mismatch_rejected() {
    let mut table = WitnessTable::new("test", vec!["a", "b", "c"]);
    use ark_bn254::Fr;

    // Correct width
    assert!(table.add_row(vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64)]).is_ok());

    // Wrong width: too few
    assert!(table.add_row(vec![Fr::from(1u64), Fr::from(2u64)]).is_err());

    // Wrong width: too many
    assert!(table
        .add_row(vec![Fr::from(1u64), Fr::from(2u64), Fr::from(3u64), Fr::from(4u64)])
        .is_err());

    // Only the valid row should be in the table
    assert_eq!(table.row_count(), 1);
}

// ---------------------------------------------------------------------------
// A-10: Completeness invariant (S1) -- all op types produce correct row counts
// ---------------------------------------------------------------------------

#[test]
fn adversarial_completeness_all_op_types() {
    let batch = BatchTrace {
        block_number: 1,
        pre_state_root: "0x1".to_string(),
        post_state_root: "0x2".to_string(),
        traces: vec![ExecutionTrace {
            tx_hash: "0x01".to_string(),
            from: "0xaa".to_string(),
            to: Some("0xbb".to_string()),
            value: "0x0".to_string(),
            gas_used: 21000,
            success: true,
            opcode_count: 10,
            entries: vec![
                // 3 BALANCE_CHANGE -> 3 arith rows
                TraceEntry {
                    op: TraceOp::BalanceChange,
                    prev_balance: "0x1".to_string(),
                    curr_balance: "0x2".to_string(),
                    ..TraceEntry::default_with_op(TraceOp::BalanceChange)
                },
                TraceEntry {
                    op: TraceOp::BalanceChange,
                    prev_balance: "0x3".to_string(),
                    curr_balance: "0x4".to_string(),
                    ..TraceEntry::default_with_op(TraceOp::BalanceChange)
                },
                TraceEntry {
                    op: TraceOp::BalanceChange,
                    prev_balance: "0x5".to_string(),
                    curr_balance: "0x6".to_string(),
                    ..TraceEntry::default_with_op(TraceOp::BalanceChange)
                },
                // 2 NONCE_CHANGE -> 2 arith rows (total 5)
                TraceEntry {
                    op: TraceOp::NonceChange,
                    prev_nonce: 0,
                    curr_nonce: 1,
                    ..TraceEntry::default_with_op(TraceOp::NonceChange)
                },
                TraceEntry {
                    op: TraceOp::NonceChange,
                    prev_nonce: 1,
                    curr_nonce: 2,
                    ..TraceEntry::default_with_op(TraceOp::NonceChange)
                },
                // 2 SLOAD -> 2 storage rows
                TraceEntry {
                    op: TraceOp::SLOAD,
                    account: "0xabc".to_string(),
                    slot: "0x01".to_string(),
                    value: "0xff".to_string(),
                    ..TraceEntry::default_with_op(TraceOp::SLOAD)
                },
                TraceEntry {
                    op: TraceOp::SLOAD,
                    account: "0xdef".to_string(),
                    slot: "0x02".to_string(),
                    value: "0xee".to_string(),
                    ..TraceEntry::default_with_op(TraceOp::SLOAD)
                },
                // 1 SSTORE -> 2 storage rows (total 4)
                TraceEntry {
                    op: TraceOp::SSTORE,
                    account: "0xabc".to_string(),
                    slot: "0x01".to_string(),
                    old_value: "0xff".to_string(),
                    new_value: "0x100".to_string(),
                    ..TraceEntry::default_with_op(TraceOp::SSTORE)
                },
                // 2 CALL -> 2 call rows
                TraceEntry {
                    op: TraceOp::CALL,
                    from: "0xaa".to_string(),
                    to: "0xbb".to_string(),
                    call_value: "0x10".to_string(),
                    ..TraceEntry::default_with_op(TraceOp::CALL)
                },
                TraceEntry {
                    op: TraceOp::CALL,
                    from: "0xcc".to_string(),
                    to: "0xdd".to_string(),
                    call_value: "0x20".to_string(),
                    ..TraceEntry::default_with_op(TraceOp::CALL)
                },
                // 1 LOG -> 0 rows
                TraceEntry::default_with_op(TraceOp::LOG),
            ],
        }],
    };

    let result = generate(&batch, &WitnessConfig::default()).unwrap();
    assert_eq!(
        result.witness.tables.get("arithmetic").unwrap().row_count(),
        5,
        "S1: 3 BALANCE_CHANGE + 2 NONCE_CHANGE = 5 arith rows"
    );
    assert_eq!(
        result.witness.tables.get("storage").unwrap().row_count(),
        4,
        "S1: 2 SLOAD (2 rows) + 1 SSTORE (2 rows) = 4 storage rows"
    );
    assert_eq!(
        result.witness.tables.get("call_context").unwrap().row_count(),
        2,
        "S1: 2 CALL = 2 call rows"
    );
    assert_eq!(result.trace_entry_count, 11);
}

// ---------------------------------------------------------------------------
// A-11: Soundness (S2) -- rows only from matching operations
// ---------------------------------------------------------------------------

#[test]
fn adversarial_soundness_no_cross_table_leak() {
    // If we only submit SLOAD entries, no arithmetic or call rows should appear.
    let batch = BatchTrace {
        block_number: 1,
        pre_state_root: "0x1".to_string(),
        post_state_root: "0x2".to_string(),
        traces: vec![ExecutionTrace {
            tx_hash: "0x01".to_string(),
            from: "0xaa".to_string(),
            to: Some("0xbb".to_string()),
            value: "0x0".to_string(),
            gas_used: 21000,
            success: true,
            opcode_count: 5,
            entries: vec![
                TraceEntry {
                    op: TraceOp::SLOAD,
                    account: "0xabc".to_string(),
                    slot: "0x01".to_string(),
                    value: "0xff".to_string(),
                    ..TraceEntry::default_with_op(TraceOp::SLOAD)
                },
                TraceEntry {
                    op: TraceOp::SLOAD,
                    account: "0xdef".to_string(),
                    slot: "0x02".to_string(),
                    value: "0xee".to_string(),
                    ..TraceEntry::default_with_op(TraceOp::SLOAD)
                },
            ],
        }],
    };

    let result = generate(&batch, &WitnessConfig::default()).unwrap();
    assert_eq!(
        result.witness.tables.get("arithmetic").unwrap().row_count(),
        0,
        "S2: SLOAD entries must not produce arithmetic rows"
    );
    assert_eq!(
        result.witness.tables.get("call_context").unwrap().row_count(),
        0,
        "S2: SLOAD entries must not produce call rows"
    );
    assert_eq!(
        result.witness.tables.get("storage").unwrap().row_count(),
        2,
        "S2: 2 SLOAD = 2 storage rows"
    );
}

// ---------------------------------------------------------------------------
// A-12: JSON round-trip (Go interoperability)
// ---------------------------------------------------------------------------

#[test]
fn adversarial_json_round_trip() {
    let batch = generate_synthetic_batch(10);
    let json = serde_json::to_string(&batch).unwrap();
    let deserialized: BatchTrace = serde_json::from_str(&json).unwrap();

    let config = WitnessConfig::default();
    let r1 = generate(&batch, &config).unwrap();
    let r2 = generate(&deserialized, &config).unwrap();

    assert_eq!(
        r1.witness.total_field_elements(),
        r2.witness.total_field_elements(),
        "JSON round-trip must preserve witness generation"
    );

    for (name, t1) in &r1.witness.tables {
        let t2 = r2.witness.tables.get(name).unwrap();
        assert_eq!(t1.rows, t2.rows, "JSON round-trip changed table {}", name);
    }
}

// ---------------------------------------------------------------------------
// A-13: SMT depth sensitivity
// ---------------------------------------------------------------------------

#[test]
fn adversarial_smt_depth_affects_storage_width() {
    let batch = BatchTrace {
        block_number: 1,
        pre_state_root: "0x1".to_string(),
        post_state_root: "0x2".to_string(),
        traces: vec![ExecutionTrace {
            tx_hash: "0x01".to_string(),
            from: "0xaa".to_string(),
            to: Some("0xbb".to_string()),
            value: "0x0".to_string(),
            gas_used: 21000,
            success: true,
            opcode_count: 1,
            entries: vec![TraceEntry {
                op: TraceOp::SLOAD,
                account: "0xabc".to_string(),
                slot: "0x01".to_string(),
                value: "0xff".to_string(),
                ..TraceEntry::default_with_op(TraceOp::SLOAD)
            }],
        }],
    };

    for depth in [4, 16, 32, 64, 128, 256] {
        let config = WitnessConfig { smt_depth: depth };
        let result = generate(&batch, &config).unwrap();
        let storage = result.witness.tables.get("storage").unwrap();
        assert_eq!(
            storage.columns.len(),
            10 + depth,
            "Storage column count must be 10 + depth for depth={}",
            depth
        );
        assert_eq!(storage.rows[0].len(), 10 + depth);
    }
}

// ---------------------------------------------------------------------------
// A-14: Failed transaction (success = false) affects call context
// ---------------------------------------------------------------------------

#[test]
fn adversarial_failed_tx_call_success_flag() {
    let batch = BatchTrace {
        block_number: 1,
        pre_state_root: "0x1".to_string(),
        post_state_root: "0x2".to_string(),
        traces: vec![ExecutionTrace {
            tx_hash: "0x01".to_string(),
            from: "0xaa".to_string(),
            to: Some("0xbb".to_string()),
            value: "0x0".to_string(),
            gas_used: 21000,
            success: false, // FAILED transaction
            opcode_count: 1,
            entries: vec![TraceEntry {
                op: TraceOp::CALL,
                from: "0xaaaa".to_string(),
                to: "0xbbbb".to_string(),
                call_value: "0x100".to_string(),
                ..TraceEntry::default_with_op(TraceOp::CALL)
            }],
        }],
    };

    let result = generate(&batch, &WitnessConfig::default()).unwrap();
    let call_table = result.witness.tables.get("call_context").unwrap();
    use ark_bn254::Fr;
    assert_eq!(
        call_table.rows[0][5],
        Fr::from(0u64),
        "Failed tx must set is_success = 0 in call context"
    );
}

// ---------------------------------------------------------------------------
// A-15: Large batch stress test (1000 tx)
// ---------------------------------------------------------------------------

#[test]
fn adversarial_large_batch_1000tx() {
    let batch = generate_synthetic_batch(1000);
    let config = WitnessConfig::default();
    let result = generate(&batch, &config).unwrap();

    assert_eq!(result.tx_count, 1000);
    assert!(result.witness.total_rows() > 0);
    assert!(result.generation_time_ms < 30_000.0, "Must complete in < 30 seconds");

    // Verify no table is empty (synthetic batch has all op types)
    for (name, table) in &result.witness.tables {
        assert!(table.row_count() > 0, "Table {} should not be empty for 1000 tx", name);
    }
}

// ---------------------------------------------------------------------------
// A-16: hex_to_fr edge cases
// ---------------------------------------------------------------------------

#[test]
fn adversarial_hex_to_fr_empty_string() {
    assert_eq!(hex_to_fr("").unwrap(), ark_bn254::Fr::from(0u64));
}

#[test]
fn adversarial_hex_to_fr_just_prefix() {
    assert_eq!(hex_to_fr("0x").unwrap(), ark_bn254::Fr::from(0u64));
}

#[test]
fn adversarial_hex_to_fr_max_u256() {
    // 2^256 - 1 (all ff bytes), should reduce mod p
    let result = hex_to_fr("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    assert!(result.is_ok(), "Max u256 must not fail (reduces mod p)");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_minimal_trace() -> ExecutionTrace {
    ExecutionTrace {
        tx_hash: "0x01".to_string(),
        from: "0xaaaa".to_string(),
        to: Some("0xbbbb".to_string()),
        value: "0x0".to_string(),
        gas_used: 21000,
        success: true,
        opcode_count: 1,
        entries: vec![TraceEntry {
            op: TraceOp::NonceChange,
            prev_nonce: 0,
            curr_nonce: 1,
            ..TraceEntry::default_with_op(TraceOp::NonceChange)
        }],
    }
}
