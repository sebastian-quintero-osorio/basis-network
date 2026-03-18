---- MODULE MC_StateCommitment ----
(*
 * Model instance for TLC model checking of StateCommitment.
 *
 * Finite parameter choices:
 *   - 2 enterprises: sufficient for cross-enterprise isolation testing
 *   - MaxBatches = 5: matches the research unit requirement
 *   - 4 roots: enough for 5 batch transitions per enterprise without
 *     forcing artificial constraints, while allowing root cycling
 *     (which tests the NoReversal property under pressure)
 *   - None = model value: sentinel distinct from all roots
 *
 * Attack coverage:
 *   - Gap attack: TLC explores all interleavings of InitializeEnterprise
 *     and SubmitBatch across both enterprises. The structural auto-increment
 *     of batchCount means no interleaving can skip a batch ID. NoGap
 *     invariant verified across the full state space.
 *   - Replay attack: TLC generates SubmitBatch with all combinations of
 *     (prevRoot, newRoot, proofIsValid). After a successful batch, the
 *     ChainContinuity guard blocks replay of the same prevRoot because
 *     currentRoot has advanced. Verified across all state interleavings.
 *)

EXTENDS StateCommitment

MC_Enterprises == {"e1", "e2"}
MC_MaxBatches == 5
MC_Roots == {"r1", "r2", "r3", "r4"}
MC_None == "none"

====
