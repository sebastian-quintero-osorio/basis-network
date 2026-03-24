//! Control flow witness generator for JUMP, JUMPI, RETURN, REVERT.

use ark_bn254::Fr;
use crate::error::WitnessResult;
use crate::types::{TraceEntry, TraceOp, WitnessRow};

pub fn process_entry(
    entry: &TraceEntry,
    global_counter: u64,
) -> WitnessResult<Vec<WitnessRow>> {
    match entry.op {
        TraceOp::JUMP | TraceOp::JUMPI => {
            let dest = Fr::from(entry.destination);
            let cond = Fr::from(entry.condition);
            let op_id = if entry.op == TraceOp::JUMP { 0x56u64 } else { 0x57u64 };
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(op_id),
                dest,
                cond,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::RETURN | TraceOp::REVERT => {
            let offset = Fr::from(entry.mem_offset);
            let size = Fr::from(entry.sha3_size);
            let op_id = if entry.op == TraceOp::RETURN { 0xF3u64 } else { 0xFDu64 };
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(op_id),
                offset,
                size,
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
    fn jump_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::JUMP);
        entry.destination = 100;
        let rows = process_entry(&entry, 1).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn return_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::RETURN);
        entry.mem_offset = 0;
        entry.sha3_size = 32;
        let rows = process_entry(&entry, 1).unwrap();
        assert_eq!(rows.len(), 1);
    }
}
