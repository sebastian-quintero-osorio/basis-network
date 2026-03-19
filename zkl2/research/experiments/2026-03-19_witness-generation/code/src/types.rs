/// Types for the witness generator, matching the Go executor's trace format.
///
/// These types mirror zkl2/node/executor/types.go (TraceEntry, ExecutionTrace)
/// and define the witness output format consumed by the ZK prover circuit.
use ark_bn254::Fr;
use ark_ff::{BigInteger, BigInteger256, PrimeField};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

// ---------------------------------------------------------------------------
// Input types (from Go executor via JSON)
// ---------------------------------------------------------------------------

/// Mirrors executor.TraceOp in Go.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum TraceOp {
    SLOAD,
    SSTORE,
    CALL,
    BALANCE_CHANGE,
    NONCE_CHANGE,
    LOG,
}

/// Mirrors executor.TraceEntry in Go.
/// Discriminated union: op determines which fields are populated.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraceEntry {
    pub op: TraceOp,

    // Storage fields (SLOAD, SSTORE)
    #[serde(default)]
    pub account: String,
    #[serde(default)]
    pub slot: String,
    #[serde(default)]
    pub value: String,
    #[serde(default)]
    pub old_value: String,
    #[serde(default)]
    pub new_value: String,

    // Call fields (CALL)
    #[serde(default)]
    pub from: String,
    #[serde(default)]
    pub to: String,
    #[serde(default)]
    pub call_value: String,

    // Balance fields (BALANCE_CHANGE)
    #[serde(default)]
    pub prev_balance: String,
    #[serde(default)]
    pub curr_balance: String,
    #[serde(default)]
    pub reason: String,

    // Nonce fields (NONCE_CHANGE)
    #[serde(default)]
    pub prev_nonce: u64,
    #[serde(default)]
    pub curr_nonce: u64,
}

/// Mirrors executor.ExecutionTrace in Go.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutionTrace {
    pub tx_hash: String,
    pub from: String,
    #[serde(default)]
    pub to: Option<String>,
    #[serde(default)]
    pub value: String,
    pub gas_used: u64,
    pub success: bool,
    pub opcode_count: usize,
    pub entries: Vec<TraceEntry>,
}

/// A batch of execution traces (one per transaction in the block).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchTrace {
    pub block_number: u64,
    pub pre_state_root: String,
    pub post_state_root: String,
    pub traces: Vec<ExecutionTrace>,
}

// ---------------------------------------------------------------------------
// Witness output types
// ---------------------------------------------------------------------------

/// A single row in a witness table. Each row is a vector of field elements.
pub type WitnessRow = Vec<Fr>;

/// A witness table: named collection of rows with column metadata.
#[derive(Debug, Clone)]
pub struct WitnessTable {
    pub name: String,
    pub columns: Vec<String>,
    pub rows: Vec<WitnessRow>,
}

impl WitnessTable {
    pub fn new(name: &str, columns: Vec<&str>) -> Self {
        Self {
            name: name.to_string(),
            columns: columns.into_iter().map(|s| s.to_string()).collect(),
            rows: Vec::new(),
        }
    }

    pub fn add_row(&mut self, row: WitnessRow) {
        debug_assert_eq!(
            row.len(),
            self.columns.len(),
            "Row length {} does not match column count {} in table {}",
            row.len(),
            self.columns.len(),
            self.name
        );
        self.rows.push(row);
    }

    pub fn row_count(&self) -> usize {
        self.rows.len()
    }

    pub fn field_element_count(&self) -> usize {
        self.rows.len() * self.columns.len()
    }
}

/// Complete witness for a batch of transactions.
/// Contains all tables needed by the ZK prover circuit.
#[derive(Debug, Clone)]
pub struct BatchWitness {
    pub block_number: u64,
    pub pre_state_root: Fr,
    pub post_state_root: Fr,
    pub tables: BTreeMap<String, WitnessTable>,
}

impl BatchWitness {
    pub fn total_rows(&self) -> usize {
        self.tables.values().map(|t| t.row_count()).sum()
    }

    pub fn total_field_elements(&self) -> usize {
        self.tables.values().map(|t| t.field_element_count()).sum()
    }

    pub fn size_bytes(&self) -> usize {
        // Each Fr is 32 bytes (256 bits for BN254 scalar)
        self.total_field_elements() * 32
    }
}

// ---------------------------------------------------------------------------
// Field element conversion utilities
// ---------------------------------------------------------------------------

/// Convert a hex string (with or without 0x prefix) to a BN254 scalar field element.
/// For 256-bit values that exceed the field modulus, returns the value mod p.
pub fn hex_to_fr(hex: &str) -> Fr {
    let hex = hex.strip_prefix("0x").unwrap_or(hex);
    if hex.is_empty() {
        return Fr::from(0u64);
    }
    // Pad to 64 hex chars (32 bytes)
    let padded = format!("{:0>64}", hex);
    let bytes = hex_to_bytes_be(&padded);
    let bigint = BigInteger256::new([
        u64::from_be_bytes(bytes[24..32].try_into().unwrap()),
        u64::from_be_bytes(bytes[16..24].try_into().unwrap()),
        u64::from_be_bytes(bytes[8..16].try_into().unwrap()),
        u64::from_be_bytes(bytes[0..8].try_into().unwrap()),
    ]);
    Fr::from_bigint(bigint).unwrap_or_else(|| {
        // Value exceeds field modulus: reduce mod p
        // This is safe because arkworks Fr::from handles reduction
        let mut reduced = bigint;
        while reduced >= Fr::MODULUS {
            reduced.sub_with_borrow(&Fr::MODULUS);
        }
        Fr::from_bigint(reduced).unwrap_or(Fr::from(0u64))
    })
}

/// Convert a hex string to a pair of field elements (hi, lo) for 256-bit values.
/// hi = upper 128 bits, lo = lower 128 bits.
/// Both limbs fit comfortably in BN254 Fr (254 bits > 128 bits).
pub fn hex_to_limbs(hex: &str) -> (Fr, Fr) {
    let hex = hex.strip_prefix("0x").unwrap_or(hex);
    let padded = format!("{:0>64}", hex);
    let hi_hex = &padded[..32]; // upper 16 bytes
    let lo_hex = &padded[32..]; // lower 16 bytes
    (hex_to_fr(hi_hex), hex_to_fr(lo_hex))
}

/// Convert a u64 to a field element.
pub fn u64_to_fr(val: u64) -> Fr {
    Fr::from(val)
}

/// Helper: big-endian hex string to bytes.
fn hex_to_bytes_be(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap_or(0))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hex_to_fr_zero() {
        let fr = hex_to_fr("0x0");
        assert_eq!(fr, Fr::from(0u64));
    }

    #[test]
    fn test_hex_to_fr_small() {
        let fr = hex_to_fr("0xff");
        assert_eq!(fr, Fr::from(255u64));
    }

    #[test]
    fn test_hex_to_limbs() {
        let (hi, lo) = hex_to_limbs("0x00000000000000000000000000000001ffffffffffffffffffffffffffffffff");
        assert_eq!(hi, Fr::from(1u64));
        // lo should be 2^128 - 1
        assert_ne!(lo, Fr::from(0u64));
    }

    #[test]
    fn test_u64_to_fr() {
        let fr = u64_to_fr(42);
        assert_eq!(fr, Fr::from(42u64));
    }

    #[test]
    fn test_empty_hex() {
        let fr = hex_to_fr("");
        assert_eq!(fr, Fr::from(0u64));
    }
}
