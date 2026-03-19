---- MODULE MC_ProductionDAC ----
(**************************************************************************)
(* Model instance for TLC model checking of ProductionDAC.               *)
(* Configuration: 7 nodes (2 malicious), 5-of-7 threshold, 1 batch.     *)
(*                                                                        *)
(* This instance exercises the production (5,7) DAC configuration:        *)
(*   - Normal path: 5 honest nodes verify, attest, produce certificate    *)
(*   - Malicious attestation: n6/n7 attest validly then corrupt chunks   *)
(*   - Early corruption: n6/n7 corrupt before verification (KZG blocks)  *)
(*   - Node failure during distribution: offline nodes miss chunks        *)
(*   - Fallback when < 5 nodes receive chunks (3+ offline at distrib.)   *)
(*   - Recovery with various subsets:                                      *)
(*       * 5+ honest nodes, no corruption: success                        *)
(*       * Mixed honest + corrupted: corrupted (commitment mismatch)      *)
(*       * Sub-threshold (< 5 nodes): failed (RS underdetermined)         *)
(*   - Corruption timing: before vs after verification/attestation       *)
(*   - All interleavings of fail/recover/corrupt/verify/attest            *)
(*                                                                        *)
(* Adversarial model: 2 malicious (n6, n7) + 5 honest (n1..n5).          *)
(* This is the maximum adversary for 5-of-7: 2 = n - k = 7 - 5.         *)
(* With 5 honest nodes, the protocol can always produce a certificate    *)
(* even if both malicious nodes refuse to participate.                    *)
(*                                                                        *)
(* State space rationale:                                                  *)
(*   (5,7) is the production configuration. 2 malicious exercises the     *)
(*   adversarial boundary. 1 batch is sufficient: batches are independent *)
(*   (no shared state except nodeOnline, which is exercised via node      *)
(*   failure interleavings).                                              *)
(**************************************************************************)

EXTENDS ProductionDAC, TLC

\* Model value declarations (instantiated via .cfg as model values)
CONSTANTS n1, n2, n3, n4, n5, n6, n7, b1

\* Finite constant overrides for model checking.
MC_Nodes == {n1, n2, n3, n4, n5, n6, n7}
MC_Batches == {b1}
MC_Threshold == 5
MC_Malicious == {n6, n7}

====
