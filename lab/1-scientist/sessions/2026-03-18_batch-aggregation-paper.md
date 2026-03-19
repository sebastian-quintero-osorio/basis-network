# Session Log: Batch Aggregation Paper (RU-V4)

> Date: 2026-03-18 | Target: validium | Agent: The Scientist

## What Was Accomplished

Wrote the full academic paper for the batch aggregation experiment (RU-V4),
including integration of the TLA+ formal verification results from the
Logicist's analysis.

## Key Findings Documented

1. **HYBRID batch aggregation**: 274,438 tx/min peak throughput, sub-ms latency,
   450/450 determinism, 150/150 crash recovery -- all hypothesis targets confirmed.

2. **NoLoss Bug (HIGHLIGHT)**: TLA+ model checking discovered a silent transaction
   loss bug that 150 empirical crash tests missed. A premature WAL checkpoint at
   batch formation creates a 1.9-12.8s durability gap during ZK proving. Fix:
   defer checkpoint to after batch processing (ProcessBatch, not FormBatch).

3. **Corrected protocol verified**: v1-fix passes 6/6 safety invariants and 1/1
   liveness property across 2,630 distinct states with zero errors.

## Artifacts Produced

All in `validium/research/experiments/2026-03-18_batch-aggregation/paper/`:

- `main.tex` -- Master document (IEEEtran conference format)
- `abstract.tex` -- 200-word abstract
- `introduction.tex` -- Motivation, gap, contributions, key result
- `related-work.tex` -- ZK-rollup batching, WAL literature, formal verification, comparison table
- `system-model.tex` -- Network architecture, trust model, safety/performance requirements
- `methodology.tex` -- Protocol design, benchmark suite, formal verification approach
- `results.tex` -- 6 tables: strategy comparison, scaling, fsync, reconciliation, correctness, TLA+
- `discussion.tex` -- Hypothesis verdict, trade-offs, value of formal verification, limitations
- `conclusion.tex` -- Contributions summary, future work
- `references.bib` -- 25 BibTeX entries
- `main.pdf` -- Compiled (7 pages, 283KB)

## Decisions Made

- Dedicated a full subsection (Section 5.4 "The NoLoss Bug") to the TLA+ discovery
  with the 6-state counterexample trace, root cause analysis, and corrected protocol.
  This is the paper's distinguishing contribution.
- Used IEEEtran conference format consistent with prior papers (RU-V1, RU-V2).
- Included comparison table with zkSync Era, Polygon zkEVM, Scroll, Aztec, Kafka,
  RabbitMQ -- our system is the only one with a formally verified crash recovery protocol.
- Framed results as trade-offs (deferred checkpoint adds re-proving cost on crash recovery)
  rather than claiming dominance.

## Next Steps

- `/review` for adversarial self-review (target 2+ review cycles)
- Update `global.md` with cross-experiment learnings
- Stage 3 adversarial testing (concurrent writers, WAL corruption injection)
