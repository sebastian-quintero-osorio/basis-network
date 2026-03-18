# Session Memory -- State Commitment Protocol (RU-V3)

## Key Decisions

- **Layout A (Minimal)** selected: roots in mapping, metadata in events. 285K gas total.
- **Integrated verification** required to stay under 300K. Delegating to ZKVerifier adds ~56K gas.
- **Single-phase submission** (unlike zkSync's 3-phase or Polygon's 2-phase) because enterprise
  validium has a trusted operator and no need for challenge periods.
- **prevRoot == currentRoot** check is both necessary and sufficient for chain continuity,
  gap detection, and reversal prevention. No explicit batch ID parameter needed.

## Gas Breakdown (Layout A, First Batch)

- Total: 285,756 gas
- ZK verification: 205,600 (72%)
- Storage + logic: 80,156 (28%)
- Margin to 300K: 14,244 gas

## Storage Breakdown (Layout A)

- Per enterprise (one-time): EnterpriseState struct = 2 slots = 64 bytes
- Per batch (incremental): batchRoots mapping = 1 slot = 32 bytes
- Event per batch: ~200 bytes (in receipts, not state)

## Patterns to Remember

- SSTORE 0->nonzero costs 22,100 gas (cold). This is the dominant per-batch storage cost.
- Cold vs warm access patterns cause ~17K gas difference between first and steady-state batches.
- Event logs are ~10x cheaper than storage for the same data (8 gas/byte vs 22,100/32 bytes).
- Production rollups use 64-96 bytes per batch. Our 32 bytes is more efficient.

## What Would Change the Recommendation

- If additional features (DAC attestation check, admin pause) push Layout A over 300K,
  consider Layout C (events only) at 263K which has 37K margin.
- If Avalanche nodes prune event logs, Layout A's reliance on events for metadata becomes
  problematic. Would need to upgrade to Layout B (rich) and accept ~306K first-batch gas.
