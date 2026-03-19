# Session Log: RU-L2 Sequencer and Block Production

- **Date**: 2026-03-19
- **Target**: zkl2
- **Experiment**: 2026-03-19_sequencer
- **Research Unit**: RU-L2 (Sequencer and Block Production)
- **Stage**: 1 (Implementation) -- COMPLETE
- **Verdict**: CONFIRMED

## What Was Accomplished

1. **Literature review**: 18 sources covering production systems (zkSync Era, Polygon CDK,
   Scroll, Arbitrum, OP Stack, Taiko), academic fair ordering (Aequitas, Themis), ZK-rollup
   benchmarking (Chaliasos IACR 2024/889), and censorship resistance mechanisms.

2. **Go prototype**: 4 modules (~500 LOC) implementing:
   - FIFO mempool with capacity enforcement and batch operations
   - Arbitrum-style forced inclusion queue with FIFO ordering and deadline enforcement
   - Single-operator block producer with forced-first-then-mempool transaction selection
   - Comprehensive metrics collection

3. **Benchmarks**: 14 result files across:
   - 6 scenario tests (steady state, burst, forced inclusion, adversarial, max capacity)
   - Block production scaling (10-5000 tx, 30 reps each)
   - Concurrent access test (4 producers)
   - Go native benchmarks (mempool insert, drain, block production)

4. **Foundation updates**: Added invariants I-09 through I-12, threats T-11 through T-13,
   updated performance targets, updated T-01 with experimental validation.

## Key Findings

- Block production at 500 tx/block: **0.14ms avg** (7,100x faster than 1s target)
- Mempool insert: **2.8M tx/s** single-threaded
- FIFO accuracy: **100%** across all scenarios including concurrent
- Forced inclusion: **100%** included, max latency = 1 block tick
- Concurrent (4 producers): **33K tx/s**, ordering preserved

## Artifacts Produced

| Artifact | Path |
|----------|------|
| hypothesis.json | zkl2/research/experiments/2026-03-19_sequencer/hypothesis.json |
| state.json | zkl2/research/experiments/2026-03-19_sequencer/state.json |
| journal.md | zkl2/research/experiments/2026-03-19_sequencer/journal.md |
| findings.md | zkl2/research/experiments/2026-03-19_sequencer/findings.md |
| types.go | zkl2/research/experiments/2026-03-19_sequencer/code/types.go |
| mempool.go | zkl2/research/experiments/2026-03-19_sequencer/code/mempool.go |
| forced_inclusion.go | zkl2/research/experiments/2026-03-19_sequencer/code/forced_inclusion.go |
| sequencer.go | zkl2/research/experiments/2026-03-19_sequencer/code/sequencer.go |
| sequencer_test.go | zkl2/research/experiments/2026-03-19_sequencer/code/sequencer_test.go |
| bench_high_throughput_test.go | zkl2/research/experiments/2026-03-19_sequencer/code/bench_high_throughput_test.go |
| 14 result JSON files | zkl2/research/experiments/2026-03-19_sequencer/results/ |
| block_production_scaling.csv | zkl2/research/experiments/2026-03-19_sequencer/results/ |
| session.md | zkl2/research/experiments/2026-03-19_sequencer/memory/session.md |
| Invariants I-09 to I-12 | zkl2/research/foundations/zk-01-objectives-and-invariants.md |
| Threats T-11 to T-13 | zkl2/research/foundations/zk-02-threat-model.md |

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Sequencer type | Single-operator | TD-005 per-enterprise chains, no consensus needed |
| Transaction ordering | FIFO (arrival time) | Zero-fee model (I-05) eliminates MEV/priority |
| Forced inclusion model | Arbitrum-style DelayedInbox | FIFO queue prevents selective censorship |
| Forced inclusion deadline | 24 hours (configurable) | Matches Arbitrum, reasonable for enterprise |
| Block time | 1 second | Matches zkSync Era, enterprise load fits easily |
| Block gas limit | 10M (configurable) | Bounds per-block execution |
| Mempool structure | Simple FIFO slice | No priority heap needed without fees |

## Next Steps

1. **Logicist (RU-L2)**: TLA+ specification with invariants:
   - Inclusion: every mempool tx eventually in a block
   - ForcedInclusion: forced tx included within deadline
   - Ordering: FIFO within each source
   - Model check: 5 txs, 2 forced txs, 3 blocks

2. **Architect (RU-L2)**: Go implementation at zkl2/node/sequencer/ integrating
   with existing executor at zkl2/node/executor/

3. **Prover (RU-L2)**: Coq verification of Inclusion and ForcedInclusion properties
