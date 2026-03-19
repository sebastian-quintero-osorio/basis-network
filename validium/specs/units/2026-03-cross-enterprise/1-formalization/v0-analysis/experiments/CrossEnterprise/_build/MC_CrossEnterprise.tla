---- MODULE MC_CrossEnterprise ----
(**************************************************************************)
(* Model instance for TLC model checking of CrossEnterprise.              *)
(* Configuration: 2 enterprises, 2 batches each, 3 state roots.          *)
(* State constraint: at most 1 active cross-reference at a time.          *)
(* Matches user requirement: "2 empresas, 2 batches, 1 referencia cruzada"*)
(**************************************************************************)

EXTENDS CrossEnterprise, TLC

\* Model value declarations (instantiated via .cfg as model values)
CONSTANTS E1, E2, B1, B2, R0, R1, R2

\* Finite sets for model checking
MC_Enterprises == {E1, E2}
MC_BatchIds == {B1, B2}
MC_StateRoots == {R0, R1, R2}

\* State constraint: limit to at most 1 active (non-"none") cross-reference.
\* Reduces state space to match the "1 cross-reference" requirement while
\* still allowing TLC to explore all possible cross-reference combinations.
MC_Constraint ==
    Cardinality({ref \in CrossRefIds : crossRefStatus[ref] # "none"}) <= 1

====
