//! JSON types matching the Go pipeline protocol.
//!
//! These types exactly mirror the Go definitions in
//! `zkl2/node/pipeline/types.go` for cross-language IPC via stdin/stdout.

use serde::{Deserialize, Serialize};

/// Input to the witness generator: batch of execution traces.
#[derive(Debug, Deserialize)]
pub struct BatchTraceJSON {
    pub block_number: u64,
    pub pre_state_root: String,
    pub post_state_root: String,
    pub traces: Vec<ExecutionTraceJSON>,
}

/// Per-transaction execution trace.
#[derive(Debug, Deserialize)]
pub struct ExecutionTraceJSON {
    pub tx_hash: String,
    pub from: String,
    #[serde(default)]
    pub to: String,
    pub value: String,
    pub gas_used: u64,
    pub success: bool,
    pub opcode_count: u64,
    pub entries: Vec<TraceEntryJSON>,
}

/// Individual state-modifying operation in a trace.
#[derive(Debug, Deserialize)]
pub struct TraceEntryJSON {
    pub op: String,
    #[serde(default)]
    pub account: String,
    #[serde(default)]
    pub slot: String,
    #[serde(default)]
    pub old_value: String,
    #[serde(default)]
    pub new_value: String,
    #[serde(default)]
    pub value: String,
    #[serde(default)]
    pub prev_balance: String,
    #[serde(default)]
    pub curr_balance: String,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub prev_nonce: u64,
    #[serde(default)]
    pub curr_nonce: u64,
}

/// Output from the witness generator / input to the prover.
#[derive(Debug, Serialize, Deserialize)]
pub struct WitnessResultJSON {
    pub block_number: u64,
    pub pre_state_root: String,
    pub post_state_root: String,
    pub total_rows: u64,
    pub total_field_elements: u64,
    pub size_bytes: u64,
    pub generation_time_ms: u64,
}

/// Output from the prover.
#[derive(Debug, Serialize)]
pub struct ProofResultJSON {
    pub proof_bytes: Vec<u8>,
    pub public_inputs: Vec<u8>,
    pub proof_size_bytes: u64,
    pub constraint_count: u64,
    pub generation_time_ms: u64,
}
