//! PSE zkEVM Circuit Integration for Basis Network zkL2.
//!
//! This crate bridges the PSE zkEVM circuits (production-grade, audited,
//! used by Scroll mainnet) with the Basis Network prover infrastructure.
//!
//! Architecture:
//!   Go Executor (traces) -> Basis Witness Generator -> PSE Circuit Tables
//!                                                   -> Basis Custom Gates
//!                                                   -> Combined PLONK Proof
//!
//! The integration connects:
//! 1. Our witness generator (basis-witness) output -> PSE circuit input format
//! 2. PSE circuit gates (100% EVM coverage) + our custom gates (enterprise)
//! 3. Combined proving using our existing KZG pipeline
//!
//! PSE zkEVM provides:
//! - Complete EVM opcode coverage (all Cancun opcodes)
//! - Lookup tables for bytecode, memory, storage, call stack
//! - Multi-circuit architecture (super circuit composing sub-circuits)
//! - 3+ years of development, multiple security audits
//!
//! Basis Network provides:
//! - Enterprise-specific gates (Poseidon SMT, per-enterprise isolation)
//! - Go-Rust IPC pipeline (witness generation, proof submission)
//! - L1 settlement contracts (PlonkVerifier, BasisRollup)
//! - Zero-fee transaction model customization

pub mod adapter;

// PSE zkEVM circuit re-exports will be added when the dependency chain
// is resolved. The adapter module provides the integration interface
// between Basis witness format and PSE circuit input format.
//
// To complete the integration:
// 1. Vendor poseidon-circuit crate (remove Scroll branch dependency)
// 2. Add zkevm-circuits as git dependency
// 3. Uncomment: pub use zkevm_circuits;
