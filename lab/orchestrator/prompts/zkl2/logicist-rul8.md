Formaliza la Production DAC con erasure coding en TLA+. Extiende Validium RU-V6.

CONTEXTO:
- Unidad: production-dac en zkl2/specs/units/2026-03-production-dac/0-input/
- Referencia: validium/specs/units/2026-03-data-availability/ (DataAvailability.tla)
- Target: zkl2, Fecha: 2026-03-19
- TLC tools: lab/2-logicist/tools/tla2tools.jar

QUE FORMALIZAR:
- Extender RU-V6 para (5,7) committee con erasure coding
- INVARIANTES:
  - DataRecoverability: datos recuperables de cualquier 5 de 7 nodos
  - AttestationLiveness: attestation completa si >= 5 nodos online
  - ErasureSoundness: shares corruptos detectados por commitment check
- MODEL CHECK: 7 nodos, 2 maliciosos, 1 offline

OUTPUT en zkl2/specs/units/2026-03-production-dac/1-formalization/v0-analysis/

SESSION LOG: lab/2-logicist/sessions/2026-03-19_production-dac.md
NO hagas commits. Comienza con /1-formalize
