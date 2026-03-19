Formaliza la investigacion sobre Data Availability Committee en TLA+.

CONTEXTO:
- Unidad: data-availability en validium/specs/units/2026-03-data-availability/0-input/
- Target: validium, Fecha: 2026-03-18
- TLC tools: lab/2-logicist/tools/tla2tools.jar

QUE FORMALIZAR:
- DAC como conjunto de 3 nodos con protocolo de attestation
- Shamir (2,3) Secret Sharing para privacidad
- INVARIANTES:
  - DataAvailability: si 2/3 nodos atestan, los datos son recuperables
  - Privacy: ningun nodo individual puede reconstruir datos completos
  - Liveness: attestation se completa si >= 2 nodos estan online
- MODEL CHECK: 3 nodos. Simular: 1 nodo caido, 1 nodo malicioso

OUTPUT en validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/:
- specs/DataAvailability/DataAvailability.tla
- experiments/DataAvailability/MC_DataAvailability.tla, .cfg, .log
- PHASE-1-FORMALIZATION_NOTES.md, PHASE-2-AUDIT_REPORT.md

SESSION LOG: lab/2-logicist/sessions/2026-03-18_data-availability.md
NO hagas commits. Comienza con /1-formalize
