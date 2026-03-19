# BasisBridge Verification Summary

**Date:** 2026-03-19
**Target:** zkl2
**Unit:** bridge
**Status:** PASS -- All theorems proved, zero Admitted

## Inputs

| Artifact | Source |
|----------|--------|
| TLA+ Specification | `zkl2/specs/units/2026-03-bridge/.../BasisBridge.tla` (346 lines) |
| Solidity Contract | `zkl2/contracts/contracts/BasisBridge.sol` (498 lines) |
| Go Relayer | `zkl2/bridge/relayer/` (relayer.go, types.go, trie.go -- 605 lines) |

## Proof Files

| File | Lines | Purpose |
|------|-------|---------|
| `Common.v` | ~280 | Types, functional maps, sum helpers, unclaimed/active_users, NoDup |
| `Spec.v` | ~245 | Faithful TLA+ translation: State, 9 actions, step, 3 safety properties |
| `Impl.v` | ~130 | BasisBridge.sol + relayer model, bisimulation refinement |
| `Refinement.v` | ~600 | Composite invariant (10 components), 9 preservation proofs, 9 theorems |

## Theorems Proved

### Invariant Establishment and Preservation

| ID | Theorem | Statement |
|----|---------|-----------|
| T1 | `inv_init_state` | Initial state satisfies the 10-component Inv |
| T2 | `inv_preserved` | Any spec step preserves Inv |

### Safety Properties (Target)

| ID | Theorem | TLA+ Invariant | Statement |
|----|---------|----------------|-----------|
| T3 | `no_double_spend` | INV-B1 | Finalized withdrawal IDs are unique |
| T4 | `balance_conservation` | INV-B2 | Pre-escape: exact accounting. Escape: bridge solvency |
| T5 | `escape_hatch_liveness` | INV-B3 | Bridge covers each active user's finalized balance |

### Implementation Refinement

| ID | Theorem | Statement |
|----|---------|-----------|
| T6 | `impl_inv_preserved` | Solidity+Go actions preserve Inv |
| T7 | `impl_no_double_spend` | Implementation satisfies INV-B1 |
| T8 | `impl_balance_conservation` | Implementation satisfies INV-B2 |
| T9 | `impl_escape_hatch_liveness` | Implementation satisfies INV-B3 |

## Composite Invariant (10 Components)

| Component | Name | Purpose |
|-----------|------|---------|
| W1 | `inv_wid_fin_nodup` | NoDup of finalized wids |
| W2 | `inv_wid_pend_nodup` | NoDup of pending wids |
| W3 | `inv_wid_disjoint` | Pending/finalized wids disjoint |
| W4 | `inv_wid_bound` | All wids < nextWid |
| B1 | `inv_balance_con` | Pre-escape accounting identity |
| G1 | `inv_fin_gap` | l2 + pending >= lastFinalized |
| E1 | `inv_escape_solv` | Escape mode solvency |
| C1 | `inv_claimed_valid` | Claimed wids from finalized |
| P1 | `inv_no_premature_escape` | No escape before escape_active |
| S1 | `inv_escape_seq` | Escape implies sequencer offline |

## Proof Architecture

The proof uses a strengthened inductive invariant with 10 components.
Each of the 9 step constructors (Deposit, InitiateWithdrawal, FinalizeBatch,
ClaimWithdrawal, ActivateEscapeHatch, EscapeWithdraw, SequencerFail,
SequencerRecover, Tick) is proved to preserve the composite invariant.

Key proof insights:

1. **NoDoubleSpend** follows from NoDup of finalized wids (W1), maintained
   by the monotonic wid counter (W4) and pending/finalized disjointness (W3).

2. **BalanceConservation** uses two invariants: exact accounting (B1) for
   pre-escape, and escape solvency (E1) for during escape. The accounting
   identity `bridge = sum_l2 + pending + unclaimed` is preserved because
   each action's effects on bridge and obligations cancel out.

3. **EscapeHatchLiveness** derives individual user coverage from aggregate
   solvency (E1) via `sum_fun_ge_elem` (element <= sum). Escape solvency
   is established at ActivateEscapeHatch from `balance_con + fin_gap`.

4. **Finalization gap** (G1) tracks that deposits after the last finalization
   create excess value covering the escape hatch. This is the mathematical
   foundation of the documented escape hatch gap.

5. **Implementation refinement** is trivial: BasisBridge.sol + relayer.go
   implement the exact same state machine as BasisBridge.tla. The refinement
   mapping is the identity function (bisimulation).

## Modeling Decisions

- **Single enterprise**: The model focuses on one enterprise. Sound because
  all TLA+ actions and invariants are per-enterprise.
- **Merkle proofs abstracted**: Trusted crypto, same as TLA+ abstraction.
- **Atomic deposit**: L1 lock + L2 credit modeled as one step (trusted relayer).
- **Over-approximated FinalizeBatch guard**: Removing the TLA+ guard
  `pending /= {} \/ l2 /= lastFinalized` makes the system more non-deterministic,
  which is safe for proving safety properties.
