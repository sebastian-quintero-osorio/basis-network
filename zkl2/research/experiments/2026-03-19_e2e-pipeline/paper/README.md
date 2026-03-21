# Paper Status: RU-L6 End-to-End Pipeline

No academic paper was generated for this experiment.

## Reason

This research unit is an integration architecture exercise that connects the five
previously-researched components (executor, sequencer, state database, witness generator,
BasisRollup contract) into a coherent pipeline. The findings document latency breakdowns,
bottleneck identification, and parallelism opportunities, but the contribution is
architectural orchestration rather than novel research.

The experimental results -- 4 benchmark JSON files covering latency, bottlenecks,
parallelism, and retry analysis -- are fully documented in `findings.md` and `results/`.

## Where to find the research

- `findings.md` -- Pipeline architecture, latency breakdown, bottleneck analysis
- `results/benchmark_results.json` -- E2E latency measurements
- `results/bottleneck_analysis.json` -- Component-level bottleneck identification
- `results/parallelism_analysis.json` -- Concurrent batch proving opportunities
- `results/retry_analysis.json` -- Failure recovery and retry strategies
- `code/` -- Go pipeline orchestrator prototype

## Related papers

- BNR-2026-008 (EVM Executor) -- pipeline stage 1
- BNR-2026-009 (Sequencer) -- pipeline stage 0 (block production)
- BNR-2026-010 (State Database) -- pipeline state backend
- BNR-2026-011 (Witness Generation) -- pipeline stage 2
- BNR-2026-014 (Proof Aggregation) -- pipeline stage 4 (multi-enterprise)
