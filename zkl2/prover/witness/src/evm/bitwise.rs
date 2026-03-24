//! Bitwise witness generator for SHL, SHR, SAR, BYTE, AND, OR, XOR, NOT opcodes.

use ark_bn254::Fr;
use crate::error::WitnessResult;
use crate::types::{TraceEntry, TraceOp, WitnessRow};

pub fn process_entry(
    entry: &TraceEntry,
    global_counter: u64,
) -> WitnessResult<Vec<WitnessRow>> {
    match entry.op {
        TraceOp::SHL | TraceOp::SHR => {
            let a = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let shift = Fr::from(entry.shift_amount);
            let op_id = if entry.op == TraceOp::SHL { 0x1Bu64 } else { 0x1Cu64 };
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(op_id),
                a,
                shift,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::SAR => {
            let a = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let shift = Fr::from(entry.shift_amount);
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x1Du64), // SAR opcode
                a,
                shift,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::BYTE => {
            let word = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let index = crate::types::hex_to_fr(&entry.operand_b).unwrap_or(Fr::from(0u64));
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x1Au64),
                word,
                index,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::AND | TraceOp::OR | TraceOp::XOR => {
            let a = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let b = crate::types::hex_to_fr(&entry.operand_b).unwrap_or(Fr::from(0u64));
            let op_id = match entry.op {
                TraceOp::AND => 0x16u64,
                TraceOp::OR => 0x17u64,
                TraceOp::XOR => 0x18u64,
                _ => 0u64,
            };
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(op_id),
                a,
                b,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::NOT => {
            let a = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x19u64), // NOT opcode
                a,
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
    fn shl_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::SHL);
        entry.operand_a = "0x05".into();
        entry.shift_amount = 3;
        let rows = process_entry(&entry, 1).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn sar_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::SAR);
        entry.operand_a = "0xff".into();
        entry.shift_amount = 4;
        let rows = process_entry(&entry, 2).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn xor_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::XOR);
        entry.operand_a = "0x0f".into();
        entry.operand_b = "0xf0".into();
        let rows = process_entry(&entry, 3).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn not_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::NOT);
        entry.operand_a = "0xff".into();
        let rows = process_entry(&entry, 4).unwrap();
        assert_eq!(rows.len(), 1);
    }
}
