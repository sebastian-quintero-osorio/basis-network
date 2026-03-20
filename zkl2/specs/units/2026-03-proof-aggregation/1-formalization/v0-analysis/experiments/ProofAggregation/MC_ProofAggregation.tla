---- MODULE MC_ProofAggregation ----

EXTENDS ProofAggregation

\* ============================================================================
\*  Model Instance: Finite Constants for Exhaustive State-Space Exploration
\* ============================================================================
\*
\* Configuration rationale:
\*   - 3 enterprises: covers multi-enterprise aggregation, partial aggregation
\*     (2 of 3), and cross-enterprise independence scenarios.
\*   - 2 proofs per enterprise: allows one valid + one invalid per enterprise,
\*     testing mixed-validity aggregation and duplicate rejection.
\*   - BaseGasPerProof = 420000: halo2-KZG individual verification cost.
\*     [Source: 0-input/REPORT.md, Section 2.1 -- halo2-KZG ~420K gas]
\*   - AggregatedGasCost = 220000: Groth16 decider cost after folding.
\*     [Source: 0-input/REPORT.md, Section 3.1 -- Nova fold + Groth16 decider ~220K]
\*
\* Scenarios this configuration exhaustively covers:
\*   1. Invalid proof at any position: enterprise generates invalid proof,
\*      it gets aggregated with valid proofs, aggregation is rejected at L1.
\*   2. Duplicate submission attempt: enterprise submits same proof twice,
\*      second submission is blocked by SubmitToPool guard.
\*   3. Partial aggregation: only 2 of 3 enterprises' proofs aggregated,
\*      third enterprise excluded. Verifies independence.
\*   4. L1 verification: aggregated proof submitted to L1, accepted or rejected
\*      based on component validity.
\*   5. Recovery from rejection: valid proofs recovered from rejected
\*      aggregation, re-aggregated without invalid proof.
\*   6. Mixed validity: valid and invalid proofs from different enterprises
\*      co-exist in the aggregation pool.
\*
\* State space estimate: with 6 proof IDs (3 enterprises * 2 proofs),
\* the power set enumeration in AggregateSubset has at most 2^6 = 64
\* subsets per state, tractable for exhaustive search.
\* ============================================================================

MC_Enterprises == {"e1", "e2", "e3"}
MC_MaxProofsPerEnt == 2
MC_BaseGasPerProof == 420000
MC_AggregatedGasCost == 220000

====
