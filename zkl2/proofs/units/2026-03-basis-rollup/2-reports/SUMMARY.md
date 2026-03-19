# BasisRollup Verification Summary

## Unit

| Field | Value |
|-------|-------|
| Unit | 2026-03-basis-rollup |
| Target | zkl2 |
| Date | 2026-03-19 |
| Verdict | PASS |
| Admitted | 0 |
| Axioms | 0 |

## Inputs

| Input | Source |
|-------|--------|
| TLA+ Specification | zkl2/specs/units/2026-03-basis-rollup/.../BasisRollup.tla |
| Solidity Implementation | zkl2/contracts/contracts/BasisRollup.sol |

## Proof Architecture

The verification uses a **composite inductive invariant** (Inv) combining 10
safety properties into a single Record type. The invariant is:

1. **Established** on `init_state` (all fields vacuously true due to zero counters).
2. **Preserved** by each of the 5 lifecycle actions:
   - InitializeEnterprise: trivial (counters remain 0, genesis root satisfies NoReversal).
   - CommitBatch: new slot gets BSCommitted and valid root; all existing slots unchanged.
   - ProveBatch: batch transitions BSCommitted -> BSProven; proven counter incremented.
   - ExecuteBatch: batch transitions BSProven -> BSExecuted; currentRoot updated (key case for BatchChainContinuity).
   - RevertBatch: case split on BSProven vs BSCommitted status of reverted batch; cleared slot and counter adjustments preserve all properties.

The per-enterprise simplification is sound because TLA+ EXCEPT ![e] and Solidity
`mapping(address => ...)` both isolate enterprise state. No action cross-contaminates.

## Key Theorems

### T3. BatchChainContinuity (INV-S1 / INV-02)

```
forall s, Inv s ->
  st_init s = true -> st_executed s > 0 ->
  st_root s = st_batch_root s (st_executed s - 1)
```

After any batch execution, the enterprise's current root equals the state root
committed with the most recently executed batch. The proof's key step is in
`inv_execute`: ExecuteBatch sets `currentRoot := batchRoot[st_executed]` and
increments `st_executed`, so `new_executed - 1 = old_executed` and the
equality holds by reflexivity.

### T4. ProveBeforeExecute (INV-R2 / INV-03)

```
forall s, Inv s ->
  forall i, st_batch_status s i = BSExecuted -> i < st_proven s
```

Every executed batch index is below the proven watermark, meaning it has
passed through ZK proof verification. Proved by StatusConsistency: any
batch with BSExecuted status must be below st_executed (by inv_status_exec),
which is below st_proven (by inv_counter_mono).

### T5. CounterMonotonicity (INV-07)

```
forall s, Inv s ->
  st_executed s <= st_proven s /\ st_proven s <= st_committed s
```

The three-phase pipeline counters are monotonically ordered. Direct
extraction from the composite invariant.

## Refinement

The Solidity implementation is proved **bidirectionally equivalent** to the
TLA+ specification:

- `impl_refines_spec`: every `impl_step` is a `step`
- `spec_refines_impl`: every `step` is an `impl_step`

Both directions hold by definitional equality: `sol_X s = do_X s` for all
actions X. The Solidity-specific guards (authorization, VK checks, block
range tracking) are orthogonal to the lifecycle state machine and do not
affect the abstracted state transitions.

## File Inventory

| File | Lines | Purpose |
|------|-------|---------|
| Common.v | 100 | Types, functional map utilities, tactics |
| Spec.v | 245 | TLA+ faithful translation (state, actions, invariants) |
| Impl.v | 185 | Solidity model, guard mapping, bidirectional refinement |
| Refinement.v | 575 | 13 theorems, 5 preservation lemmas, 0 Admitted |

## TLA+ Invariant Coverage

| TLA+ Invariant | Coq Theorem | Status |
|----------------|-------------|--------|
| BatchChainContinuity (INV-S1/02) | batch_chain_continuity | PROVED |
| ProveBeforeExecute (INV-R2/03) | prove_before_execute | PROVED |
| ExecuteInOrder (INV-R1/04) | execute_in_order | PROVED |
| RevertSafety (INV-R5/05) | (embedded in inv_revert) | PROVED |
| CommitBeforeProve (INV-R3/06) | counter_monotonicity | PROVED |
| CounterMonotonicity (INV-07) | counter_monotonicity | PROVED |
| NoReversal (INV-08) | no_reversal | PROVED |
| InitBeforeBatch (INV-09) | init_before_batch | PROVED |
| StatusConsistency (INV-10) | status_consistency | PROVED |
| GlobalCountIntegrity (INV-11) | (excluded: derived sum) | N/A |
| BatchRootIntegrity (INV-12) | batch_root_integrity | PROVED |
| TypeOK (INV-01) | (Coq type system) | BY CONSTRUCTION |
