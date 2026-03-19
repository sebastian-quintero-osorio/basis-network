Verifica la implementacion del Sequencer contra su especificacion TLA+.

CONTEXTO: Target: zkl2, Fecha: 2026-03-19, Unidad: sequencer

INPUTS:
1. TLA+ spec: zkl2/specs/units/2026-03-sequencer/1-formalization/v0-analysis/specs/Sequencer/Sequencer.tla
2. Go impl: zkl2/node/sequencer/ (sequencer.go, mempool.go, forced_inclusion.go, block_builder.go, types.go)
3. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en zkl2/proofs/units/2026-03-sequencer/

ENFOQUE:
- Probar Inclusion: toda tx valida eventualmente en un bloque
- Probar ForcedInclusion: txs forzadas incluidas dentro del deadline
- Probar NoDoubleInclusion
- Modela goroutines como transiciones de estado (no concurrencia real en Coq)

SESSION LOG: lab/4-prover/sessions/2026-03-19_sequencer.md
NO hagas commits. Comienza con /verify
