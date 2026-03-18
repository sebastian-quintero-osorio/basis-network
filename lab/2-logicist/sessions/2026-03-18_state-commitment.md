# Session Log: State Commitment Protocol Formalization

**Date**: 2026-03-18
**Target**: validium
**Unit**: state-commitment (`validium/specs/units/2026-03-state-commitment/`)
**Phase**: 1 -- Formalize Research
**Result**: PASS

---

## Accomplished

Phase 1 formalization of the L1 State Commitment Protocol (RU-V3).

Translated the Scientist's experimental evidence (StateCommitmentV1.sol, gas benchmarks,
invariant test results) into a TLA+ specification covering:

- 2 actions: `InitializeEnterprise`, `SubmitBatch`
- 5 state variables: `currentRoot`, `batchCount`, `initialized`, `batchHistory`, `totalCommitted`
- 6 invariants: `TypeOK`, `ChainContinuity`, `NoGap`, `NoReversal`, `InitBeforeBatch`, `GlobalCountIntegrity`

TLC exhaustively verified the model: 3,778,441 states generated, 1,874,161 distinct states,
0 violations, 21 seconds with 4 workers.

## Artifacts Produced

| Artifact | Path |
|----------|------|
| TLA+ Specification | `validium/specs/units/2026-03-state-commitment/1-formalization/v0-analysis/specs/StateCommitment/StateCommitment.tla` |
| Model Instance | `validium/specs/units/2026-03-state-commitment/1-formalization/v0-analysis/experiments/StateCommitment/MC_StateCommitment.tla` |
| TLC Configuration | `validium/specs/units/2026-03-state-commitment/1-formalization/v0-analysis/experiments/StateCommitment/MC_StateCommitment.cfg` |
| TLC Log (Certificate) | `validium/specs/units/2026-03-state-commitment/1-formalization/v0-analysis/experiments/StateCommitment/MC_StateCommitment.log` |
| Phase 1 Report | `validium/specs/units/2026-03-state-commitment/1-formalization/v0-analysis/PHASE-1-FORMALIZATION_NOTES.md` |

## Decisions and Rationale

1. **ZK proof as oracle**: Abstracted Groth16 verification as a boolean parameter. The
   model non-deterministically generates valid and invalid proofs; the guard blocks invalid
   ones. This captures ProofBeforeState without modeling BN256 arithmetic.

2. **4 roots, 2 enterprises, 5 batches**: Chosen for exhaustive search feasibility (~1.87M
   distinct states, 21s). 4 roots allows natural root cycling, testing whether the protocol
   handles hash "collisions" in the abstract domain.

3. **No-op transitions allowed**: The contract does not check `newRoot != prevRoot`. The
   TLA+ model faithfully reflects this. Identified as an open issue for Phase 2.

4. **Events not modeled**: BatchCommitted and EnterpriseInitialized events do not affect
   state. Excluded from the formal model.

5. **VK lifecycle not modeled**: The verifying key setup is a deployment concern, not a
   protocol-level concern. Excluded to keep the model focused on runtime safety.

## Next Steps

- Phase 2 (`/2-audit`): Verify formalization integrity. Side-by-side comparison of
  0-input/ materials against the TLA+ specification. Check for hallucinations and omissions.
