# Session Memory: Bridge L1-L2 Experiment

## Key Design Decisions

1. **Lock-Mint pattern** chosen over Shared Bridge (too complex for enterprise context)
   and LxLy Exit Trees (multi-chain overhead not needed)

2. **Keccak256 for withdraw trie** (not Poseidon) because:
   - L1 verification cost: ~48K gas (keccak256) vs ~160K gas (Poseidon without precompile)
   - Withdraw trie is separate from L2 state trie -- no hash alignment needed
   - Follows Scroll's proven architecture

3. **24h escape timeout** balances safety (gives enterprise time to recover) with liveness
   (user funds not locked indefinitely). Production bridges use 7 days (Scroll, Polygon)
   but enterprise context with single operator justifies shorter timeout.

4. **Per-enterprise bridge accounting** maintains I-23 (Enterprise Batch Isolation). Each
   enterprise's deposits and withdrawals are tracked independently.

5. **Nullifier mapping** for double-spend prevention (simpler than bitmap for low volume
   enterprise use case). Can optimize to bitmap later if volume warrants.

## Critical Integration Points

- BasisBridge reads BasisRollup.enterprises[].currentRoot for escape hatch
- BasisBridge reads BasisRollup.isExecutedRoot() not used directly -- instead checks
  withdraw root existence + batch execution counter
- Relayer must call submitWithdrawRoot() AND recordBatchExecution() after each batch
- Escape mode is per-enterprise, not global

## Open Questions for Downstream Agents

- Logicist: Model the deposit->credit->withdraw->claim lifecycle as a state machine
- Logicist: Verify NoDoubleSpend, BalanceConservation, EscapeHatchLiveness under concurrent users
- Architect: Implement withdraw trie as part of L2 node (separate from Poseidon state trie)
- Architect: Integrate relayer with pipeline orchestrator (trigger on BatchExecuted event)
- Prover: Prove balance conservation across deposit/withdrawal/escape paths

## Metrics Summary

| Metric | Value |
|--------|-------|
| Deposit gas | 61,500 |
| Withdrawal gas | 82,000 |
| Escape gas | 118,500 |
| Deposit latency (default) | 4.6s |
| Withdrawal latency (default) | 21.1s |
| Literature references | 21 |
| Invariants added | 7 (I-25 through I-31) |
| Threats added | 7 (T-25 through T-31) |
