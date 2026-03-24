/// Basis Network PLONK Circuit Library
///
/// halo2-KZG circuit implementation for the Basis Network zkEVM L2.
/// Provides the complete proving pipeline: circuit definition, key generation,
/// proof creation, and proof verification.
///
/// # Architecture
///
/// ```text
/// Witness tables (basis-witness)
///       |
///       v
/// BasisCircuit (circuit.rs)
///   - Custom gates: Add, Mul, Poseidon, Memory, Stack (gates.rs)
///   - Column layout: 4 advice + 1 instance + 5 selectors + 1 fixed (columns.rs)
///       |
///       v
/// Prover (prover.rs)
///   - SRS: Universal KZG setup (srs.rs)
///   - Keygen: vk + pk from circuit + SRS
///   - Prove: witness -> PLONK proof (500-900 bytes)
///       |
///       v
/// Verifier (verifier.rs)
///   - Off-chain: Rust-native verification
///   - On-chain: BasisVerifier.sol (Solidity, EIP-196/197 precompiles)
/// ```
///
/// # Migration Support
///
/// The `types` module defines the migration phase state machine
/// (Groth16Only -> Dual -> PlonkOnly) with rollback support.
/// Phase-aware verification is provided by `verifier::verify_with_phase`.
///
/// [Spec: lab/3-architect/implementation-history/prover-plonk-migration/specs/PlonkMigration.tla]
pub mod circuit;
pub mod columns;
pub mod gates;
pub mod evm_gates;
pub mod prover;
pub mod srs;
pub mod types;
pub mod verifier;

#[cfg(test)]
mod tests;
