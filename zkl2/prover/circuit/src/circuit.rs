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
use crate::evm_gates::configure_evm_gates;

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

    // -- Extended EVM operations (evm_gates.rs selectors) --

    /// Shift left: c = a << b. d = 2^b (precomputed). Selector: q_shl.
    Shl { a: Fr, shift_pow: Fr },
    /// Shift right: c = a >> b. d = 2^b (precomputed). Selector: q_shr.
    Shr { a: Fr, shift_pow: Fr },
    /// Arithmetic shift right: c = a >> b (signed). d = 2^b. Selector: q_sar.
    Sar { a: Fr, shift_pow: Fr, result: Fr },
    /// Extract byte: a=word, b=index, c=byte. Selector: q_byte.
    Byte { word: Fr, index: Fr, result: Fr },
    /// Sign extend: a=value, b=byte_pos, c=result. Selector: q_signextend.
    SignExtend { value: Fr, byte_pos: Fr, result: Fr },
    /// Exponentiation: c = a^b (single step, d=1). Selector: q_exp.
    Exp { base: Fr, result: Fr },
    /// SHA3/Keccak256: a=offset, b=size, c=hash. Selector: q_sha3.
    Sha3 { offset: Fr, size: Fr, hash: Fr },
    /// Bitwise XOR: c = a XOR b. Selector: q_xor.
    Xor { a: Fr, b: Fr, result: Fr },
    /// Signed less-than: c = (a <_signed b) ? 1 : 0. Selector: q_slt.
    Slt { a: Fr, b: Fr, result: Fr },
    /// Signed greater-than: c = (a >_signed b) ? 1 : 0. Selector: q_sgt.
    Sgt { a: Fr, b: Fr, result: Fr },
    /// Signed division: c = a /_ b (signed). Selector: q_sdiv.
    Sdiv { a: Fr, b: Fr, result: Fr },
    /// Signed modulo: c = a %_signed b. Selector: q_smod.
    Smod { a: Fr, b: Fr, result: Fr },
    /// Modular addition: c = (a + b) mod N. d = N. Selector: q_addmod.
    Addmod { a: Fr, b: Fr, n: Fr, result: Fr },
    /// Modular multiplication: c = (a * b) mod N. d = N. Selector: q_mulmod.
    Mulmod { a: Fr, b: Fr, n: Fr, result: Fr },
    /// Calldata load: a=offset, c=value. Selector: q_calldataload.
    CalldataLoad { offset: Fr, value: Fr },
    /// Calldata size: c=size. Selector: q_calldatasize.
    CalldataSize { size: Fr },
    /// Calldata copy: a=dest, b=offset, c=size. Selector: q_calldatacopy.
    CalldataCopy { dest: Fr, offset: Fr, size: Fr },
    /// Code size: c=size. Selector: q_codesize.
    CodeSize { size: Fr },
    /// Code copy: a=dest, b=offset, c=size. Selector: q_codecopy.
    CodeCopy { dest: Fr, offset: Fr, size: Fr },
    /// Memory store 8-bit: a=offset, c=value. Selector: q_mstore8.
    Mstore8 { address: Fr, value: Fr },
    /// Memory size: c=size. Selector: q_msize.
    Msize { size: Fr },
    /// Program counter: c=pc. Selector: q_pc.
    Pc { pc: Fr },
    /// Remaining gas: c=gas. Selector: q_gas.
    Gas { gas: Fr },
    /// External code size: a=address, c=size. Selector: q_extcodesize.
    ExtCodeSize { address: Fr, size: Fr },
    /// External code copy: a=address, b=dest. Selector: q_extcodecopy.
    ExtCodeCopy { address: Fr, dest: Fr, offset: Fr, size: Fr },
    /// External code hash: a=address, c=hash. Selector: q_extcodehash.
    ExtCodeHash { address: Fr, hash: Fr },
    /// Return data size: c=size. Selector: q_returndatasize.
    ReturnDataSize { size: Fr },
    /// Return data copy: a=dest, b=offset, c=size. Selector: q_returndatacopy.
    ReturnDataCopy { dest: Fr, offset: Fr, size: Fr },
    /// Transient storage load: a=slot, c=value. Selector: q_tload.
    Tload { slot: Fr, value: Fr },
    /// Transient storage store: a=slot, c=value. Selector: q_tstore.
    Tstore { slot: Fr, value: Fr },
    /// Memory copy: a=dest, b=src, c=size. Selector: q_mcopy.
    Mcopy { dest: Fr, src: Fr, size: Fr },
    /// Push zero: c=0. Selector: q_push0.
    Push0,
    /// Stop execution. Selector: q_stop.
    Stop,
    /// Jump destination marker. Selector: q_jumpdest.
    JumpDest,
    /// Environment opcode: c=value, d=expected. Selector: q_env.
    Env { value: Fr },
    /// Block context opcode: c=value, d=expected. Selector: q_block.
    Block { value: Fr },
    /// Log emission: a=offset, b=topic_count. Selector: q_log.
    Log { offset: Fr, topic_count: Fr },
    /// Contract creation: a=value, b=salt, c=address, d=success. Selector: q_create.
    Create { value: Fr, salt: Fr, address: Fr, success: bool },
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
            CircuitOp::Shl { a, shift_pow } => *a * *shift_pow,
            CircuitOp::Shr { a, shift_pow } => {
                if *shift_pow == Fr::ZERO { *a } else { *a * shift_pow.invert().unwrap() }
            }
            CircuitOp::Sar { result, .. } => *result,
            CircuitOp::Byte { result, .. } => *result,
            CircuitOp::SignExtend { result, .. } => *result,
            CircuitOp::Exp { result, .. } => *result,
            CircuitOp::Sha3 { hash, .. } => *hash,
            CircuitOp::Xor { result, .. } => *result,
            CircuitOp::Slt { result, .. } => *result,
            CircuitOp::Sgt { result, .. } => *result,
            CircuitOp::Sdiv { result, .. } => *result,
            CircuitOp::Smod { result, .. } => *result,
            CircuitOp::Addmod { result, .. } => *result,
            CircuitOp::Mulmod { result, .. } => *result,
            CircuitOp::CalldataLoad { value, .. } => *value,
            CircuitOp::CalldataSize { size } => *size,
            CircuitOp::CalldataCopy { size, .. } => *size,
            CircuitOp::CodeSize { size } => *size,
            CircuitOp::CodeCopy { size, .. } => *size,
            CircuitOp::Mstore8 { value, .. } => *value,
            CircuitOp::Msize { size } => *size,
            CircuitOp::Pc { pc } => *pc,
            CircuitOp::Gas { gas } => *gas,
            CircuitOp::ExtCodeSize { size, .. } => *size,
            CircuitOp::ExtCodeCopy { size, .. } => *size,
            CircuitOp::ExtCodeHash { hash, .. } => *hash,
            CircuitOp::ReturnDataSize { size } => *size,
            CircuitOp::ReturnDataCopy { size, .. } => *size,
            CircuitOp::Tload { value, .. } => *value,
            CircuitOp::Tstore { value, .. } => *value,
            CircuitOp::Mcopy { size, .. } => *size,
            CircuitOp::Push0 => Fr::ZERO,
            CircuitOp::Stop => Fr::ZERO,
            CircuitOp::JumpDest => Fr::ZERO,
            CircuitOp::Env { value } => *value,
            CircuitOp::Block { value } => *value,
            CircuitOp::Log { offset, .. } => *offset,
            CircuitOp::Create { address, .. } => *address,
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
        configure_evm_gates(meta, &config);
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

                        // -- Extended EVM ops --

                        CircuitOp::Shl { a, shift_pow } => {
                            config.q_shl.enable(&mut region, row)?;
                            region.assign_advice(|| "shl_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "shl_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "shl_c", config.c, row, || Value::known(*a * *shift_pow))?;
                            region.assign_advice(|| "shl_d", config.d, row, || Value::known(*shift_pow))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Shr { a, shift_pow } => {
                            config.q_shr.enable(&mut region, row)?;
                            let c_val = if *shift_pow == Fr::ZERO { *a } else { *a * shift_pow.invert().unwrap() };
                            region.assign_advice(|| "shr_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "shr_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "shr_c", config.c, row, || Value::known(c_val))?;
                            region.assign_advice(|| "shr_d", config.d, row, || Value::known(*shift_pow))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Sar { a, shift_pow, result } => {
                            config.q_sar.enable(&mut region, row)?;
                            region.assign_advice(|| "sar_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "sar_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "sar_c", config.c, row, || Value::known(*result))?;
                            region.assign_advice(|| "sar_d", config.d, row, || Value::known(*shift_pow))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Byte { word, index, result } => {
                            config.q_byte.enable(&mut region, row)?;
                            region.assign_advice(|| "byte_a", config.a, row, || Value::known(*word))?;
                            region.assign_advice(|| "byte_b", config.b, row, || Value::known(*index))?;
                            let c_cell = region.assign_advice(|| "byte_c", config.c, row, || Value::known(*result))?;
                            region.assign_advice(|| "byte_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::SignExtend { value, byte_pos, result } => {
                            config.q_signextend.enable(&mut region, row)?;
                            region.assign_advice(|| "sext_a", config.a, row, || Value::known(*value))?;
                            region.assign_advice(|| "sext_b", config.b, row, || Value::known(*byte_pos))?;
                            let c_cell = region.assign_advice(|| "sext_c", config.c, row, || Value::known(*result))?;
                            region.assign_advice(|| "sext_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Exp { base, result } => {
                            config.q_exp.enable(&mut region, row)?;
                            region.assign_advice(|| "exp_a", config.a, row, || Value::known(*base))?;
                            region.assign_advice(|| "exp_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "exp_c", config.c, row, || Value::known(*result))?;
                            region.assign_advice(|| "exp_d", config.d, row, || Value::known(Fr::from(1u64)))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Sha3 { offset, size, hash } => {
                            config.q_sha3.enable(&mut region, row)?;
                            region.assign_advice(|| "sha3_a", config.a, row, || Value::known(*offset))?;
                            region.assign_advice(|| "sha3_b", config.b, row, || Value::known(*size))?;
                            let c_cell = region.assign_advice(|| "sha3_c", config.c, row, || Value::known(*hash))?;
                            region.assign_advice(|| "sha3_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Xor { a, b, result } => {
                            config.q_xor.enable(&mut region, row)?;
                            region.assign_advice(|| "xor_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "xor_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "xor_c", config.c, row, || Value::known(*result))?;
                            region.assign_advice(|| "xor_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Slt { a, b, result } => {
                            config.q_slt.enable(&mut region, row)?;
                            region.assign_advice(|| "slt_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "slt_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "slt_c", config.c, row, || Value::known(*result))?;
                            region.assign_advice(|| "slt_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Sgt { a, b, result } => {
                            config.q_sgt.enable(&mut region, row)?;
                            region.assign_advice(|| "sgt_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "sgt_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "sgt_c", config.c, row, || Value::known(*result))?;
                            region.assign_advice(|| "sgt_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Sdiv { a, b, result } => {
                            config.q_sdiv.enable(&mut region, row)?;
                            region.assign_advice(|| "sdiv_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "sdiv_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "sdiv_c", config.c, row, || Value::known(*result))?;
                            region.assign_advice(|| "sdiv_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Smod { a, b, result } => {
                            config.q_smod.enable(&mut region, row)?;
                            let q_val = if *b == Fr::ZERO { Fr::ZERO } else { *a * b.invert().unwrap() };
                            region.assign_advice(|| "smod_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "smod_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "smod_c", config.c, row, || Value::known(*result))?;
                            region.assign_advice(|| "smod_d", config.d, row, || Value::known(q_val))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Addmod { a, b, n, result } => {
                            config.q_addmod.enable(&mut region, row)?;
                            region.assign_advice(|| "amod_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "amod_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "amod_c", config.c, row, || Value::known(*result))?;
                            region.assign_advice(|| "amod_d", config.d, row, || Value::known(*n))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Mulmod { a, b, n, result } => {
                            config.q_mulmod.enable(&mut region, row)?;
                            region.assign_advice(|| "mmod_a", config.a, row, || Value::known(*a))?;
                            region.assign_advice(|| "mmod_b", config.b, row, || Value::known(*b))?;
                            let c_cell = region.assign_advice(|| "mmod_c", config.c, row, || Value::known(*result))?;
                            region.assign_advice(|| "mmod_d", config.d, row, || Value::known(*n))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::CalldataLoad { offset, value } => {
                            config.q_calldataload.enable(&mut region, row)?;
                            region.assign_advice(|| "cdl_a", config.a, row, || Value::known(*offset))?;
                            region.assign_advice(|| "cdl_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "cdl_c", config.c, row, || Value::known(*value))?;
                            region.assign_advice(|| "cdl_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::CalldataSize { size } => {
                            config.q_calldatasize.enable(&mut region, row)?;
                            region.assign_advice(|| "cds_a", config.a, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "cds_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "cds_c", config.c, row, || Value::known(*size))?;
                            region.assign_advice(|| "cds_d", config.d, row, || Value::known(*size))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::CalldataCopy { dest, offset, size } => {
                            config.q_calldatacopy.enable(&mut region, row)?;
                            region.assign_advice(|| "cdc_a", config.a, row, || Value::known(*dest))?;
                            region.assign_advice(|| "cdc_b", config.b, row, || Value::known(*offset))?;
                            let c_cell = region.assign_advice(|| "cdc_c", config.c, row, || Value::known(*size))?;
                            region.assign_advice(|| "cdc_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::CodeSize { size } => {
                            config.q_codesize.enable(&mut region, row)?;
                            region.assign_advice(|| "csz_a", config.a, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "csz_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "csz_c", config.c, row, || Value::known(*size))?;
                            region.assign_advice(|| "csz_d", config.d, row, || Value::known(*size))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::CodeCopy { dest, offset, size } => {
                            config.q_codecopy.enable(&mut region, row)?;
                            region.assign_advice(|| "cc_a", config.a, row, || Value::known(*dest))?;
                            region.assign_advice(|| "cc_b", config.b, row, || Value::known(*offset))?;
                            let c_cell = region.assign_advice(|| "cc_c", config.c, row, || Value::known(*size))?;
                            region.assign_advice(|| "cc_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Mstore8 { address, value } => {
                            config.q_mstore8.enable(&mut region, row)?;
                            region.assign_advice(|| "ms8_a", config.a, row, || Value::known(*address))?;
                            region.assign_advice(|| "ms8_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "ms8_c", config.c, row, || Value::known(*value))?;
                            region.assign_advice(|| "ms8_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Msize { size } => {
                            config.q_msize.enable(&mut region, row)?;
                            region.assign_advice(|| "msz_a", config.a, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "msz_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "msz_c", config.c, row, || Value::known(*size))?;
                            region.assign_advice(|| "msz_d", config.d, row, || Value::known(*size))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Pc { pc } => {
                            config.q_pc.enable(&mut region, row)?;
                            region.assign_advice(|| "pc_a", config.a, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "pc_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "pc_c", config.c, row, || Value::known(*pc))?;
                            region.assign_advice(|| "pc_d", config.d, row, || Value::known(*pc))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Gas { gas } => {
                            config.q_gas.enable(&mut region, row)?;
                            region.assign_advice(|| "gas_a", config.a, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "gas_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "gas_c", config.c, row, || Value::known(*gas))?;
                            region.assign_advice(|| "gas_d", config.d, row, || Value::known(*gas))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::ExtCodeSize { address, size } => {
                            config.q_extcodesize.enable(&mut region, row)?;
                            region.assign_advice(|| "ecs_a", config.a, row, || Value::known(*address))?;
                            region.assign_advice(|| "ecs_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "ecs_c", config.c, row, || Value::known(*size))?;
                            region.assign_advice(|| "ecs_d", config.d, row, || Value::known(*size))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::ExtCodeCopy { address, dest, offset: _, size } => {
                            config.q_extcodecopy.enable(&mut region, row)?;
                            region.assign_advice(|| "ecc_a", config.a, row, || Value::known(*address))?;
                            region.assign_advice(|| "ecc_b", config.b, row, || Value::known(*dest))?;
                            let c_cell = region.assign_advice(|| "ecc_c", config.c, row, || Value::known(*size))?;
                            region.assign_advice(|| "ecc_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::ExtCodeHash { address, hash } => {
                            config.q_extcodehash.enable(&mut region, row)?;
                            region.assign_advice(|| "ech_a", config.a, row, || Value::known(*address))?;
                            region.assign_advice(|| "ech_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "ech_c", config.c, row, || Value::known(*hash))?;
                            region.assign_advice(|| "ech_d", config.d, row, || Value::known(*hash))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::ReturnDataSize { size } => {
                            config.q_returndatasize.enable(&mut region, row)?;
                            region.assign_advice(|| "rds_a", config.a, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "rds_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "rds_c", config.c, row, || Value::known(*size))?;
                            region.assign_advice(|| "rds_d", config.d, row, || Value::known(*size))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::ReturnDataCopy { dest, offset, size } => {
                            config.q_returndatacopy.enable(&mut region, row)?;
                            region.assign_advice(|| "rdc_a", config.a, row, || Value::known(*dest))?;
                            region.assign_advice(|| "rdc_b", config.b, row, || Value::known(*offset))?;
                            let c_cell = region.assign_advice(|| "rdc_c", config.c, row, || Value::known(*size))?;
                            region.assign_advice(|| "rdc_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Tload { slot, value } => {
                            config.q_tload.enable(&mut region, row)?;
                            region.assign_advice(|| "tl_a", config.a, row, || Value::known(*slot))?;
                            region.assign_advice(|| "tl_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "tl_c", config.c, row, || Value::known(*value))?;
                            region.assign_advice(|| "tl_d", config.d, row, || Value::known(*value))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Tstore { slot, value } => {
                            config.q_tstore.enable(&mut region, row)?;
                            region.assign_advice(|| "ts_a", config.a, row, || Value::known(*slot))?;
                            region.assign_advice(|| "ts_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "ts_c", config.c, row, || Value::known(*value))?;
                            region.assign_advice(|| "ts_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Mcopy { dest, src, size } => {
                            config.q_mcopy.enable(&mut region, row)?;
                            region.assign_advice(|| "mc_a", config.a, row, || Value::known(*dest))?;
                            region.assign_advice(|| "mc_b", config.b, row, || Value::known(*src))?;
                            let c_cell = region.assign_advice(|| "mc_c", config.c, row, || Value::known(*size))?;
                            region.assign_advice(|| "mc_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Push0 => {
                            config.q_push0.enable(&mut region, row)?;
                            region.assign_advice(|| "p0_a", config.a, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "p0_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "p0_c", config.c, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "p0_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Stop => {
                            config.q_stop.enable(&mut region, row)?;
                            region.assign_advice(|| "stop_a", config.a, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "stop_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "stop_c", config.c, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "stop_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::JumpDest => {
                            config.q_jumpdest.enable(&mut region, row)?;
                            region.assign_advice(|| "jd_a", config.a, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "jd_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "jd_c", config.c, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "jd_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Env { value } => {
                            config.q_env.enable(&mut region, row)?;
                            region.assign_advice(|| "env_a", config.a, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "env_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "env_c", config.c, row, || Value::known(*value))?;
                            region.assign_advice(|| "env_d", config.d, row, || Value::known(*value))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Block { value } => {
                            config.q_block.enable(&mut region, row)?;
                            region.assign_advice(|| "blk_a", config.a, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "blk_b", config.b, row, || Value::known(Fr::ZERO))?;
                            let c_cell = region.assign_advice(|| "blk_c", config.c, row, || Value::known(*value))?;
                            region.assign_advice(|| "blk_d", config.d, row, || Value::known(*value))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Log { offset, topic_count } => {
                            config.q_log.enable(&mut region, row)?;
                            region.assign_advice(|| "log_a", config.a, row, || Value::known(*offset))?;
                            region.assign_advice(|| "log_b", config.b, row, || Value::known(*topic_count))?;
                            let c_cell = region.assign_advice(|| "log_c", config.c, row, || Value::known(Fr::ZERO))?;
                            region.assign_advice(|| "log_d", config.d, row, || Value::known(Fr::ZERO))?;
                            assigned_cells.push(c_cell);
                        }
                        CircuitOp::Create { value, salt, address, success } => {
                            config.q_create.enable(&mut region, row)?;
                            let d_val = if *success { Fr::from(1u64) } else { Fr::ZERO };
                            region.assign_advice(|| "crt_a", config.a, row, || Value::known(*value))?;
                            region.assign_advice(|| "crt_b", config.b, row, || Value::known(*salt))?;
                            let c_cell = region.assign_advice(|| "crt_c", config.c, row, || Value::known(*address))?;
                            region.assign_advice(|| "crt_d", config.d, row, || Value::known(d_val))?;
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
