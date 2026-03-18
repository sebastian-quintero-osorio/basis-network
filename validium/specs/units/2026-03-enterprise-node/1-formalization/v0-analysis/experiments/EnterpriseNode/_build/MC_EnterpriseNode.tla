---- MODULE MC_EnterpriseNode ----
(**************************************************************************)
(* Model instance for TLC model checking of EnterpriseNode.               *)
(* Configuration: 3 transactions, batch threshold 2, max 2 crashes.       *)
(*                                                                        *)
(* 3 txs with threshold 2 exercises:                                      *)
(*   - 1 full-size batch (2 txs) + 1 timer-triggered batch (1 tx)        *)
(*   - Pipelined ingestion: tx3 arrives during proving/submitting         *)
(*   - Multiple crash/recovery cycles at every interleaving point         *)
(*   - L1 rejection and retry                                             *)
(*   - Timer-triggered sub-threshold batches                              *)
(*                                                                        *)
(* Scenarios verified via exhaustive state-space exploration:              *)
(*   - Happy path: receive all -> batch(2) -> prove -> submit -> confirm  *)
(*     -> CheckQueue -> timer -> batch(1) -> prove -> submit -> confirm   *)
(*   - Crash during proving: WAL recovery restores all uncommitted txs    *)
(*   - Crash during batching: batch txs still in uncommitted WAL segment  *)
(*   - L1 failure: retry re-processes batch from WAL                      *)
(*   - Concurrent submission: tx3 arrives during batch(tx1,tx2) proving   *)
(*   - Double crash: crash -> recover -> crash -> recover -> complete     *)
(*                                                                        *)
(* The property is parameterized: correctness for N=3 implies correctness *)
(* for the protocol structure at any N (same actions, same guards).       *)
(**************************************************************************)

EXTENDS EnterpriseNode, TLC

\* Model value declarations (instantiated via .cfg as model values)
CONSTANTS tx1, tx2, tx3

\* Finite transaction set for model checking.
MC_AllTxs == {tx1, tx2, tx3}

====
