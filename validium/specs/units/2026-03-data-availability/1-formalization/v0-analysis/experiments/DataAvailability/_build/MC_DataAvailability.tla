---- MODULE MC_DataAvailability ----
(**************************************************************************)
(* Model instance for TLC model checking of DataAvailability.             *)
(* Configuration: 3 nodes (1 malicious), 2-of-3 threshold, 1 batch.      *)
(*                                                                        *)
(* This instance exercises:                                                *)
(*   - Normal attestation path (2 honest nodes reach threshold)            *)
(*   - Malicious node behavior (valid attestation, corrupted recovery)     *)
(*   - Node failure during attestation (1 node crash, 2 still attest)     *)
(*   - Node failure during distribution (offline node misses shares)       *)
(*   - Fallback when < 2 nodes receive shares (2+ offline at distrib.)    *)
(*   - Recovery with various subsets:                                      *)
(*       * All honest: success                                             *)
(*       * Mixed honest+malicious: corrupted (detected via commitment)     *)
(*       * Sub-threshold (single node): failed (privacy guarantee)         *)
(*                                                                        *)
(* State space rationale:                                                  *)
(*   (2,3) is the minimum non-trivial threshold configuration.             *)
(*   1 malicious + 2 honest exercises the adversarial boundary.            *)
(*   1 batch is sufficient: batches are independent (no shared state       *)
(*   except nodeOnline, which is exercised via node failure interleavings).*)
(**************************************************************************)

EXTENDS DataAvailability, TLC

\* Model value declarations (instantiated via .cfg as model values)
CONSTANTS n1, n2, n3, b1

\* Finite constant overrides for model checking.
MC_Nodes == {n1, n2, n3}
MC_Batches == {b1}
MC_Threshold == 2
MC_Malicious == {n3}

====
