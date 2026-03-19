# Session Log: BasisRollup Implementation

**Date**: 2026-03-19
**Target**: zkl2 (zkEVM L2)
**Unit**: basis-rollup (RU-L5)
**Agent**: Prime Architect

---

## What Was Implemented

Production-grade implementation of BasisRollup.sol -- the L1 settlement contract for the Basis Network zkEVM L2. Translates the TLA+-verified three-phase commit-prove-execute lifecycle into Solidity 0.8.24 (evmVersion: cancun).

## Safety Latch

**PASS** -- TLC model checking log confirms:
- "Model checking completed. No error has been found."
- 2,187,547 states generated, 383,161 distinct states, depth 21
- All 12 invariants verified (2 enterprises, 3 batches, 3 roots)

Source: `zkl2/specs/units/2026-03-basis-rollup/1-formalization/v0-analysis/experiments/BasisRollup/MC_BasisRollup.log`

## Files Created

### Hardhat Project Structure
- `zkl2/contracts/package.json` -- Project manifest
- `zkl2/contracts/hardhat.config.ts` -- Solidity 0.8.24, evmVersion: cancun
- `zkl2/contracts/tsconfig.json` -- TypeScript configuration
- `zkl2/contracts/.gitignore` -- Ignore artifacts, cache, node_modules

### Production Contracts
- `zkl2/contracts/contracts/BasisRollup.sol` -- Main rollup contract (commit-prove-execute lifecycle, per-enterprise state chains, batch revert, inline Groth16 verification)
- `zkl2/contracts/contracts/IEnterpriseRegistry.sol` -- Enterprise authorization interface

### Test Infrastructure
- `zkl2/contracts/contracts/test/MockEnterpriseRegistry.sol` -- Mock registry for testing
- `zkl2/contracts/contracts/test/BasisRollupHarness.sol` -- Harness with mock Groth16 verification
- `zkl2/contracts/test/BasisRollup.test.ts` -- 88 tests (65 functional + 23 adversarial)

### Reports
- `zkl2/tests/adversarial/basis-rollup/ADVERSARIAL-REPORT.md` -- Adversarial test report

## Quality Gate Results

- Compilation: 4 Solidity files compiled successfully (cancun target)
- Tests: 88 passing, 0 failing
- All 12 TLA+ invariants mapped to test coverage
- 23 adversarial test vectors across 5 attack categories
- Adversarial verdict: NO VIOLATIONS FOUND

## Decisions and Rationale

1. **Scientist prototype adopted as-is**: The prototype BasisRollup.sol produced by the Scientist (RU-L5) was already high-quality and faithfully mapped to the TLA+ specification. Production version adds spec traceability tags and is placed in the canonical target directory.

2. **BasisRollupHarness for testing**: Overrides `_verifyProof()` with a configurable mock. This allows testing all business logic without BN256 precompile complexity. The inline Groth16 verification is battle-tested from the validium StateCommitment.sol.

3. **No ADR created**: The technology choice (Solidity 0.8.24, Hardhat) was predetermined by the project architecture and does not represent a new decision.

4. **Block range validation kept**: Though abstracted in TLA+ (INV-R4), the Solidity implementation retains contiguous block range enforcement as a data-level integrity constraint.

## TLA+ to Solidity Mapping

| TLA+ Variable | Solidity Field |
|--------------|---------------|
| currentRoot | EnterpriseState.currentRoot |
| initialized | EnterpriseState.initialized |
| totalBatchesCommitted | EnterpriseState.totalBatchesCommitted |
| totalBatchesProven | EnterpriseState.totalBatchesProven |
| totalBatchesExecuted | EnterpriseState.totalBatchesExecuted |
| batchStatus | StoredBatchInfo.status |
| batchRoot | StoredBatchInfo.stateRoot |
| globalCommitted | totalBatchesCommitted (contract-level) |
| globalProven | totalBatchesProven (contract-level) |
| globalExecuted | totalBatchesExecuted (contract-level) |

## Informational Findings

1. **INFO-01**: Admin is a single EOA. Production deployment should use multisig.
2. **INFO-02**: No forced inclusion deadline. Future research unit needed for liveness properties.

## Next Steps

- Downstream: Prover agent (lab/4-prover/) can now create Coq proofs of isomorphism between BasisRollup.tla and BasisRollup.sol
- Future: BasisBridge.sol and BasisDAC.sol contracts (separate research units)
- Hardening: Admin transfer functionality, multisig recommendation
