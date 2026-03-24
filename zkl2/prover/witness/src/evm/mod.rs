//! EVM witness table generators for PSE zkEVM circuit integration.
//!
//! This module extends the Basis witness generator with tables required by
//! PSE zkEVM circuits. Each sub-module generates a specific lookup table
//! from the Go executor's execution traces.
//!
//! Tables follow the PSE zkEVM architecture:
//!   - bytecode: Deployed contract bytecode lookup
//!   - execution: Per-opcode CPU execution trace
//!   - memory: Read/write memory access log
//!   - stack: Push/pop stack operations
//!   - tx: Transaction-level context (from, to, value, gas)
//!   - block: Block-level context (number, timestamp, coinbase)
//!
//! Each table produces WitnessRow vectors (Vec<Fr>) that are assigned to
//! the corresponding circuit columns during synthesis.
//!
//! Integration: generator.rs dispatches to these modules alongside the
//! existing arithmetic/storage/call_context generators.

pub mod execution;
pub mod memory;
pub mod tx;
pub mod math;
pub mod bitwise;
pub mod control;
pub mod crypto;
pub mod lifecycle;
pub mod stack_ops;
pub mod data_ops;

// Types re-exported for sub-modules.
// Sub-modules use crate::types directly for TraceEntry, Fr, etc.

/// Operation codes for the execution table.
/// Maps EVM opcodes to field element identifiers used in circuit selectors.
pub const OP_STOP: u64 = 0x00;
pub const OP_ADD: u64 = 0x01;
pub const OP_MUL: u64 = 0x02;
pub const OP_SUB: u64 = 0x03;
pub const OP_DIV: u64 = 0x04;
pub const OP_SDIV: u64 = 0x05;
pub const OP_MOD: u64 = 0x06;
pub const OP_SMOD: u64 = 0x07;
pub const OP_ADDMOD: u64 = 0x08;
pub const OP_MULMOD: u64 = 0x09;
pub const OP_EXP: u64 = 0x0A;
pub const OP_SIGNEXTEND: u64 = 0x0B;
pub const OP_LT: u64 = 0x10;
pub const OP_GT: u64 = 0x11;
pub const OP_SLT: u64 = 0x12;
pub const OP_SGT: u64 = 0x13;
pub const OP_EQ: u64 = 0x14;
pub const OP_ISZERO: u64 = 0x15;
pub const OP_AND: u64 = 0x16;
pub const OP_OR: u64 = 0x17;
pub const OP_XOR: u64 = 0x18;
pub const OP_NOT: u64 = 0x19;
pub const OP_BYTE: u64 = 0x1A;
pub const OP_SHL: u64 = 0x1B;
pub const OP_SHR: u64 = 0x1C;
pub const OP_SAR: u64 = 0x1D;
pub const OP_SHA3: u64 = 0x20;
pub const OP_ADDRESS: u64 = 0x30;
pub const OP_BALANCE: u64 = 0x31;
pub const OP_ORIGIN: u64 = 0x32;
pub const OP_CALLER: u64 = 0x33;
pub const OP_CALLVALUE: u64 = 0x34;
pub const OP_CALLDATALOAD: u64 = 0x35;
pub const OP_CALLDATASIZE: u64 = 0x36;
pub const OP_CALLDATACOPY: u64 = 0x37;
pub const OP_CODESIZE: u64 = 0x38;
pub const OP_CODECOPY: u64 = 0x39;
pub const OP_GASPRICE: u64 = 0x3A;
pub const OP_EXTCODESIZE: u64 = 0x3B;
pub const OP_EXTCODECOPY: u64 = 0x3C;
pub const OP_RETURNDATASIZE: u64 = 0x3D;
pub const OP_RETURNDATACOPY: u64 = 0x3E;
pub const OP_EXTCODEHASH: u64 = 0x3F;
pub const OP_BLOCKHASH: u64 = 0x40;
pub const OP_COINBASE: u64 = 0x41;
pub const OP_TIMESTAMP: u64 = 0x42;
pub const OP_NUMBER: u64 = 0x43;
pub const OP_GASLIMIT: u64 = 0x45;
pub const OP_CHAINID: u64 = 0x46;
pub const OP_SELFBALANCE: u64 = 0x47;
pub const OP_BASEFEE: u64 = 0x48;
pub const OP_POP: u64 = 0x50;
pub const OP_MLOAD: u64 = 0x51;
pub const OP_MSTORE: u64 = 0x52;
pub const OP_MSTORE8: u64 = 0x53;
pub const OP_SLOAD: u64 = 0x54;
pub const OP_SSTORE: u64 = 0x55;
pub const OP_JUMP: u64 = 0x56;
pub const OP_JUMPI: u64 = 0x57;
pub const OP_PC: u64 = 0x58;
pub const OP_MSIZE: u64 = 0x59;
pub const OP_GAS: u64 = 0x5A;
pub const OP_JUMPDEST: u64 = 0x5B;
pub const OP_TLOAD: u64 = 0x5C;
pub const OP_TSTORE: u64 = 0x5D;
pub const OP_MCOPY: u64 = 0x5E;
pub const OP_PUSH0: u64 = 0x5F;
pub const OP_CREATE: u64 = 0xF0;
pub const OP_CALL: u64 = 0xF1;
pub const OP_RETURN: u64 = 0xF3;
pub const OP_DELEGATECALL: u64 = 0xF4;
pub const OP_CREATE2: u64 = 0xF5;
pub const OP_STATICCALL: u64 = 0xFA;
pub const OP_REVERT: u64 = 0xFD;
pub const OP_SELFDESTRUCT: u64 = 0xFF;
