# Session Log: EVM Executor Formalization

**Date**: 2026-03-19
**Target**: zkl2
**Unit**: evm-executor
**Phase**: Phase 1 (Formalize Research)
**Result**: PASS

---

## What Was Accomplished

Formalized the EVM Execution Engine research (RU-L1) into a verified TLA+ specification. The specification models the EVM as a deterministic state machine executing 5 representative opcodes (PUSH, ADD, SLOAD, SSTORE, CALL) and generating execution traces for ZK witness generation.

TLC model checker verified all 7 invariants across 6,217 states with zero violations.

## Artifacts Produced

| Artifact | Path |
|---|---|
| TLA+ Specification | `zkl2/specs/units/2026-03-evm-executor/1-formalization/v0-analysis/specs/EvmExecutor/EvmExecutor.tla` |
| Model Instance | `zkl2/specs/units/2026-03-evm-executor/1-formalization/v0-analysis/experiments/EvmExecutor/MC_EvmExecutor.tla` |
| TLC Configuration | `zkl2/specs/units/2026-03-evm-executor/1-formalization/v0-analysis/experiments/EvmExecutor/MC_EvmExecutor.cfg` |
| Certificate of Truth | `zkl2/specs/units/2026-03-evm-executor/1-formalization/v0-analysis/experiments/EvmExecutor/MC_EvmExecutor.log` |
| Phase 1 Report | `zkl2/specs/units/2026-03-evm-executor/1-formalization/v0-analysis/PHASE-1-FORMALIZATION_NOTES.md` |

## Decisions Made

1. **NullTx pattern over string sentinel**: TLC cannot compare strings with records for fingerprinting. Replaced `"none"` with a typed NullTx record; the `phase` variable discriminates idle from executing states.

2. **CALL modeled as value transfer only**: No recursive code execution at CALL targets. This simplification is appropriate for verifying trace completeness and determinism without modeling the full call stack.

3. **Modular arithmetic for ADD**: `(a + b) % (MaxValue + 1)` models uint256 wrapping behavior within the bounded domain.

4. **Trace entries for failed CALLs**: The prover needs to verify every attempted CALL, including failures. Failed CALLs generate trace entries but do not modify account state.

5. **Initial balance of 1 per account**: Keeps total value at |Accounts| = 3, preventing overflow while allowing meaningful transfers.

## Invariants Verified

- **Determinism**: Same transaction on same pre-state produces identical post-state and trace.
- **TraceCompleteness**: Bijection between state-modifying opcodes in program and trace entries.
- **SloadAfterSstoreConsistency**: SLOAD after SSTORE on same slot returns the written value.
- **SloadFromInitialState**: SLOAD without prior SSTORE returns the pre-transaction value.
- **NoNegativeBalance**: Account balances never go negative.
- **BalanceConservation**: Total balance across all accounts is invariant.
- **TypeOK**: All variables remain within declared domains.

## Next Steps

- Phase 2: `/2-audit` -- Verify formalization integrity against 0-input/ materials.
- Future: Model CREATE opcode, recursive CALL execution, revert semantics, gas metering.
