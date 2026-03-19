# Phase 1: Formalization Notes -- Sequencer and Block Production

## Unit Information

- **Unit**: 2026-03-sequencer (RU-L2)
- **Target**: zkl2
- **Date**: 2026-03-19
- **Input**: `zkl2/specs/units/2026-03-sequencer/0-input/`
- **Hypothesis**: A single-operator sequencer can produce L2 blocks every 1-2 seconds with FIFO ordering while a forced inclusion mechanism via L1 guarantees censorship resistance with maximum 24-hour latency.

## Research-to-Spec Mapping

| Research Element | TLA+ Element | Source |
|---|---|---|
| Mempool FIFO queue | `mempool` variable (Seq) | `0-input/code/mempool.go`, Mempool struct |
| Transaction submission | `SubmitTx(tx)` action | `0-input/code/mempool.go`, `Add()` method |
| Forced inclusion queue | `forcedQueue` variable (Seq) | `0-input/code/forced_inclusion.go`, ForcedInclusionQueue |
| Forced tx submission via L1 | `SubmitForcedTx(ftx)` action | `0-input/code/forced_inclusion.go`, `Submit()` |
| Block production loop | `ProduceBlock` action | `0-input/code/sequencer.go`, `ProduceBlock()` |
| Forced-first block assembly | `forcedPart \o mempoolPart` | `0-input/code/sequencer.go`, lines 75-106 |
| FIFO drain from mempool | `Take(mempool, mempoolCount)` | `0-input/code/mempool.go`, `Drain()` |
| Deadline enforcement | `IsExpired(i)` / `minRequired` | `0-input/code/forced_inclusion.go`, `DrainDue()` |
| Arbitrum FIFO constraint | Cannot skip queue items | `0-input/REPORT.md`, Section "Forced Inclusion Mechanisms" |
| Block lifecycle (pending to sealed) | `blockNum` advancement | `0-input/REPORT.md`, "Block Lifecycle Maps to Proven Pattern" |
| 24h forced inclusion window | `ForcedDeadlineBlocks` constant | `0-input/REPORT.md`, "Arbitrum-style DelayedInbox" |
| Zero-fee FIFO ordering | No priority ordering in mempool | `0-input/REPORT.md`, "FIFO Ordering is Natural for Enterprise" |
| Cooperative vs non-cooperative | `numForced \in 0..Len(forcedQueue)` | `0-input/code/forced_inclusion.go`, `DrainDue()` `includeAll` param |

## Modeling Decisions

### Variables (6)

| Variable | Type | Purpose |
|---|---|---|
| `mempool` | Seq(Txs) | FIFO queue of pending regular transactions |
| `forcedQueue` | Seq(ForcedTxs) | FIFO queue of forced transactions from L1 |
| `blocks` | Seq(Seq(AllTxIds)) | Produced blocks, each a sequence of tx IDs |
| `blockNum` | 0..MaxBlocks | Counter of blocks produced |
| `forcedSubmitBlock` | [ForcedTxs -> Nat] | Records block number at forced tx submission |
| `submitOrder` | [AllTxIds -> Nat] | Global monotonic ordering for FIFO verification |

Three operators are derived (not state variables):
- `submitted` = `DOMAIN submitOrder \cap Txs`
- `forcedSubmitted` = `DOMAIN forcedSubmitBlock`
- `included` = `UNION {Range(blocks[i]) : i \in 1..Len(blocks)}`

### Abstraction Choices

1. **Gas limit abstracted**: The Go implementation limits blocks by both `MaxTxPerBlock` and `BlockGasLimit`. In the zero-fee enterprise model, all transactions use `DefaultTxGas = 21000`, making `BlockGasLimit / DefaultTxGas ~ MaxTxPerBlock`. The TLA+ model uses only `MaxTxPerBlock` as the capacity bound.

2. **Block lifecycle truncated**: The full lifecycle is `pending -> sealed -> committed -> proved -> finalized`. The spec models only `pending -> sealed` (the sequencer's responsibility). Downstream stages (commit, prove, finalize) are handled by other pipeline components (RU-L4, RU-L5, RU-L6).

3. **Cooperative vs non-cooperative**: The sequencer non-deterministically chooses how many forced txs to include (`numForced`), bounded by `minRequired` (must include expired) and `MaxTxPerBlock` (capacity). This models the full adversarial range from cooperative (include all) to censoring (delay until deadline).

4. **Time abstracted to blocks**: The 24-hour forced inclusion window is modeled as `ForcedDeadlineBlocks` (number of blocks, not wall-clock time). At 1-second blocks, 24h = 86,400 blocks. The model uses 2 blocks for tractable verification.

5. **Mempool capacity unbounded**: The Go implementation has a `MempoolCapacity` limit (10K). The TLA+ model does not bound mempool size, relying on the finite tx set to naturally limit it. Adding capacity would require modeling tx drops, which is orthogonal to the core protocol properties.

## Invariants Verified

| Invariant | Property Type | Description | Result |
|---|---|---|---|
| `TypeOK` | Type safety | All variables have well-typed values | PASS |
| `NoDoubleInclusion` | Safety | No tx appears in more than one block | PASS |
| `ForcedInclusionDeadline` | Safety | Forced txs included within deadline blocks | PASS |
| `IncludedWereSubmitted` | Safety | Only submitted txs appear in blocks | PASS |
| `ForcedBeforeMempool` | Safety | Forced txs precede mempool txs in each block | PASS |
| `FIFOWithinBlock` | Safety | FIFO ordering preserved within each category | PASS |

## Liveness Properties (Defined, Not Model-Checked)

| Property | Description | Reason Not Checked |
|---|---|---|
| `EventualInclusion` | Every submitted tx is eventually included | MaxBlocks bounds block production; liveness requires unbounded model |
| `ForcedEventualInclusion` | Every forced tx is eventually included | Same limitation; structurally guaranteed by `ForcedInclusionDeadline` + fairness |

Liveness is structurally implied: with `WF_vars(ProduceBlock)` (weak fairness on block production) and the `ForcedInclusionDeadline` invariant, forced txs are guaranteed to be included. Regular txs require sufficient block capacity, which is guaranteed when `MaxBlocks * MaxTxPerBlock >= |Txs| + |ForcedTxs|`.

## Verification Results

- **Tool**: TLC 2.16 (tla2tools.jar)
- **Workers**: 4 (on 20 cores)
- **Result**: **PASS -- No error found**
- **States generated**: 4,833,902
- **Distinct states**: 4,406,662
- **State graph depth**: 11
- **Time**: 31 seconds
- **Fingerprint collision probability**: 1.7e-6 (negligible)

### Model Parameters

| Constant | Value | Rationale |
|---|---|---|
| `Txs` | {t1, t2, t3, t4, t5} | 5 regular txs -- sufficient to test FIFO ordering and block splitting |
| `ForcedTxs` | {f1, f2} | 2 forced txs -- tests FIFO in forced queue and deadline enforcement |
| `MaxTxPerBlock` | 3 | Forces block splitting (7 txs cannot fit in one block) |
| `MaxBlocks` | 3 | Allows deadline to trigger (deadline=2 fires at block 3) |
| `ForcedDeadlineBlocks` | 2 | Tight deadline testable within 3-block bound |

### Reproduction

```bash
cd zkl2/specs/units/2026-03-sequencer/1-formalization/v0-analysis/experiments/Sequencer/_build/
java -cp <repo>/lab/2-logicist/tools/tla2tools.jar tlc2.TLC MC_Sequencer -workers 4 -deadlock
```

## Key Findings

1. **Forced inclusion deadline is enforceable**: The `ForcedInclusionDeadline` invariant holds across all 4.8M states. The sequencer's `minRequired` constraint (must include expired forced txs) is necessary and sufficient. Without it, TLC would find counterexamples where the sequencer censors forced txs past their deadline.

2. **FIFO ordering is structural**: Because block assembly always takes from the front of both queues (`Take` = `SubSeq(s, 1, n)`), FIFO ordering within blocks is guaranteed by construction. The `FIFOWithinBlock` invariant confirms this across all reachable states.

3. **No double inclusion is guaranteed**: Once a tx is drained from its queue, it cannot re-enter. The `NoDoubleInclusion` invariant confirms no tx appears in multiple blocks.

4. **Forced-before-mempool is guaranteed**: Block assembly concatenates forced and mempool parts in order (`forcedPart \o mempoolPart`), structurally ensuring forced txs precede mempool txs.

5. **Adversarial sequencer bounded**: The non-deterministic choice of `numForced` models the full range from cooperative (include all forced) to maximally censoring (delay until deadline). The protocol remains safe across this entire adversarial spectrum.

## Open Issues

1. **Mempool capacity**: The Go implementation drops transactions when the mempool is full (capacity 10K). The TLA+ model does not model this. A future refinement could add capacity bounds and verify that dropped txs are handled correctly (returned to sender, not silently lost).

2. **Gas metering**: The model abstracts gas as a simple tx count. If transactions have variable gas costs, the block capacity constraint becomes more complex (knapsack-like). This is relevant for contract interactions but not for simple transfers.

3. **Cross-block FIFO**: The model verifies FIFO within each block but does not explicitly verify FIFO across blocks (that txs in block N were submitted before txs in block N+1 from the same queue). This property follows from the structural queue operations but is not independently verified by an invariant.

4. **Concurrent submission**: The Go implementation uses mutexes for concurrent mempool access. The TLA+ model uses atomic actions (interleaving semantics), which is a weaker concurrency model. The Go benchmarks confirm 100% FIFO accuracy under 4-goroutine concurrent load.
