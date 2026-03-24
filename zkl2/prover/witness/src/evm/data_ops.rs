//! Data access witness generator for CALLDATASIZE, CALLDATACOPY, CODESIZE,
//! CODECOPY, RETURNDATASIZE, RETURNDATACOPY, EXTCODESIZE, EXTCODECOPY,
//! EXTCODEHASH opcodes.

use ark_bn254::Fr;
use crate::error::WitnessResult;
use crate::types::{TraceEntry, TraceOp, WitnessRow};

pub fn process_entry(
    entry: &TraceEntry,
    global_counter: u64,
) -> WitnessResult<Vec<WitnessRow>> {
    match entry.op {
        TraceOp::CALLDATALOAD => {
            let offset = Fr::from(entry.mem_offset);
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x35u64), // CALLDATALOAD opcode
                offset,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::CALLDATASIZE => {
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x36u64), // CALLDATASIZE opcode
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::CALLDATACOPY => {
            let dest = Fr::from(entry.mem_offset);
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x37u64), // CALLDATACOPY opcode
                dest,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::CODESIZE => {
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x38u64), // CODESIZE opcode
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::CODECOPY => {
            let dest = Fr::from(entry.mem_offset);
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x39u64), // CODECOPY opcode
                dest,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::EXTCODESIZE => {
            let addr = crate::types::hex_to_fr(&entry.account).unwrap_or(Fr::from(0u64));
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x3Bu64), // EXTCODESIZE opcode
                addr,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::EXTCODECOPY => {
            let addr = crate::types::hex_to_fr(&entry.account).unwrap_or(Fr::from(0u64));
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x3Cu64), // EXTCODECOPY opcode
                addr,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::EXTCODEHASH => {
            let addr = crate::types::hex_to_fr(&entry.account).unwrap_or(Fr::from(0u64));
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x3Fu64), // EXTCODEHASH opcode
                addr,
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::RETURNDATASIZE => {
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x3Du64), // RETURNDATASIZE opcode
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
                Fr::from(0u64),
            ]])
        }
        TraceOp::RETURNDATACOPY => {
            let dest = Fr::from(entry.mem_offset);
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x3Eu64), // RETURNDATACOPY opcode
                dest,
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
    fn calldatasize_produces_row() {
        let entry = TraceEntry::default_with_op(TraceOp::CALLDATASIZE);
        let rows = process_entry(&entry, 1).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn calldatacopy_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::CALLDATACOPY);
        entry.mem_offset = 0;
        let rows = process_entry(&entry, 2).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn codesize_produces_row() {
        let entry = TraceEntry::default_with_op(TraceOp::CODESIZE);
        let rows = process_entry(&entry, 3).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn extcodesize_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::EXTCODESIZE);
        entry.account = "0xdead".into();
        let rows = process_entry(&entry, 4).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn extcodehash_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::EXTCODEHASH);
        entry.account = "0xbeef".into();
        let rows = process_entry(&entry, 5).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn returndatasize_produces_row() {
        let entry = TraceEntry::default_with_op(TraceOp::RETURNDATASIZE);
        let rows = process_entry(&entry, 6).unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn returndatacopy_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::RETURNDATACOPY);
        entry.mem_offset = 64;
        let rows = process_entry(&entry, 7).unwrap();
        assert_eq!(rows.len(), 1);
    }
}
