# Session Log: Batch Aggregation (RU-V4)

- **Date**: 2026-03-18
- **Target**: validium (MVP)
- **Experiment**: batch-aggregation
- **Stage**: 1 (Implementation) -> 2 (Baseline) complete
- **Iteration**: 1
- **Verdict**: CONFIRMED

## What Was Accomplished

1. **Literature review** (20 sources): Surveyed persistent queue systems (PostgreSQL WAL,
   Kafka, RabbitMQ), production L2 batch formation (zkSync Era, Polygon zkEVM, Scroll, Aztec),
   and academic papers on transaction ordering and crash recovery.

2. **Implementation**: Built three TypeScript modules:
   - `WriteAheadLog`: Append-only JSON-lines WAL with SHA-256 checksums, group commit, crash recovery
   - `PersistentQueue`: FIFO queue backed by WAL with checkpoint-based durability
   - `BatchAggregator`: Configurable batch formation (SIZE, TIME, HYBRID strategies)

3. **Benchmarks** (5 phases, 30 replications each):
   - Phase 1: Strategy comparison (SIZE vs TIME vs HYBRID)
   - Phase 2: Batch size sweep (4, 8, 16, 32, 64)
   - Phase 3: Arrival rate sweep (50, 100, 200, 500, 1000 tx/min)
   - Phase 4: Time threshold sweep (1000, 2000, 5000 ms)
   - Phase 5: fsync strategy comparison (per-entry vs group commit)

4. **Determinism tests**: 450/450 passed (3 strategies x 5 batch sizes x 30 reps)

5. **Crash recovery tests**: 150/150 passed across 5 scenarios (pre-batch crash, mid-batch crash,
   corrupted WAL, post-checkpoint crash, multiple sequential crashes)

## Key Findings

- HYBRID batch formation is the clear winner (18.5K tx/min vs 16K for SIZE-only)
- Batch formation latency is sub-0.02ms -- negligible vs proving time (5.8-12.8s from RU-V2)
- Throughput exceeds 100 tx/min target by 141x-2,744x depending on configuration
- Zero transaction loss across all 150 crash recovery test cases
- Perfect determinism across all 450 test cases
- Group commit is 24% faster than per-entry fsync
- WAL write latency: 149-210 us per entry (JSON + SHA-256 overhead)

## Bug Found and Fixed

- Initial checkpoint implementation used global WAL sequence counter instead of per-batch
  dequeued sequence. This caused crash recovery Scenario 2 (mid-batch crash) to fail because
  the checkpoint marked all WAL entries as committed, not just the batch's entries.
  Fix: Track `lastDequeuedSeq` in PersistentQueue, pass to WAL checkpoint.

## Artifacts Produced

| Artifact | Path |
|----------|------|
| Hypothesis | `validium/research/experiments/2026-03-18_batch-aggregation/hypothesis.json` |
| State | `validium/research/experiments/2026-03-18_batch-aggregation/state.json` |
| Journal | `validium/research/experiments/2026-03-18_batch-aggregation/journal.md` |
| Findings | `validium/research/experiments/2026-03-18_batch-aggregation/findings.md` |
| WAL module | `validium/research/experiments/2026-03-18_batch-aggregation/code/src/wal.ts` |
| Queue module | `validium/research/experiments/2026-03-18_batch-aggregation/code/src/persistent-queue.ts` |
| Aggregator | `validium/research/experiments/2026-03-18_batch-aggregation/code/src/batch-aggregator.ts` |
| Tx generator | `validium/research/experiments/2026-03-18_batch-aggregation/code/src/tx-generator.ts` |
| Benchmark | `validium/research/experiments/2026-03-18_batch-aggregation/code/src/benchmark.ts` |
| Determinism test | `validium/research/experiments/2026-03-18_batch-aggregation/code/src/test-determinism.ts` |
| Crash test | `validium/research/experiments/2026-03-18_batch-aggregation/code/src/test-crash-recovery.ts` |
| Results JSON | `validium/research/experiments/2026-03-18_batch-aggregation/results/benchmark_results.json` |
| Invariants update | `validium/research/foundations/zk-01-objectives-and-invariants.md` (INV-BA1..6, PROP-BA1..3, OQ-6..8) |
| Threat model update | `validium/research/foundations/zk-02-threat-model.md` (ATK-BA1..5) |
| Global memory | `lab/1-scientist/memory/global.md` (experiment index + patterns) |

## Next Steps

1. **Logicist (RU-V4 [10])**: Formalize Enqueue(tx), FormBatch(), ProcessBatch() in TLA+
   with invariants NoLoss, Determinism, Ordering, Completeness. Model check crash recovery.
2. **Architect (RU-V4 [11])**: Implement production TransactionQueue, BatchAggregator, and
   BatchBuilder in `validium/node/src/queue/` and `validium/node/src/batch/`.
3. **Prover (RU-V4 [12])**: Coq proofs of NoLoss and Determinism under crash recovery.
4. **Future experiment considerations**:
   - Concurrent multi-enterprise writer benchmarks
   - Linux fsync benchmarks on production hardware
   - Binary WAL format comparison for high-throughput scenarios
   - Integration benchmark with actual SMT state transitions (1.8ms per insert overhead)
