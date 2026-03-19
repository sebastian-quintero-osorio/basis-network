Formaliza BasisRollup.sol en TLA+. Extiende Validium RU-V3 para el modelo L2 completo.

CONTEXTO:
- Unidad: basis-rollup en zkl2/specs/units/2026-03-basis-rollup/0-input/
- Target: zkl2, Fecha: 2026-03-19
- TLC tools: lab/2-logicist/tools/tla2tools.jar
- Referencia: validium/specs/units/2026-03-state-commitment/ (StateCommitment.tla)

QUE FORMALIZAR:
- Commit-prove-execute batch lifecycle
- INVARIANTES:
  - BatchChainContinuity: prevRoot matches committed batch
  - ProveBeforeExecute: proof required before execution
  - ExecuteInOrder: batches execute sequentially
  - RevertSafety: revert restores previous valid state
- MODEL CHECK: 2 enterprises, 3 batches, commit-prove-execute lifecycle

OUTPUT en zkl2/specs/units/2026-03-basis-rollup/1-formalization/v0-analysis/

SESSION LOG: lab/2-logicist/sessions/2026-03-19_basis-rollup.md
NO hagas commits. Comienza con /1-formalize
