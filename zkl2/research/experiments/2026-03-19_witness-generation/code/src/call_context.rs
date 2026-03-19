/// Call context witness table generator.
///
/// Processes CALL trace entries, converting them to field element rows
/// for the call context constraint table. Each CALL requires context switch
/// data including caller, callee, transferred value, and call depth.
use ark_bn254::Fr;

use crate::types::{hex_to_fr, hex_to_limbs, u64_to_fr, TraceEntry, TraceOp, WitnessRow, WitnessTable};

/// Column layout for the call context table:
/// [global_counter, caller_hash, callee_hash, value_hi, value_lo,
///  is_success, call_depth, gas_available]
const COLUMNS: &[&str] = &[
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
/// Returns rows only for CALL operations.
pub fn process_entry(entry: &TraceEntry, global_counter: u64, tx_success: bool) -> Vec<WitnessRow> {
    match entry.op {
        TraceOp::CALL => {
            let caller_hash = hex_to_fr(&entry.from);
            let callee_hash = hex_to_fr(&entry.to);
            let (value_hi, value_lo) = hex_to_limbs(&entry.call_value);

            vec![vec![
                u64_to_fr(global_counter),
                caller_hash,
                callee_hash,
                value_hi,
                value_lo,
                if tx_success { Fr::from(1u64) } else { Fr::from(0u64) },
                Fr::from(1u64), // depth (simplified: always 1 for top-level calls)
                Fr::from(0u64), // gas_available (zero-fee model, placeholder)
            ]]
        }
        _ => vec![],
    }
}

/// Create a new call context witness table.
pub fn new_table() -> WitnessTable {
    WitnessTable::new("call_context", COLUMNS.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_call_witness() {
        let entry = TraceEntry {
            op: TraceOp::CALL,
            from: "0xaaaa".to_string(),
            to: "0xbbbb".to_string(),
            call_value: "0x100".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 5, true);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].len(), COLUMNS.len());
        // Verify success flag is 1
        assert_eq!(rows[0][5], Fr::from(1u64));
    }

    #[test]
    fn test_non_call_ignored() {
        let entry = TraceEntry {
            op: TraceOp::SLOAD,
            ..default_entry()
        };
        let rows = process_entry(&entry, 0, true);
        assert!(rows.is_empty());
    }

    fn default_entry() -> TraceEntry {
        TraceEntry {
            op: TraceOp::LOG,
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
}
