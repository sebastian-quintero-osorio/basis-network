//! Transaction context table generator.
//!
//! Produces one row per transaction in the batch, capturing the
//! transaction-level context needed by the zkEVM circuit for
//! environment opcodes (ORIGIN, CALLER, CALLVALUE, etc.).
//!
//! Column layout (10 columns):
//!   [tx_id, from_hash, to_hash, value, gas_limit, gas_used,
//!    nonce, is_create, success, opcode_count]

use ark_bn254::Fr;
use crate::error::WitnessResult;
use crate::types::{ExecutionTrace, WitnessRow};

/// Number of columns in the transaction table.
pub const TX_TABLE_COLUMNS: usize = 10;

pub const COL_TX_ID: usize = 0;
pub const COL_FROM: usize = 1;
pub const COL_TO: usize = 2;
pub const COL_VALUE: usize = 3;
pub const COL_GAS_LIMIT: usize = 4;
pub const COL_GAS_USED: usize = 5;
pub const COL_NONCE: usize = 6;
pub const COL_IS_CREATE: usize = 7;
pub const COL_SUCCESS: usize = 8;
pub const COL_OPCODE_COUNT: usize = 9;

/// Generate a transaction table row from an execution trace.
pub fn process_trace(
    trace: &ExecutionTrace,
    tx_id: u64,
) -> WitnessResult<WitnessRow> {
    let mut row = vec![Fr::from(0u64); TX_TABLE_COLUMNS];

    row[COL_TX_ID] = Fr::from(tx_id);

    if let Ok(from) = crate::types::hex_to_fr(&trace.from) {
        row[COL_FROM] = from;
    }
    if let Some(ref to) = trace.to {
        if let Ok(to_fr) = crate::types::hex_to_fr(to) {
            row[COL_TO] = to_fr;
        }
    }
    if let Ok(val) = crate::types::hex_to_fr(&trace.value) {
        row[COL_VALUE] = val;
    }

    row[COL_GAS_USED] = Fr::from(trace.gas_used);
    row[COL_IS_CREATE] = Fr::from(if trace.to.is_none() { 1u64 } else { 0u64 });
    row[COL_SUCCESS] = Fr::from(if trace.success { 1u64 } else { 0u64 });
    row[COL_OPCODE_COUNT] = Fr::from(trace.opcode_count as u64);

    Ok(row)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::ExecutionTrace;

    #[test]
    fn tx_row_from_trace() {
        let trace = ExecutionTrace {
            tx_hash: "0xabc".into(),
            from: "0x01".into(),
            to: Some("0x02".into()),
            value: "0x0".into(),
            gas_used: 21000,
            success: true,
            opcode_count: 50,
            entries: vec![],
        };
        let row = process_trace(&trace, 1).unwrap();
        assert_eq!(row.len(), TX_TABLE_COLUMNS);
        assert_eq!(row[COL_TX_ID], Fr::from(1u64));
        assert_eq!(row[COL_GAS_USED], Fr::from(21000u64));
        assert_eq!(row[COL_SUCCESS], Fr::from(1u64));
        assert_eq!(row[COL_IS_CREATE], Fr::from(0u64));
    }

    #[test]
    fn contract_creation_detected() {
        let trace = ExecutionTrace {
            tx_hash: "0xabc".into(),
            from: "0x01".into(),
            to: None, // Contract creation
            value: "0x0".into(),
            gas_used: 50000,
            success: true,
            opcode_count: 100,
            entries: vec![],
        };
        let row = process_trace(&trace, 2).unwrap();
        assert_eq!(row[COL_IS_CREATE], Fr::from(1u64));
    }
}
