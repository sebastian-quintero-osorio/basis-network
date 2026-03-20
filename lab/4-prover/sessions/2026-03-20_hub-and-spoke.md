# Session Log: Hub-and-Spoke Verification

**Date**: 2026-03-20
**Target**: zkl2
**Unit**: `zkl2/proofs/units/2026-03-hub-and-spoke/`
**Status**: COMPLETE -- All proofs verified

---

## Summary

Constructed and verified Coq proofs certifying that the Hub-and-Spoke
cross-enterprise communication protocol implementation (Go + Solidity)
is isomorphic to its TLA+ specification. All 6 safety invariants
proved without Admitted.

## Inputs Consumed

| Artifact | Path |
|---|---|
| TLA+ Spec | `verification-history/2026-03-hub-and-spoke/specs/HubAndSpoke.tla` |
| Go Impl | `verification-history/2026-03-hub-and-spoke/impl/hub.go`, `spoke.go` |
| Solidity | `verification-history/2026-03-hub-and-spoke/impl/BasisHub.sol` |
| Tests | `verification-history/2026-03-hub-and-spoke/impl/cross_test.go` |
| TLC Log | `verification-history/2026-03-hub-and-spoke/tlc-evidence/MC_HubAndSpoke.log` |

## Artifacts Produced

| Artifact | Path |
|---|---|
| Common.v | `zkl2/proofs/units/2026-03-hub-and-spoke/1-proofs/Common.v` |
| Spec.v | `zkl2/proofs/units/2026-03-hub-and-spoke/1-proofs/Spec.v` |
| Impl.v | `zkl2/proofs/units/2026-03-hub-and-spoke/1-proofs/Impl.v` |
| Refinement.v | `zkl2/proofs/units/2026-03-hub-and-spoke/1-proofs/Refinement.v` |
| SUMMARY.md | `zkl2/proofs/units/2026-03-hub-and-spoke/2-reports/SUMMARY.md` |
| verification.log | `zkl2/proofs/units/2026-03-hub-and-spoke/2-reports/verification.log` |
| Frozen spec | `zkl2/proofs/units/2026-03-hub-and-spoke/0-input-spec/` |
| Frozen impl | `zkl2/proofs/units/2026-03-hub-and-spoke/0-input-impl/` |

## Theorems Proved (12 total, 0 Admitted)

### Core Safety
- T1 `inv_init` -- Init establishes invariant
- T2 `inv_preserved` -- Step preserves invariant
- T3 `cross_isolation` -- INV-CE5: Isolation (source /= dest, no private data)
- T4 `atomic_settlement` -- INV-CE6: Both roots advanced or neither (CRITICAL)
- T5 `cross_ref_consistency` -- INV-CE7: Settled => both proofs valid
- T6 `replay_protection` -- INV-CE8: Nonce consumed => no re-verification (CRITICAL)
- T7 `timeout_safety` -- INV-CE9: No premature timeouts
- T8 `hub_neutrality` -- INV-CE10: Hub only verifies, never generates proofs

### Implementation Refinement
- T9 `impl_inv_preserved` -- Go + Solidity preserve invariant
- C1-C3 Implementation satisfies INV-CE6, INV-CE7, INV-CE8

## Modeling Decisions

1. **Map-based message store**: Messages indexed by (source, dest, nonce) triples,
   matching both the TLA+ set-of-records model and the Solidity
   `mapping(bytes32 => Message)`. This provides structural replay protection.

2. **advance_roots function**: Models TLA+ `[stateRoots EXCEPT ![e1]=@+1, ![e2]=@+1]`.
   The `advance_roots_at_e2` lemma proves correctness regardless of whether
   source = dest (both cases yield `roots e2 + 1`).

3. **Identity refinement**: The Go/Solidity implementation faithfully mirrors the
   TLA+ spec. Each method maps 1:1 to a TLA+ action. The refinement is trivial
   (definitional equality).

4. **Cryptographic axioms**: ZK soundness, zero-knowledge, Poseidon hiding, and
   hub neutrality are trusted assumptions. The Coq proof verifies protocol logic
   under these assumptions.

## Issues Encountered

- `subst` in the initial `msg_split` tactic removed key variables from the context.
  Fixed by using `[-> [-> ->]]` intro patterns instead.
- `Nat.eqb` destruct without `Nat.eqb_spec` loses equality information needed by `lia`.
  Fixed by using `Nat.eqb_spec` with `[-> | _]` pattern.
- Invariant components I3-I7 have extra hypotheses (status/post-verified checks) that
  must be introduced separately from the message store lookup.

## Next Steps

None. This verification unit is complete. The hub-and-spoke protocol is certified.
