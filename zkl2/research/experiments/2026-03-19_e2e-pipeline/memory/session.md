# Session Memory: E2E Pipeline Experiment

## Key Decisions

1. **JSON over stdin/stdout for Go-Rust boundary**: Chosen over gRPC/FFI because witness
   generation is 1.5ms; serialization overhead is negligible. Simplicity wins.

2. **Simulated proving times calibrated from Polygon/gnark/snarkjs**: 5s base + 50ms/tx
   default scenario. Conservative relative to gnark's 2M constraints/s on BN254.

3. **Retry policy: 5 retries, exponential backoff 1s->30s**: Achieves 100% reliability
   even at 30% failure injection rate. Dead-letter queue for exhausted retries.

4. **Pipeline parallelism concurrency=2**: Sweet spot of 2.42x speedup without excessive
   memory. Prover saturation is the goal.

## Critical Findings

- Proof generation is 71.3% of E2E time (primary optimization target)
- Execute + witness combined is <0.2% (not bottlenecks at all)
- L1 submission is 28.5% (constrained by Avalanche finality, not our code)
- Max batch under 5min: 5,791 tx (default), 2,761 tx (pessimistic)
- All scenarios pass the 100-tx < 5min target with massive margin (14s default)

## Benchmark Reconciliation Status

No divergence >10x from published benchmarks. Our estimates are conservative because
enterprise circuits are simpler than full zkEVM (500 constraints/tx vs millions).

## Next Steps for Stage 3

- Adversarial scenarios: prover crash mid-proof, L1 reorg during submit, witness
  corruption, concurrent batch state conflicts
- Fault injection: sustained failure periods, cascading failures, resource exhaustion
