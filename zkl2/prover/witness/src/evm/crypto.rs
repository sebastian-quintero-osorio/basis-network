//! Crypto witness generator for SHA3/KECCAK256.

use ark_bn254::Fr;
use crate::error::WitnessResult;
use crate::types::{TraceEntry, TraceOp, WitnessRow};

pub fn process_entry(
    entry: &TraceEntry,
    global_counter: u64,
) -> WitnessResult<Vec<WitnessRow>> {
    match entry.op {
        TraceOp::SHA3 => {
            let offset = Fr::from(entry.mem_offset);
            let size = Fr::from(entry.sha3_size);
            Ok(vec![vec![
                Fr::from(global_counter),
                Fr::from(0x20u64), // SHA3 opcode
                offset,
                size,
                Fr::from(0u64), // hash result (computed off-chain)
            ]])
        }
        _ => Ok(vec![]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha3_produces_row() {
        let mut entry = TraceEntry::default_with_op(TraceOp::SHA3);
        entry.mem_offset = 0;
        entry.sha3_size = 32;
        let rows = process_entry(&entry, 1).unwrap();
        assert_eq!(rows.len(), 1);
    }
}
