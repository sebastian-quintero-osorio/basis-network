# Session Memory: Batch Aggregation (RU-V4)

## Key Decisions

1. HYBRID batch formation chosen over SIZE-only or TIME-only (matches all production ZK-rollups).
2. JSON-lines WAL format (human-readable, sufficient at MVP scale).
3. Group commit (fsync per WAL batch) rather than per-entry fsync for throughput.
4. FIFO ordering with sequence number tie-breaking for determinism.
5. Checkpoint-based crash recovery (truncate WAL after batch commit).

## Integration Points

- Each transaction modifies SMT (conceptually -- benchmark uses simulated state updates)
- Batch output must be compatible with state_transition.circom inputs
- Batch size must match circuit batch size parameter (4, 8, 16, 32, 64)

## Known Constraints

- WAL fsync: ~880us per entry (SSD), ~5-15ms (RabbitMQ observed)
- Circuit constraint formula: 1,038 * (depth + 1) * batchSize
- Circuit depth: 32 (production), 10 (fast testing)
- Prior experiment results in global.md and RU-V2 findings

## Benchmarks to Beat

- 100+ tx/min throughput (hypothesis target)
- <5s batch formation latency (hypothesis target)
- 0 transaction loss under crash (hypothesis target)
- Production reference: zkSync Era 15K TPS, Polygon 190-200s prove/batch
