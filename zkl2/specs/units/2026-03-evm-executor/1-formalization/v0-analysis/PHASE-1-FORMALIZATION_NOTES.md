# Phase 1: Formalization Notes -- EVM Executor

**Unit**: evm-executor
**Target**: zkl2
**Date**: 2026-03-19
**Result**: PASS (all invariants hold)

---

## 1. Research-to-Specification Mapping

| Source Material | Specification Element | Notes |
|---|---|---|
| hypothesis.json: "minimal fork of go-ethereum" | Module EvmExecutor: deterministic state machine | Models EVM as sequential opcode execution |
| REPORT.md: "Geth Module Analysis" (core/vm, core/state) | accountState variable: [Accounts -> [balance, nonce, storage]] | Abstracts StateDB to pure function |
| code/main.go: ZKTrace struct (lines 33-48) | TraceEntrySet: SLOAD, SSTORE, CALL entries | Each trace entry maps to a Geth tracer hook |
| code/main.go: OnStorageChange hook (lines 122-127) | ExecSstore action + SSTORE trace entry | Records old/new values for SMT proof |
| code/main.go: OnBalanceChange hook (lines 129-135) | ExecCall action + CALL trace entry | Records from/to/value for balance proof |
| code/opcode_analysis.go: ZK difficulty tiers | 5 opcodes modeled: PUSH, ADD, SLOAD, SSTORE, CALL | One opcode per difficulty tier (Trivial through VeryExpensive) |
| REPORT.md: Observation 4 "trace format is critical" | TraceCompleteness invariant | Bijection between state-modifying opcodes and trace entries |
| hypothesis.json: "100% Cancun opcode compatibility" | Determinism invariant | Same tx + same state = same result + same trace |
| code/main.go: CanTransfer/Transfer (lines 249-254) | SubmitTx value transfer guards | Overflow prevention, balance sufficiency |

## 2. Assumptions

1. **Sequential execution**: Transactions execute one at a time (no concurrent execution within the EVM). This matches Geth's single-threaded EVM execution model.

2. **Modular arithmetic**: ADD wraps modulo (MaxValue+1), modeling uint256 wrapping behavior. In the bounded model, MaxValue=3, so ADD(2,2)=0.

3. **CALL simplification**: CALL is modeled as a value transfer without recursive code execution at the target (equivalent to calling an EOA). Production zkEVM requires recursive proving or stack-based proving for cross-contract calls.

4. **No gas metering**: Gas is not modeled. The Basis Network L2 uses zero-fee transactions (gas price = 0), and gas accounting does not affect state correctness for ZK proving purposes.

5. **No revert/exception handling**: Programs that cause stack underflow are simply not explored by TLC (the opcode action's precondition is not met). A production specification would model explicit revert semantics.

6. **Bounded values**: All integer values are bounded to 0..MaxValue (0..3 in the model instance). Initial balance is 1 per account. This keeps the state space tractable while preserving meaningful interactions.

7. **Storage addressed by symbolic slots**: Storage slots are model values (S1, S2), not computed addresses. The real EVM computes storage addresses via KECCAK256 hashing.

## 3. Verification Results

### Model Configuration

| Parameter | Value |
|---|---|
| Accounts | {A1, A2, A3} |
| Storage Slots | {S1, S2} |
| MaxValue | 3 |
| MaxTransactions | 2 |
| Programs | 3 (arithmetic, storage, call) |
| Workers | 4 |

### TLC Output

| Metric | Value |
|---|---|
| States generated | 6,217 |
| Distinct states | 6,217 |
| State graph depth | 11 |
| Max outdegree | 31 |
| Execution time | 1 second |
| Collision probability | 0.0 |
| Result | **No error found** |

### Invariants Verified

| # | Invariant | Type | Result |
|---|---|---|---|
| 1 | TypeOK | Type safety | PASS |
| 2 | Determinism | Safety (Property 1) | PASS |
| 3 | TraceCompleteness | Safety (Property 2) | PASS |
| 4 | SloadAfterSstoreConsistency | Safety (Property 3a) | PASS |
| 5 | SloadFromInitialState | Safety (Property 3b) | PASS |
| 6 | NoNegativeBalance | Safety (Property 4) | PASS |
| 7 | BalanceConservation | Safety (Property 5) | PASS |

### Reproduction

```bash
cd zkl2/specs/units/2026-03-evm-executor/1-formalization/v0-analysis/experiments/EvmExecutor/_build
java -cp lab/2-logicist/tools/tla2tools.jar tlc2.TLC MC_EvmExecutor -workers 4 -deadlock
```

## 4. Programs Tested

| # | Program | Opcodes Exercised | Trace Entries |
|---|---|---|---|
| 1 | PUSH(1), PUSH(2), ADD | PUSH, ADD | 0 (no state modification) |
| 2 | PUSH(1), SSTORE(S1), SLOAD(S1) | PUSH, SSTORE, SLOAD | 2 (1 SSTORE + 1 SLOAD) |
| 3 | PUSH(1), CALL(A3) | PUSH, CALL | 1 (1 CALL) |

## 5. Design Decisions

### 5.1 NullTx Pattern

TLC cannot compare strings with records for fingerprinting. The initial design used `"none"` as a sentinel for `currentTx` when idle. This was replaced with a `NullTx` record (a valid transaction record with an empty program) and the `phase` variable as the authoritative state indicator. This is a modeling technique, not a protocol decision.

### 5.2 Trace Entries for Failed Calls

CALL generates a trace entry regardless of success or failure. The ZK prover needs to verify that every CALL was attempted correctly, including those that fail due to insufficient balance. This ensures the witness is complete even for error paths.

### 5.3 Value Transfer at Submission

The msg.value transfer from sender to receiver happens in SubmitTx (before opcode execution), matching Geth's behavior where value is transferred before EVM code runs.

## 6. Open Issues

1. **Recursive CALL execution**: The current model does not execute code at the CALL target. A production specification should model call frames, delegate calls, and re-entrancy.

2. **CREATE opcode**: Not modeled. Contract creation involves address derivation (KECCAK256), code deployment, and init code execution. This is the most complex opcode for ZK proving.

3. **Revert semantics**: Stack underflow and failed assertions should produce explicit REVERT states with state rollback. The current model simply does not enable the action.

4. **Gas accounting**: While Basis Network uses zero-fee transactions, gas limits still bound execution. A complete specification would model gas consumption per opcode.

5. **KECCAK256**: The most expensive opcode for ZK proving (~150K R1CS constraints). Not modeled because it does not affect state-machine correctness, but its constraint cost is critical for batch sizing.

6. **Transient storage**: TLOAD/TSTORE (EIP-1153, Cancun) provide transaction-scoped storage. Not modeled but relevant for gas optimization.
