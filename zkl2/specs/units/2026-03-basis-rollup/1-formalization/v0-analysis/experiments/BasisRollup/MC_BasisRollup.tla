---- MODULE MC_BasisRollup ----
(*
 * Model instance for TLC model checking of BasisRollup.
 *
 * Finite parameter choices:
 *   - 2 enterprises: sufficient for cross-enterprise isolation testing
 *     and interleaving coverage (e1 commits while e2 proves, etc.)
 *   - MaxBatches = 3: per user requirement. Exposes ordering bugs across
 *     commit-prove-execute phases while keeping state space tractable.
 *     3 batches * 4 statuses * 2 enterprises = rich interleaving space.
 *   - 3 roots: allows distinct roots per batch without forcing reuse,
 *     while testing the case where two batches share a root.
 *   - None = "none": sentinel distinct from all roots.
 *
 * Attack coverage:
 *   - Out-of-order execution: TLC explores all interleavings of CommitBatch,
 *     ProveBatch, ExecuteBatch across both enterprises. The sequential counter
 *     guards prevent any batch from being proved or executed out of order.
 *   - Proof bypass: proofIsValid = FALSE is generated for ProveBatch but blocked
 *     by the guard. TLC confirms no state change occurs without a valid proof.
 *   - Revert of executed: RevertBatch is attempted on all enterprises in all
 *     states. TLC confirms executed batches are never reverted.
 *   - Cross-enterprise isolation: interleaved operations on e1 and e2 confirm
 *     that actions on one enterprise never affect the other's state.
 *   - Double transition: TLC confirms no batch transitions Committed->Executed
 *     (skipping Proven) or None->Proven (skipping Committed).
 *)

EXTENDS BasisRollup

MC_Enterprises == {"e1", "e2"}
MC_MaxBatches == 3
MC_Roots == {"r1", "r2", "r3"}
MC_None == "none"

====
