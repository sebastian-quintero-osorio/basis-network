Verifica BasisRollup.sol contra su TLA+ spec.

CONTEXTO: Target: zkl2, Fecha: 2026-03-19, Unidad: basis-rollup

INPUTS:
1. TLA+ spec: zkl2/specs/units/2026-03-basis-rollup/.../specs/BasisRollup/BasisRollup.tla
2. Solidity impl: zkl2/contracts/contracts/BasisRollup.sol
3. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en zkl2/proofs/units/2026-03-basis-rollup/

ENFOQUE:
- Probar BatchChainContinuity y ProveBeforeExecute
- Modela Solidity storage como mappings, require/revert como precondiciones
- Commit-prove-execute lifecycle correctness

SESSION LOG: lab/4-prover/sessions/2026-03-19_basis-rollup.md
NO hagas commits. Comienza con /verify
