---- MODULE MC_PlonkMigration ----

EXTENDS PlonkMigration

\* ============================================================================
\*  Model Instance: Finite Constants for Exhaustive State-Space Exploration
\* ============================================================================
\*
\* Configuration rationale:
\*   - 3 enterprises: exposes cross-enterprise isolation bugs and tests that
\*     per-enterprise queue invariants hold across multiple enterprises.
\*   - 2 batches per enterprise: allows 1 Groth16 + 1 PLONK per enterprise,
\*     testing interleaving of both proof systems during migration transitions.
\*   - MaxMigrationSteps=2: bounds the dual period, exercises tick mechanism.
\*   - ProofSystems = {"groth16", "plonk"}: the two systems under migration.
\*
\* Scenarios this configuration exhaustively covers:
\*   1. Submit during transition: enterprise submits while phase changes
\*   2. Batch without proof during migration: batch queued, not yet verified
\*   3. Groth16 proof after cutover: Groth16 batch submitted in plonk_only phase
\*   4. Rollback: failure detected during dual, revert to groth16_only
\*   5. Mixed queues: Groth16 and PLONK batches interleaved in same queue
\*   6. Cross-enterprise isolation: one enterprise's batches do not affect another's
\*
\* Verification result:
\*   9,117,756 states generated, 3,985,171 distinct states, depth 22.
\*   All 9 invariants PASS. Completed in 37 seconds (4 workers).
\*
\* Scaling note:
\*   Configuration (3 enterprises, 4 batches, steps=3) produces 183M+ states
\*   in 10 minutes with queue still growing -- intractable for exhaustive search.
\*   This configuration covers all required scenarios at tractable scale.
\* ============================================================================

MC_Enterprises == {"e1", "e2", "e3"}
MC_MaxBatches == 2
MC_ProofSystems == {"groth16", "plonk"}
MC_MaxMigrationSteps == 2

====
