Formaliza la investigacion sobre protocolo de state commitment en TLA+.

CONTEXTO:
- Unidad: state-commitment en validium/specs/units/2026-03-state-commitment/0-input/
- Target: validium, Fecha: 2026-03-18
- TLC tools: lab/2-logicist/tools/tla2tools.jar

QUE FORMALIZAR:
- SubmitBatch(enterprise, prevRoot, newRoot, proof) como accion TLA+
- INVARIANTES:
  - ChainContinuity: newBatch.prevRoot == currentRoot[enterprise]
  - NoGap: batch IDs consecutivos por empresa
  - NoReversal: state root nunca retrocede sin rollback explicito
  - ProofBeforeState: estado solo cambia si proof es valido
- MODEL CHECK: 2 empresas, 5 batches. Simular gap attack y replay attack.

OUTPUT en validium/specs/units/2026-03-state-commitment/1-formalization/v0-analysis/

SESSION LOG: lab/2-logicist/sessions/2026-03-18_state-commitment.md
NO hagas commits. Comienza con /1-formalize
