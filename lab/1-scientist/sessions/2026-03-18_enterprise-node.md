# Session Log: RU-V5 Scientist -- Enterprise Node Orchestrator

- **Date:** 2026-03-18
- **Target:** validium (MVP)
- **Experiment:** 2026-03-18_enterprise-node
- **Stage:** 1 (Implementation) -- COMPLETE
- **Research Unit:** RU-V5 (Item [21] in ROADMAP_CHECKLIST)

## What Was Accomplished

1. **Literature review** (20 sources, exceeding 15 minimum):
   - Polygon zkEVM node architecture (Sequencer + Aggregator + zkProver)
   - zkSync Era server (Sequencer + Batcher + Prover, idempotent recovery)
   - Scroll coordinator (Blocks -> Chunks -> Batches, random prover assignment)
   - push0/Zircuit orchestration (NATS message bus, 0.5s MTTR, 0 task loss)
   - Prover comparison: snarkjs vs rapidsnark vs ICICLE-Snark
   - Node.js patterns: graceful shutdown, WAL, event-driven state machines
   - Fastify vs Express performance (2-4x throughput advantage)

2. **State machine design** (6 states, 17 transitions):
   - Idle, Receiving, Batching, Proving, Submitting, Error
   - Pipelined: accepts transactions during Proving and Submitting
   - Full transition table with guards, validated by 46 tests

3. **API contract definition**:
   - REST: POST /v1/transactions, GET /v1/status, GET /v1/batches/:id
   - WebSocket: tx:accepted, batch:proving, batch:confirmed events
   - Transaction format for PLASMA/Trace integration

4. **Experimental benchmarks**:
   - Orchestration overhead: 593 ms per batch (0.66% of 90s budget)
   - Batch formation: 11.4 ms (state machine + SMT inserts for 8 txs)
   - Pipeline speedup: 1.29x at batch 64 with rapidsnark
   - Target E2E: 14.6s (pipelined, b64, rapidsnark) -- well under 90s

5. **Foundation updates**:
   - 6 new invariants (INV-NO1 through INV-NO6) added to zk-01
   - 4 new properties (PROP-NO1 through PROP-NO4) added to zk-01
   - 6 new attack vectors (ATK-NO1 through ATK-NO6) added to zk-02
   - 4 new open questions (OQ-15 through OQ-18) added to zk-01

## Key Findings

- **Proving is the sole bottleneck**: 85%+ of E2E latency is proof generation.
  Orchestration overhead is negligible (<1% of budget).
- **snarkjs cannot handle batch 64**: ~150s proving time at d32. Must use
  rapidsnark (8-15s) or reduce to batch 16 (28s) for MVP.
- **Pipelined architecture is justified**: 1.29x speedup at b64, increasing
  with batch size as preparation time grows.
- **push0 validates the approach**: Production system on Zircuit since March 2025,
  0 task loss, 0.5s crash recovery.

## Artifacts Produced

| Artifact | Path |
|----------|------|
| hypothesis.json | validium/research/experiments/2026-03-18_enterprise-node/hypothesis.json |
| state.json | validium/research/experiments/2026-03-18_enterprise-node/state.json |
| findings.md | validium/research/experiments/2026-03-18_enterprise-node/findings.md |
| journal.md | validium/research/experiments/2026-03-18_enterprise-node/journal.md |
| State machine (TypeScript) | .../code/src/state-machine.ts |
| Orchestrator (TypeScript) | .../code/src/orchestrator.ts |
| Types (TypeScript) | .../code/src/types.ts |
| Orchestrator benchmark | .../code/src/benchmark.ts |
| Pipeline benchmark | .../code/src/benchmark-pipeline.ts |
| State machine tests | .../code/src/test-state-machine.ts |
| Pipeline results | .../results/benchmark-pipeline.json |
| Updated invariants | validium/research/foundations/zk-01-objectives-and-invariants.md |
| Updated threat model | validium/research/foundations/zk-02-threat-model.md |

## Next Steps

1. **Logicist (Item [22])**: Formalize the node state machine in TLA+.
   States, transitions, crash recovery, concurrent enterprise access.
   Key invariants: INV-NO1 (Liveness), INV-NO2 (Safety), INV-NO4 (Crash Recovery).
2. **Architect (Item [23])**: Implement the full service integrating all components.
   Use the experimental code as reference. Fastify server, real SMT, snarkjs/rapidsnark.
3. **Prover (Item [24])**: Verify Safety and Liveness properties in Coq.
