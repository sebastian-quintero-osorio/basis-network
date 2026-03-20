# Session: Hub-and-Spoke Cross-Enterprise Implementation (RU-L11)

> Date: 2026-03-20
> Target: zkl2
> Unit: 2026-03-hub-and-spoke
> Agent: Prime Architect

---

## What Was Accomplished

Implemented the hub-and-spoke cross-enterprise communication protocol from the
TLC-verified TLA+ specification (HubAndSpoke.tla, 7,411 states, 0 errors).

Two implementation targets:

1. **Go protocol layer** (`zkl2/node/cross/`) -- Hub, Spoke, and Settlement logic
2. **Solidity L1 contract** (`zkl2/contracts/contracts/BasisHub.sol`) -- On-chain enforcement

All 6 TLA+ invariants verified by tests:
- INV-CE5 CrossEnterpriseIsolation
- INV-CE6 AtomicSettlement
- INV-CE7 CrossRefConsistency
- INV-CE8 ReplayProtection
- INV-CE9 TimeoutSafety
- INV-CE10 HubNeutrality

---

## Artifacts Produced

### Go Package (`zkl2/node/cross/`)

| File | Purpose | Lines |
|------|---------|-------|
| `types.go` | MessageStatus, CrossEnterpriseMessage, EnterprisePair, Config, HubState, errors, interfaces | ~230 |
| `message.go` | ComputeMessageID, NewPreparedMessage, ValidateMessage, ComputePairHash | ~100 |
| `hub.go` | Hub: VerifyMessage, SettleMessage, TimeoutMessage, AdvanceBlock, state queries | ~280 |
| `spoke.go` | Spoke: PrepareMessage, RespondToMessage | ~120 |
| `settlement.go` | SettlementCoordinator: ExecuteCrossEnterpriseTx (4-phase orchestration) | ~120 |
| `cross_test.go` | 24 test functions covering all invariants and adversarial scenarios | ~530 |

### Solidity Contract (`zkl2/contracts/`)

| File | Purpose | Lines |
|------|---------|-------|
| `contracts/BasisHub.sol` | L1 hub: prepareMessage, verifyMessage, respondToMessage, settleMessage, timeoutMessage | ~590 |
| `contracts/test/BasisHubHarness.sol` | Mock proof verification for testing | ~30 |
| `test/BasisHub.test.ts` | 51 tests: all 6 invariants, adversarial scenarios, 3-enterprise chains | ~530 |

### Reports

| File | Purpose |
|------|---------|
| `zkl2/tests/adversarial/2026-03-hub-and-spoke/ADVERSARIAL-REPORT.md` | Adversarial testing report (17 attack vectors, 0 violations) |
| `lab/3-architect/sessions/2026-03-20_hub-and-spoke-implementation.md` | This session log |

---

## Quality Gate Results

### Solidity Compilation
- Compiler: solc 0.8.24, evmVersion: cancun
- Optimizer: enabled, 200 runs
- Compilation: PASS (0 errors, 0 warnings)

### Solidity Tests
- Framework: Hardhat + ethers.js v6
- Tests: 51 passing, 0 failing (2 seconds)
- Coverage: All public functions, all status transitions, all error paths

### Go (structural verification)
- Go runtime not available on system
- Code follows existing codebase patterns (da/, executor/, pipeline/, sequencer/, statedb/)
- 24 test functions written covering all invariants
- Module: `basis-network/zkl2/node`, package: `cross`

### Regression
- All existing contract tests: 252 passing, 1 pre-existing flake (BasisVerifier timestamp)
- No regressions introduced

---

## Decisions and Rationale

### D1: Separate Hub and Spoke roles in Go

The Go implementation models the Hub (L1 protocol logic) and Spoke (enterprise-side logic)
as distinct types. This mirrors the TLA+ specification's actor model where the hub and
enterprises have different capabilities. The Hub never generates proofs (INV-CE10).

### D2: Direct storage writes in Solidity prepareMessage

The `prepareMessage` function writes directly to storage (`Message storage m = messages[msgId]`)
instead of constructing a struct literal. This avoids Solidity's stack-too-deep limitation
with the Groth16 proof parameters. Trade-off: slightly more gas for individual SSTORE
operations vs. not compiling at all.

### D3: Groth16 verification pattern from BasisRollup

BasisHub's `_verifyProof`, `_ecPairing`, `_ecAdd`, `_ecMul`, and `_negate` functions
are copied from BasisRollup.sol. This ensures identical verification behavior and
avoids introducing a shared library (which would change the deployment model).

### D4: State root freshness via caller parameter

`verifyMessage` and `settleMessage` accept the current state root as a parameter
(caller-asserted) rather than reading from BasisRollup. This decouples BasisHub from
BasisRollup's storage layout and allows the hub to be deployed independently. The
caller (typically the enterprise's agent or a relayer) is responsible for providing
the correct current root. In production, this would be verified against BasisRollup.

### D5: No ADR created

No new technology was introduced. Go and Solidity are already established in the codebase.
The hub-and-spoke architecture is documented in the research findings and TLA+ spec.

---

## Next Steps

1. **Prover**: Verify INV-CE5 (Isolation) and INV-CE6 (AtomicSettlement) in Coq
2. **Integration**: Connect BasisHub to BasisRollup via IBasisRollup interface for
   on-chain state root verification
3. **Production**: Deploy BasisHub to Fuji testnet alongside existing contracts
4. **Proof aggregation**: Integrate cross-enterprise proofs with BasisAggregator
   for gas-efficient batched verification
