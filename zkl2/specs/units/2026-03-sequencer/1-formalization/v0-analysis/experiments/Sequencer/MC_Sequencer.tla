---- MODULE MC_Sequencer ----
(***************************************************************************)
(* Model checking instance for Sequencer specification.                    *)
(* Parameters: 5 regular txs, 2 forced txs, 3 blocks, capacity 3/block.   *)
(* Forced inclusion deadline: 2 blocks.                                    *)
(***************************************************************************)

EXTENDS Sequencer, TLC

\* Model values for regular transactions
CONSTANTS t1, t2, t3, t4, t5

\* Model values for forced transactions
CONSTANTS f1, f2

\* Finite constant assignments
MC_Txs == {t1, t2, t3, t4, t5}
MC_ForcedTxs == {f1, f2}
MC_MaxTxPerBlock == 3
MC_MaxBlocks == 3
MC_ForcedDeadlineBlocks == 2

====
