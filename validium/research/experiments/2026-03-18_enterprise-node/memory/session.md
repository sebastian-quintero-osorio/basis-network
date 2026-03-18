# Session Memory: Enterprise Node Orchestrator

## Architecture Decisions
- Pipelined state machine with 3 concurrent loops (ingestion, batching, proving/submission)
- Fastify + @fastify/websocket for API (not Express)
- Single-writer SMT model (batch loop owns the tree)
- WAL-based crash recovery reusing RU-V4 infrastructure
- Child process for ZK proving (decoupled from event loop)

## Key Numbers
- Orchestration overhead target: <100ms (push0 achieves 5ms)
- Proving bottleneck: 12.8s (snarkjs, d32, b8), ~120-180s (snarkjs, d32, b64)
- Rapidsnark estimate: 8-15s for d32, b64 (4-10x faster)
- SMT insert: 1.8ms/tx, WAL write: 149us/tx, batch formation: 0.02ms
- DAC attestation: 163ms (JS), <10ms (native)
- L1 submission: ~2s estimated (Avalanche Fuji finality)

## Open Questions
- Actual rapidsnark performance on target hardware?
- SMT checkpoint serialization time at 100K+ entries?
- Avalanche Fuji L1 submission latency distribution?
- Multi-enterprise concurrent access patterns?
