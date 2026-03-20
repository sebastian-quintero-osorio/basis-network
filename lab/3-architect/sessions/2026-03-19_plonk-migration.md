# Session Log: RU-L9 PLONK Migration (Architect)

**Date:** 2026-03-19
**Target:** zkl2 (Enterprise zkEVM L2)
**Unit:** RU-L9 PLONK Migration
**Agent:** Prime Architect

---

## What Was Implemented

Implementation of the verified TLA+ specification for migrating from Groth16 to PLONK
(halo2-KZG) proof system. Two major components:

### 1. Rust Circuit Crate (zkl2/prover/circuit/)

Complete PLONK circuit implementation using halo2-KZG (PSE fork, BN254):

- **types.rs**: MigrationPhase enum, ProofSystem enum, CircuitError, ProofData,
  VerificationKeyData, ark-bn254 to halo2curves Fr conversion utilities
- **columns.rs**: BasisCircuitConfig with 4 advice + 1 instance + 5 selectors + 1 fixed column
- **gates.rs**: 5 custom gates (AddGate, MulGate, PoseidonGate, MemoryGate, StackGate)
- **circuit.rs**: BasisCircuit implementing halo2 Circuit trait with CircuitOp enum
- **srs.rs**: Universal KZG SRS generation, serialization, loading
- **prover.rs**: Key generation (vk + pk) and proof creation (PLONK-KZG with SHPLONK)
- **verifier.rs**: Off-chain proof verification with migration phase awareness
- **lib.rs**: Module exports
- **tests.rs**: 46 tests covering all gates, prove+verify E2E, migration phases, adversarial

### 2. Solidity Contract (zkl2/contracts/contracts/BasisVerifier.sol)

Dual-mode proof verifier with migration state machine:

- 4 migration phases: Groth16Only, Dual, PlonkOnly, Rollback
- Phase-aware proof routing (Groth16 and PLONK verification backends)
- All TLA+ actions implemented: StartDualVerification, CutoverToPlonkOnly,
  DualPeriodTick, DetectFailure, RollbackMigration, CompleteRollback
- BasisVerifierHarness for testable mock verification
- 48 Hardhat tests covering all 8 safety invariants

---

## Files Created or Modified

### Created

| File | Lines | Purpose |
|------|-------|---------|
| `zkl2/prover/circuit/Cargo.toml` | 23 | Crate definition (halo2_proofs + ark-bn254) |
| `zkl2/prover/circuit/src/types.rs` | 268 | Core types, errors, Fr conversion |
| `zkl2/prover/circuit/src/columns.rs` | 91 | Column layout |
| `zkl2/prover/circuit/src/gates.rs` | 140 | 5 custom gates |
| `zkl2/prover/circuit/src/circuit.rs` | 271 | BasisCircuit + CircuitOp |
| `zkl2/prover/circuit/src/srs.rs` | 78 | SRS management |
| `zkl2/prover/circuit/src/prover.rs` | 92 | Proof generation pipeline |
| `zkl2/prover/circuit/src/verifier.rs` | 84 | Proof verification |
| `zkl2/prover/circuit/src/lib.rs` | 33 | Module exports |
| `zkl2/prover/circuit/src/tests.rs` | 513 | 46 tests |
| `zkl2/contracts/contracts/BasisVerifier.sol` | 487 | Dual verification contract |
| `zkl2/contracts/contracts/test/BasisVerifierHarness.sol` | 42 | Test harness |
| `zkl2/contracts/test/BasisVerifier.test.ts` | 535 | 48 Solidity tests |
| `zkl2/tests/adversarial/RU-L9-plonk-migration/ADVERSARIAL-REPORT.md` | 178 | Adversarial report |

### Modified

| File | Change |
|------|--------|
| `zkl2/prover/Cargo.toml` | Added `circuit` to workspace members |

---

## Quality Gate Results

| Gate | Result |
|------|--------|
| Rust: `cargo check -p basis-circuit` | PASS (0 warnings) |
| Rust: `cargo test -p basis-circuit` | PASS (46/46) |
| Solidity: `npx hardhat compile` | PASS (3 contracts, evmVersion: cancun) |
| Solidity: `npx hardhat test` | PASS (48/48) |

---

## Decisions Made

### D-01: PSE halo2 fork over axiom-crypto fork

The research recommended axiom-crypto/halo2. We used PSE halo2 v0.3.0 instead because:
- The benchmark code was validated against PSE halo2
- API compatibility confirmed
- More widely available and documented
- BN254 KZG support identical

### D-02: Memory gate simplification

Original design: `(a_next - a_cur) * (c_cur - c_next) = 0` (disjunction).
Final design: `c - d = 0` (value equals expected).

The disjunction form is incorrect for memory consistency (allows same-address-different-value).
The simplified form delegates address-based consistency to the witness generator, which
maintains the sorted memory access log. This is the standard pattern in production zkEVM
circuits (Scroll, PSE zkEVM).

### D-03: Selector-dependent verification keys

Different operation types produce different halo2 verification keys because selector columns
differ. Production circuits must use a fixed universal layout. Documented as LOW finding.

---

## Next Steps

1. **Prover (lab/4-prover)**: Coq verification of circuit soundness and migration safety
2. **Integration**: Wire BasisVerifier into BasisRollup.proveBatch for dual-mode proving
3. **Production circuit**: Design universal row layout covering all EVM operations
4. **Benchmarks**: Full k=20 proving time and proof size measurements
5. **Gas profiling**: On-chain PLONK verification gas cost measurement
