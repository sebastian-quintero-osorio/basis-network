# Phase 1: Formalization Notes -- BasisRollup

**Unit**: basis-rollup
**Target**: zkl2
**Date**: 2026-03-19
**Result**: PASS -- All 12 invariants verified across 2,187,547 states

---

## 1. Research-to-Spec Mapping

| Source (0-input/) | TLA+ Element | Notes |
|-------------------|--------------|-------|
| BasisRollup.sol line 34: `enum BatchStatus` | `StatusNone`, `StatusCommitted`, `StatusProven`, `StatusExecuted` | Modeled as strings for readability |
| BasisRollup.sol lines 45-53: `EnterpriseState` struct | `currentRoot`, `initialized`, `totalBatchesCommitted/Proven/Executed` | `lastL2Block` abstracted (see Assumptions) |
| BasisRollup.sol lines 65-71: `StoredBatchInfo` struct | `batchStatus`, `batchRoot` per enterprise per batch ID | `batchHash`, `l2BlockStart/End` abstracted |
| BasisRollup.sol lines 213-229: `initializeEnterprise()` | `InitializeEnterprise(e, genesisRoot)` | Faithful 1:1 translation |
| BasisRollup.sol lines 240-293: `commitBatch()` | `CommitBatch(e, newRoot)` | Block range validation abstracted |
| BasisRollup.sol lines 308-337: `proveBatch()` | `ProveBatch(e, proofIsValid)` | Proof as boolean oracle; sequential proving enforced |
| BasisRollup.sol lines 349-375: `executeBatch()` | `ExecuteBatch(e)` | State root advancement modeled; L2->L1 messages abstracted |
| BasisRollup.sol lines 386-416: `revertBatch()` | `RevertBatch(e)` | LIFO revert, proven counter rollback modeled |
| REPORT.md: INV-S1 ChainContinuity | `BatchChainContinuity` | Extended: checks against last executed batch root |
| REPORT.md: INV-S2 ProofBeforeState | `ProveBeforeExecute` | Decomposed: proof gate is now between Phase 2 and Phase 3 |
| REPORT.md: INV-R1 SequentialExecution | `ExecuteInOrder` | All batches before index i must be Executed if i is Executed |
| REPORT.md: INV-R2 ProveBeforeExecute | `ProveBeforeExecute` | Batch index must be below proven watermark |
| REPORT.md: INV-R3 CommitBeforeProve | `CommitBeforeProve` | Counter ordering: proven <= committed |
| REPORT.md: INV-R5 RevertSafety | `RevertSafety` | Executed batches remain Executed (never deleted) |
| REPORT.md: NoGap | Structural in `CommitBatch` | batchId = totalBatchesCommitted[e], auto-incremented |
| REPORT.md: EnterpriseIsolation | EXCEPT ![e] semantics | Verified by cross-enterprise interleaving in TLC |
| REPORT.md: GlobalCountIntegrity | `GlobalCountIntegrity` | Extended to three counters (committed, proven, executed) |
| StateCommitment.tla: NoReversal | `NoReversal` | Preserved: initialized enterprise always has valid root |
| StateCommitment.tla: InitBeforeBatch | `InitBeforeBatch` | Preserved: batches only for initialized enterprises |

## 2. Extension from StateCommitment (RU-V3)

The validium StateCommitment models a **single-phase atomic** operation: `SubmitBatch` simultaneously verifies the ZK proof and updates the state root. BasisRollup decomposes this into three phases:

| Aspect | StateCommitment (RU-V3) | BasisRollup (RU-L5) |
|--------|------------------------|---------------------|
| Actions | 2 (Initialize, SubmitBatch) | 5 (Initialize, Commit, Prove, Execute, Revert) |
| Batch status | Implicit (exists or not) | Explicit 4-state machine (None/Committed/Proven/Executed) |
| Proof verification | Inline in SubmitBatch | Separate ProveBatch phase |
| State root update | Atomic with proof | Deferred to ExecuteBatch |
| Revert capability | None | RevertBatch (LIFO, unexecuted only) |
| Counters per enterprise | 1 (batchCount) | 3 (committed, proven, executed) |
| Global counters | 1 (totalCommitted) | 3 (globalCommitted, globalProven, globalExecuted) |
| Variables | 5 | 10 |
| Invariants | 6 | 12 |

The three-phase decomposition introduces new invariants not needed in the atomic model:
- **CounterMonotonicity**: executed <= proven <= committed (pipeline ordering)
- **StatusConsistency**: batch statuses align with counter watermarks
- **BatchRootIntegrity**: committed batches have roots, uncommitted do not

## 3. Assumptions

1. **Block range tracking abstracted**: INV-R4 MonotonicBlockRange (l2BlockStart, l2BlockEnd) is a data-level constraint enforced by uint64 comparisons in Solidity. It does not interact with the batch lifecycle state machine. The TLA+ model omits L2 block numbers to focus on the lifecycle invariants.

2. **Proof as boolean oracle**: ZK proof verification is modeled as a non-deterministic boolean. TLC generates both TRUE and FALSE, but only TRUE enables the ProveBatch guard. This verifies that no state mutation occurs without proof validation, without modeling Groth16 internals.

3. **Batch hash abstracted**: The `batchHash = keccak256(...)` computation in `commitBatch()` is an integrity mechanism for the prove phase. The TLA+ model captures the semantic effect (batch must be committed before proving) without modeling the hash itself.

4. **L2->L1 messages abstracted**: The execute phase in production processes withdrawals and cross-enterprise messages. These are application-layer concerns that do not affect the batch lifecycle state machine.

5. **Authorization abstracted**: `enterpriseRegistry.isAuthorized(msg.sender)` and `onlyAdmin` modifiers are access control mechanisms. The TLA+ model assumes only authorized actors invoke actions, focusing on the protocol state machine.

6. **Finite model**: MaxBatches = 3 bounds the state space. Terminal states (all batches fully processed) are expected and not protocol deadlocks. The `-deadlock` flag suppresses TLC's deadlock detection for this reason.

## 4. Verification Results

```
TLC2 Version 2.16 of 31 December 2020
Model checking completed. No error has been found.
2,187,547 states generated, 383,161 distinct states found, 0 states left on queue.
Depth of complete state graph search: 21.
Finished in 18s.
```

**Parameters**: 2 enterprises, 3 batches, 3 roots, 4 workers.

**Invariants verified (all PASS)**:

| # | Invariant | Origin | Status |
|---|-----------|--------|--------|
| 1 | TypeOK | Standard | PASS |
| 2 | BatchChainContinuity | INV-S1 extended | PASS |
| 3 | ProveBeforeExecute | INV-R2 | PASS |
| 4 | ExecuteInOrder | INV-R1 | PASS |
| 5 | RevertSafety | INV-R5 | PASS |
| 6 | CommitBeforeProve | INV-R3 | PASS |
| 7 | CounterMonotonicity | New (pipeline ordering) | PASS |
| 8 | NoReversal | RU-V3 preserved | PASS |
| 9 | InitBeforeBatch | RU-V3 preserved | PASS |
| 10 | StatusConsistency | New (status/counter alignment) | PASS |
| 11 | GlobalCountIntegrity | RU-V3 extended to 3 counters | PASS |
| 12 | BatchRootIntegrity | New (root/status alignment) | PASS |

### Reproduction

```bash
cd zkl2/specs/units/2026-03-basis-rollup/1-formalization/v0-analysis/experiments/BasisRollup/_build/
java -cp lab/2-logicist/tools/tla2tools.jar tlc2.TLC MC_BasisRollup -workers 4 -deadlock -cleanup
```

## 5. Open Issues

1. **INV-R4 MonotonicBlockRange**: Abstracted in this formalization. Could be modeled as a separate concern if block range bugs are suspected, but the Solidity tests (61/61 PASS) already verify this at the implementation level.

2. **Batch range proving**: The current model proves batches individually. Production systems prove batch ranges (N to N+M). A future research unit could extend the ProveBatch action to accept ranges.

3. **Priority operations**: The `priorityOpsHash` field is stored but not enforced in the current contract. Forced inclusion deadlines would introduce liveness requirements not yet modeled.

4. **Deadlock in finite model**: Terminal states occur when all batches are fully processed. This is expected behavior for a bounded model, not a protocol flaw. A liveness property (e.g., "every committed batch is eventually executed") would require fairness conditions.

---

## 6. Verdict

**PASS**. The BasisRollup commit-prove-execute lifecycle is formally verified. All 12 invariants hold across the full state space of 383,161 distinct states. The specification faithfully extends the validium StateCommitment model to the three-phase rollup pattern.

Ready for Phase 2: Audit (`/2-audit`).
