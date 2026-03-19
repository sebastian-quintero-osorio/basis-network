# Session Memory: basis-rollup

## Key Numbers

- Validium baseline: 285,756 gas (StateCommitment.sol, single-phase)
- BasisRollup first batch total: 287,773 gas (commit 150K + prove 68K + execute 70K)
- BasisRollup steady-state total: 219,626 gas (commit 116K + prove 51K + execute 53K)
- Groth16 verification: ~205,600 gas (4-pair pairing check)
- Projected total with real Groth16: 425-493K gas (under 500K target)
- Cold vs warm delta: ~68K gas (first batch costs more)
- Block range scaling: negligible (uint64 packing)
- Revert cost: 46-50K gas
- Storage per batch: ~128 bytes (3 slots: hash, stateRoot, packed metadata)
- Tests: 61/61 passing
- Invariants verified: 10 (5 from validium + 5 new rollup)

## Design Patterns

- Commit-prove-execute (zkSync Era model)
- Per-enterprise state chains (from validium)
- StoredBatchInfo with batchHash, stateRoot, l2BlockStart, l2BlockEnd, status
- Sequential proving and execution (no skipping)
- Admin revert for unexecuted batches
- MockEnterpriseRegistry via IEnterpriseRegistry interface

## Critical Observations

- Prove phase without Groth16 costs only 51-68K (just storage + counter updates)
- Three-phase separation enables async proving (sequencer commits fast, prover catches up)
- First batch margin with Groth16: only 7K gas under 500K target
- Steady-state margin with Groth16: 75K gas under 500K target
- Block-level tracking adds zero gas overhead (packed into existing slots)

## What Would Change the Recommendation

- If real Groth16 verification on Subnet-EVM costs more than ~206K (would push first batch over 500K)
- If batch range proving (aggregating multiple batches) is needed to stay under budget
- If L2->L1 message processing in execute phase adds significant gas
