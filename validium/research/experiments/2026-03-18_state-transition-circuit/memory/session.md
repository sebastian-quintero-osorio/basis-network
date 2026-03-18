# Session Memory -- State Transition Circuit (RU-V2)

## Key Decisions

- Target: validium (MVP)
- Depends on: RU-V1 (Sparse Merkle Tree) -- CONFIRMED hypothesis
- SMT implementation: depth 32, Poseidon hash, BN128 field
- Existing batch_verifier.circom: 742 constraints, batch 4, no state transitions
- Circuit design: ChainedBatchStateTransition using MerklePathVerifier + Poseidon leaf hashing
- Did NOT use circomlib SMTProcessor (too complex for PoC; update-only is sufficient for MVP)

## Verified Constraint Formula

```
constraints_per_tx = 1,038 * (depth + 1)
total_constraints = constraints_per_tx * batchSize + ~3
```

This is EXACT across all 7 benchmark configurations.

## Key Numbers (from measurements)

- Poseidon(2) in circom: 240 constraints (confirmed)
- MerklePathVerifier per level: ~519 constraints (Poseidon + 2*Mux1 + routing)
- Per-tx at depth 32: 34,254 constraints
- Per-tx at depth 20: 21,798 constraints
- Proof size (Groth16): 803-807 bytes (constant regardless of circuit size)
- Verification time: ~2-3 seconds (snarkjs, constant)

## Proving Time Scaling (snarkjs, commodity desktop)

- ~65 us/constraint average
- 45K constraints: ~3.4s
- 137K constraints: ~6.9s
- 274K constraints: ~12.8s

## Hypothesis Outcome

- 100K constraint target: REJECTED for batch 64 (needs 2.2M)
- 60s proving time: CONFIRMED with rapidsnark (~14-35s estimated for 2.2M constraints)
- snarkjs proving time for batch 64: ~142s (REJECTED, 2.4x over target)

## Production Recommendation

- Use rapidsnark (C++) for production, snarkjs for dev/test only
- Depth 20 for MVP (1M+ key capacity, ~36% fewer constraints)
- Depth 32 for production (4B+ key capacity)
- Batch 64 is feasible but large; consider batch 16-32 as MVP starting point
