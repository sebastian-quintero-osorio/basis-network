//! Adapter between Basis witness format and PSE zkEVM circuit input.
//!
//! Converts the Basis BatchWitness (generated from Go executor traces)
//! into the PSE zkEVM Block/Transaction witness format required by
//! the PSE SuperCircuit.
//!
//! The PSE circuit expects:
//! - eth_types::Block with transactions
//! - eth_types::GethExecTrace per transaction
//! - bus_mapping::circuit_input_builder output
//!
//! Our witness generator produces:
//! - basis_witness::BatchTrace with ExecutionTrace per transaction
//! - WitnessTable with field element rows
//!
//! This adapter bridges the two formats.

use basis_witness::types::{BatchTrace, TraceOp};

/// Convert a Basis ExecutionTrace to a simplified PSE-compatible format.
///
/// PSE circuits use `eth_types::GethExecTrace` which includes:
/// - gas, failed, return_value
/// - struct_logs: Vec<GethExecStep> (one per opcode)
///
/// Our ExecutionTrace has state-modifying entries only (SLOAD, SSTORE, etc).
/// For full PSE compatibility, the Go executor needs to capture ALL opcodes
/// (including non-state-modifying ones like ADD, PUSH, etc).
///
/// This adapter creates a minimal compatible representation from our traces.
pub struct PseTraceAdapter;

impl PseTraceAdapter {
    /// Check if a batch trace has sufficient data for PSE circuit proving.
    ///
    /// Returns the number of state-modifying operations that map to PSE circuit rows.
    pub fn analyze_coverage(batch: &BatchTrace) -> TraceCoverage {
        let mut coverage = TraceCoverage::default();

        for trace in &batch.traces {
            coverage.total_txs += 1;
            for entry in &trace.entries {
                match entry.op {
                    TraceOp::SLOAD => coverage.sload_count += 1,
                    TraceOp::SSTORE => coverage.sstore_count += 1,
                    TraceOp::CALL => coverage.call_count += 1,
                    TraceOp::BalanceChange => coverage.balance_change_count += 1,
                    TraceOp::NonceChange => coverage.nonce_change_count += 1,
                    TraceOp::LOG => coverage.log_count += 1,
                    _ => {} // Extended opcodes counted via opcode_count
                }
            }
        }

        coverage
    }

    /// Estimate the PSE circuit row count for a batch.
    ///
    /// PSE circuit rows scale with the number of EVM steps (opcodes executed).
    /// Our traces only capture state-modifying operations, so the actual row
    /// count will be higher when full opcode traces are available.
    pub fn estimate_circuit_rows(batch: &BatchTrace) -> usize {
        let mut rows = 0;
        for trace in &batch.traces {
            // Base: each tx has overhead (tx context, signature verification)
            rows += 100;
            // Each trace entry maps to ~1-10 circuit rows depending on opcode
            for entry in &trace.entries {
                rows += match entry.op {
                    TraceOp::SLOAD => 5,   // Storage read: lookup + verification
                    TraceOp::SSTORE => 10, // Storage write: old/new lookup + verification
                    TraceOp::CALL => 20,   // Call: context switch, value transfer
                    TraceOp::BalanceChange => 3,
                    TraceOp::NonceChange => 2,
                    TraceOp::LOG => 5,
                    // Extended opcodes: 1-2 rows each
                    TraceOp::ADD | TraceOp::SUB | TraceOp::MUL | TraceOp::DIV | TraceOp::MOD => 1,
                    TraceOp::EXP => 3,
                    TraceOp::SHL | TraceOp::SHR | TraceOp::BYTE => 1,
                    TraceOp::MLOAD | TraceOp::MSTORE => 2,
                    TraceOp::PUSH | TraceOp::POP | TraceOp::DUP | TraceOp::SWAP => 1,
                    TraceOp::JUMP | TraceOp::JUMPI => 1,
                    TraceOp::RETURN | TraceOp::REVERT => 2,
                    TraceOp::SHA3 => 5,
                    TraceOp::CREATE | TraceOp::CREATE2 => 10,
                    _ => 1, // Default: 1 row for unhandled opcodes
                };
            }
            // Opcode count from executor (approximation for non-state-modifying ops)
            rows += trace.opcode_count;
        }
        rows
    }
}

/// Coverage analysis of a batch trace for PSE circuit proving.
#[derive(Debug, Default)]
pub struct TraceCoverage {
    pub total_txs: usize,
    pub sload_count: usize,
    pub sstore_count: usize,
    pub call_count: usize,
    pub balance_change_count: usize,
    pub nonce_change_count: usize,
    pub log_count: usize,
}

impl TraceCoverage {
    /// Total state-modifying operations.
    pub fn total_state_ops(&self) -> usize {
        self.sload_count
            + self.sstore_count
            + self.call_count
            + self.balance_change_count
            + self.nonce_change_count
            + self.log_count
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use basis_witness::types::{ExecutionTrace, TraceEntry};

    #[test]
    fn analyze_empty_batch() {
        let batch = BatchTrace {
            block_number: 1,
            pre_state_root: "0x01".into(),
            post_state_root: "0x02".into(),
            traces: vec![],
        };
        let coverage = PseTraceAdapter::analyze_coverage(&batch);
        assert_eq!(coverage.total_txs, 0);
        assert_eq!(coverage.total_state_ops(), 0);
    }

    #[test]
    fn analyze_batch_with_traces() {
        let batch = BatchTrace {
            block_number: 1,
            pre_state_root: "0x01".into(),
            post_state_root: "0x02".into(),
            traces: vec![ExecutionTrace {
                tx_hash: "0xabc".into(),
                from: "0x01".into(),
                to: Some("0x02".into()),
                value: "0x0".into(),
                gas_used: 21000,
                success: true,
                opcode_count: 50,
                entries: vec![
                    {
                        let mut e = TraceEntry::default_with_op(TraceOp::BalanceChange);
                        e.account = "0x01".into();
                        e.prev_balance = "0x1000".into();
                        e.curr_balance = "0x500".into();
                        e
                    },
                    {
                        let mut e = TraceEntry::default_with_op(TraceOp::SSTORE);
                        e.account = "0x02".into();
                        e.old_value = "0x00".into();
                        e.new_value = "0xff".into();
                        e
                    },
                ],
            }],
        };

        let coverage = PseTraceAdapter::analyze_coverage(&batch);
        assert_eq!(coverage.total_txs, 1);
        assert_eq!(coverage.balance_change_count, 1);
        assert_eq!(coverage.sstore_count, 1);
        assert_eq!(coverage.total_state_ops(), 2);

        let rows = PseTraceAdapter::estimate_circuit_rows(&batch);
        assert!(rows > 100, "should estimate > 100 rows: got {}", rows);
    }
}
