/// Core types for the witness generator, matching the Go executor's trace format.
///
/// Input types mirror `zkl2/node/executor/types.go` (TraceEntry, ExecutionTrace)
/// and define the witness output format consumed by the ZK prover circuit.
///
/// [Spec: zkl2/specs/units/2026-03-witness-generation/1-formalization/v0-analysis/specs/WitnessGeneration/WitnessGeneration.tla]
use ark_bn254::Fr;
use ark_ff::{BigInteger, BigInteger256, PrimeField};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::error::{WitnessError, WitnessResult};

// ---------------------------------------------------------------------------
// Input types (from Go executor via JSON)
// ---------------------------------------------------------------------------

/// Mirrors `executor.TraceOp` in Go (`zkl2/node/executor/types.go`).
///
/// Corresponds to TLA+ `OpTypes` constant.
/// The operation type determines which witness table receives rows:
/// - ArithOps: BALANCE_CHANGE, NONCE_CHANGE -> arithmetic table
/// - StorageReadOps: SLOAD -> storage table (1 row)
/// - StorageWriteOps: SSTORE -> storage table (2 rows)
/// - CallOps: CALL -> call_context table
/// - Other (LOG): skipped, no witness rows produced
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum TraceOp {
    // Original state-modifying ops
    SLOAD,
    SSTORE,
    CALL,
    #[serde(rename = "BALANCE_CHANGE")]
    BalanceChange,
    #[serde(rename = "NONCE_CHANGE")]
    NonceChange,
    LOG,

    // Arithmetic
    ADD,
    SUB,
    MUL,
    DIV,
    MOD,
    EXP,
    SDIV,
    SMOD,
    ADDMOD,
    MULMOD,
    SIGNEXTEND,

    // Comparison
    LT,
    GT,
    SLT,
    SGT,
    EQ,
    ISZERO,

    // Bitwise
    AND,
    OR,
    XOR,
    NOT,
    SHL,
    SHR,
    SAR,
    BYTE,

    // Memory
    MLOAD,
    MSTORE,
    MSTORE8,
    MSIZE,
    MCOPY,

    // Stack
    PUSH,
    POP,
    DUP,
    SWAP,
    PUSH0,

    // Control flow
    JUMP,
    JUMPI,
    RETURN,
    REVERT,
    STOP,
    JUMPDEST,
    PC,
    GAS,

    // Crypto
    SHA3,

    // Data access
    CALLDATALOAD,
    CALLDATASIZE,
    CALLDATACOPY,
    CODESIZE,
    CODECOPY,
    RETURNDATASIZE,
    RETURNDATACOPY,

    // External code
    EXTCODESIZE,
    EXTCODECOPY,
    EXTCODEHASH,

    // Transient storage (EIP-1153)
    TLOAD,
    TSTORE,

    // Lifecycle
    CREATE,
    CREATE2,
}

/// Mirrors `executor.TraceEntry` in Go (`zkl2/node/executor/types.go`).
///
/// Discriminated union: `op` determines which fields are populated.
/// - SLOAD: account, slot, value
/// - SSTORE: account, slot, old_value, new_value
/// - CALL: from, to, call_value
/// - BALANCE_CHANGE: account, prev_balance, curr_balance, reason
/// - NONCE_CHANGE: account, prev_nonce, curr_nonce
///
/// Corresponds to TLA+ `Trace[i]` record with `.op` field.
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

    // Arithmetic fields (ADD, SUB, MUL, DIV, MOD, EXP)
    #[serde(default)]
    pub operand_a: String,
    #[serde(default)]
    pub operand_b: String,
    #[serde(default)]
    pub result: String,

    // Shift fields (SHL, SHR)
    #[serde(default)]
    pub shift_amount: u64,

    // Memory fields (MLOAD, MSTORE)
    #[serde(default)]
    pub mem_offset: u64,
    #[serde(default)]
    pub mem_value: String,

    // SHA3 fields
    #[serde(default)]
    pub sha3_hash: String,
    #[serde(default)]
    pub sha3_size: u64,

    // Stack fields (PUSH, DUP)
    #[serde(default)]
    pub stack_value: String,

    // Control flow fields
    #[serde(default)]
    pub destination: u64,
    #[serde(default)]
    pub condition: u64,
}

impl TraceEntry {
    /// Create a default entry (used in tests and synthetic trace generation).
    pub fn default_with_op(op: TraceOp) -> Self {
        Self {
            op,
            account: String::new(),
            slot: String::new(),
            value: String::new(),
            old_value: String::new(),
            new_value: String::new(),
            from: String::new(),
            to: String::new(),
            call_value: String::new(),
            prev_balance: String::new(),
            curr_balance: String::new(),
            reason: String::new(),
            prev_nonce: 0,
            curr_nonce: 0,
            operand_a: String::new(),
            operand_b: String::new(),
            result: String::new(),
            shift_amount: 0,
            mem_offset: 0,
            mem_value: String::new(),
            sha3_hash: String::new(),
            sha3_size: 0,
            stack_value: String::new(),
            destination: 0,
            condition: 0,
        }
    }
}

/// Mirrors `executor.ExecutionTrace` in Go (`zkl2/node/executor/types.go`).
///
/// Captures the complete execution trace of a single transaction.
/// The trace is an ordered sequence of state-modifying operations.
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
///
/// This is the top-level input to the witness generator.
/// The Go node serializes this as JSON for cross-language communication.
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

/// A single row in a witness table: a vector of BN254 scalar field elements.
///
/// Each row corresponds to one or more trace entries processed by a table generator.
/// The row width must match the table's column count (TLA+ invariant S3: RowWidthConsistency).
pub type WitnessRow = Vec<Fr>;

/// A witness table: named collection of rows with column metadata.
///
/// Corresponds to TLA+ `arithRows`, `storageRows`, or `callRows` sequences.
/// Column count is fixed at construction time; all rows must match.
#[derive(Debug, Clone)]
pub struct WitnessTable {
    pub name: String,
    pub columns: Vec<String>,
    pub rows: Vec<WitnessRow>,
}

impl WitnessTable {
    /// Create a new empty witness table with the given column layout.
    pub fn new(name: &str, columns: Vec<&str>) -> Self {
        Self {
            name: name.to_string(),
            columns: columns.into_iter().map(|s| s.to_string()).collect(),
            rows: Vec::new(),
        }
    }

    /// Create a new empty witness table with owned column names.
    pub fn with_columns(name: String, columns: Vec<String>) -> Self {
        Self {
            name,
            columns,
            rows: Vec::new(),
        }
    }

    /// Add a row to the table, validating column count.
    ///
    /// Enforces TLA+ invariant S3 (RowWidthConsistency):
    /// every row in a table must have the same column count.
    pub fn add_row(&mut self, row: WitnessRow) -> WitnessResult<()> {
        if row.len() != self.columns.len() {
            return Err(WitnessError::RowWidthMismatch {
                table: self.name.clone(),
                expected: self.columns.len(),
                actual: row.len(),
            });
        }
        self.rows.push(row);
        Ok(())
    }

    /// Number of rows in this table.
    pub fn row_count(&self) -> usize {
        self.rows.len()
    }

    /// Total field elements in this table (rows * columns).
    pub fn field_element_count(&self) -> usize {
        self.rows.len() * self.columns.len()
    }
}

/// Complete witness for a batch of transactions.
///
/// Contains all tables needed by the ZK prover circuit.
/// Tables are stored in a BTreeMap for deterministic iteration order
/// (TLA+ invariant S5: DeterminismGuard).
#[derive(Debug, Clone)]
pub struct BatchWitness {
    pub block_number: u64,
    pub pre_state_root: Fr,
    pub post_state_root: Fr,
    pub tables: BTreeMap<String, WitnessTable>,
}

impl BatchWitness {
    /// Total rows across all tables.
    pub fn total_rows(&self) -> usize {
        self.tables.values().map(|t| t.row_count()).sum()
    }

    /// Total field elements across all tables.
    pub fn total_field_elements(&self) -> usize {
        self.tables.values().map(|t| t.field_element_count()).sum()
    }

    /// Estimated witness size in bytes (each Fr is 32 bytes for BN254).
    pub fn size_bytes(&self) -> usize {
        self.total_field_elements() * 32
    }
}

// ---------------------------------------------------------------------------
// Field element conversion utilities
// ---------------------------------------------------------------------------

/// Convert a hex string (with or without 0x prefix) to a BN254 scalar field element.
///
/// For 256-bit values that exceed the field modulus, returns the value mod p.
/// Returns an error for invalid hex characters.
pub fn hex_to_fr(hex: &str) -> WitnessResult<Fr> {
    let hex = hex.strip_prefix("0x").unwrap_or(hex);
    if hex.is_empty() {
        return Ok(Fr::from(0u64));
    }
    let padded = format!("{:0>64}", hex);
    let bytes = hex_to_bytes_be(&padded)?;
    let bigint = BigInteger256::new([
        u64::from_be_bytes([
            bytes[24], bytes[25], bytes[26], bytes[27],
            bytes[28], bytes[29], bytes[30], bytes[31],
        ]),
        u64::from_be_bytes([
            bytes[16], bytes[17], bytes[18], bytes[19],
            bytes[20], bytes[21], bytes[22], bytes[23],
        ]),
        u64::from_be_bytes([
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        ]),
        u64::from_be_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
        ]),
    ]);
    Ok(Fr::from_bigint(bigint).unwrap_or_else(|| {
        // Value exceeds field modulus: reduce mod p.
        let mut reduced = bigint;
        while reduced >= Fr::MODULUS {
            reduced.sub_with_borrow(&Fr::MODULUS);
        }
        Fr::from_bigint(reduced).unwrap_or(Fr::from(0u64))
    }))
}

/// Convert a hex string to a pair of field elements (hi, lo) for 256-bit values.
///
/// hi = upper 128 bits, lo = lower 128 bits.
/// Both limbs fit in BN254 Fr (254 bits > 128 bits).
pub fn hex_to_limbs(hex: &str) -> WitnessResult<(Fr, Fr)> {
    let hex = hex.strip_prefix("0x").unwrap_or(hex);
    let padded = format!("{:0>64}", hex);
    let hi_hex = &padded[..32];
    let lo_hex = &padded[32..];
    Ok((hex_to_fr(hi_hex)?, hex_to_fr(lo_hex)?))
}

/// Convert a u64 to a field element.
pub fn u64_to_fr(val: u64) -> Fr {
    Fr::from(val)
}

/// Big-endian hex string to bytes. Returns error on invalid hex characters.
fn hex_to_bytes_be(hex: &str) -> WitnessResult<Vec<u8>> {
    let mut bytes = Vec::with_capacity(hex.len() / 2);
    for i in (0..hex.len()).step_by(2) {
        let byte_str = &hex[i..i + 2];
        let byte = u8::from_str_radix(byte_str, 16).map_err(|_| WitnessError::InvalidHex {
            value: byte_str.to_string(),
            reason: "non-hex character in byte".to_string(),
        })?;
        bytes.push(byte);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_to_fr_zero() {
        let fr = hex_to_fr("0x0").unwrap();
        assert_eq!(fr, Fr::from(0u64));
    }

    #[test]
    fn hex_to_fr_small() {
        let fr = hex_to_fr("0xff").unwrap();
        assert_eq!(fr, Fr::from(255u64));
    }

    #[test]
    fn hex_to_fr_empty() {
        let fr = hex_to_fr("").unwrap();
        assert_eq!(fr, Fr::from(0u64));
    }

    #[test]
    fn hex_to_fr_no_prefix() {
        let fr = hex_to_fr("ff").unwrap();
        assert_eq!(fr, Fr::from(255u64));
    }

    #[test]
    fn hex_to_fr_invalid_returns_error() {
        let result = hex_to_fr("0xZZZZ");
        assert!(result.is_err());
    }

    #[test]
    fn hex_to_limbs_split() {
        let (hi, lo) =
            hex_to_limbs("0x00000000000000000000000000000001ffffffffffffffffffffffffffffffff")
                .unwrap();
        assert_eq!(hi, Fr::from(1u64));
        assert_ne!(lo, Fr::from(0u64));
    }

    #[test]
    fn u64_to_fr_roundtrip() {
        let fr = u64_to_fr(42);
        assert_eq!(fr, Fr::from(42u64));
    }

    #[test]
    fn witness_table_add_row_valid() {
        let mut table = WitnessTable::new("test", vec!["a", "b"]);
        let result = table.add_row(vec![Fr::from(1u64), Fr::from(2u64)]);
        assert!(result.is_ok());
        assert_eq!(table.row_count(), 1);
    }

    #[test]
    fn witness_table_add_row_wrong_width() {
        let mut table = WitnessTable::new("test", vec!["a", "b"]);
        let result = table.add_row(vec![Fr::from(1u64)]);
        assert!(result.is_err());
        assert_eq!(table.row_count(), 0);
    }

    #[test]
    fn batch_witness_size_calculation() {
        let mut tables = BTreeMap::new();
        let mut table = WitnessTable::new("test", vec!["a", "b"]);
        table.add_row(vec![Fr::from(1u64), Fr::from(2u64)]).unwrap();
        table.add_row(vec![Fr::from(3u64), Fr::from(4u64)]).unwrap();
        tables.insert("test".to_string(), table);

        let witness = BatchWitness {
            block_number: 1,
            pre_state_root: Fr::from(0u64),
            post_state_root: Fr::from(0u64),
            tables,
        };
        assert_eq!(witness.total_rows(), 2);
        assert_eq!(witness.total_field_elements(), 4);
        assert_eq!(witness.size_bytes(), 128); // 4 * 32
    }
}
