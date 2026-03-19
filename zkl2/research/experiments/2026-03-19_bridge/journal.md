# Journal: L1-L2 Bridge Design for Enterprise zkEVM

## 2026-03-19 -- Experiment Creation

### Context

RU-L7 is the first component in Phase 3 (Bridge and Data Availability). It depends on:
- RU-L5 (BasisRollup.sol) -- COMPLETE: 3-phase commit-prove-execute lifecycle, 12 TLA+ invariants
- RU-L6 (E2E Pipeline) -- COMPLETE: 14s default latency for 100-tx batch

The bridge must integrate with BasisRollup.sol's batch finality model. Withdrawals can only
be finalized after the batch containing the withdrawal transaction has been executed on L1.

### Key Design Constraints

1. Zero-fee L1 (gas price 0 on Basis Network Avalanche L1)
2. Single-operator sequencer per enterprise (enterprise-operated)
3. Per-enterprise state chains on L1 (each enterprise has independent state root)
4. Avalanche sub-second finality for L1 transactions
5. evmVersion: cancun (no Pectra)
6. Bridge must support escape hatch for censorship resistance

### Hypothesis

A bridge can process deposits (L1->L2) in < 5 minutes and withdrawals (L2->L1) in < 30
minutes, with an escape hatch that allows withdrawal via Merkle proof directly on L1 if
the sequencer is offline for > 24 hours.

### What Would Change My Mind?

- If escape hatch Merkle proofs require > 1M gas to verify on L1
- If double-spend prevention requires complex nullifier schemes that exceed gas budget
- If the 24-hour timeout for escape hatch is insufficient for enterprise recovery scenarios
- If production bridges show that even simpler designs have critical vulnerabilities
