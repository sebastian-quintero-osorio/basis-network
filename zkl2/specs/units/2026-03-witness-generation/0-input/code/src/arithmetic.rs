/// Arithmetic witness table generator.
///
/// Processes trace entries related to value transfers and balance/nonce changes,
/// converting them to field element rows for the arithmetic constraint table.
///
/// In a full zkEVM, this table handles ADD, SUB, MUL, DIV, etc.
/// For this prototype, we focus on balance arithmetic (transfers) and nonce increments
/// which are the operations captured by the Go executor's trace format.
use ark_bn254::Fr;

use crate::types::{hex_to_limbs, u64_to_fr, TraceEntry, TraceOp, WitnessRow, WitnessTable};

/// Column layout for the arithmetic table:
/// [global_counter, op_type, operand_a_hi, operand_a_lo, operand_b_hi, operand_b_lo,
///  result_hi, result_lo]
const COLUMNS: &[&str] = &[
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
/// Returns rows only for BALANCE_CHANGE and NONCE_CHANGE operations.
pub fn process_entry(entry: &TraceEntry, global_counter: u64) -> Vec<WitnessRow> {
    match entry.op {
        TraceOp::BALANCE_CHANGE => {
            let (prev_hi, prev_lo) = hex_to_limbs(&entry.prev_balance);
            let (curr_hi, curr_lo) = hex_to_limbs(&entry.curr_balance);
            // Delta = curr - prev (the transfer amount)
            // For the circuit, we encode: prev + delta = curr
            // delta_hi = curr_hi - prev_hi, delta_lo = curr_lo - prev_lo
            // The circuit will verify this arithmetic constraint
            vec![vec![
                u64_to_fr(global_counter),
                u64_to_fr(OP_BALANCE_CHANGE),
                prev_hi,
                prev_lo,
                curr_hi,
                curr_lo,
                curr_hi - prev_hi,
                curr_lo - prev_lo,
            ]]
        }
        TraceOp::NONCE_CHANGE => {
            // Nonce is a u64, fits in a single field element
            let prev = u64_to_fr(entry.prev_nonce);
            let curr = u64_to_fr(entry.curr_nonce);
            let delta = curr - prev;
            vec![vec![
                u64_to_fr(global_counter),
                u64_to_fr(OP_NONCE_CHANGE),
                Fr::from(0u64), // hi limb unused for u64
                prev,
                Fr::from(0u64),
                curr,
                Fr::from(0u64),
                delta,
            ]]
        }
        _ => vec![],
    }
}

/// Create a new arithmetic witness table with the correct column layout.
pub fn new_table() -> WitnessTable {
    WitnessTable::new("arithmetic", COLUMNS.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::TraceEntry;

    #[test]
    fn test_balance_change_witness() {
        let entry = TraceEntry {
            op: TraceOp::BALANCE_CHANGE,
            account: "0x1234".to_string(),
            prev_balance: "0x64".to_string(), // 100
            curr_balance: "0x32".to_string(), // 50
            reason: "transfer".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 1);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].len(), COLUMNS.len());
    }

    #[test]
    fn test_nonce_change_witness() {
        let entry = TraceEntry {
            op: TraceOp::NONCE_CHANGE,
            account: "0x1234".to_string(),
            prev_nonce: 5,
            curr_nonce: 6,
            ..default_entry()
        };
        let rows = process_entry(&entry, 2);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0][1], u64_to_fr(OP_NONCE_CHANGE));
    }

    #[test]
    fn test_sload_ignored() {
        let entry = TraceEntry {
            op: TraceOp::SLOAD,
            ..default_entry()
        };
        let rows = process_entry(&entry, 0);
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
