---- MODULE MC_BatchAggregation ----
(**************************************************************************)
(* Model instance for TLC model checking of BatchAggregation.             *)
(* Configuration: 10 transactions, batch size threshold 4.                *)
(* Expected behaviors: up to 3 batches (4+4+2 with time trigger for tail) *)
(* Crash scenario: system can crash at any point, including after batch   *)
(* formation but before processing.                                       *)
(**************************************************************************)

EXTENDS BatchAggregation, TLC

\* Model value declarations (instantiated via .cfg as model values)
CONSTANTS tx1, tx2, tx3, tx4, tx5, tx6, tx7, tx8, tx9, tx10

\* Finite transaction set for model checking.
MC_AllTxs == {tx1, tx2, tx3, tx4, tx5, tx6, tx7, tx8, tx9, tx10}

\* NOTE: Symmetry reduction via Permutations(MC_AllTxs) is theoretically safe
\* (no invariant depends on specific tx identity), but computing Permutations
\* for 10 elements (10! = 3.6M) exceeds TLC 2.16 startup capacity.
\* Omitted. BFS finds the counterexample at depth 5 regardless.

====
