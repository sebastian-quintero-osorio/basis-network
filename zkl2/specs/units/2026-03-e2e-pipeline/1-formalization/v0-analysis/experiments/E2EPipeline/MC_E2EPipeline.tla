---- MODULE MC_E2EPipeline ----

(***************************************************************************)
(* Model instance for E2E Pipeline specification.                          *)
(*                                                                         *)
(* Finite constants:                                                       *)
(*   - 3 batches: sufficient to expose interleaving and ordering bugs      *)
(*     across concurrent pipeline executions.                              *)
(*   - MaxRetries = 3: yields 4 total attempts per stage (initial + 3),    *)
(*     matching production retry policy. State space: each batch has        *)
(*     retry counts 0..3 at each stage.                                    *)
(*                                                                         *)
(* Expected state space (upper bound):                                     *)
(*   Per batch: ~22 reachable states (7 stages * retry/artifact combos)    *)
(*   3 batches with symmetry: ~22^3 / 6 = ~1,775 distinct states          *)
(*   Actual reachable states will be smaller due to guard constraints.     *)
(***************************************************************************)

EXTENDS E2EPipeline, TLC

\* Model values for batch identifiers
CONSTANTS b1, b2, b3

\* Finite constant definitions
MC_Batches == {b1, b2, b3}
MC_MaxRetries == 3

\* Symmetry set: batches are interchangeable (reduces state space by 3! = 6)
MC_Symmetry == Permutations(MC_Batches)

====
