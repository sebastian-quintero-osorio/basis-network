Verifica la implementacion del protocolo de state commitment contra su especificacion TLA+.

CONTEXTO:
- Target: validium, Fecha: 2026-03-18, Unidad: state-commitment

INPUTS:
1. TLA+ spec: validium/specs/units/2026-03-state-commitment/1-formalization/v0-analysis/specs/StateCommitment/StateCommitment.tla
2. Solidity impl: l1/contracts/contracts/core/StateCommitment.sol
3. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en validium/proofs/units/2026-03-state-commitment/:
0-input-spec/, 0-input-impl/, 1-proofs/ (Common.v, Spec.v, Impl.v, Refinement.v), 2-reports/

ENFOQUE:
- Modela storage de Solidity como mappings en Coq
- Modela require/revert como precondiciones
- Probar ChainContinuity y ProofBeforeState bajo todas las transiciones

SESSION LOG: lab/4-prover/sessions/2026-03-18_state-commitment.md
NO hagas commits. Comienza con /verify
