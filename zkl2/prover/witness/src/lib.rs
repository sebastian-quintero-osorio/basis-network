/// Witness generation library for Basis Network zkEVM L2.
///
/// Converts EVM execution traces (from Go executor at `zkl2/node/executor/`)
/// into structured witness data (field element tables) consumed by the ZK
/// prover circuit.
///
/// Architecture: multi-table design following production zkEVM patterns
/// (Polygon 13-SM, Scroll bus-mapping, zkSync Boojum multi-circuit).
///
/// Tables:
/// - arithmetic: balance changes, nonce changes (value arithmetic)
/// - storage: SLOAD/SSTORE with Merkle proof paths (SMT siblings)
/// - call_context: CALL operations with context switch data
///
/// Invariant I-08: Trace-Witness Bijection (deterministic mapping).
/// Same trace always produces the same witness, bit-for-bit identical.
///
/// [Spec: zkl2/specs/units/2026-03-witness-generation/1-formalization/v0-analysis/specs/WitnessGeneration/WitnessGeneration.tla]
pub mod error;
pub mod types;
pub mod arithmetic;
pub mod storage;
pub mod call_context;
pub mod evm;
pub mod generator;

// Public API re-exports
pub use error::WitnessError;
pub use generator::{generate, generate_synthetic_batch, GenerationResult, WitnessConfig};
pub use types::{BatchTrace, BatchWitness, ExecutionTrace, TraceEntry, TraceOp};
