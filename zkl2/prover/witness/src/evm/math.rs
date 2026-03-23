//! Arithmetic witness table generator for EVM math opcodes.
//!
//! Handles: ADD, SUB, MUL, DIV, MOD, EXP
//! Produces rows for the arithmetic execution table.

use ark_bn254::Fr;
use crate::error::WitnessResult;
use crate::types::{TraceEntry, TraceOp, WitnessRow};

/// Process an arithmetic trace entry into witness rows.
pub fn process_entry(
    entry: &TraceEntry,
    global_counter: u64,
) -> WitnessResult<Vec<WitnessRow>> {
    match entry.op {
        TraceOp::ADD | TraceOp::SUB | TraceOp::MUL | TraceOp::DIV | TraceOp::MOD => {
            let a = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let b = crate::types::hex_to_fr(&entry.operand_b).unwrap_or(Fr::from(0u64));
            let op_id = match entry.op {
                TraceOp::ADD => 0x01u64,
                TraceOp::SUB => 0x03u64,
                TraceOp::MUL => 0x02u64,
                TraceOp::DIV => 0x04u64,
                TraceOp::MOD => 0x06u64,
                _ => 0u64,
            };
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(op_id),
                a,
                b,
                Fr::from(0u64), // result placeholder (computed by circuit)
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::EXP => {
            let base = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let exp = crate::types::hex_to_fr(&entry.operand_b).unwrap_or(Fr::from(0u64));
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x0Au64), // EXP opcode
                base,
                exp,
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
    fn add_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::ADD);
        entry.operand_a = "0x0a".into();
        entry.operand_b = "0x14".into();
        let rows = process_entry(&entry, 1).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].len(), 8);
    }

    #[test]
    fn exp_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::EXP);
        entry.operand_a = "0x02".into();
        entry.operand_b = "0x08".into();
        let rows = process_entry(&entry, 2).unwrap();
        assert_eq!(rows.len(), 1);
    }
}
