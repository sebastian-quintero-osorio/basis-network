# Experiment Journal: Batch Aggregation (RU-V4)

> Target: validium | Domain: l2-architecture

## 2026-03-18 -- Iteration 1: Implementation

### Orientation

Target: validium | Stage: 1 (Implementation) | Iteration: 1 | Best metric: N/A (first run)
Action: draft
Rationale: New experiment -- implementing persistent queue with WAL and batch aggregator from scratch.

### Context

Existing infrastructure:
- `validium/adapters/src/common/queue.ts`: Basic FIFO queue with retry/backoff, NO persistence, NO batching
- `validium/node/src/state/sparse-merkle-tree.ts`: Production SMT (Poseidon, depth 32, verified)
- `validium/circuits/circuits/state_transition.circom`: Batch state transition circuit (RU-V2, verified)

The batch aggregation system sits between transaction ingestion and proof generation:
```
Enterprise Tx -> [TransactionQueue + WAL] -> [BatchAggregator] -> [BatchBuilder] -> Circuit Input
```

### Literature Review Summary

See findings.md for full details. Key takeaways:
- Write-ahead logging is the standard approach for crash-safe queues (PostgreSQL, RocksDB, Kafka)
- Production L2 sequencers (Polygon Hermez, zkSync Era) use hybrid batch formation (size OR time threshold)
- Deterministic ordering requires total order on transaction timestamps + tie-breaking
- WAL fsync latency on SSD: 50-200 us per entry (sequential writes)
- Production batch sizes: 100-2000 tx per batch, formation time 1-15 seconds

### Design Decisions

1. **WAL format**: Append-only file with JSON-lines format. Each entry: `{seq, timestamp, tx, checksum}`.
   Simple, human-readable, easy to debug. Binary format unnecessary at MVP scale (<10K tx/min).

2. **Batch formation**: Three strategies implemented:
   - SIZE: Form batch when queue reaches N transactions
   - TIME: Form batch every T milliseconds regardless of queue size
   - HYBRID: Form batch on whichever threshold triggers first (size OR time)

3. **Ordering**: Strictly chronological (FIFO by arrival timestamp). Ties broken by sequence number.
   This guarantees determinism: same transactions in same order -> same batch.

4. **Crash recovery**: On startup, replay WAL from last checkpoint. Checkpoint = batch committed.
   Only truncate WAL entries after batch is fully processed.

5. **Determinism contract**: Batch ID = SHA-256(sorted tx hashes). Same transactions -> same batch ID.
   Transaction ordering within batch is by arrival timestamp (stable sort).

### What Would Change My Mind?

- If WAL fsync latency exceeds 1ms consistently, the 5s batch formation target becomes tight
  with many individual transactions (>5000 per batch). Would need group commit.
- If non-determinism arises from floating-point timestamps, would need monotonic integer clock.
- If crash recovery replay takes >10s for reasonable WAL sizes, would need more frequent checkpointing.
