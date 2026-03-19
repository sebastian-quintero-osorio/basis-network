# Session Log: EVM Executor Verification

**Date**: 2026-03-19
**Target**: zkl2
**Unit**: 2026-03-evm-executor
**Proof Status**: COMPLETE -- All 10 theorems proved, zero Admitted
**Prover**: Rocq 9.0.1

## What Was Accomplished

Constructed and verified Coq proofs certifying that the Go EVM Executor
implementation (executor.go, tracer.go) is isomorphic to its TLA+
specification (EvmExecutor.tla).

### Artifacts Produced

| Artifact | Path |
|----------|------|
| Common.v | `zkl2/proofs/units/2026-03-evm-executor/1-proofs/Common.v` |
| Spec.v | `zkl2/proofs/units/2026-03-evm-executor/1-proofs/Spec.v` |
| Impl.v | `zkl2/proofs/units/2026-03-evm-executor/1-proofs/Impl.v` |
| Refinement.v | `zkl2/proofs/units/2026-03-evm-executor/1-proofs/Refinement.v` |
| Verification Log | `zkl2/proofs/units/2026-03-evm-executor/2-reports/verification.log` |
| Summary | `zkl2/proofs/units/2026-03-evm-executor/2-reports/SUMMARY.md` |
| Frozen TLA+ | `zkl2/proofs/units/2026-03-evm-executor/0-input-spec/EvmExecutor.tla` |
| Frozen Go | `zkl2/proofs/units/2026-03-evm-executor/0-input-impl/*.go` |

### Theorems Proved

1. `determinism_step` -- Single-step execution is deterministic
2. `determinism_program` -- Full program execution is deterministic
3. `trace_type_correctness` -- Trace entry type matches opcode type
4. `non_modifying_no_trace` -- PUSH/ADD produce no trace entries
5. `trace_completeness_gen` -- Generalized trace completeness (inductive)
6. `trace_completeness` -- Main TraceCompleteness theorem
7. `refinement_step` -- Impl single step = Spec single step
8. `refinement_program` -- Impl full program = Spec full program
9. `impl_determinism` -- Implementation is deterministic
10. `impl_trace_completeness` -- Implementation satisfies TraceCompleteness

## Decisions Made

1. **Abstracted account balances**: Focused on opcode-to-trace correspondence
   since Determinism and TraceCompleteness do not depend on balance arithmetic.

2. **Used nat for values**: Avoided modular arithmetic complexity since it
   does not affect the target properties.

3. **CALL modeled as always-succeeding**: Safe for TraceCompleteness because
   the TLA+ spec generates the trace entry regardless of call outcome.

4. **Rocq 9.0 imports**: Used `From Stdlib Require Import` to avoid
   deprecation warnings (Rocq 9.0 renamed standard library from Coq to Stdlib).

5. **Explicit destruct naming**: Used `destruct op as [v | | sl | sl | tgt]`
   to control variable names across Coq versions.

6. **Avoided lia for base case**: Used manual rewriting (`Nat.add_0_r` +
   `reflexivity`) instead of `lia` for the base case of trace_completeness_gen,
   due to `lia` failing on terms involving `count_pred` in Rocq 9.0.

## Compilation Commands

```bash
cd zkl2/proofs/units/2026-03-evm-executor/1-proofs/
coqc -R . EvmExecutor Common.v
coqc -R . EvmExecutor Spec.v
coqc -R . EvmExecutor Impl.v
coqc -R . EvmExecutor Refinement.v
```

## Next Steps

- The verification unit is complete. No further action required.
- If the TLA+ spec or Go implementation changes, a new verification unit
  must be created (the current unit's inputs are frozen).
