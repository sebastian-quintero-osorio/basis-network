/// Witness generation library for Basis Network zkEVM L2.
///
/// Converts EVM execution traces (from Go executor) into structured witness data
/// (field element tables) consumed by the ZK prover circuit.
///
/// Architecture: multi-table design following production zkEVM patterns
/// (Polygon 13-SM, Scroll bus-mapping, zkSync Boojum multi-circuit).
///
/// Tables:
///   - arithmetic: balance changes, nonce changes (value arithmetic)
///   - storage: SLOAD/SSTORE with Merkle proof paths
///   - call_context: CALL operations with context switch data
///
/// Invariant I-08: Trace-Witness Bijection (deterministic mapping).
pub mod types;
pub mod arithmetic;
pub mod storage;
pub mod call_context;
pub mod generator;

pub use generator::{generate, generate_synthetic_batch, WitnessConfig, WitnessResult};
pub use types::{BatchTrace, BatchWitness, ExecutionTrace};
