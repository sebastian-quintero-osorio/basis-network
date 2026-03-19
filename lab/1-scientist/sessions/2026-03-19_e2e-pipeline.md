# Session Log: E2E Pipeline Research

- **Date**: 2026-03-19
- **Target**: zkl2
- **Research Unit**: RU-L6 (E2E Pipeline)
- **Experiment**: 2026-03-19_e2e-pipeline
- **Stage**: 1 (Implementation) -> 2 (Baseline)

## What Was Accomplished

### Literature Review (19 references)

Surveyed production E2E proving pipelines across 5 major systems:

1. **push0/Zircuit** (arxiv 2602.16338): Event-driven orchestrator, 5ms P50 overhead,
   99-100% scaling at 32 dispatchers, 14M+ blocks processed. Key insight: stateless
   dispatchers over persistent queues with partition-affine routing.

2. **Polygon CDK**: Two-stage proving (range + aggregation), 500 tx in <120s on
   224-thread GCP, 84s with FPGA. Aggregator batches hundreds of transactions.

3. **zkSync Era**: Boojum prover, Merkle tree is bottleneck (2.44s/batch), 10-20 min
   hard finality, >15K TPS with Atlas upgrade.

4. **Scroll**: Three-level proof hierarchy (chunk -> batch -> bundle), Ceno + OpenVM
   for GPU-native proving, reducing latency and cost.

5. **Taiko**: Multi-proof (ZK + SGX) for speed/security tradeoff, gradually transitioning
   from SGX to full ZK.

### Go Pipeline Orchestrator Prototype

Implemented a full pipeline orchestrator in Go with:
- State machine: Pending -> Executed -> Witnessed -> Proved -> Submitted -> Finalized
- Exponential backoff retry policy (5 retries, 1s-30s backoff)
- Pipeline parallelism (configurable concurrency)
- Per-stage metrics and timing
- JSON IPC for Go-Rust witness generation boundary
- Pluggable stage executors (real or simulated)

Files: `code/pipeline/types.go`, `orchestrator.go`, `stages_sim.go`, `benchmark_test.go`

### Benchmark Suite (Python)

Ran calibrated simulations across 3 scenarios x 7 batch sizes with 30 replications for
stochastic analysis:

**Key Result**: 100-tx batch E2E = 14.0s (default), 33.0s (pessimistic) -- well under
the 5-minute target.

## Key Findings

| Metric | Value |
|--------|-------|
| 100-tx E2E (default) | 14.0 s |
| 100-tx E2E (optimistic) | 8.0 s |
| 100-tx E2E (pessimistic) | 33.0 s |
| Pipeline bottleneck | Prove (71.3% of total) |
| Retry success rate (30% failure) | 100% |
| Max batch under 5min (default) | 5,791 tx |
| Pipeline parallelism (2x) speedup | 2.42x |

## Artifacts Produced

| Path | Description |
|------|-------------|
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/hypothesis.json` | Hypothesis definition |
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/state.json` | Current state (stage 2) |
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/findings.md` | Complete findings with 19 refs |
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/journal.md` | Experiment journal |
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/code/pipeline/types.go` | Pipeline types |
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/code/pipeline/orchestrator.go` | Orchestrator |
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/code/pipeline/stages_sim.go` | Simulated stages |
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/code/pipeline/benchmark_test.go` | Go benchmarks |
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/code/benchmark.py` | Python benchmark |
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/results/benchmark_results.json` | Results data |
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/results/bottleneck_analysis.json` | Bottleneck data |
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/results/retry_analysis.json` | Retry data |
| `zkl2/research/experiments/2026-03-19_e2e-pipeline/results/parallelism_analysis.json` | Parallelism data |

## Decisions Made

1. **JSON IPC over gRPC/FFI for Go-Rust**: Witness gen is 1.5ms; serialization overhead
   is negligible. Simplicity over marginal latency.
2. **Event-driven architecture (push0 pattern)**: Stateless dispatchers decouple scheduling
   from proving, enabling prover-agnostic orchestration.
3. **Concurrency=2 default**: Balances prover utilization (near 100%) with memory overhead.
4. **Conservative timing calibration**: Our estimates are 4-5x faster than Polygon for
   equivalent batch sizes because enterprise circuits are fundamentally simpler.

## Next Steps

1. **Logicist**: Formalize pipeline state machine in TLA+ with invariants:
   - PipelineIntegrity: every finalized batch has valid proof on L1
   - Liveness: pending batches eventually finalize
   - Atomicity: partial failure does not corrupt state
   - RetryBoundedness: retries are bounded by policy
2. **Architect**: Implement production orchestrator in `zkl2/node/pipeline/`
3. **Prover**: Verify pipeline correctness properties in Coq
