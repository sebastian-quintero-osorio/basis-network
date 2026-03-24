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

// STATUS: ADAPTER ONLY (NO PSE CIRCUIT DEPENDENCY YET)
//
// The adapter module provides trace analysis and row estimation functions.
// It does NOT import or use PSE zkEVM circuits directly because the
// dependency chain (zkevm-circuits v0.3.1 -> poseidon-circuit -> Scroll
// branch scroll-dev-0215) is broken upstream.
//
// Current coverage without PSE: 37 custom gates covering all major EVM
// opcode categories (arithmetic, comparison, bitwise, storage, memory,
// control flow, crypto, environment, contract lifecycle).
//
// To complete PSE integration:
// 1. Vendor poseidon-circuit crate locally (remove Scroll branch dependency)
// 2. Add zkevm-circuits as workspace dependency
// 3. Implement real trace conversion in adapter.rs (BatchTrace -> GethExecTrace)
// 4. Wire PSE SuperCircuit alongside BasisCircuit in the prover pipeline
