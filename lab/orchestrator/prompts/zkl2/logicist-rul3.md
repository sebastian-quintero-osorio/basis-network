Formaliza la investigacion sobre Witness Generation en TLA+.

CONTEXTO:
- Unidad: witness-generation en zkl2/specs/units/2026-03-witness-generation/0-input/
- Target: zkl2, Fecha: 2026-03-19
- TLC tools: lab/2-logicist/tools/tla2tools.jar

QUE FORMALIZAR:
- WitnessExtract(trace) -> witness como funcion
- INVARIANTES:
  - Completeness: witness contiene toda la informacion necesaria para proof generation
  - Soundness: witness invalido produce proof invalido (no false positive)
  - Determinism: mismo trace siempre produce mismo witness
- MODEL CHECK: 3 operaciones (arithmetic, storage, call), 2 transacciones

OUTPUT en zkl2/specs/units/2026-03-witness-generation/1-formalization/v0-analysis/

SESSION LOG: lab/2-logicist/sessions/2026-03-19_witness-generation.md
NO hagas commits. Comienza con /1-formalize
