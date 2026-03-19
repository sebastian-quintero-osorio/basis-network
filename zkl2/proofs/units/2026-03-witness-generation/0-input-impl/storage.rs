/// Storage witness table generator.
///
/// Processes SLOAD and SSTORE trace entries, converting them to field element rows
/// for the storage constraint table. This is the most witness-intensive table because
/// each storage operation requires a full Merkle proof path (siblings at each SMT level).
///
/// Corresponds to TLA+ actions:
/// - `ProcessStorageRead`: SLOAD -> 1 row with StorageColCount columns
/// - `ProcessStorageWrite`: SSTORE -> 2 rows (old-state path + new-state path),
///   both carrying the same global counter (same source entry)
///
/// [Spec: zkl2/specs/units/2026-03-witness-generation/1-formalization/v0-analysis/specs/WitnessGeneration/WitnessGeneration.tla]
use ark_bn254::Fr;

use crate::error::WitnessResult;
use crate::types::{hex_to_fr, hex_to_limbs, u64_to_fr, TraceEntry, TraceOp, WitnessRow, WitnessTable};

/// Default Sparse Merkle Tree depth for witness size estimation.
/// Production: 160 (account trie) or 256 (storage trie).
/// Default: 32 (matching RU-L4 State Database benchmarks).
pub const DEFAULT_SMT_DEPTH: usize = 32;

/// Fixed column count before Merkle siblings.
const FIXED_COLUMNS: usize = 10;

/// Operation type encoding for storage table.
const OP_SLOAD: u64 = 1;
const OP_SSTORE: u64 = 2;
/// Marker offset for the second Merkle path row in SSTORE.
/// The circuit uses this to distinguish old-state from new-state paths.
const OP_SSTORE_NEW_PATH_MARKER: u64 = 100;

/// Generate column names for the storage table.
///
/// Layout: [global_counter, op_type, account_hash, slot_hash, value_hi, value_lo,
///          old_value_hi, old_value_lo, new_value_hi, new_value_lo,
///          sibling_0, sibling_1, ..., sibling_{depth-1}]
///
/// Total columns: 10 + depth (matches TLA+ StorageColCount).
fn column_names(depth: usize) -> Vec<String> {
    let mut cols = vec![
        "global_counter".to_string(),
        "op_type".to_string(),
        "account_hash".to_string(),
        "slot_hash".to_string(),
        "value_hi".to_string(),
        "value_lo".to_string(),
        "old_value_hi".to_string(),
        "old_value_lo".to_string(),
        "new_value_hi".to_string(),
        "new_value_lo".to_string(),
    ];
    for i in 0..depth {
        cols.push(format!("sibling_{}", i));
    }
    cols
}

/// Generate storage witness rows from a trace entry.
///
/// - SLOAD: 1 row (current value + Merkle inclusion proof)
/// - SSTORE: 2 rows (old-state Merkle path + new-state Merkle path)
/// - Other ops: empty vector
///
/// In production, Merkle siblings come from the State Database's `GetProof()`.
/// Here we use deterministic pseudo-random siblings seeded from the slot hash
/// to ensure determinism while accurately measuring witness size.
pub fn process_entry(
    entry: &TraceEntry,
    global_counter: u64,
    depth: usize,
) -> WitnessResult<Vec<WitnessRow>> {
    match entry.op {
        TraceOp::SLOAD => {
            let account_hash = hex_to_fr(&entry.account)?;
            let slot_hash = hex_to_fr(&entry.slot)?;
            let (value_hi, value_lo) = hex_to_limbs(&entry.value)?;

            let mut row = Vec::with_capacity(FIXED_COLUMNS + depth);
            row.extend_from_slice(&[
                u64_to_fr(global_counter),
                u64_to_fr(OP_SLOAD),
                account_hash,
                slot_hash,
                value_hi,
                value_lo,
                Fr::from(0u64), // old_value_hi (unused for SLOAD)
                Fr::from(0u64), // old_value_lo
                Fr::from(0u64), // new_value_hi
                Fr::from(0u64), // new_value_lo
            ]);

            let siblings = generate_deterministic_siblings(slot_hash, depth);
            row.extend(siblings);

            Ok(vec![row])
        }
        TraceOp::SSTORE => {
            let account_hash = hex_to_fr(&entry.account)?;
            let slot_hash = hex_to_fr(&entry.slot)?;
            let (old_hi, old_lo) = hex_to_limbs(&entry.old_value)?;
            let (new_hi, new_lo) = hex_to_limbs(&entry.new_value)?;

            // Row 1: old-state Merkle path
            let mut row1 = Vec::with_capacity(FIXED_COLUMNS + depth);
            row1.extend_from_slice(&[
                u64_to_fr(global_counter),
                u64_to_fr(OP_SSTORE),
                account_hash,
                slot_hash,
                Fr::from(0u64), // value (unused for SSTORE)
                Fr::from(0u64),
                old_hi,
                old_lo,
                new_hi,
                new_lo,
            ]);
            let old_siblings = generate_deterministic_siblings(slot_hash, depth);
            row1.extend(old_siblings);

            // Row 2: new-state Merkle path (same global counter, same source entry)
            let mut row2 = Vec::with_capacity(FIXED_COLUMNS + depth);
            row2.extend_from_slice(&[
                u64_to_fr(global_counter),
                u64_to_fr(OP_SSTORE + OP_SSTORE_NEW_PATH_MARKER),
                account_hash,
                slot_hash,
                Fr::from(0u64),
                Fr::from(0u64),
                old_hi,
                old_lo,
                new_hi,
                new_lo,
            ]);
            let new_siblings =
                generate_deterministic_siblings(slot_hash + Fr::from(1u64), depth);
            row2.extend(new_siblings);

            Ok(vec![row1, row2])
        }
        _ => Ok(vec![]),
    }
}

/// Generate deterministic pseudo-random Merkle siblings from a seed.
///
/// Uses repeated squaring of the seed field element to produce siblings.
/// Determinism guarantee: same seed -> same siblings (invariant I-08).
///
/// In production, this is replaced by actual Poseidon SMT siblings from `statedb.GetProof()`.
fn generate_deterministic_siblings(seed: Fr, depth: usize) -> Vec<Fr> {
    let mut siblings = Vec::with_capacity(depth);
    let mut current = seed + Fr::from(42u64);
    for _ in 0..depth {
        current = current * current + Fr::from(7u64);
        siblings.push(current);
    }
    siblings
}

/// Create a new storage witness table with the correct column layout.
pub fn new_table(depth: usize) -> WitnessTable {
    let col_names = column_names(depth);
    WitnessTable::with_columns("storage".to_string(), col_names)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_entry() -> TraceEntry {
        TraceEntry::default_with_op(TraceOp::LOG)
    }

    #[test]
    fn sload_produces_one_row() {
        let entry = TraceEntry {
            op: TraceOp::SLOAD,
            account: "0xabcdef".to_string(),
            slot: "0x01".to_string(),
            value: "0xff".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 1, 32).unwrap();
        assert_eq!(rows.len(), 1, "SLOAD must produce exactly 1 row");
        assert_eq!(rows[0].len(), FIXED_COLUMNS + 32, "Row width must be 10 + depth");
    }

    #[test]
    fn sstore_produces_two_rows() {
        let entry = TraceEntry {
            op: TraceOp::SSTORE,
            account: "0xabcdef".to_string(),
            slot: "0x01".to_string(),
            old_value: "0x0a".to_string(),
            new_value: "0x0b".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 2, 32).unwrap();
        assert_eq!(rows.len(), 2, "SSTORE must produce exactly 2 rows");
        assert_eq!(rows[0].len(), FIXED_COLUMNS + 32);
        assert_eq!(rows[1].len(), FIXED_COLUMNS + 32);
    }

    #[test]
    fn sstore_rows_share_global_counter() {
        let entry = TraceEntry {
            op: TraceOp::SSTORE,
            account: "0xabc".to_string(),
            slot: "0x01".to_string(),
            old_value: "0x0".to_string(),
            new_value: "0x1".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 7, 16).unwrap();
        assert_eq!(rows[0][0], rows[1][0], "Both SSTORE rows must share global counter");
        assert_eq!(rows[0][0], u64_to_fr(7));
    }

    #[test]
    fn sstore_second_row_has_marker() {
        let entry = TraceEntry {
            op: TraceOp::SSTORE,
            account: "0xabc".to_string(),
            slot: "0x01".to_string(),
            old_value: "0x0".to_string(),
            new_value: "0x1".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 0, 16).unwrap();
        assert_eq!(rows[0][1], u64_to_fr(OP_SSTORE));
        assert_eq!(
            rows[1][1],
            u64_to_fr(OP_SSTORE + OP_SSTORE_NEW_PATH_MARKER),
            "Second row must have new-path marker"
        );
    }

    #[test]
    fn determinism_same_input_same_output() {
        let entry = TraceEntry {
            op: TraceOp::SLOAD,
            account: "0xabcdef".to_string(),
            slot: "0x42".to_string(),
            value: "0x100".to_string(),
            ..default_entry()
        };
        let rows1 = process_entry(&entry, 1, 32).unwrap();
        let rows2 = process_entry(&entry, 1, 32).unwrap();
        assert_eq!(rows1, rows2, "Determinism violated: same input produced different output");
    }

    #[test]
    fn balance_change_produces_no_rows() {
        let entry = TraceEntry {
            op: TraceOp::BalanceChange,
            ..default_entry()
        };
        let rows = process_entry(&entry, 0, 32).unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn call_produces_no_rows() {
        let entry = TraceEntry {
            op: TraceOp::CALL,
            ..default_entry()
        };
        let rows = process_entry(&entry, 0, 32).unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn variable_depth() {
        let entry = TraceEntry {
            op: TraceOp::SLOAD,
            account: "0xabc".to_string(),
            slot: "0x01".to_string(),
            value: "0xff".to_string(),
            ..default_entry()
        };
        for depth in [4, 16, 32, 64, 128] {
            let rows = process_entry(&entry, 0, depth).unwrap();
            assert_eq!(rows[0].len(), FIXED_COLUMNS + depth);
        }
    }
}
