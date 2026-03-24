/// Column layout for the Basis Network PLONK circuit.
///
/// Defines the advice (private witness), instance (public input), and fixed
/// (selector + constant) columns used by the EVM state transition circuit.
///
/// Column design follows the PLONKish arithmetization where each row
/// represents one operation (ADD, MUL, Poseidon hash, memory access, or
/// stack operation), selected by the corresponding gate selector.
///
/// [Spec: lab/3-architect/implementation-history/prover-plonk-migration/specs/PlonkMigration.tla]
use halo2_proofs::{
    halo2curves::bn256::Fr,
    plonk::{Advice, Column, ConstraintSystem, Fixed, Instance, Selector},
};

/// Complete column configuration for the BasisCircuit.
///
/// This struct is produced by `BasisCircuit::configure()` and consumed by
/// `BasisCircuit::synthesize()`. It holds references to all columns and
/// selectors needed for witness assignment and constraint checking.
#[derive(Debug, Clone)]
pub struct BasisCircuitConfig {
    // -- Advice columns (private witness data) --

    /// Left operand / address / input value.
    pub a: Column<Advice>,
    /// Right operand / slot / secondary input.
    pub b: Column<Advice>,
    /// Result / output value.
    pub c: Column<Advice>,
    /// Auxiliary column (round constants, depth, flags).
    pub d: Column<Advice>,

    // -- Instance column (public inputs) --

    /// Public inputs: pre_state_root, post_state_root, batch_hash.
    /// All three values are placed in a single instance column at rows 0, 1, 2.
    pub instance: Column<Instance>,

    // -- Gate selectors --

    /// Selector for AddGate: a + b = c.
    pub q_add: Selector,
    /// Selector for MulGate: a * b = c.
    pub q_mul: Selector,
    /// Selector for PoseidonGate: a^5 + d = c.
    pub q_poseidon: Selector,
    /// Selector for MemoryGate: memory read/write consistency.
    pub q_memory: Selector,
    /// Selector for StackGate: stack discipline (c_prev feeds a_cur).
    pub q_stack: Selector,

    // -- EVM arithmetic selectors --

    /// Selector for SubGate: a - b = c.
    pub q_sub: Selector,
    /// Selector for DivGate: a / b = c (b != 0), or c = 0 when b = 0 (EVM convention).
    pub q_div: Selector,
    /// Selector for ModGate: a mod b = c.
    pub q_mod: Selector,
    /// Selector for LtGate: (a < b) = c (0 or 1).
    pub q_lt: Selector,
    /// Selector for EqGate: (a == b) = c (0 or 1).
    pub q_eq: Selector,
    /// Selector for IsZeroGate: (a == 0) = c (0 or 1).
    pub q_iszero: Selector,
    /// Selector for AndGate: a AND b = c (bitwise, modeled as a * b for booleans).
    pub q_and: Selector,
    /// Selector for OrGate: a OR b = c (bitwise, modeled as a + b - a*b for booleans).
    pub q_or: Selector,
    /// Selector for NotGate: NOT a = c (modeled as 1 - a for booleans).
    pub q_not: Selector,

    // -- Storage/Memory selectors --

    /// Selector for SloadGate: storage read consistency (value matches state).
    pub q_sload: Selector,
    /// Selector for SstoreGate: storage write with state root transition.
    pub q_sstore: Selector,
    /// Selector for MloadGate: memory read consistency.
    pub q_mload: Selector,
    /// Selector for MstoreGate: memory write operation.
    pub q_mstore: Selector,
    /// Selector for HashGate: generic 2-to-1 hash (Poseidon for Merkle nodes).
    pub q_hash: Selector,

    // -- Control flow selectors --

    /// Selector for JumpGate: JUMP/JUMPI destination validation.
    pub q_jump: Selector,
    /// Selector for PushGate: PUSH value onto stack.
    pub q_push: Selector,
    /// Selector for PopGate: POP value from stack.
    pub q_pop: Selector,
    /// Selector for DupGate: DUP copies stack value.
    pub q_dup: Selector,
    /// Selector for SwapGate: SWAP exchanges stack values.
    pub q_swap: Selector,
    /// Selector for CallGate: CALL/STATICCALL/DELEGATECALL context switch.
    pub q_call: Selector,
    /// Selector for ReturnGate: RETURN/REVERT execution termination.
    pub q_return: Selector,

    // -- Extended EVM selectors --

    /// Selector for SHL (shift left).
    pub q_shl: Selector,
    /// Selector for SHR (shift right).
    pub q_shr: Selector,
    /// Selector for SAR (arithmetic shift right).
    pub q_sar: Selector,
    /// Selector for BYTE (extract byte).
    pub q_byte: Selector,
    /// Selector for SIGNEXTEND (sign extension).
    pub q_signextend: Selector,
    /// Selector for EXP (exponentiation).
    pub q_exp: Selector,
    /// Selector for SHA3 (keccak256).
    pub q_sha3: Selector,
    /// Selector for XOR (bitwise exclusive or).
    pub q_xor: Selector,
    /// Selector for SLT (signed less-than).
    pub q_slt: Selector,
    /// Selector for SGT (signed greater-than).
    pub q_sgt: Selector,
    /// Selector for SDIV (signed division).
    pub q_sdiv: Selector,
    /// Selector for SMOD (signed modulo).
    pub q_smod: Selector,
    /// Selector for ADDMOD (modular addition).
    pub q_addmod: Selector,
    /// Selector for MULMOD (modular multiplication).
    pub q_mulmod: Selector,
    /// Selector for CALLDATALOAD.
    pub q_calldataload: Selector,
    /// Selector for CALLDATASIZE.
    pub q_calldatasize: Selector,
    /// Selector for CALLDATACOPY.
    pub q_calldatacopy: Selector,
    /// Selector for CODESIZE.
    pub q_codesize: Selector,
    /// Selector for CODECOPY.
    pub q_codecopy: Selector,
    /// Selector for MSTORE8 (memory store single byte).
    pub q_mstore8: Selector,
    /// Selector for MSIZE (memory size).
    pub q_msize: Selector,
    /// Selector for PC (program counter).
    pub q_pc: Selector,
    /// Selector for GAS (remaining gas).
    pub q_gas: Selector,
    /// Selector for EXTCODESIZE (external code size).
    pub q_extcodesize: Selector,
    /// Selector for EXTCODECOPY (external code copy).
    pub q_extcodecopy: Selector,
    /// Selector for EXTCODEHASH (external code hash).
    pub q_extcodehash: Selector,
    /// Selector for RETURNDATASIZE.
    pub q_returndatasize: Selector,
    /// Selector for RETURNDATACOPY.
    pub q_returndatacopy: Selector,
    /// Selector for TLOAD (transient storage load, EIP-1153).
    pub q_tload: Selector,
    /// Selector for TSTORE (transient storage store, EIP-1153).
    pub q_tstore: Selector,
    /// Selector for MCOPY (memory copy, EIP-5656).
    pub q_mcopy: Selector,
    /// Selector for PUSH0 (push zero, EIP-3855).
    pub q_push0: Selector,
    /// Selector for STOP (halt execution).
    pub q_stop: Selector,
    /// Selector for JUMPDEST (jump destination marker).
    pub q_jumpdest: Selector,
    /// Selector for environment opcodes (ADDRESS, BALANCE, ORIGIN, etc).
    pub q_env: Selector,
    /// Selector for block context opcodes (BLOCKHASH, TIMESTAMP, etc).
    pub q_block: Selector,
    /// Selector for LOG0-LOG4.
    pub q_log: Selector,
    /// Selector for CREATE/CREATE2.
    pub q_create: Selector,

    // -- Fixed column --

    /// Constants column for round constants and lookup values.
    pub constant: Column<Fixed>,
}

impl BasisCircuitConfig {
    /// Allocate all columns and register them with the constraint system.
    ///
    /// This is called from `Circuit::configure()`. Column allocation must happen
    /// before any gate or lookup configuration.
    pub fn allocate(meta: &mut ConstraintSystem<Fr>) -> Self {
        // Advice columns (4 columns for operands, results, and auxiliary data)
        let a = meta.advice_column();
        let b = meta.advice_column();
        let c = meta.advice_column();
        let d = meta.advice_column();

        // Instance column (public inputs)
        let instance = meta.instance_column();

        // Gate selectors (one per custom gate type)
        let q_add = meta.selector();
        let q_mul = meta.selector();
        let q_poseidon = meta.selector();
        let q_memory = meta.selector();
        let q_stack = meta.selector();

        // EVM arithmetic selectors
        let q_sub = meta.selector();
        let q_div = meta.selector();
        let q_mod = meta.selector();
        let q_lt = meta.selector();
        let q_eq = meta.selector();
        let q_iszero = meta.selector();
        let q_and = meta.selector();
        let q_or = meta.selector();
        let q_not = meta.selector();

        // Storage/Memory selectors
        let q_sload = meta.selector();
        let q_sstore = meta.selector();
        let q_mload = meta.selector();
        let q_mstore = meta.selector();
        let q_hash = meta.selector();

        // Control flow selectors
        let q_jump = meta.selector();
        let q_push = meta.selector();
        let q_pop = meta.selector();
        let q_dup = meta.selector();
        let q_swap = meta.selector();
        let q_call = meta.selector();
        let q_return = meta.selector();

        // Extended EVM selectors
        let q_shl = meta.selector();
        let q_shr = meta.selector();
        let q_sar = meta.selector();
        let q_byte = meta.selector();
        let q_signextend = meta.selector();
        let q_exp = meta.selector();
        let q_sha3 = meta.selector();
        let q_xor = meta.selector();
        let q_slt = meta.selector();
        let q_sgt = meta.selector();
        let q_sdiv = meta.selector();
        let q_smod = meta.selector();
        let q_addmod = meta.selector();
        let q_mulmod = meta.selector();
        let q_calldataload = meta.selector();
        let q_calldatasize = meta.selector();
        let q_calldatacopy = meta.selector();
        let q_codesize = meta.selector();
        let q_codecopy = meta.selector();
        let q_mstore8 = meta.selector();
        let q_msize = meta.selector();
        let q_pc = meta.selector();
        let q_gas = meta.selector();
        let q_extcodesize = meta.selector();
        let q_extcodecopy = meta.selector();
        let q_extcodehash = meta.selector();
        let q_returndatasize = meta.selector();
        let q_returndatacopy = meta.selector();
        let q_tload = meta.selector();
        let q_tstore = meta.selector();
        let q_mcopy = meta.selector();
        let q_push0 = meta.selector();
        let q_stop = meta.selector();
        let q_jumpdest = meta.selector();
        let q_env = meta.selector();
        let q_block = meta.selector();
        let q_log = meta.selector();
        let q_create = meta.selector();

        // Fixed column for constants
        let constant = meta.fixed_column();

        // Enable equality constraints on advice and instance columns.
        // Required for copy constraints (permutation argument) that enforce
        // wiring between cells across different rows/regions.
        meta.enable_equality(a);
        meta.enable_equality(b);
        meta.enable_equality(c);
        meta.enable_equality(d);
        meta.enable_equality(instance);
        meta.enable_constant(constant);

        BasisCircuitConfig {
            a,
            b,
            c,
            d,
            instance,
            q_add,
            q_mul,
            q_poseidon,
            q_memory,
            q_stack,
            q_sub,
            q_div,
            q_mod,
            q_lt,
            q_eq,
            q_iszero,
            q_and,
            q_or,
            q_not,
            q_sload,
            q_sstore,
            q_mload,
            q_mstore,
            q_hash,
            q_jump,
            q_push,
            q_pop,
            q_dup,
            q_swap,
            q_call,
            q_return,
            q_shl,
            q_shr,
            q_sar,
            q_byte,
            q_signextend,
            q_exp,
            q_sha3,
            q_xor,
            q_slt,
            q_sgt,
            q_sdiv,
            q_smod,
            q_addmod,
            q_mulmod,
            q_calldataload,
            q_calldatasize,
            q_calldatacopy,
            q_codesize,
            q_codecopy,
            q_mstore8,
            q_msize,
            q_pc,
            q_gas,
            q_extcodesize,
            q_extcodecopy,
            q_extcodehash,
            q_returndatasize,
            q_returndatacopy,
            q_tload,
            q_tstore,
            q_mcopy,
            q_push0,
            q_stop,
            q_jumpdest,
            q_env,
            q_block,
            q_log,
            q_create,
            constant,
        }
    }
}
