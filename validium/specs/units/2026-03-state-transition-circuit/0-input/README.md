# RU-V2: State Transition Circuit -- Logicist Input

## Context

This unit contains experimental results from the Scientist's investigation of ZK state
transition circuits for the Basis Network enterprise validium node.

The circuit proves state transitions (prevStateRoot -> newStateRoot) for batches of
transactions, verifying Merkle proof integrity and state root chain consistency.

## Key Results

7 benchmarks across depth 10/20/32 x batch 4/8/16:

| Config | Constraints | Proving Time |
|--------|-----------|-------------|
| d10, b4 | 45,671 | 3.4s |
| d10, b8 | 91,339 | 5.1s |
| d10, b16 | 182,675 | 8.0s |
| d20, b4 | 87,191 | 8.7s |
| d20, b8 | 174,379 | 13.6s |
| d32, b4 | 137,015 | 6.9s |
| d32, b8 | 274,027 | 12.8s |

Constraint scaling: ~34K per transaction at depth 32. Linear with batch size.
Recommended MVP: batch 16 at depth 32 (~548K constraints, ~26s proving).

## Objectives for Formalization

1. Formalize StateTransition(prevRoot, newRoot, txBatch) as TLA+ action
2. Invariants:
   - StateRootChain: newRoot = deterministic function of prevRoot + txBatch
   - BatchIntegrity: each tx has valid Merkle proof against intermediate state
   - ProofSoundness: invalid proof always rejected
3. Model check with 3 enterprises, batch size 4, 3 state roots, depth 3

## Materials

- REPORT.md -- Full findings with literature review and benchmarks
- code/state_transition_verifier.circom -- Working Circom circuit
- code/generate_input.js -- Witness generation script
- results/benchmark_*.json -- All benchmark data
