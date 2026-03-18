# RU-V5: Enterprise Node Orchestrator -- Experiment Journal

## 2026-03-18 -- Iteration 1: Architecture Research and Prototype

### What I did
1. Conducted literature review across 20 sources covering ZK node architectures
   (Polygon, zkSync, Scroll, push0/Zircuit), proving orchestration patterns,
   event-driven state machine design, and crash recovery strategies.
2. Compiled component latencies from all prior RU experiments (V1, V2, V3, V4, V6)
   to estimate end-to-end latency.
3. Designed the node state machine with 6 states and pipelined execution model.
4. Defined REST/WebSocket API contract for PLASMA/Trace integration.
5. Wrote experimental code: state machine prototype with TypeScript.

### Key findings
- Orchestration overhead is negligible (~5-15ms) compared to proving time (12s+).
- The bottleneck is exclusively ZK proof generation.
- Batch 64 at depth 32 with snarkjs exceeds 60s. Must use rapidsnark or reduce batch.
- All production ZK nodes use a pipelined model: ingestion runs concurrently with proving.
- push0 (deployed on Zircuit since March 2025) demonstrates that event-driven
  orchestration with crash recovery achieves 0 task loss and 0.5s MTTR.
- Fastify is the recommended HTTP framework (2-4x faster than Express, native WS).

### What would change my mind?
- If orchestration overhead is >1s (unlikely based on push0 benchmarks).
- If SMT serialization for checkpoint exceeds 5s (memory issue at scale).
- If concurrent enterprise access creates state corruption (need to verify single-writer).
- If ethers.js L1 submission has unpredictable latency spikes on Avalanche Fuji.

### Decisions
- Use pipelined architecture (not sequential) based on zkSync/push0 evidence.
- Use Fastify (not Express) for API layer based on performance data.
- Mock components for Stage 1 to isolate orchestration overhead measurement.
- Single-writer SMT model to prevent concurrent access races.

### Next steps
- Run benchmarks on the prototype to measure orchestration overhead.
- If overhead < 100ms, proceed to Stage 2 with real components.
