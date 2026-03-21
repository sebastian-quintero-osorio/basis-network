# Session Memory: PLONK Migration

## Context Loaded

- This is RU-L9, checklist item [33], Phase 4: Production Hardening
- All Phase 1-3 items complete (32/44)
- Current Groth16 baseline: 274K constraints, 12.9s proving, 306K gas, ~805 bytes proof
- Witness generator is Rust (ark-bn254 field), node is Go
- BasisRollup.sol uses commit-prove-execute with Groth16 verification (~256K gas prove step)
- TD-003 already targets PLONK; this experiment validates and selects library

## Key Constraints

- Must use BN254 scalar field for EVM precompile compatibility (ecAdd/ecMul/ecPairing at 0x06-0x08)
- L1 verification gas < 500K (current total batch: 425K with Groth16)
- Prover is a separate Rust process communicating with Go node via gRPC
- Proof system must be trait-based in Rust (TD-003 consequence)
- Cancun EVM only (no Pectra)

## Decisions Made

- Comparing 4 systems: Groth16 (arkworks), halo2-KZG (PSE), halo2-IPA (Zcash), plonky2 (Polygon)
- Benchmark on equivalent circuits: simple arithmetic, Poseidon hash, state transition
- Custom gate analysis: ADD, MUL, memory load/store, conditional select

## Key Insight from Prior Research

- Groth16 proof size is constant ~805 bytes regardless of circuit
- snarkjs proving: ~65 us/constraint on commodity hardware
- rapidsnark (C++): ~14s for 2.2M constraints (from RU-V2)
- Enterprise circuits: ~500 constraints/tx (from E2E pipeline findings)
- ZK verification is 72% of total L1 submission cost
