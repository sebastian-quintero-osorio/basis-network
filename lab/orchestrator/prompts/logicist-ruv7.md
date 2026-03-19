Formaliza la investigacion sobre verificacion cross-enterprise en TLA+.

CONTEXTO:
- Unidad: cross-enterprise en validium/specs/units/2026-03-cross-enterprise/0-input/
- Target: validium, Fecha: 2026-03-18
- TLC tools: lab/2-logicist/tools/tla2tools.jar

QUE FORMALIZAR:
- CrossEnterpriseVerification como accion que toma proofs de 2+ empresas
- INVARIANTES:
  - Isolation: proof de empresa A no revela info de empresa B
  - Consistency: referencia cruzada valida solo si ambos proofs son validos
- MODEL CHECK: 2 empresas, 2 batches cada una, 1 referencia cruzada

OUTPUT en validium/specs/units/2026-03-cross-enterprise/1-formalization/v0-analysis/

SESSION LOG: lab/2-logicist/sessions/2026-03-18_cross-enterprise.md
NO hagas commits. Comienza con /1-formalize
