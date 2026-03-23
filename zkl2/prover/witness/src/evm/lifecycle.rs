//! Lifecycle witness generator for CREATE, CREATE2.

use ark_bn254::Fr;
use crate::error::WitnessResult;
use crate::types::{TraceEntry, TraceOp, WitnessRow};

pub fn process_entry(
    entry: &TraceEntry,
    global_counter: u64,
) -> WitnessResult<Vec<WitnessRow>> {
    match entry.op {
        TraceOp::CREATE | TraceOp::CREATE2 => {
            let value = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let op_id = if entry.op == TraceOp::CREATE { 0xF0u64 } else { 0xF5u64 };
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(op_id),
                value,
                Fr::from(0u64), // salt (CREATE2) or zero
                Fr::from(1u64), // success flag
            ]])
        }
        _ => Ok(vec![]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::CREATE);
        entry.operand_a = "0x00".into();
        let rows = process_entry(&entry, 1).unwrap();
        assert_eq!(rows.len(), 1);
    }
}
