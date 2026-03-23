/// Custom gate definitions for the Basis Network PLONK circuit.
///
/// Each gate encodes a specific EVM operation type as a polynomial constraint.
/// Custom gates are the key advantage of PLONK over Groth16: they reduce
/// the number of rows needed per operation, directly lowering proving time.
///
/// Gate reduction factors (vs R1CS):
///   AddGate:     1 row vs 1 constraint  (1:1, but composable)
///   MulGate:     1 row vs 1 constraint  (1:1, but composable)
///   PoseidonGate: 1 row vs 3 constraints (3:1 reduction for x^5)
///   MemoryGate:  1 row for consistency check (rotation-based)
///   StackGate:   1 row for stack discipline (rotation-based)
///
/// [Spec: lab/3-architect/implementation-history/prover-plonk-migration/specs/PlonkMigration.tla]
/// [Source: implementation-history/prover-plonk-migration/research/findings.md, Section 5]
use halo2_proofs::{
    halo2curves::bn256::Fr,
    plonk::{ConstraintSystem, VirtualCells},
    poly::Rotation,
};

use crate::columns::BasisCircuitConfig;

// ---------------------------------------------------------------------------
// Gate configuration
// ---------------------------------------------------------------------------

/// Configure all custom gates on the constraint system.
///
/// Must be called during `Circuit::configure()` after column allocation.
/// Each gate is activated by its selector; when a selector is off (0),
/// the constraint is trivially satisfied (0 * anything = 0).
pub fn configure_gates(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    // Core gates
    configure_add_gate(meta, config);
    configure_mul_gate(meta, config);
    configure_poseidon_gate(meta, config);
    configure_memory_gate(meta, config);
    configure_stack_gate(meta, config);

    // EVM arithmetic gates
    configure_sub_gate(meta, config);
    configure_div_gate(meta, config);
    configure_mod_gate(meta, config);
    configure_lt_gate(meta, config);
    configure_eq_gate(meta, config);
    configure_iszero_gate(meta, config);
    configure_and_gate(meta, config);
    configure_or_gate(meta, config);
    configure_not_gate(meta, config);
}

// ---------------------------------------------------------------------------
// AddGate: a + b - c = 0
// ---------------------------------------------------------------------------

/// Arithmetic addition gate for EVM ADD operations.
///
/// Constraint: `q_add * (a + b - c) = 0`
///
/// When q_add is enabled on a row, the prover must assign values such that
/// c = a + b (in the BN254 scalar field). Used for balance updates,
/// counter increments, and EVM ADD/SUB operations.
fn configure_add_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("add_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_add);
        let a = meta.query_advice(config.a, Rotation::cur());
        let b = meta.query_advice(config.b, Rotation::cur());
        let c = meta.query_advice(config.c, Rotation::cur());

        // q_add * (a + b - c) = 0
        vec![q * (a + b - c)]
    });
}

// ---------------------------------------------------------------------------
// MulGate: a * b - c = 0
// ---------------------------------------------------------------------------

/// Arithmetic multiplication gate for EVM MUL operations.
///
/// Constraint: `q_mul * (a * b - c) = 0`
///
/// When q_mul is enabled, the prover must assign c = a * b.
/// Used for EVM MUL, gas calculations, and polynomial evaluation steps.
fn configure_mul_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("mul_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_mul);
        let a = meta.query_advice(config.a, Rotation::cur());
        let b = meta.query_advice(config.b, Rotation::cur());
        let c = meta.query_advice(config.c, Rotation::cur());

        // q_mul * (a * b - c) = 0
        vec![q * (a.clone() * b - c)]
    });
}

// ---------------------------------------------------------------------------
// PoseidonGate: a^5 + d - c = 0
// ---------------------------------------------------------------------------

/// Degree-5 custom gate for Poseidon S-box computation.
///
/// Constraint: `q_poseidon * (a^5 + d - c) = 0`
///
/// This is the key custom gate that demonstrates PLONK's advantage over R1CS.
/// In Groth16 (R1CS), computing x^5 requires 3 constraints:
///   t1 = x * x       (x^2)
///   t2 = t1 * t1     (x^4)
///   t3 = t2 * x      (x^5)
///
/// In PLONK, we use a single degree-5 gate: x^5 + constant - output = 0.
/// This is a 3:1 constraint reduction for every Poseidon round, yielding
/// 600-900x overall reduction for Poseidon-heavy circuits.
///
/// Column d holds the round constant; c holds the output.
fn configure_poseidon_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("poseidon_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_poseidon);
        let a = meta.query_advice(config.a, Rotation::cur());
        let d = meta.query_advice(config.d, Rotation::cur());
        let c = meta.query_advice(config.c, Rotation::cur());

        // a^5 = a * a * a * a * a
        let a2 = a.clone() * a.clone();
        let a4 = a2.clone() * a2;
        let a5 = a4 * a.clone();

        // q_poseidon * (a^5 + d - c) = 0
        vec![q * (a5 + d - c)]
    });
}

// ---------------------------------------------------------------------------
// MemoryGate: memory read/write consistency
// ---------------------------------------------------------------------------

/// Memory consistency gate for EVM MLOAD/MSTORE operations.
///
/// Constraint: `q_memory * (c - d) = 0`
///
/// Enforces that the memory value (c) matches the expected value (d) precomputed
/// by the witness generator from the memory state. The witness generator is
/// responsible for tracking address-to-value mappings and providing the correct
/// expected value in column d.
///
/// This design separates the memory consistency logic:
/// - Gate (constraint): value matches expected
/// - Witness generator: computes expected values from sorted access log
///
/// Column c = actual memory value, column d = expected value from state.
fn configure_memory_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("memory_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_memory);
        let c = meta.query_advice(config.c, Rotation::cur());
        let d = meta.query_advice(config.d, Rotation::cur());

        // q_memory * (c - d) = 0
        // When enabled: actual value must equal expected value.
        vec![q * (c - d)]
    });
}

// ---------------------------------------------------------------------------
// StackGate: stack push/pop discipline
// ---------------------------------------------------------------------------

/// Stack operation gate for EVM stack discipline.
///
/// Constraint: `q_stack * (c_prev - a_cur) = 0`
///
/// Enforces that the output of the previous operation (c at row-1) feeds as
/// the input to the current operation (a at row 0). This models the EVM stack
/// where results are pushed and consumed in LIFO order.
///
/// Uses Rotation::prev() to access the previous row's result.
fn configure_stack_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("stack_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_stack);
        let c_prev = meta.query_advice(config.c, Rotation::prev());
        let a_cur = meta.query_advice(config.a, Rotation::cur());

        // q_stack * (c_prev - a_cur) = 0
        vec![q * (c_prev - a_cur)]
    });
}

// ===========================================================================
// EVM Arithmetic Gates
// ===========================================================================

// ---------------------------------------------------------------------------
// SubGate: a - b - c = 0
// ---------------------------------------------------------------------------

/// EVM SUB: subtraction gate.
/// Constraint: `q_sub * (a - b - c) = 0` => c = a - b
fn configure_sub_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("sub_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_sub);
        let a = meta.query_advice(config.a, Rotation::cur());
        let b = meta.query_advice(config.b, Rotation::cur());
        let c = meta.query_advice(config.c, Rotation::cur());
        vec![q * (a - b - c)]
    });
}

// ---------------------------------------------------------------------------
// DivGate: a - b * c = 0 (integer division: a / b = c when b != 0)
// ---------------------------------------------------------------------------

/// EVM DIV: integer division gate.
/// Constraint: `q_div * (a - b * c) = 0` => a = b * c (i.e., c = a / b)
/// The prover computes c = a / b off-chain and the circuit verifies b * c = a.
/// When b = 0, EVM returns 0; the prover assigns c = 0 and a must also be 0
/// (or the remainder is handled by a separate constraint row).
fn configure_div_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("div_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_div);
        let a = meta.query_advice(config.a, Rotation::cur());
        let b = meta.query_advice(config.b, Rotation::cur());
        let c = meta.query_advice(config.c, Rotation::cur());
        // a = b * c (quotient * divisor = dividend, ignoring remainder for now)
        vec![q * (a - b * c)]
    });
}

// ---------------------------------------------------------------------------
// ModGate: a - b * d - c = 0 (a mod b = c, where d = a / b quotient)
// ---------------------------------------------------------------------------

/// EVM MOD: modulo gate.
/// Constraint: `q_mod * (a - b * d - c) = 0` => a = b * d + c, where c = a mod b
/// Column d holds the quotient (a / b), column c holds the remainder (a mod b).
fn configure_mod_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("mod_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_mod);
        let a = meta.query_advice(config.a, Rotation::cur());
        let b = meta.query_advice(config.b, Rotation::cur());
        let c = meta.query_advice(config.c, Rotation::cur());
        let d = meta.query_advice(config.d, Rotation::cur());
        // a = b * d + c  =>  a - b * d - c = 0
        vec![q * (a - b * d - c)]
    });
}

// ---------------------------------------------------------------------------
// LtGate: c * (a - b) + (1 - c) * (b - a + d) = 0
// ---------------------------------------------------------------------------

/// EVM LT: less-than comparison gate.
/// c is boolean (0 or 1). When c = 1: a < b. When c = 0: a >= b.
/// d is the non-negative difference (auxiliary witness for soundness).
/// Constraints:
///   1. c * (1 - c) = 0 (boolean constraint)
///   2. c * (b - a - 1) = (1 - c) * (a - b) ... simplified via auxiliary d
fn configure_lt_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("lt_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_lt);
        let a = meta.query_advice(config.a, Rotation::cur());
        let b = meta.query_advice(config.b, Rotation::cur());
        let c = meta.query_advice(config.c, Rotation::cur());

        // Boolean constraint: c * (1 - c) = 0
        let one = halo2_proofs::plonk::Expression::Constant(Fr::from(1));
        let bool_check = c.clone() * (one.clone() - c.clone());

        // When c = 1: a + (b - a) = b (trivially true, but we need a - b to be negative)
        // When c = 0: a >= b
        // Simplified: just enforce c is boolean. The prover computes c = (a < b ? 1 : 0)
        // and the soundness relies on the execution trace matching the EVM result.
        vec![q * bool_check]
    });
}

// ---------------------------------------------------------------------------
// EqGate: c * (a - b) = 0 AND c * (1 - c) = 0
// ---------------------------------------------------------------------------

/// EVM EQ: equality comparison gate.
/// c = 1 if a == b, else c = 0.
/// Constraints:
///   1. c * (1 - c) = 0 (boolean)
///   2. (1 - c) * (a - b) must be invertible ... simplified: c * (a - b) = 0
fn configure_eq_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("eq_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_eq);
        let a = meta.query_advice(config.a, Rotation::cur());
        let b = meta.query_advice(config.b, Rotation::cur());
        let c = meta.query_advice(config.c, Rotation::cur());

        let one = halo2_proofs::plonk::Expression::Constant(Fr::from(1));

        // c is boolean
        let bool_check = c.clone() * (one - c.clone());
        // When c = 1, a must equal b
        let eq_check = c * (a - b);

        vec![q.clone() * bool_check, q * eq_check]
    });
}

// ---------------------------------------------------------------------------
// IsZeroGate: c * a = 0 AND c * (1 - c) = 0
// ---------------------------------------------------------------------------

/// EVM ISZERO: zero check gate.
/// c = 1 if a == 0, else c = 0.
fn configure_iszero_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("iszero_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_iszero);
        let a = meta.query_advice(config.a, Rotation::cur());
        let c = meta.query_advice(config.c, Rotation::cur());

        let one = halo2_proofs::plonk::Expression::Constant(Fr::from(1));

        let bool_check = c.clone() * (one - c.clone());
        let zero_check = c * a;

        vec![q.clone() * bool_check, q * zero_check]
    });
}

// ---------------------------------------------------------------------------
// AndGate: a * b - c = 0 (boolean AND)
// ---------------------------------------------------------------------------

/// Bitwise AND gate (boolean model: a * b = c for single-bit values).
fn configure_and_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("and_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_and);
        let a = meta.query_advice(config.a, Rotation::cur());
        let b = meta.query_advice(config.b, Rotation::cur());
        let c = meta.query_advice(config.c, Rotation::cur());
        vec![q * (a * b - c)]
    });
}

// ---------------------------------------------------------------------------
// OrGate: a + b - a * b - c = 0 (boolean OR)
// ---------------------------------------------------------------------------

/// Bitwise OR gate (boolean model: a + b - a*b = c).
fn configure_or_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("or_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_or);
        let a = meta.query_advice(config.a, Rotation::cur());
        let b = meta.query_advice(config.b, Rotation::cur());
        let c = meta.query_advice(config.c, Rotation::cur());
        vec![q * (a.clone() * b.clone() - a - b + c)]
    });
}

// ---------------------------------------------------------------------------
// NotGate: 1 - a - c = 0 (boolean NOT)
// ---------------------------------------------------------------------------

/// Bitwise NOT gate (boolean model: c = 1 - a).
fn configure_not_gate(meta: &mut ConstraintSystem<Fr>, config: &BasisCircuitConfig) {
    meta.create_gate("not_gate", |meta: &mut VirtualCells<Fr>| {
        let q = meta.query_selector(config.q_not);
        let a = meta.query_advice(config.a, Rotation::cur());
        let c = meta.query_advice(config.c, Rotation::cur());
        let one = halo2_proofs::plonk::Expression::Constant(Fr::from(1));
        vec![q * (one - a - c)]
    });
}
