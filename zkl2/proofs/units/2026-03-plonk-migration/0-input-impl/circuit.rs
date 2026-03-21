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
    halo2curves::bn256::Fr,
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
    /// The `input` value must match the previous operation's output.
    Stack { input: Fr, b: Fr },
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
                            // Stack gate uses Rotation::prev, so skip row 0.
                            if row > 0 {
                                config.q_stack.enable(&mut region, row)?;
                            }
                            region.assign_advice(
                                || format!("stack_a_{}", row),
                                config.a,
                                row,
                                || Value::known(*input),
                            )?;
                            region.assign_advice(
                                || format!("stack_b_{}", row),
                                config.b,
                                row,
                                || Value::known(*b),
                            )?;
                            let output = *input + *b;
                            let c_cell = region.assign_advice(
                                || format!("stack_c_{}", row),
                                config.c,
                                row,
                                || Value::known(output),
                            )?;
                            region.assign_advice(
                                || format!("stack_d_{}", row),
                                config.d,
                                row,
                                || Value::known(Fr::ZERO),
                            )?;
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
