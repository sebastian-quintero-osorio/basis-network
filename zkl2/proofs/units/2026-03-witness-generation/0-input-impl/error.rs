/// Custom error types for the witness generator.
///
/// Each module has specific error variants. All errors propagate through
/// `WitnessError` as the top-level error type for the crate.
///
/// [Spec: zkl2/specs/units/2026-03-witness-generation/1-formalization/v0-analysis/specs/WitnessGeneration/WitnessGeneration.tla]
use thiserror::Error;

/// Top-level error type for the witness generator crate.
#[derive(Debug, Error)]
pub enum WitnessError {
    /// A hex string could not be parsed into a field element.
    #[error("invalid hex value '{value}': {reason}")]
    InvalidHex { value: String, reason: String },

    /// A trace entry has an unexpected or missing field for its operation type.
    #[error("malformed trace entry at index {index}: {reason}")]
    MalformedEntry { index: usize, reason: String },

    /// A witness row has the wrong number of columns for its table.
    /// Enforces TLA+ invariant S3 (RowWidthConsistency).
    #[error(
        "row width mismatch in table '{table}': expected {expected} columns, got {actual}"
    )]
    RowWidthMismatch {
        table: String,
        expected: usize,
        actual: usize,
    },

    /// The batch trace contains no transactions.
    #[error("empty batch trace: no transactions to process")]
    EmptyBatch,

    /// JSON deserialization of a batch trace failed.
    #[error("trace deserialization failed: {0}")]
    Deserialization(#[from] serde_json::Error),
}

/// Result type alias for witness generation operations.
pub type WitnessResult<T> = std::result::Result<T, WitnessError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_display_invalid_hex() {
        let err = WitnessError::InvalidHex {
            value: "0xZZZZ".to_string(),
            reason: "non-hex character".to_string(),
        };
        assert!(err.to_string().contains("0xZZZZ"));
        assert!(err.to_string().contains("non-hex character"));
    }

    #[test]
    fn error_display_row_width() {
        let err = WitnessError::RowWidthMismatch {
            table: "arithmetic".to_string(),
            expected: 8,
            actual: 7,
        };
        assert!(err.to_string().contains("arithmetic"));
        assert!(err.to_string().contains("8"));
    }

    #[test]
    fn error_display_malformed_entry() {
        let err = WitnessError::MalformedEntry {
            index: 3,
            reason: "missing account field for SSTORE".to_string(),
        };
        assert!(err.to_string().contains("index 3"));
    }
}
