//! Arithmetic witness table generator for EVM math opcodes.
//!
//! Handles: ADD, SUB, MUL, DIV, MOD, EXP, SDIV, SMOD, ADDMOD, MULMOD,
//!          SIGNEXTEND, LT, GT, SLT, SGT, EQ, ISZERO
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
        TraceOp::SDIV => {
            let a = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let b = crate::types::hex_to_fr(&entry.operand_b).unwrap_or(Fr::from(0u64));
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x05u64), // SDIV opcode
                a,
                b,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::SMOD => {
            let a = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let b = crate::types::hex_to_fr(&entry.operand_b).unwrap_or(Fr::from(0u64));
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x07u64), // SMOD opcode
                a,
                b,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::ADDMOD => {
            let a = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let b = crate::types::hex_to_fr(&entry.operand_b).unwrap_or(Fr::from(0u64));
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x08u64), // ADDMOD opcode
                a,
                b,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::MULMOD => {
            let a = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let b = crate::types::hex_to_fr(&entry.operand_b).unwrap_or(Fr::from(0u64));
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x09u64), // MULMOD opcode
                a,
                b,
                Fr::from(0u64),
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
        TraceOp::SIGNEXTEND => {
            let a = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let b = crate::types::hex_to_fr(&entry.operand_b).unwrap_or(Fr::from(0u64));
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x0Bu64), // SIGNEXTEND opcode
                a,
                b,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::LT | TraceOp::GT | TraceOp::SLT | TraceOp::SGT | TraceOp::EQ => {
            let a = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            let b = crate::types::hex_to_fr(&entry.operand_b).unwrap_or(Fr::from(0u64));
            let op_id = match entry.op {
                TraceOp::LT => 0x10u64,
                TraceOp::GT => 0x11u64,
                TraceOp::SLT => 0x12u64,
                TraceOp::SGT => 0x13u64,
                TraceOp::EQ => 0x14u64,
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
        TraceOp::ISZERO => {
            let a = crate::types::hex_to_fr(&entry.operand_a).unwrap_or(Fr::from(0u64));
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x15u64), // ISZERO opcode
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

    #[test]
    fn sdiv_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::SDIV);
        entry.operand_a = "0x0a".into();
        entry.operand_b = "0x02".into();
        let rows = process_entry(&entry, 3).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn addmod_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::ADDMOD);
        entry.operand_a = "0x0a".into();
        entry.operand_b = "0x14".into();
        let rows = process_entry(&entry, 4).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn slt_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::SLT);
        entry.operand_a = "0x0a".into();
        entry.operand_b = "0x14".into();
        let rows = process_entry(&entry, 5).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn signextend_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::SIGNEXTEND);
        entry.operand_a = "0xff".into();
        entry.operand_b = "0x00".into();
        let rows = process_entry(&entry, 6).unwrap();
        assert_eq!(rows.len(), 1);
    }
}
