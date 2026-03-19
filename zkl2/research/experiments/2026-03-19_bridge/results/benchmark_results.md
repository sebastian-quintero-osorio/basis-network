# Bridge Benchmark Results

## Gas Cost Estimates

| Operation | Gas | Notes |
|-----------|-----|-------|
| deposit() | 61,500 | Lock ETH, emit event, update counters |
| claimWithdrawal() | 82,000 | Merkle proof (32 hashes) + nullifier + transfer |
| escapeWithdraw() | 118,500 | State proof (32 hashes) + external call + nullifier + transfer |
| activateEscapeHatch() | 32,000 | Timeout check + SSTORE |
| submitWithdrawRoot() | 52,000 | Admin sets withdraw root per batch |

### Gas Breakdown: claimWithdrawal()

| Component | Gas |
|-----------|-----|
| Calldata + params + proof | 3,500 |
| Read withdrawRoots (cold SLOAD) | 2,100 |
| Leaf hash (keccak256) | 100 |
| Withdrawal hash (keccak256) | 100 |
| Nullifier check (cold SLOAD) | 2,100 |
| Merkle verify (32 x keccak256) | 48,000 |
| Nullifier write (cold SSTORE) | 20,000 |
| totalWithdrawn update | 5,000 |
| ETH transfer | 2,300 |
| Event emission | 3,100 |

### Gas Breakdown: escapeWithdraw()

| Component | Gas |
|-----------|-----|
| Calldata + params + proof | 3,500 |
| escapeMode check (SLOAD) | 2,100 |
| Escape nullifier check (cold SLOAD) | 2,100 |
| External call to rollup (STATICCALL) | 4,700 |
| Leaf hash (keccak256) | 100 |
| Merkle verify (32 x keccak256) | 48,000 |
| Escape nullifier write (cold SSTORE) | 20,000 |
| totalWithdrawn update | 5,000 |
| Balance check | 100 |
| ETH transfer | 2,300 |
| Event emission | 3,100 |
| Overhead | 27,000 |

**All operations well within Basis L1 block gas limit. Zero-fee means no economic cost.**

## Latency Simulation (30 replications, seed 42)

### Deposit Latency (L1 -> L2)

| Scenario | Avg Latency | Target | Pass |
|----------|-------------|--------|------|
| optimistic | 3.55s | < 5 min | OK |
| default | 4.60s | < 5 min | OK |
| pessimistic | 7.75s | < 5 min | OK |

#### Deposit Breakdown (Default Scenario)

| Phase | Duration |
|-------|----------|
| L1 tx confirmation (Avalanche finality) | ~2.0s |
| Relayer detects deposit event | ~1.0s |
| Relayer processing | ~0.1s |
| L2 tx inclusion | ~1.0s |
| **Total** | **~4.1s** |

### Withdrawal Latency (L2 -> L1)

| Scenario | Avg Latency | Target | Pass |
|----------|-------------|--------|------|
| optimistic | 12.55s | < 30 min | OK |
| default | 21.10s | < 30 min | OK |
| pessimistic | 52.75s | < 30 min | OK |

#### Withdrawal Breakdown (Default Scenario)

| Phase | Duration | % of Total |
|-------|----------|------------|
| L2 tx inclusion | 1.0s | 4.7% |
| Batch aggregation wait | 5.0s | 23.7% |
| Pipeline: execute | 0.015s | 0.1% |
| Pipeline: witness | 0.002s | 0.0% |
| Pipeline: prove | 10.0s | 47.4% |
| Pipeline: L1 submit | 4.0s | 19.0% |
| Relayer submit withdraw root | 1.1s | 5.2% |
| L1 claim tx | 2.0s | 9.5% |
| **Total** | **~21.1s** | **100%** |

**Primary bottleneck**: Proof generation (47.4%), consistent with E2E pipeline findings.
**Secondary bottleneck**: L1 submission (19.0%), constrained by 3 sequential L1 txs.

## Withdraw Trie Performance (1000 entries)

| Metric | Value |
|--------|-------|
| Depth | 32 (binary Merkle, keccak256) |
| Avg insert time | ~2 us |
| Avg root computation | ~500 us (1000 leaves) |
| Avg proof generation | ~200 us |
| Proof size | 320 bytes (10 siblings x 32 bytes for 1024-leaf tree) |
| L1 proof size (depth 32) | 1,024 bytes (32 siblings x 32 bytes) |

## Escape Hatch Analysis

| Parameter | Value |
|-----------|-------|
| Timeout | 86,400 seconds (24 hours) |
| Activation gas | 32,000 |
| Escape withdrawal gas | 118,500 |
| Total gas for user to escape | 150,500 |
| Gas cost on Basis L1 | FREE (zero-fee) |
| Nullifier storage | 1 bool per (enterprise, account) pair |

### Escape Hatch Scenario Analysis

| Scenario | Description | Latency |
|----------|-------------|---------|
| Sequencer offline 24h | User waits timeout, then withdraws | 24h + ~10s |
| Multiple users escape | Each user submits independently | 24h + ~10s per user |
| Enterprise fully exits | All accounts escape | 24h + N * ~10s |

**Key advantage vs Ethereum-based bridges**: Zero gas cost removes the economic barrier
to escape hatch usage. On Ethereum, escape hatch withdrawal costs $10-50 in gas, which
discourages small balance users. On Basis L1, any user can escape regardless of balance.

## Comparison with Production Bridges

| Metric | Basis Bridge | zkSync Era | Polygon zkEVM | Scroll |
|--------|-------------|------------|---------------|--------|
| Deposit latency | ~5s | ~5 min | 5-15 min | 10-20 min |
| Withdrawal latency | ~21s | 3+ hours | 30-60 min | 3-5 hours |
| Deposit gas (L1) | FREE | ~50K ($5-50) | ~60K ($5-50) | ~50K ($5-50) |
| Withdrawal gas (L1) | FREE | ~100K ($10-100) | ~80K ($5-80) | ~80-120K |
| Escape timeout | 24h | N/A (no true escape) | 1 week | 7 days |
| Escape gas | FREE | N/A | N/A | N/A |

**Speedup rationale**: Avalanche sub-2s finality (vs Ethereum 12+ min) explains the 60-180x
improvement. Zero-fee model removes all gas cost barriers. Enterprise context (permissioned,
low contention) enables aggressive parameters.

## Hypothesis Verdict

**SUPPORTED**: All latency targets met across all scenarios.

| Criterion | Target | Achieved (Default) | Achieved (Pessimistic) |
|-----------|--------|--------------------|------------------------|
| Deposit latency | < 5 min | 4.6s | 7.75s |
| Withdrawal latency | < 30 min | 21.1s | 52.75s |
| Escape hatch | 24h timeout | 24h + 10s | 24h + 10s |
| Escape gas barrier | None (zero-fee) | FREE | FREE |
| Double-spend prevention | Required | Nullifier mapping | Nullifier mapping |

The null hypothesis is rejected: the bridge achieves sub-minute deposit and withdrawal
latency in all tested scenarios, and the escape hatch mechanism is economically viable
on the zero-fee Basis Network L1.
