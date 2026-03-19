Formaliza la investigacion sobre el Sequencer y Block Production en TLA+.

CONTEXTO:
- Unidad: sequencer en zkl2/specs/units/2026-03-sequencer/0-input/
- Target: zkl2, Fecha: 2026-03-19
- TLC tools: lab/2-logicist/tools/tla2tools.jar

QUE FORMALIZAR:
- Sequencer como productor de bloques con mempool y forced inclusion queue
- INVARIANTES:
  - Inclusion: toda tx valida eventualmente se incluye en un bloque
  - ForcedInclusion: tx submitted a L1 se incluye en L2 dentro de T bloques
  - Ordering: txs dentro de un bloque respetan ordering deterministico (FIFO)
- MODEL CHECK: 5 txs, 2 forced txs, 3 bloques

OUTPUT en zkl2/specs/units/2026-03-sequencer/1-formalization/v0-analysis/

SESSION LOG: lab/2-logicist/sessions/2026-03-19_sequencer.md
NO hagas commits. Comienza con /1-formalize
