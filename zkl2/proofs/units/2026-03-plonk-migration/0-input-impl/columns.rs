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
            constant,
        }
    }
}
