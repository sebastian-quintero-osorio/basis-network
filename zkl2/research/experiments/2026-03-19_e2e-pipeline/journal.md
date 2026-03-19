# Experiment Journal: E2E Pipeline

## 2026-03-19 -- Iteration 1: Setup and Literature Review

### Context

Research Unit L6 (E2E Pipeline) connects all Phase 1-2 components into a unified
pipeline. This is the integration layer that makes the zkEVM L2 operational.

### Existing Components (all verified)

| Component | Location | Language | Key Metric |
|-----------|----------|----------|------------|
| Sequencer | zkl2/node/sequencer/ | Go | 500 tx/block, 1s interval |
| EVM Executor | zkl2/node/executor/ | Go | 4K-12K tx/s, deterministic traces |
| StateDB | zkl2/node/statedb/ | Go | Poseidon2 SMT, 125us/insert |
| Witness Generator | zkl2/prover/witness/ | Rust | 1000 tx in 13.37ms |
| BasisRollup.sol | zkl2/contracts/ | Solidity | 287K gas/batch, Groth16 verify |

### Key Design Questions

1. **Go-Rust boundary**: How to efficiently pass execution traces from Go executor
   to Rust witness generator? Options: gRPC, FFI (cgo+Rust), JSON over stdin/stdout,
   shared memory.
2. **Proof generation**: The actual ZK proving step (Groth16/PLONK) is the expected
   bottleneck. Need to benchmark realistic proving times.
3. **Pipeline parallelism**: Can we overlap execution of batch N+1 with proving of
   batch N?
4. **Retry semantics**: What failures are retryable? What requires rollback?
5. **State consistency**: How to maintain atomicity across the pipeline stages?

### What would change my mind?

If proof generation for 100 transactions exceeds 10 minutes even with parallelism,
the 5-minute E2E target is infeasible and we need recursive proof composition or
hardware acceleration (GPU proving).

## 2026-03-19 -- Iteration 1: Results

### Design Decisions

1. **Go-Rust boundary**: JSON over stdin/stdout. Witness gen is 1.5ms for 100 tx;
   serialization overhead (<1ms) is negligible. Simplicity over marginal latency.
   gRPC adds 5ms overhead and operational complexity for no measurable benefit at
   this scale.

2. **Pipeline architecture**: Event-driven dispatcher-collector pattern (informed by
   push0, arxiv 2602.16338). Stateless dispatchers enable horizontal scaling.
   Persistent message queues provide exactly-once delivery with downstream dedup.

3. **Retry policy**: 5 retries with exponential backoff (1s -> 2s -> 4s -> 8s -> 16s).
   Dead-letter queue for exhausted retries. 100% success rate at 30% failure injection.

4. **Pipeline parallelism**: Concurrency=2 as default. While batch N proves, batch N+1
   executes + witnesses. 2.42x speedup; prover near-fully utilized.

### Benchmark Results

100-tx batch E2E (default scenario): 14.0 seconds
- Execute:  15ms  (0.1%)
- Witness:  1.5ms (0.0%)
- Prove:    10.0s (71.3%) <-- BOTTLENECK
- Submit:   4.0s  (28.5%)

All 3 scenarios (optimistic/default/pessimistic) pass the 5-minute target.
Even the pessimistic scenario (33s) is 9x under the limit.

### Benchmark Reconciliation

No divergence >10x from published benchmarks.
- Our 100-tx prove time (10s) vs Polygon 500-tx prove time (<120s): consistent
  because our enterprise circuit is 4-5x simpler (500 constr/tx vs millions).
- Our orchestration overhead (~5ms) matches push0's 5.2ms P50.
- L1 submit time (4s for 3 Avalanche txs) is consistent with sub-second finality.

### Anti-Confirmation Bias Check

Seeking disconfirming evidence:
- The 100-tx target is too easy. Even pessimistic = 33s. This is because enterprise
  circuits are fundamentally simpler than zkEVM circuits.
- The REAL test will be when actual Groth16 proving is integrated (not simulated).
  The simulation uses published benchmarks, but actual performance depends on circuit
  design (RU-L7 and beyond).
- L1 submission depends on Avalanche network conditions; 8s pessimistic may be
  optimistic during congestion events.

### What would change my mind now?

- If the actual circuit (post RU-L7) exceeds 100K constraints per tx instead of
  our estimated 500, proving times would scale 200x and the bottleneck analysis
  would be fundamentally different.
- If Avalanche L1 has sustained congestion >30s per tx, the L1 submission stage
  would become the bottleneck instead of proving.
