//! Memory access table generator for EVM memory operations.
//!
//! Tracks MLOAD/MSTORE operations to enforce memory read-write consistency
//! within the zkEVM circuit. Each memory access produces a witness row
//! that the circuit verifies against a sorted memory access log.
//!
//! Column layout (6 columns):
//!   [global_counter, is_write, address, value, prev_value, call_id]

use ark_bn254::Fr;
use crate::error::WitnessResult;
use crate::types::{TraceEntry, TraceOp, WitnessRow};

/// Number of columns in the memory table.
pub const MEMORY_TABLE_COLUMNS: usize = 6;

pub const COL_GLOBAL_COUNTER: usize = 0;
pub const COL_IS_WRITE: usize = 1;
pub const COL_ADDRESS: usize = 2;
pub const COL_VALUE: usize = 3;
pub const COL_PREV_VALUE: usize = 4;
pub const COL_CALL_ID: usize = 5;

/// Generate memory table rows from a trace entry.
///
/// Currently generates rows for SSTORE (memory-like write pattern).
/// Full MLOAD/MSTORE support requires opcode-level trace granularity
/// from the Go executor.
pub fn process_entry(
    entry: &TraceEntry,
    global_counter: u64,
) -> WitnessResult<Vec<WitnessRow>> {
    match entry.op {
        TraceOp::SSTORE => {
            let mut row = vec![Fr::from(0u64); MEMORY_TABLE_COLUMNS];
            row[COL_GLOBAL_COUNTER] = Fr::from(global_counter);
            row[COL_IS_WRITE] = Fr::from(1u64);

            if let Ok(addr) = crate::types::hex_to_fr(&entry.account) {
                row[COL_ADDRESS] = addr;
            }
            if let Ok(val) = crate::types::hex_to_fr(&entry.new_value) {
                row[COL_VALUE] = val;
            }
            if let Ok(prev) = crate::types::hex_to_fr(&entry.old_value) {
                row[COL_PREV_VALUE] = prev;
            }

            Ok(vec![row])
        }
        TraceOp::SLOAD => {
            let mut row = vec![Fr::from(0u64); MEMORY_TABLE_COLUMNS];
            row[COL_GLOBAL_COUNTER] = Fr::from(global_counter);
            row[COL_IS_WRITE] = Fr::from(0u64); // Read

            if let Ok(addr) = crate::types::hex_to_fr(&entry.account) {
                row[COL_ADDRESS] = addr;
            }
            if let Ok(val) = crate::types::hex_to_fr(&entry.value) {
                row[COL_VALUE] = val;
            }

            Ok(vec![row])
        }
        _ => Ok(vec![]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::TraceEntry;

    #[test]
    fn sstore_produces_write_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::SSTORE);
        entry.account = "0x01".into();
        entry.old_value = "0x00".into();
        entry.new_value = "0xff".into();
        let entry = entry;
        let rows = process_entry(&entry, 5).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0][COL_IS_WRITE], Fr::from(1u64));
    }

    #[test]
    fn sload_produces_read_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::SLOAD);
        entry.account = "0x01".into();
        entry.value = "0x42".into();
        let rows = process_entry(&entry, 3).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0][COL_IS_WRITE], Fr::from(0u64));
    }
}
