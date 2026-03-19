# Session Memory: Sequencer Experiment (RU-L2)

## Key Decisions

- Target: zkl2 (RU-L2 in roadmap)
- Language: Go (aligns with TD-001, Geth ecosystem)
- Scope: sequencer module between JSON-RPC and EVM executor
- Verdict: CONFIRMED

## Architecture Context

- EVM executor already built in zkl2/node/executor/ (Go, 1740 LOC)
- Sequencer feeds transactions to executor, receives execution traces
- Traces then go to batch builder -> witness generator -> prover pipeline
- Per-enterprise chains (TD-005): each enterprise runs own sequencer

## Design Choices Made

- Single-operator sequencer (all production ZK-rollups use this)
- FIFO ordering via simple slice queue (no priority heap -- zero-fee model)
- Arbitrum-style forced inclusion: FIFO queue, 24h deadline, L1 contract
- 1-second block time (matches zkSync Era, ~7100x headroom at 500 TPS)
- Block gas limit 10M (configurable)
- Forced transactions get priority in block assembly (included first)
- HYBRID batch strategy for downstream (validated in RU-V4)

## Constraints Discovered

- Zero-fee model eliminates MEV and priority ordering
- FIFO is the natural ordering strategy for enterprise
- Forced inclusion is the ONLY censorship resistance mechanism
- Block gas limit still needed for execution bounds
- Windows timer resolution (~15ms) affects sub-millisecond measurements
- Go installed as zip (not MSI) at /c/Users/BASSEE/go-sdk/go/

## Performance Boundaries

- Block production: 0.14ms at 500 tx/block (NOT including EVM execution)
- Mempool insert: 365 ns/op single-thread, 33K tx/s concurrent (4 goroutines)
- Mempool memory: 168 bytes/insert
- Full pipeline latency (seq + exec + prove) NOT measured here -- see RU-L6

## Invariants Established

- I-09: Transaction Inclusion
- I-10: Forced Inclusion Guarantee
- I-11: FIFO Transaction Ordering
- I-12: Block Production Liveness

## Threats Identified

- T-11: Sequencer Liveness Failure
- T-12: Mempool Overflow Under Burst Load
- T-13: Forced Inclusion State Manipulation

## Downstream Handoff

The Logicist should formalize:
1. Sequencer as state machine: Idle -> CollectTx -> BuildBlock -> SealBlock
2. Mempool as FIFO queue with capacity
3. Forced inclusion queue with deadline and FIFO enforcement
4. Invariants: Inclusion, ForcedInclusion, Ordering
5. Model check parameters: 5 txs, 2 forced txs, 3 blocks
