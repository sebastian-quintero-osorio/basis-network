---- MODULE MC_ProductionDAC_liveness ----
(**************************************************************************)
(* Reduced model instance for liveness checking of ProductionDAC.        *)
(* Configuration: 5 nodes (2 malicious), 3-of-5 threshold, 1 batch.     *)
(*                                                                        *)
(* Rationale: Temporal property checking requires SCC analysis which      *)
(* scales superlinearly with state space. The 7-node model produces      *)
(* ~10M distinct states; this 5-node reduction produces ~100K states     *)
(* while preserving the essential protocol structure:                     *)
(*   - Same adversary ratio: 2 malicious out of n-k non-essential nodes  *)
(*   - Same honest-majority guarantee: honest nodes alone meet threshold *)
(*   - Same corruption/verification/attestation dynamics                  *)
(*                                                                        *)
(* Safety invariants are verified on the full 7-node model separately.   *)
(**************************************************************************)

EXTENDS ProductionDAC, TLC

\* Model value declarations
CONSTANTS n1, n2, n3, n4, n5, b1

\* Reduced configuration: 5 nodes, 3-of-5 threshold, 2 malicious.
MC_Nodes == {n1, n2, n3, n4, n5}
MC_Batches == {b1}
MC_Threshold == 3
MC_Malicious == {n4, n5}

====
