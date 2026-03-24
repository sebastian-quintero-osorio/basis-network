//! JSON types matching the Go pipeline protocol.
//!
//! These types exactly mirror the Go definitions in
//! `zkl2/node/pipeline/types.go` for cross-language IPC via stdin/stdout.

use serde::{Deserialize, Deserializer, Serialize};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};

/// Input to the witness generator: batch of execution traces.
/// Deserialized from Go pipeline JSON (never constructed directly in Rust).
#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct BatchTraceJSON {
    pub block_number: u64,
    pub pre_state_root: String,
    pub post_state_root: String,
    pub traces: Vec<ExecutionTraceJSON>,
}

/// Per-transaction execution trace.
#[derive(Debug, Deserialize)]
#[allow(dead_code)]
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
#[allow(dead_code)]
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
/// Fields use a custom deserializer to handle both Go's base64 encoding of []byte
/// and Rust's native JSON array encoding.
#[derive(Debug, Serialize, Deserialize)]
pub struct ProofResultJSON {
    #[serde(deserialize_with = "deserialize_bytes")]
    pub proof_bytes: Vec<u8>,
    #[serde(deserialize_with = "deserialize_bytes")]
    pub public_inputs: Vec<u8>,
    pub proof_size_bytes: u64,
    pub constraint_count: u64,
    pub generation_time_ms: u64,
}

/// Deserialize bytes that may come as a base64 string (from Go's json.Marshal of []byte)
/// or as a JSON array of numbers (from Rust's serde_json).
fn deserialize_bytes<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
where
    D: Deserializer<'de>,
{
    use serde::de;

    struct BytesVisitor;

    impl<'de> de::Visitor<'de> for BytesVisitor {
        type Value = Vec<u8>;

        fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
            formatter.write_str("a base64 string or a sequence of bytes")
        }

        fn visit_str<E: de::Error>(self, v: &str) -> Result<Vec<u8>, E> {
            BASE64.decode(v).map_err(|e| de::Error::custom(format!("invalid base64: {}", e)))
        }

        fn visit_seq<A: de::SeqAccess<'de>>(self, mut seq: A) -> Result<Vec<u8>, A::Error> {
            let mut bytes = Vec::new();
            while let Some(b) = seq.next_element::<u8>()? {
                bytes.push(b);
            }
            Ok(bytes)
        }
    }

    deserializer.deserialize_any(BytesVisitor)
}

/// Input for proof aggregation: one entry per enterprise batch proof.
#[derive(Debug, Deserialize)]
pub struct AggregateInputJSON {
    pub enterprise_id: u64,
    pub batch_id: u64,
    pub pre_state_root: u64,
    pub post_state_root: u64,
    pub is_valid: bool,
}

/// Output of proof aggregation: folded result + decider proof.
#[derive(Debug, Serialize)]
pub struct AggregateOutputJSON {
    pub instance_count: usize,
    pub is_satisfiable: bool,
    pub proof_bytes: Vec<u8>,
    pub estimated_gas: u64,
    pub generation_time_ms: u64,
}
