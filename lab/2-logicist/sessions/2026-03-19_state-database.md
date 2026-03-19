# Session Log: State Database (RU-L4)

**Date**: 2026-03-19
**Target**: zkl2
**Unit**: `zkl2/specs/units/2026-03-state-database/`
**Phase Completed**: Phase 1 (Formalization)
**Result**: PASS

---

## Accomplished

Formalized the State Database research unit (RU-L4) as a TLA+ specification extending the Sparse Merkle Tree formalization from RU-V1 (validium). The specification models the EVM account model with a two-level Sparse Merkle Tree:

- **Level 1**: Account Trie (address -> Hash(balance, storageRoot))
- **Level 2**: Storage Tries (slot -> value, one per contract)

All core tree operators from RU-V1 were reused with depth parameterization to support the two-level architecture. Four state-changing actions were formalized: CreateAccount, Transfer (UpdateBalance), SetStorage (including deletion), and SelfDestruct. GetStorage was modeled as the StorageIsolation invariant (proof completeness for all storage slots).

TLC model checking passed with 0 violations across 883 distinct states (15,231 generated), verifying all 5 invariants:

1. **TypeOK** -- type safety
2. **ConsistencyInvariant** -- incremental WalkUp matches full ComputeRoot at both trie levels
3. **AccountIsolation** -- every account leaf position has a valid Merkle proof
4. **StorageIsolation** -- every storage slot position has a valid Merkle proof per contract
5. **BalanceConservation** -- total balance preserved across all transitions

## Artifacts Produced

| Artifact | Path |
|---|---|
| TLA+ Specification | `zkl2/specs/units/2026-03-state-database/1-formalization/v0-analysis/specs/StateDatabase/StateDatabase.tla` |
| Model Instance | `zkl2/specs/units/2026-03-state-database/1-formalization/v0-analysis/experiments/StateDatabase/MC_StateDatabase.tla` |
| TLC Configuration | `zkl2/specs/units/2026-03-state-database/1-formalization/v0-analysis/experiments/StateDatabase/MC_StateDatabase.cfg` |
| Certificate of Truth | `zkl2/specs/units/2026-03-state-database/1-formalization/v0-analysis/experiments/StateDatabase/MC_StateDatabase.log` |
| Phase 1 Report | `zkl2/specs/units/2026-03-state-database/1-formalization/v0-analysis/PHASE-1-FORMALIZATION_NOTES.md` |

## Key Decisions

1. **Depth parameterization over TLA+ INSTANCE**: Instead of using TLA+ module instantiation (INSTANCE), all tree operators were rewritten with an explicit `depth` parameter. This avoids cross-directory module dependencies and keeps the spec self-contained while reusing the mathematical foundations from RU-V1.

2. **Two-step WalkUp for multi-leaf updates**: Transfer and SelfDestruct modify two account leaves atomically. The implementation applies updates sequentially: first WalkUp with current entries, then second WalkUp with intermediate entries. This faithfully models the real implementation's sequential batch update behavior.

3. **Nonce and codeHash omitted**: The EVM account hash includes nonce and codeHash, but these are orthogonal to the four target invariants (consistency, isolation, conservation). Omitting them reduces state space without loss of verification coverage.

4. **Single EOA genesis**: One externally-owned account holds the entire initial supply (MaxBalance). This ensures MaxBalance serves as both total supply and individual balance ceiling, avoiding TypeOK overflow.

## Next Steps

- Phase 2: `/2-audit` -- Verify the formalization faithfully represents the Scientist's research.
