Formaliza la investigacion sobre cola de transacciones y agregacion de batches en TLA+.

CONTEXTO:
- Unidad: batch-aggregation
- Materiales en validium/specs/units/2026-03-batch-aggregation/0-input/
- Target: validium, Fecha: 2026-03-18
- TLC tools: lab/2-logicist/tools/tla2tools.jar

QUE FORMALIZAR:
1. Enqueue(tx) -- encolar una transaccion
2. FormBatch() -- formar un batch cuando se alcanza el threshold (size o time)
3. ProcessBatch() -- procesar un batch formado

INVARIANTES:
- NoLoss: toda tx enqueued eventualmente aparece en un batch
- Determinism: mismo set de txs produce mismo batch
- Ordering: txs en batch respetan orden de llegada (FIFO)
- Completeness: batch formation se dispara cuando threshold se alcanza

MODEL CHECK: 10 txs, batch size 4. Simula crash despues de enqueue pero antes de batch formation.

OUTPUT en validium/specs/units/2026-03-batch-aggregation/1-formalization/v0-analysis/:
- specs/BatchAggregation/BatchAggregation.tla
- experiments/BatchAggregation/MC_BatchAggregation.tla, .cfg, .log
- PHASE-1-FORMALIZATION_NOTES.md
- PHASE-2-AUDIT_REPORT.md

SESSION LOG: lab/2-logicist/sessions/2026-03-18_batch-aggregation.md
NO hagas commits. Comienza con /1-formalize
