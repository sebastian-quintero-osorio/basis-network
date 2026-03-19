/// Call context witness table generator.
///
/// Processes CALL trace entries, converting them to field element rows
/// for the call context constraint table. Each CALL requires context switch
/// data: caller, callee, transferred value, success flag, call depth, gas.
///
/// Corresponds to TLA+ `ProcessCallEntry` action:
/// - Guard: `CurrentEntry.op \in CallOps`
/// - Effect: appends exactly 1 row with `CallColCount` columns (8)
///
/// [Spec: zkl2/specs/units/2026-03-witness-generation/1-formalization/v0-analysis/specs/WitnessGeneration/WitnessGeneration.tla]
use ark_bn254::Fr;

use crate::error::WitnessResult;
use crate::types::{hex_to_fr, hex_to_limbs, u64_to_fr, TraceEntry, TraceOp, WitnessRow, WitnessTable};

/// Column layout for the call context table (8 columns, matches TLA+ CallColCount = 8):
/// [global_counter, caller_hash, callee_hash, value_hi, value_lo,
///  is_success, call_depth, gas_available]
pub const COLUMNS: &[&str] = &[
    "global_counter",
    "caller_hash",
    "callee_hash",
    "value_hi",
    "value_lo",
    "is_success",
    "call_depth",
    "gas_available",
];

/// Generate call context witness rows from a trace entry.
///
/// Returns rows only for CALL operations. All other operations return empty.
///
/// The `tx_success` flag comes from the parent `ExecutionTrace.success` field
/// and determines whether the CALL completed without revert.
pub fn process_entry(
    entry: &TraceEntry,
    global_counter: u64,
    tx_success: bool,
) -> WitnessResult<Vec<WitnessRow>> {
    match entry.op {
        TraceOp::CALL => {
            let caller_hash = hex_to_fr(&entry.from)?;
            let callee_hash = hex_to_fr(&entry.to)?;
            let (value_hi, value_lo) = hex_to_limbs(&entry.call_value)?;

            Ok(vec![vec![
                u64_to_fr(global_counter),
                caller_hash,
                callee_hash,
                value_hi,
                value_lo,
                if tx_success { Fr::from(1u64) } else { Fr::from(0u64) },
                Fr::from(1u64), // depth (simplified: always 1 for top-level calls)
                Fr::from(0u64), // gas_available (zero-fee model, placeholder)
            ]])
        }
        _ => Ok(vec![]),
    }
}

/// Create a new call context witness table.
pub fn new_table() -> WitnessTable {
    WitnessTable::new("call_context", COLUMNS.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_entry() -> TraceEntry {
        TraceEntry::default_with_op(TraceOp::LOG)
    }

    #[test]
    fn call_produces_one_row() {
        let entry = TraceEntry {
            op: TraceOp::CALL,
            from: "0xaaaa".to_string(),
            to: "0xbbbb".to_string(),
            call_value: "0x100".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 5, true).unwrap();
        assert_eq!(rows.len(), 1, "CALL must produce exactly 1 row");
        assert_eq!(rows[0].len(), COLUMNS.len(), "Row width must match CallColCount");
    }

    #[test]
    fn success_flag_true() {
        let entry = TraceEntry {
            op: TraceOp::CALL,
            from: "0xaaaa".to_string(),
            to: "0xbbbb".to_string(),
            call_value: "0x0".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 0, true).unwrap();
        assert_eq!(rows[0][5], Fr::from(1u64), "Success flag must be 1 for successful tx");
    }

    #[test]
    fn success_flag_false() {
        let entry = TraceEntry {
            op: TraceOp::CALL,
            from: "0xaaaa".to_string(),
            to: "0xbbbb".to_string(),
            call_value: "0x0".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 0, false).unwrap();
        assert_eq!(rows[0][5], Fr::from(0u64), "Success flag must be 0 for failed tx");
    }

    #[test]
    fn sload_produces_no_rows() {
        let entry = TraceEntry {
            op: TraceOp::SLOAD,
            ..default_entry()
        };
        let rows = process_entry(&entry, 0, true).unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn balance_change_produces_no_rows() {
        let entry = TraceEntry {
            op: TraceOp::BalanceChange,
            ..default_entry()
        };
        let rows = process_entry(&entry, 0, true).unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn global_counter_is_first_column() {
        let entry = TraceEntry {
            op: TraceOp::CALL,
            from: "0x1".to_string(),
            to: "0x2".to_string(),
            call_value: "0x0".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 99, true).unwrap();
        assert_eq!(rows[0][0], u64_to_fr(99));
    }
}
