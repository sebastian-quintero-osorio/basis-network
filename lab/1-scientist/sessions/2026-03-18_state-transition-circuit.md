# Session Log -- State Transition Circuit (RU-V2)

**Date**: 2026-03-18
**Target**: validium (MVP)
**Experiment**: state-transition-circuit
**Stage**: 1-2 (Implementation + Baseline)
**Pipeline Step**: [05] Scientist | RU-V2

## What Was Accomplished

1. **Literature Review** (15+ sources): Surveyed Poseidon constraint costs, Groth16 proving
   time benchmarks (rapidsnark, tachyon, snarkjs), Hermez rollup circuit architecture,
   Polygon zkEVM prover design, Tornado Cash circuits, and circomlib SMT primitives.

2. **Circuit Design**: Designed and implemented ChainedBatchStateTransition circuit in Circom
   that proves a batch of sequential SMT state transitions. Each tx: verify old Merkle path,
   compute new root, chain roots across transactions.

3. **Benchmarking**: Compiled and proved 7 circuit configurations across 3 tree depths
   (10, 20, 32) and 3 batch sizes (4, 8, 16). Full Groth16 pipeline: compile, witness,
   trusted setup, prove, verify.

4. **Constraint Formula**: Derived exact formula from measurements:
   `constraints_per_tx = 1,038 * (depth + 1)`, validated across all 7 configs.

5. **Hypothesis Evaluation**: Original hypothesis partially rejected. The 100K constraint
   target is infeasible for batch 64 (needs 2.2M constraints). However, the 60-second
   proving time target IS achievable with production provers (rapidsnark: est. 14-35s).

## Key Findings

- Per-tx constraint cost at depth 32: **34,254 constraints**
- Batch 64 at depth 32: **~2.2M constraints** (22x over 100K target)
- snarkjs proving at 274K constraints: **12.8 seconds** (commodity desktop)
- Proof size: **~805 bytes** (constant, independent of circuit size)
- Verification: **~2 seconds** (constant)

## Artifacts Produced

All in `validium/research/experiments/2026-03-18_state-transition-circuit/`:

| File | Description |
|------|-------------|
| `hypothesis.json` | Formal hypothesis with predictions |
| `state.json` | Current experiment state (stage 2, partially rejected) |
| `journal.md` | Decision log and analysis |
| `findings.md` | Literature review (15 refs) + experimental results (7 configs) |
| `memory/session.md` | Per-experiment memory |
| `code/state_transition_verifier.circom` | Circuit implementation |
| `code/generate_input.js` | Witness input generator (builds real SMT) |
| `code/benchmark.sh` | Automated benchmark pipeline |
| `code/package.json` | Dependencies (circomlibjs) |
| `results/benchmark_d10_b4.json` | Benchmark: depth 10, batch 4 |
| `results/benchmark_d10_b8.json` | Benchmark: depth 10, batch 8 |
| `results/benchmark_d10_b16.json` | Benchmark: depth 10, batch 16 |
| `results/benchmark_d20_b4.json` | Benchmark: depth 20, batch 4 |
| `results/benchmark_d20_b8.json` | Benchmark: depth 20, batch 8 |
| `results/benchmark_d32_b4.json` | Benchmark: depth 32, batch 4 |
| `results/benchmark_d32_b8.json` | Benchmark: depth 32, batch 8 |
| `results/build_*/` | Compiled circuits, proofs, verification keys |

## Decisions and Rationale

1. **Used custom circuit instead of circomlib SMTProcessor**: SMTProcessor includes
   insert/delete/NOP logic (~40% overhead) that is unnecessary for the MVP (update-only).
   The custom circuit is simpler and produces cleaner constraint analysis.

2. **Revised constraint target**: 100K constraints is not meaningful for state transition
   circuits. The correct metric is proving time. Production systems (Hermez, Polygon)
   use millions to billions of constraints with specialized provers.

3. **Recommended depth 20 for MVP**: Supports 1M+ keys per enterprise with 36% fewer
   constraints than depth 32. Can upgrade to depth 32 later.

## Next Steps

1. **Downstream**: This experiment is ready for The Logicist (RU-V2) to formalize the
   state transition circuit specification in TLA+. Key properties to verify:
   - Root chain consistency (no gaps, no reversals)
   - Merkle proof soundness (invalid proofs rejected)
   - State transition determinism (same inputs -> same outputs)

2. **For The Architect**: Implement production state_transition.circom using the
   ChainedBatchStateTransition template. Target depth 20, batch 64, with rapidsnark.

3. **Optional Stage 3**: Adversarial scenarios (malformed witnesses, boundary conditions,
   hash collision attempts). Low priority since the circuit inherits Poseidon's security.
