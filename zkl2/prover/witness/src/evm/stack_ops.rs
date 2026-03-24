//! Stack operation witness generator for PUSH, PUSH0, POP, DUP, SWAP.

use ark_bn254::Fr;
use crate::error::WitnessResult;
use crate::types::{TraceEntry, TraceOp, WitnessRow};

pub fn process_entry(
    entry: &TraceEntry,
    global_counter: u64,
) -> WitnessResult<Vec<WitnessRow>> {
    match entry.op {
        TraceOp::PUSH | TraceOp::DUP => {
            let value = crate::types::hex_to_fr(&entry.stack_value).unwrap_or(Fr::from(0u64));
            let op_id = if entry.op == TraceOp::PUSH { 0x60u64 } else { 0x80u64 };
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(op_id),
                value,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::POP | TraceOp::SWAP => {
            let op_id = if entry.op == TraceOp::POP { 0x50u64 } else { 0x90u64 };
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(op_id),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::PUSH0 => {
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x5Fu64), // PUSH0 opcode
                Fr::from(0u64),    // Value is always zero
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        _ => Ok(vec![]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::PUSH);
        entry.stack_value = "0xff".into();
        let rows = process_entry(&entry, 1).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn pop_produces_row() {
        let entry = TraceEntry::default_with_op(TraceOp::POP);
        let rows = process_entry(&entry, 1).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn push0_produces_row() {
        let entry = TraceEntry::default_with_op(TraceOp::PUSH0);
        let rows = process_entry(&entry, 1).unwrap();
        assert_eq!(rows.len(), 1);
        // Verify the value is zero (field element at index 2)
        assert_eq!(rows[0][2], Fr::from(0u64));
    }
}
