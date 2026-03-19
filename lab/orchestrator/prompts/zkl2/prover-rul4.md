Verifica la implementacion de la State Database contra su especificacion TLA+.

CONTEXTO: Target: zkl2, Fecha: 2026-03-19, Unidad: state-database

INPUTS:
1. TLA+ spec: zkl2/specs/units/2026-03-state-database/1-formalization/v0-analysis/specs/StateDatabase/StateDatabase.tla
2. Go impl: zkl2/node/statedb/ (smt.go, state_db.go, account.go, types.go)
3. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en zkl2/proofs/units/2026-03-state-database/

ENFOQUE:
- Extender RU-V1 proofs para el two-level trie model
- Probar AccountIsolation y StorageIsolation
- Probar BalanceConservation para transferencias
- Modela Go como transiciones de estado

SESSION LOG: lab/4-prover/sessions/2026-03-19_state-database.md
NO hagas commits. Comienza con /verify
