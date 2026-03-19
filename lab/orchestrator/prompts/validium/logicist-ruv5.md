Formaliza la investigacion sobre el nodo validium empresarial en TLA+.

CONTEXTO:
- Unidad: enterprise-node en validium/specs/units/2026-03-enterprise-node/0-input/
- Target: validium, Fecha: 2026-03-18
- TLC tools: lab/2-logicist/tools/tla2tools.jar

QUE FORMALIZAR:
- State machine COMPLETA: Idle, Receiving, Batching, Proving, Submitting, Error
- Transiciones y recovery paths
- INVARIANTES:
  - Liveness: si hay txs pendientes, eventualmente se prueba un batch
  - Safety: nunca se envia un proof sin el state root correcto
  - Privacy: ningun dato privado sale del nodo excepto proof + public signals
- MODEL CHECK: happy path, crash durante proving, fallo L1, concurrent submissions

OUTPUT en validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/

SESSION LOG: lab/2-logicist/sessions/2026-03-18_enterprise-node.md
NO hagas commits. Comienza con /1-formalize
