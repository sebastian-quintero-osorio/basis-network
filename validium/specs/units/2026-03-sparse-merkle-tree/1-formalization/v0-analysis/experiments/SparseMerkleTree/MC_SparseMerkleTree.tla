---- MODULE MC_SparseMerkleTree ----
(* ================================================================ *)
(* Model Checking Instance for SparseMerkleTree                     *)
(* ================================================================ *)
(*                                                                  *)
(* Finite parameter set for exhaustive state-space exploration.     *)
(*                                                                  *)
(* Configuration:                                                   *)
(*   DEPTH  = 4   (16 possible leaves, sufficient for path-bit     *)
(*                  coverage across all 4 bit positions)            *)
(*   Keys   = {0, 2, 5, 7, 9, 12, 14, 15}                         *)
(*                 (8 keys spread across tree for maximum subtree   *)
(*                  diversity -- exercises both left and right       *)
(*                  branches at every level)                        *)
(*   Values = {1, 2, 3}                                            *)
(*                 (3 non-zero values -- sufficient to distinguish  *)
(*                  overwrite from insert and expose hash chain     *)
(*                  divergence)                                     *)
(*                                                                  *)
(* State space: 4^8 = 65,536 reachable states                      *)
(*   (3 non-zero values + EMPTY, across 8 key positions)           *)
(*                                                                  *)
(* Invariant checks per state:                                      *)
(*   TypeOK              -- type correctness                        *)
(*   ConsistencyInvariant -- WalkUp agrees with ComputeRoot         *)
(*   SoundnessInvariant  -- wrong value => verification fails       *)
(*                          (16 positions x 4 value candidates)     *)
(*   CompletenessInvariant -- correct value => verification passes  *)
(*                          (16 positions)                          *)
(* ================================================================ *)

EXTENDS SparseMerkleTree

MC_DEPTH == 4

MC_Keys == {0, 2, 5, 7, 9, 12, 14, 15}

MC_Values == {1, 2, 3}

====
