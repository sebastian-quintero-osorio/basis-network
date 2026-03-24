//! Execution table generator for EVM opcode traces.
//!
//! Generates witness rows for the CPU execution trace table, mapping each
//! state-modifying operation from the Go executor into field element rows
//! for the zkEVM circuit.
//!
//! Column layout (14 columns):
//!   [global_counter, tx_id, op_id, pc, gas_left, stack_depth,
//!    operand_a, operand_b, result, state_root_before, state_root_after,
//!    is_success, call_id, memory_size]
//!
//! This table is the core of the zkEVM circuit -- it proves that each
//! EVM opcode was executed correctly given the input state.

use ark_bn254::Fr;

use crate::error::WitnessResult;
use crate::types::{TraceEntry, TraceOp, WitnessRow};

/// Number of columns in the execution table.
pub const EXECUTION_TABLE_COLUMNS: usize = 14;

/// Column indices.
pub const COL_GLOBAL_COUNTER: usize = 0;
pub const COL_TX_ID: usize = 1;
pub const COL_OP_ID: usize = 2;
pub const COL_PC: usize = 3;
pub const COL_GAS_LEFT: usize = 4;
pub const COL_STACK_DEPTH: usize = 5;
pub const COL_OPERAND_A: usize = 6;
pub const COL_OPERAND_B: usize = 7;
pub const COL_RESULT: usize = 8;
pub const COL_STATE_ROOT_BEFORE: usize = 9;
pub const COL_STATE_ROOT_AFTER: usize = 10;
pub const COL_IS_SUCCESS: usize = 11;
pub const COL_CALL_ID: usize = 12;
pub const COL_MEMORY_SIZE: usize = 13;

/// Generate execution table rows from a trace entry.
///
/// Maps TraceOp variants to EVM opcodes and produces one row per
/// state-modifying operation.
pub fn process_entry(
    entry: &TraceEntry,
    global_counter: u64,
    tx_id: u64,
) -> WitnessResult<Vec<WitnessRow>> {
    let op_id = match entry.op {
        TraceOp::BalanceChange => super::OP_BALANCE,
        TraceOp::NonceChange => super::OP_ADD,
        TraceOp::SLOAD => super::OP_SLOAD,
        TraceOp::SSTORE => super::OP_SSTORE,
        TraceOp::CALL => super::OP_CALL,
        TraceOp::LOG => return Ok(vec![]),
        // Arithmetic opcodes
        TraceOp::ADD => super::OP_ADD,
        TraceOp::SUB => super::OP_SUB,
        TraceOp::MUL => super::OP_MUL,
        TraceOp::DIV => super::OP_DIV,
        TraceOp::MOD => super::OP_MOD,
        TraceOp::EXP => super::OP_EXP,
        TraceOp::SDIV => super::OP_SDIV,
        TraceOp::SMOD => super::OP_SMOD,
        TraceOp::ADDMOD => super::OP_ADDMOD,
        TraceOp::MULMOD => super::OP_MULMOD,
        TraceOp::SIGNEXTEND => super::OP_SIGNEXTEND,
        // Comparison opcodes
        TraceOp::LT => super::OP_LT,
        TraceOp::GT => super::OP_GT,
        TraceOp::SLT => super::OP_SLT,
        TraceOp::SGT => super::OP_SGT,
        TraceOp::EQ => super::OP_EQ,
        TraceOp::ISZERO => super::OP_ISZERO,
        // Bitwise opcodes
        TraceOp::AND => super::OP_AND,
        TraceOp::OR => super::OP_OR,
        TraceOp::XOR => super::OP_XOR,
        TraceOp::NOT => super::OP_NOT,
        TraceOp::SHL => super::OP_SHL,
        TraceOp::SHR => super::OP_SHR,
        TraceOp::SAR => super::OP_SAR,
        TraceOp::BYTE => super::OP_BYTE,
        // Crypto
        TraceOp::SHA3 => super::OP_SHA3,
        // Memory opcodes
        TraceOp::MLOAD => super::OP_MLOAD,
        TraceOp::MSTORE => super::OP_MSTORE,
        TraceOp::MSTORE8 => super::OP_MSTORE8,
        TraceOp::MSIZE => super::OP_MSIZE,
        TraceOp::MCOPY => super::OP_MCOPY,
        // Stack opcodes
        TraceOp::PUSH => super::OP_PUSH0, // Generic PUSH
        TraceOp::POP => super::OP_POP,
        TraceOp::DUP => super::OP_PUSH0,  // Generic DUP
        TraceOp::SWAP => super::OP_PUSH0,  // Generic SWAP
        TraceOp::PUSH0 => super::OP_PUSH0,
        // Control flow opcodes
        TraceOp::JUMP => super::OP_JUMP,
        TraceOp::JUMPI => super::OP_JUMPI,
        TraceOp::RETURN => super::OP_RETURN,
        TraceOp::REVERT => super::OP_REVERT,
        TraceOp::STOP => super::OP_STOP,
        TraceOp::JUMPDEST => super::OP_JUMPDEST,
        TraceOp::PC => super::OP_PC,
        TraceOp::GAS => super::OP_GAS,
        // Data access opcodes
        TraceOp::CALLDATALOAD => super::OP_CALLDATALOAD,
        TraceOp::CALLDATASIZE => super::OP_CALLDATASIZE,
        TraceOp::CALLDATACOPY => super::OP_CALLDATACOPY,
        TraceOp::CODESIZE => super::OP_CODESIZE,
        TraceOp::CODECOPY => super::OP_CODECOPY,
        TraceOp::RETURNDATASIZE => super::OP_RETURNDATASIZE,
        TraceOp::RETURNDATACOPY => super::OP_RETURNDATACOPY,
        // External code opcodes
        TraceOp::EXTCODESIZE => super::OP_EXTCODESIZE,
        TraceOp::EXTCODECOPY => super::OP_EXTCODECOPY,
        TraceOp::EXTCODEHASH => super::OP_EXTCODEHASH,
        // Transient storage opcodes (EIP-1153)
        TraceOp::TLOAD => super::OP_TLOAD,
        TraceOp::TSTORE => super::OP_TSTORE,
        // Lifecycle opcodes
        TraceOp::CREATE => super::OP_CREATE,
        TraceOp::CREATE2 => super::OP_CREATE2,
    };

    let mut row = vec![Fr::from(0u64); EXECUTION_TABLE_COLUMNS];

    row[COL_GLOBAL_COUNTER] = Fr::from(global_counter);
    row[COL_TX_ID] = Fr::from(tx_id);
    row[COL_OP_ID] = Fr::from(op_id);
    row[COL_PC] = Fr::from(0u64); // Simplified: no PC tracking yet
    row[COL_GAS_LEFT] = Fr::from(0u64); // Zero-fee L2
    row[COL_STACK_DEPTH] = Fr::from(0u64);
    row[COL_IS_SUCCESS] = Fr::from(1u64);
    row[COL_CALL_ID] = Fr::from(0u64);
    row[COL_MEMORY_SIZE] = Fr::from(0u64);

    // Fill operands based on operation type
    match entry.op {
        TraceOp::BalanceChange => {
            if let (Ok(prev), Ok(curr)) = (
                crate::types::hex_to_fr(&entry.prev_balance),
                crate::types::hex_to_fr(&entry.curr_balance),
            ) {
                row[COL_OPERAND_A] = prev;
                row[COL_RESULT] = curr;
            }
        }
        TraceOp::SLOAD => {
            if let Ok(val) = crate::types::hex_to_fr(&entry.value) {
                row[COL_RESULT] = val;
            }
        }
        TraceOp::SSTORE => {
            if let (Ok(old), Ok(new)) = (
                crate::types::hex_to_fr(&entry.old_value),
                crate::types::hex_to_fr(&entry.new_value),
            ) {
                row[COL_OPERAND_A] = old;
                row[COL_RESULT] = new;
            }
        }
        TraceOp::CALL => {
            if let Ok(val) = crate::types::hex_to_fr(&entry.call_value) {
                row[COL_OPERAND_A] = val;
            }
        }
        _ => {}
    }

    Ok(vec![row])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::TraceEntry;

    fn make_balance_entry() -> TraceEntry {
        let mut e = TraceEntry::default_with_op(TraceOp::BalanceChange);
        e.account = "0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD".into();
        e.prev_balance = "0x1000".into();
        e.curr_balance = "0x500".into();
        e
    }

    #[test]
    fn execution_row_from_balance_change() {
        let entry = make_balance_entry();
        let rows = process_entry(&entry, 1, 1).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].len(), EXECUTION_TABLE_COLUMNS);
        // Global counter
        assert_eq!(rows[0][COL_GLOBAL_COUNTER], Fr::from(1u64));
        // TX ID
        assert_eq!(rows[0][COL_TX_ID], Fr::from(1u64));
    }

    #[test]
    fn log_produces_no_rows() {
        let entry = TraceEntry {
            op: TraceOp::LOG,
            ..make_balance_entry()
        };
        let rows = process_entry(&entry, 1, 1).unwrap();
        assert!(rows.is_empty());
    }
}
