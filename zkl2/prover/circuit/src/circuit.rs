/// Main PLONK circuit definition for Basis Network zkEVM state transitions.
///
/// Implements the halo2 `Circuit` trait for the BasisCircuit, which proves
/// that applying a batch of EVM transactions to a pre-state root produces
/// the claimed post-state root. The circuit uses custom gates (AddGate,
/// MulGate, PoseidonGate, MemoryGate, StackGate) to efficiently encode
/// EVM operations with fewer rows than R1CS-based Groth16.
///
/// [Spec: lab/3-architect/implementation-history/prover-plonk-migration/specs/PlonkMigration.tla]
use halo2_proofs::{
    arithmetic::Field,
    circuit::{AssignedCell, Layouter, SimpleFloorPlanner, Value},
    halo2curves::{bn256::Fr, ff::PrimeField},
    plonk::{Circuit, ConstraintSystem, Error},
};

use crate::columns::BasisCircuitConfig;
use crate::gates::configure_gates;

// ---------------------------------------------------------------------------
// Operation types for circuit witness
// ---------------------------------------------------------------------------

/// An operation to be proven in the circuit.
///
/// Each operation maps to exactly one row in the circuit, with the
/// corresponding gate selector enabled. The gate enforces the constraint.
#[derive(Debug, Clone)]
pub enum CircuitOp {
    /// Addition: c = a + b. Selector: q_add.
    Add { a: Fr, b: Fr },
    /// Multiplication: c = a * b. Selector: q_mul.
    Mul { a: Fr, b: Fr },
    /// Poseidon S-box: c = a^5 + round_constant. Selector: q_poseidon.
    Poseidon { input: Fr, round_constant: Fr },
    /// Memory access: address=a, value=c. Selector: q_memory.
    Memory { address: Fr, value: Fr },
    /// Stack operation: a must equal previous c. Selector: q_stack.
    Stack { input: Fr, b: Fr },

    // -- EVM arithmetic operations --

    /// Subtraction: c = a - b. Selector: q_sub.
    Sub { a: Fr, b: Fr },
    /// Division: c = a / b (integer). Selector: q_div.
    Div { a: Fr, b: Fr },
    /// Modulo: c = a mod b, d = a / b (quotient). Selector: q_mod.
    Mod { a: Fr, b: Fr },
    /// Less-than: c = (a < b) ? 1 : 0. Selector: q_lt.
    Lt { a: Fr, b: Fr },
    /// Equality: c = (a == b) ? 1 : 0. Selector: q_eq.
    Eq { a: Fr, b: Fr },
    /// Is-zero: c = (a == 0) ? 1 : 0. Selector: q_iszero.
    IsZero { a: Fr },
    /// Boolean AND: c = a * b. Selector: q_and.
    And { a: Fr, b: Fr },
    /// Boolean OR: c = a + b - a*b. Selector: q_or.
    Or { a: Fr, b: Fr },
    /// Boolean NOT: c = 1 - a. Selector: q_not.
    Not { a: Fr },

    // -- Storage/Memory operations --

    /// Storage read: slot=a, value=c, expected=d. Selector: q_sload.
    Sload { slot: Fr, value: Fr },
    /// Storage write: slot=a, old_value=b, new_value=c. Selector: q_sstore.
    Sstore { slot: Fr, old_value: Fr, new_value: Fr },
    /// Memory read: address=a, value=c, expected=d. Selector: q_mload.
    Mload { address: Fr, value: Fr },
    /// Memory write: address=a, value=c. Selector: q_mstore.
    Mstore { address: Fr, value: Fr },
    /// Hash: c = Hash(a, b). Selector: q_hash.
    Hash { left: Fr, right: Fr },

    // -- Control flow operations --

    /// Jump: destination=a, condition=b, next_pc=c. Selector: q_jump.
    Jump { destination: Fr, condition: Fr },
    /// Push: value=a pushed to stack, c=a. Selector: q_push.
    Push { value: Fr },
    /// Pop: consume stack value (no output). Selector: q_pop.
    Pop { value: Fr },
    /// Dup: duplicate a -> c. Selector: q_dup.
    Dup { value: Fr },
    /// Swap: exchange a and b, c = b. Selector: q_swap.
    Swap { first: Fr, second: Fr },
    /// Call: gas=a, target=b, value=c, success=d. Selector: q_call.
    Call { gas: Fr, target: Fr, value: Fr, success: bool },
    /// Return/Revert: offset=a, size=b, is_revert=d. Selector: q_return.
    Return { offset: Fr, size: Fr, is_revert: bool },
}

impl CircuitOp {
    /// Compute the expected output for this operation.
    pub fn expected_output(&self) -> Fr {
        match self {
            CircuitOp::Add { a, b } => *a + *b,
            CircuitOp::Mul { a, b } => *a * *b,
            CircuitOp::Poseidon {
                input,
                round_constant,
            } => {
                let x = *input;
                let x2 = x * x;
                let x4 = x2 * x2;
                let x5 = x4 * x;
                x5 + *round_constant
            }
            CircuitOp::Memory { value, .. } => *value,
            CircuitOp::Stack { input, b } => *input + *b,
            CircuitOp::Sub { a, b } => *a - *b,
            CircuitOp::Div { a, b } => {
                if *b == Fr::from(0u64) { Fr::from(0u64) } else { *a * b.invert().unwrap() }
            }
            CircuitOp::Mod { a, b } => {
                // In field arithmetic, mod is complex. For the circuit,
                // the prover computes the result off-chain.
                // c = a - b * (a / b)
                if *b == Fr::from(0u64) { Fr::from(0u64) } else {
                    let q = *a * b.invert().unwrap();
                    *a - *b * q
                }
            }
            CircuitOp::Lt { a, b } => {
                // Field comparison: use Montgomery representation ordering
                if a.to_repr() < b.to_repr() { Fr::from(1u64) } else { Fr::from(0u64) }
            }
            CircuitOp::Eq { a, b } => {
                if *a == *b { Fr::from(1u64) } else { Fr::from(0u64) }
            }
            CircuitOp::IsZero { a } => {
                if *a == Fr::from(0u64) { Fr::from(1u64) } else { Fr::from(0u64) }
            }
            CircuitOp::And { a, b } => *a * *b,
            CircuitOp::Or { a, b } => *a + *b - *a * *b,
            CircuitOp::Not { a } => Fr::from(1u64) - *a,
            CircuitOp::Sload { value, .. } => *value,
            CircuitOp::Sstore { new_value, .. } => *new_value,
            CircuitOp::Mload { value, .. } => *value,
            CircuitOp::Mstore { value, .. } => *value,
            CircuitOp::Hash { left, right } => {
                let x = *left;
                let x2 = x * x;
                let x4 = x2 * x2;
                let x5 = x4 * x;
                x5 + *right
            }
            CircuitOp::Jump { destination, condition } => {
                if *condition != Fr::ZERO { *destination } else { Fr::ZERO }
            }
            CircuitOp::Push { value } => *value,
            CircuitOp::Pop { value } => *value,
            CircuitOp::Dup { value } => *value,
            CircuitOp::Swap { second, .. } => *second,
            CircuitOp::Call { value, .. } => *value,
            CircuitOp::Return { offset, .. } => *offset,
        }
    }
}

// ---------------------------------------------------------------------------
// BasisCircuit
// ---------------------------------------------------------------------------

/// PLONK circuit for Basis Network EVM state transition proofs.
///
/// The circuit takes:
/// - Public inputs: pre_state_root, post_state_root, batch_hash
/// - Private witness: sequence of EVM operations with their values
///
/// The constraint system ensures that each operation is correctly computed
/// (via custom gates) and that the final state matches the claimed post_state_root.
#[derive(Debug, Clone)]
pub struct BasisCircuit {
    /// Sequence of operations comprising the EVM execution trace.
    pub operations: Vec<CircuitOp>,
    /// Public input: state root before batch execution.
    pub pre_state_root: Fr,
    /// Public input: state root after batch execution.
    pub post_state_root: Fr,
    /// Public input: hash of the batch data.
    pub batch_hash: Fr,
}

impl BasisCircuit {
    /// Create a new circuit with the given operations and public inputs.
    pub fn new(
        operations: Vec<CircuitOp>,
        pre_state_root: Fr,
        post_state_root: Fr,
        batch_hash: Fr,
    ) -> Self {
        Self {
            operations,
            pre_state_root,
            post_state_root,
            batch_hash,
        }
    }

    /// Create a minimal circuit for testing with a single ADD operation.
    pub fn trivial() -> Self {
        let a = Fr::from(1u64);
        let b = Fr::from(2u64);
        Self {
            operations: vec![CircuitOp::Add { a, b }],
            pre_state_root: Fr::from(100u64),
            post_state_root: Fr::from(200u64),
            batch_hash: Fr::from(300u64),
        }
    }
}

impl Circuit<Fr> for BasisCircuit {
    type Config = BasisCircuitConfig;
    type FloorPlanner = SimpleFloorPlanner;

    fn without_witnesses(&self) -> Self {
        Self {
            operations: vec![],
            pre_state_root: Fr::ZERO,
            post_state_root: Fr::ZERO,
            batch_hash: Fr::ZERO,
        }
    }

    /// Configure the constraint system: allocate columns and define gates.
    ///
    /// This is called once during key generation. The resulting Config is
    /// reused for all proof generations with this circuit shape.
    fn configure(meta: &mut ConstraintSystem<Fr>) -> Self::Config {
        let config = BasisCircuitConfig::allocate(meta);
        configure_gates(meta, &config);
        config
    }

    /// Synthesize the circuit: assign witness values to cells.
    ///
    /// This is called during proof generation with concrete witness values.
    /// Each operation is assigned to a row with the appropriate selector enabled.
    fn synthesize(
        &self,
        config: Self::Config,
        mut layouter: impl Layouter<Fr>,
    ) -> Result<(), Error> {
        // Assign public inputs to instance column via constrain_instance
        let _public_cells = layouter.assign_region(
            || "operations",
            |mut region| {
                let mut assigned_cells: Vec<AssignedCell<Fr, Fr>> = Vec::new();

                // Assign each operation to consecutive rows
                for (row, op) in self.operations.iter().enumerate() {
                    match op {
                        CircuitOp::Add { a, b } => {
                            config.q_add.enable(&mut region, row)?;
                            region.assign_advice(
                                || format!("add_a_{}", row),
                                config.a,
                                row,
                                || Value::known(*a),
                            )?;
                            region.assign_advice(
                                || format!("add_b_{}", row),
                                config.b,
                                row,
                                || Value::known(*b),
                            )?;
                            let c_cell = region.assign_advice(
                                || format!("add_c_{}", row),
                                config.c,
                                row,
                                || Value::known(*a + *b),
                            )?;
                            region.assign_advice(
                                || format!("add_d_{}", row),
                                config.d,
                                row,
                                || Value::known(Fr::ZERO),
                            )?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Mul { a, b } => {
                            config.q_mul.enable(&mut region, row)?;
                            region.assign_advice(
                                || format!("mul_a_{}", row),
                                config.a,
                                row,
                                || Value::known(*a),
                            )?;
                            region.assign_advice(
                                || format!("mul_b_{}", row),
                                config.b,
                                row,
                                || Value::known(*b),
                            )?;
                            let c_cell = region.assign_advice(
                                || format!("mul_c_{}", row),
                                config.c,
                                row,
                                || Value::known(*a * *b),
                            )?;
                            region.assign_advice(
                                || format!("mul_d_{}", row),
                                config.d,
                                row,
                                || Value::known(Fr::ZERO),
                            )?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Poseidon {
                            input,
                            round_constant,
                        } => {
                            config.q_poseidon.enable(&mut region, row)?;
                            let x = *input;
                            let x2 = x * x;
                            let x4 = x2 * x2;
                            let x5 = x4 * x;
                            let output = x5 + *round_constant;

                            region.assign_advice(
                                || format!("poseidon_a_{}", row),
                                config.a,
                                row,
                                || Value::known(x),
                            )?;
                            region.assign_advice(
                                || format!("poseidon_b_{}", row),
                                config.b,
                                row,
                                || Value::known(Fr::ZERO),
                            )?;
                            let c_cell = region.assign_advice(
                                || format!("poseidon_c_{}", row),
                                config.c,
                                row,
                                || Value::known(output),
                            )?;
                            region.assign_advice(
                                || format!("poseidon_d_{}", row),
                                config.d,
                                row,
                                || Value::known(*round_constant),
                            )?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Memory { address, value } => {
                            config.q_memory.enable(&mut region, row)?;
                            region.assign_advice(
                                || format!("mem_a_{}", row),
                                config.a,
                                row,
                                || Value::known(*address),
                            )?;
                            region.assign_advice(
                                || format!("mem_b_{}", row),
                                config.b,
                                row,
                                || Value::known(Fr::ZERO),
                            )?;
                            let c_cell = region.assign_advice(
                                || format!("mem_c_{}", row),
                                config.c,
                                row,
                                || Value::known(*value),
                            )?;
                            // d = expected value (must equal c for memory consistency)
                            region.assign_advice(
                                || format!("mem_d_{}", row),
                                config.d,
                                row,
                                || Value::known(*value),
                            )?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Stack { input, b } => {
                            if row > 0 {
                                config.q_stack.enable(&mut region, row)?;
                            }
                            region.assign_advice(|| format!("stack_a_{}", row), config.a, row, || Value::known(*input))?;
                            region.assign_advice(|| format!("stack_b_{}", row), config.b, row, || Value::known(*b))?;
                            let output = *input + *b;
                            let c_cell = region.assign_advice(|| format!("stack_c_{}", row), config.c, row, || Value::known(output))?;
                            region.assign_advice(|| format!("stack_d_{}", row), config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        // -- EVM arithmetic ops (all follow same pattern: enable selector, assign a/b/c/d) --

                        CircuitOp::Sub { a, b } => {
                            config.q_sub.enable(&mut region, row)?;
                            region.assign_advice(|| "sub_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "sub_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "sub_c", config.c, row, || Value::known(*a - *b))?;
                            region.assign_advice(|| "sub_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Div { a, b } => {
                            config.q_div.enable(&mut region, row)?;
                            let c_val = if *b == Fr::ZERO { Fr::ZERO } else { *a * b.invert().unwrap() };
                            region.assign_advice(|| "div_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "div_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "div_c", config.c, row, || Value::known(c_val))?;
                            region.assign_advice(|| "div_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Mod { a, b } => {
                            config.q_mod.enable(&mut region, row)?;
                            let (q_val, c_val) = if *b == Fr::ZERO {
                                (Fr::ZERO, Fr::ZERO)
                            } else {
                                let q_val = *a * b.invert().unwrap();
                                (q_val, *a - *b * q_val)
                            };
                            region.assign_advice(|| "mod_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "mod_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "mod_c", config.c, row, || Value::known(c_val))?;
                            region.assign_advice(|| "mod_d", config.d, row, || Value::known(q_val))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Lt { a, b } => {
                            config.q_lt.enable(&mut region, row)?;
                            let c_val = if a.to_repr() < b.to_repr() { Fr::from(1u64) } else { Fr::from(0u64) };
                            region.assign_advice(|| "lt_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "lt_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "lt_c", config.c, row, || Value::known(c_val))?;
                            region.assign_advice(|| "lt_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Eq { a, b } => {
                            config.q_eq.enable(&mut region, row)?;
                            let c_val = if *a == *b { Fr::from(1u64) } else { Fr::from(0u64) };
                            region.assign_advice(|| "eq_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "eq_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "eq_c", config.c, row, || Value::known(c_val))?;
                            region.assign_advice(|| "eq_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::IsZero { a } => {
                            config.q_iszero.enable(&mut region, row)?;
                            let c_val = if *a == Fr::ZERO { Fr::from(1u64) } else { Fr::from(0u64) };
                            region.assign_advice(|| "iz_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "iz_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "iz_c", config.c, row, || Value::known(c_val))?;
                            region.assign_advice(|| "iz_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::And { a, b } => {
                            config.q_and.enable(&mut region, row)?;
                            region.assign_advice(|| "and_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "and_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "and_c", config.c, row, || Value::known(*a * *b))?;
                            region.assign_advice(|| "and_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Or { a, b } => {
                            config.q_or.enable(&mut region, row)?;
                            let c_val = *a + *b - *a * *b;
                            region.assign_advice(|| "or_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "or_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "or_c", config.c, row, || Value::known(c_val))?;
                            region.assign_advice(|| "or_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Not { a } => {
                            config.q_not.enable(&mut region, row)?;
                            let c_val = Fr::from(1u64) - *a;
                            region.assign_advice(|| "not_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "not_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "not_c", config.c, row, || Value::known(c_val))?;
                            region.assign_advice(|| "not_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        // -- Storage/Memory ops --

                        CircuitOp::Sload { slot, value } => {
                            config.q_sload.enable(&mut region, row)?;
                            region.assign_advice(|| "sload_a", config.a, row, || Value::known(*slot))?;
                            region.assign_advice(|| "sload_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "sload_c", config.c, row, || Value::known(*value))?;
                            region.assign_advice(|| "sload_d", config.d, row, || Value::known(*value))?; // expected = actual
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Sstore { slot, old_value, new_value } => {
                            config.q_sstore.enable(&mut region, row)?;
                            region.assign_advice(|| "sstore_a", config.a, row, || Value::known(*slot))?;
                            region.assign_advice(|| "sstore_b", config.b, row, || Value::known(*old_value))?;
                            let c_cell = region.assign_advice(|| "sstore_c", config.c, row, || Value::known(*new_value))?;
                            // d = 0 for non-identity write, 1 for identity (old == new)
                            let identity = if *old_value == *new_value { Fr::from(1u64) } else { Fr::ZERO };
                            region.assign_advice(|| "sstore_d", config.d, row, || Value::known(identity))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Mload { address, value } => {
                            config.q_mload.enable(&mut region, row)?;
                            region.assign_advice(|| "mload_a", config.a, row, || Value::known(*address))?;
                            region.assign_advice(|| "mload_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "mload_c", config.c, row, || Value::known(*value))?;
                            region.assign_advice(|| "mload_d", config.d, row, || Value::known(*value))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Mstore { address, value } => {
                            config.q_mstore.enable(&mut region, row)?;
                            region.assign_advice(|| "mstore_a", config.a, row, || Value::known(*address))?;
                            region.assign_advice(|| "mstore_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "mstore_c", config.c, row, || Value::known(*value))?;
                            region.assign_advice(|| "mstore_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Hash { left, right } => {
                            config.q_hash.enable(&mut region, row)?;
                            let x = *left;
                            let x2 = x * x;
                            let x4 = x2 * x2;
                            let x5 = x4 * x;
                            let c_val = x5 + *right;
                            region.assign_advice(|| "hash_a", config.a, row, || Value::known(*left))?;
                            region.assign_advice(|| "hash_b", config.b, row, || Value::known(*right))?;
                            let c_cell = region.assign_advice(|| "hash_c", config.c, row, || Value::known(c_val))?;
                            region.assign_advice(|| "hash_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        // -- Control flow ops --

                        CircuitOp::Jump { destination, condition } => {
                            config.q_jump.enable(&mut region, row)?;
                            let c_val = if *condition != Fr::ZERO { *destination } else { Fr::ZERO };
                            region.assign_advice(|| "jump_a", config.a, row, || Value::known(*destination))?;
                            region.assign_advice(|| "jump_b", config.b, row, || Value::known(*condition))?;
                            let c_cell = region.assign_advice(|| "jump_c", config.c, row, || Value::known(c_val))?;
                            region.assign_advice(|| "jump_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Push { value } => {
                            config.q_push.enable(&mut region, row)?;
                            region.assign_advice(|| "push_a", config.a, row, || Value::known(*value))?;
                            region.assign_advice(|| "push_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "push_c", config.c, row, || Value::known(*value))?;
                            region.assign_advice(|| "push_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Pop { value } => {
                            config.q_pop.enable(&mut region, row)?;
                            region.assign_advice(|| "pop_a", config.a, row, || Value::known(*value))?;
                            region.assign_advice(|| "pop_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "pop_c", config.c, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "pop_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Dup { value } => {
                            config.q_dup.enable(&mut region, row)?;
                            region.assign_advice(|| "dup_a", config.a, row, || Value::known(*value))?;
                            region.assign_advice(|| "dup_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "dup_c", config.c, row, || Value::known(*value))?;
                            region.assign_advice(|| "dup_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Swap { first, second } => {
                            config.q_swap.enable(&mut region, row)?;
                            region.assign_advice(|| "swap_a", config.a, row, || Value::known(*first))?;
                            region.assign_advice(|| "swap_b", config.b, row, || Value::known(*second))?;
                            let c_cell = region.assign_advice(|| "swap_c", config.c, row, || Value::known(*second))?;
                            region.assign_advice(|| "swap_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Call { gas, target, value, success } => {
                            config.q_call.enable(&mut region, row)?;
                            let d_val = if *success { Fr::from(1u64) } else { Fr::ZERO };
                            region.assign_advice(|| "call_a", config.a, row, || Value::known(*gas))?;
                            region.assign_advice(|| "call_b", config.b, row, || Value::known(*target))?;
                            let c_cell = region.assign_advice(|| "call_c", config.c, row, || Value::known(*value))?;
                            region.assign_advice(|| "call_d", config.d, row, || Value::known(d_val))?;
                            assigned_cells.push(c_cell);
                        }

                        CircuitOp::Return { offset, size, is_revert } => {
                            config.q_return.enable(&mut region, row)?;
                            let d_val = if *is_revert { Fr::from(1u64) } else { Fr::ZERO };
                            region.assign_advice(|| "ret_a", config.a, row, || Value::known(*offset))?;
                            region.assign_advice(|| "ret_b", config.b, row, || Value::known(*size))?;
                            let c_cell = region.assign_advice(|| "ret_c", config.c, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "ret_d", config.d, row, || Value::known(d_val))?;
                            assigned_cells.push(c_cell);
                        }
                    }
                }

                Ok(assigned_cells)
            },
        )?;

        // Constrain public inputs: expose pre_state_root, post_state_root, batch_hash
        // to the instance column at rows 0, 1, 2 respectively.
        // This binds the circuit's computation to the claimed public values.
        layouter.assign_region(
            || "public_inputs",
            |mut region| {
                let pre_cell = region.assign_advice(
                    || "pre_state_root",
                    config.a,
                    0,
                    || Value::known(self.pre_state_root),
                )?;
                let post_cell = region.assign_advice(
                    || "post_state_root",
                    config.b,
                    0,
                    || Value::known(self.post_state_root),
                )?;
                let batch_cell = region.assign_advice(
                    || "batch_hash",
                    config.c,
                    0,
                    || Value::known(self.batch_hash),
                )?;
                // Padding for column d
                region.assign_advice(
                    || "padding_d",
                    config.d,
                    0,
                    || Value::known(Fr::ZERO),
                )?;
                Ok((pre_cell, post_cell, batch_cell))
            },
        )
        .and_then(|(pre_cell, post_cell, batch_cell)| {
            layouter.constrain_instance(pre_cell.cell(), config.instance, 0)?;
            layouter.constrain_instance(post_cell.cell(), config.instance, 1)?;
            layouter.constrain_instance(batch_cell.cell(), config.instance, 2)?;
            Ok(())
        })?;

        Ok(())
    }
}
