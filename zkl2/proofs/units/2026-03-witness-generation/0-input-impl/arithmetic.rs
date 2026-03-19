/// Arithmetic witness table generator.
///
/// Processes trace entries related to value transfers and balance/nonce changes,
/// converting them to field element rows for the arithmetic constraint table.
///
/// Corresponds to TLA+ `ProcessArithEntry` action:
/// - Guard: `CurrentEntry.op \in ArithOps` (BALANCE_CHANGE, NONCE_CHANGE)
/// - Effect: appends exactly 1 row with `ArithColCount` columns (8)
///
/// [Spec: zkl2/specs/units/2026-03-witness-generation/1-formalization/v0-analysis/specs/WitnessGeneration/WitnessGeneration.tla]
use ark_bn254::Fr;

use crate::error::WitnessResult;
use crate::types::{hex_to_limbs, u64_to_fr, TraceEntry, TraceOp, WitnessRow, WitnessTable};

/// Column layout for the arithmetic table (8 columns, matches TLA+ ArithColCount = 8):
/// [global_counter, op_type, operand_a_hi, operand_a_lo, operand_b_hi, operand_b_lo,
///  result_hi, result_lo]
pub const COLUMNS: &[&str] = &[
    "global_counter",
    "op_type",
    "operand_a_hi",
    "operand_a_lo",
    "operand_b_hi",
    "operand_b_lo",
    "result_hi",
    "result_lo",
];

/// Operation type encoding for arithmetic table.
const OP_BALANCE_CHANGE: u64 = 1;
const OP_NONCE_CHANGE: u64 = 2;

/// Generate arithmetic witness rows from a trace entry.
///
/// Returns rows only for BALANCE_CHANGE and NONCE_CHANGE operations.
/// All other operation types return an empty vector (TLA+ ProcessSkipEntry for this table).
///
/// Invariant S5 (DeterminismGuard): mutual exclusion via match dispatch ensures
/// exactly one branch is taken per entry.
pub fn process_entry(entry: &TraceEntry, global_counter: u64) -> WitnessResult<Vec<WitnessRow>> {
    match entry.op {
        TraceOp::BalanceChange => {
            let (prev_hi, prev_lo) = hex_to_limbs(&entry.prev_balance)?;
            let (curr_hi, curr_lo) = hex_to_limbs(&entry.curr_balance)?;
            // Circuit constraint: prev + delta = curr
            // delta = curr - prev (field subtraction, wraps in Fr)
            Ok(vec![vec![
                u64_to_fr(global_counter),
                u64_to_fr(OP_BALANCE_CHANGE),
                prev_hi,
                prev_lo,
                curr_hi,
                curr_lo,
                curr_hi - prev_hi,
                curr_lo - prev_lo,
            ]])
        }
        TraceOp::NonceChange => {
            // Nonce is u64, fits in a single field element (no limb decomposition).
            let prev = u64_to_fr(entry.prev_nonce);
            let curr = u64_to_fr(entry.curr_nonce);
            let delta = curr - prev;
            Ok(vec![vec![
                u64_to_fr(global_counter),
                u64_to_fr(OP_NONCE_CHANGE),
                Fr::from(0u64), // hi limb unused for u64
                prev,
                Fr::from(0u64),
                curr,
                Fr::from(0u64),
                delta,
            ]])
        }
        _ => Ok(vec![]),
    }
}

/// Create a new arithmetic witness table with the correct column layout.
pub fn new_table() -> WitnessTable {
    WitnessTable::new("arithmetic", COLUMNS.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_entry() -> TraceEntry {
        TraceEntry::default_with_op(TraceOp::LOG)
    }

    #[test]
    fn balance_change_produces_one_row() {
        let entry = TraceEntry {
            op: TraceOp::BalanceChange,
            account: "0x1234".to_string(),
            prev_balance: "0x64".to_string(),
            curr_balance: "0x32".to_string(),
            reason: "transfer".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 1).unwrap();
        assert_eq!(rows.len(), 1, "BALANCE_CHANGE must produce exactly 1 row");
        assert_eq!(rows[0].len(), COLUMNS.len(), "Row width must match ArithColCount");
    }

    #[test]
    fn nonce_change_produces_one_row() {
        let entry = TraceEntry {
            op: TraceOp::NonceChange,
            prev_nonce: 5,
            curr_nonce: 6,
            ..default_entry()
        };
        let rows = process_entry(&entry, 2).unwrap();
        assert_eq!(rows.len(), 1, "NONCE_CHANGE must produce exactly 1 row");
        assert_eq!(rows[0][1], u64_to_fr(OP_NONCE_CHANGE));
    }

    #[test]
    fn nonce_delta_is_correct() {
        let entry = TraceEntry {
            op: TraceOp::NonceChange,
            prev_nonce: 10,
            curr_nonce: 15,
            ..default_entry()
        };
        let rows = process_entry(&entry, 0).unwrap();
        // delta = curr - prev = 15 - 10 = 5
        assert_eq!(rows[0][7], Fr::from(5u64));
    }

    #[test]
    fn sload_produces_no_rows() {
        let entry = TraceEntry {
            op: TraceOp::SLOAD,
            ..default_entry()
        };
        let rows = process_entry(&entry, 0).unwrap();
        assert!(rows.is_empty(), "SLOAD must not produce arithmetic rows");
    }

    #[test]
    fn sstore_produces_no_rows() {
        let entry = TraceEntry {
            op: TraceOp::SSTORE,
            ..default_entry()
        };
        let rows = process_entry(&entry, 0).unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn call_produces_no_rows() {
        let entry = TraceEntry {
            op: TraceOp::CALL,
            ..default_entry()
        };
        let rows = process_entry(&entry, 0).unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn log_produces_no_rows() {
        let entry = TraceEntry {
            op: TraceOp::LOG,
            ..default_entry()
        };
        let rows = process_entry(&entry, 0).unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn global_counter_is_first_column() {
        let entry = TraceEntry {
            op: TraceOp::BalanceChange,
            prev_balance: "0x0".to_string(),
            curr_balance: "0x1".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 42).unwrap();
        assert_eq!(rows[0][0], u64_to_fr(42));
    }
}
