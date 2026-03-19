Verifica la implementacion de la cola de transacciones y agregacion de batches contra su especificacion TLA+.

CONTEXTO:
- Target: validium, Fecha: 2026-03-18, Unidad: batch-aggregation

INPUTS:
1. TLA+ spec (v1-fix): validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla
2. TypeScript impl: validium/node/src/queue/ y validium/node/src/batch/
3. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en validium/proofs/units/2026-03-batch-aggregation/:
```
0-input-spec/    -- Copiar BatchAggregation.tla (v1-fix)
0-input-impl/    -- Copiar transaction-queue.ts, wal.ts, batch-aggregator.ts, batch-builder.ts
1-proofs/Common.v, Spec.v, Impl.v, Refinement.v
2-reports/verification.log, SUMMARY.md
```

ENFOQUE:
- Spec.v: cola como secuencia, batch como subsecuencia
- Impl.v: modelo de la implementacion con WAL y checkpoint
- Refinement.v: probar NoLoss y Determinism bajo crash recovery
- Modela WAL como secuencia con checkpoint pointer

SESSION LOG: lab/4-prover/sessions/2026-03-18_batch-aggregation.md
NO hagas commits. Comienza con /verify
