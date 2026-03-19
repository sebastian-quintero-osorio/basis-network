Verifica la implementacion del circuito de transicion de estado contra su especificacion TLA+.

CONTEXTO:
- Target: validium (MVP), Fecha: 2026-03-18
- Unidad: state-transition-circuit

INPUTS:
1. TLA+ spec: validium/specs/units/2026-03-state-transition-circuit/1-formalization/v0-analysis/specs/StateTransitionCircuit/StateTransitionCircuit.tla
2. TLC log: validium/specs/units/2026-03-state-transition-circuit/1-formalization/v0-analysis/experiments/StateTransitionCircuit/MC_StateTransitionCircuit.log (PASS)
3. Circom implementation: validium/circuits/circuits/state_transition.circom
4. Helper: validium/circuits/circuits/merkle_proof_verifier.circom

ESTRUCTURA DE OUTPUT en validium/proofs/units/2026-03-state-transition-circuit/:
```
0-input-spec/     -- Copiar StateTransitionCircuit.tla
0-input-impl/     -- Copiar state_transition.circom, merkle_proof_verifier.circom
1-proofs/
  Common.v        -- Reutilizar de RU-V1 (validium/proofs/units/2026-03-sparse-merkle-tree/1-proofs/Common.v)
  Spec.v          -- Modelo del constraint system como ecuaciones sobre campo finito
  Impl.v          -- Modelo del circuito Circom (signals como elementos del campo BN128)
  Refinement.v    -- Prueba de que cada constraint es necesario y suficiente
2-reports/
  verification.log
  SUMMARY.md
```

ENFOQUE:
- Modela signals como elementos de Z modulo p (campo BN128)
- Modela constraints como ecuaciones algebraicas
- Prueba StateRootChain: que la cadena de raices es correcta
- Prueba ProofSoundness: que un proof invalido siempre es rechazado
- Reutiliza Common.v de RU-V1

HERRAMIENTAS:
- Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc
- Compilar en orden: Common.v -> Spec.v -> Impl.v -> Refinement.v

SESSION LOG: lab/4-prover/sessions/2026-03-18_state-transition-circuit.md
NO hagas commits de git.

Comienza con /verify
