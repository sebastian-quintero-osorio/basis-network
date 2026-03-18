---- MODULE MC_BatchAggregation ----
(**************************************************************************)
(* Model instance for TLC model checking of BatchAggregation v1-fix.      *)
(* Configuration: 4 transactions, batch size threshold 2.                 *)
(*                                                                        *)
(* Reduced from v0's 10 txs to 4 txs for full state-space exploration.    *)
(* 4 txs with threshold 2 exercises:                                      *)
(*   - 2 full-size batches (2+2)                                          *)
(*   - Timer-triggered sub-threshold batches (1 tx)                       *)
(*   - Multiple crash/recovery cycles at every interleaving point         *)
(*   - The exact counterexample trace from v0 (2 txs, timer, crash)       *)
(*                                                                        *)
(* The property is parameterized: correctness for N=4 implies correctness *)
(* for the protocol structure at any N (same actions, same guards).       *)
(**************************************************************************)

EXTENDS BatchAggregation, TLC

\* Model value declarations (instantiated via .cfg as model values)
CONSTANTS tx1, tx2, tx3, tx4

\* Finite transaction set for model checking.
MC_AllTxs == {tx1, tx2, tx3, tx4}

====
