# Verification Summary: Sequencer

**Unit**: 2026-03-sequencer
**Target**: zkl2
**Date**: 2026-03-19
**Status**: PASS -- All theorems proved, zero Admitted

---

## Scope

Verification of the enterprise L2 sequencer implementation (Go) against
its TLA+ specification. The sequencer manages:
- FIFO mempool for regular transactions
- Arbitrum-style forced inclusion queue with deadline enforcement
- Single-operator block production with forced-first ordering

## Input Artifacts

| Artifact | Source |
|----------|--------|
| TLA+ Specification | `zkl2/specs/units/2026-03-sequencer/...Sequencer.tla` (262 lines) |
| Go Implementation | `zkl2/node/sequencer/*.go` (5 files, ~1000 lines) |

## Proof Files

| File | Lines | Purpose |
|------|-------|---------|
| Common.v | 316 | List infrastructure: take/drop, NoDup, sorted pairs, tactics |
| Spec.v | 275 | TLA+ translation: state, step relation, safety properties, invariant record |
| Impl.v | 244 | Go model: impl state, deterministic block production, refinement |
| Refinement.v | 548 | All proofs: invariant preservation, safety theorems, reachability |
| **Total** | **1383** | |

## Theorems Proved

### Safety Properties (for all reachable states)

| # | Theorem | Property | TLA+ Source |
|---|---------|----------|-------------|
| 1 | `thm_no_double_inclusion` | No transaction appears in multiple blocks | lines 191-193 |
| 2 | `thm_included_were_submitted` | Only submitted transactions appear in blocks | lines 205-206 |
| 3 | `thm_forced_before_mempool` | Forced txs precede mempool txs in each block | lines 211-217 |
| 4 | `thm_fifo_within_block` | Each block has forced prefix then mempool suffix | lines 224-233 |
| 5 | `thm_forced_inclusion_deadline` | Expired forced txs are included in blocks | lines 199-201 |

### Structural Invariants (preserved inductively)

| # | Invariant | Purpose |
|---|-----------|---------|
| 1 | `nd_inv` | NoDup across mempool, forced queue IDs, and all blocks |
| 2 | `ei_inv` | All active elements tracked in the everseen dedup set |
| 3 | `bs_inv` | Type constraints (regular/forced) + block structure |
| 4 | `fd_inv` | Sorted queue + conservation + forced deadline |

### Refinement

| # | Theorem | Property |
|---|---------|----------|
| 10 | `impl_refines_spec` | Every Go impl step is a valid TLA+ spec step |
| 11 | `map_init` | Impl initial state maps to spec initial state |

## Proof Architecture

- **Modular sub-invariants** rather than monolithic invariant.
  Each sub-invariant is proved independently for each of the 3 actions.
- **nd_inv** (NoDoubleInclusion): Uses `NoDup_insert` for submissions and
  direct NoDup construction from parts for ProduceBlock (extracting NoDup
  of take/drop components and proving pairwise disjointness).
- **fd_inv** (ForcedInclusionDeadline): Uses `sorted_snd` property of the
  forced queue + `expired_in_prefix` lemma to show all expired forced txs
  fall within the consumed prefix of ProduceBlock.
- **bs_inv** (ForcedBeforeMempool): Uses `new_block_structure` to show
  each block has a forced prefix (all `is_forced_b = true`) followed by
  a mempool suffix (all `is_forced_b = false`).
- **Refinement**: The Go implementation's cooperative block production mode
  makes a deterministic choice within the spec's non-deterministic range
  (`impl_nf >= expired_prefix_count`, `impl_nf + impl_nm <= MaxTxPerBlock`).

## Liveness (Not Proved)

`EventualInclusion` (every submitted tx is eventually included) requires
temporal logic / fairness reasoning (`WF_vars(ProduceBlock)` in TLA+)
which is beyond the scope of inductive safety verification in Coq.

## Compilation

```
Rocq Prover version 9.0.1, compiled with OCaml 4.14.2
Namespace: Sequencer
Compilation order: Common.v -> Spec.v -> Impl.v -> Refinement.v
Result: ALL PASS, zero Admitted
```
