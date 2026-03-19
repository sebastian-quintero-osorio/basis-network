Implementa la especificacion verificada de cola de transacciones y agregacion de batches.

SAFETY LATCH: El TLC log v1-fix en validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/experiments/BatchAggregation/MC_BatchAggregation.log muestra PASS. Procede.

CONTEXTO:
- TLA+ spec (CORREGIDA): validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla
- CRITICO: La v0 tenia un bug (NoLoss violation). La v1-fix corrige el checkpoint timing -- checkpoint DESPUES de ProcessBatch, no durante FormBatch.
- Codigo de referencia del Scientist: validium/specs/units/2026-03-batch-aggregation/0-input/code/src/
- Destino: validium/node/src/queue/ y validium/node/src/batch/

QUE IMPLEMENTAR:

1. validium/node/src/queue/transaction-queue.ts:
   - Persistent queue con Write-Ahead Log (file-based)
   - enqueue(tx), dequeue(), peek(), size()
   - WAL: append-only log, checkpoint AFTER batch processing (not formation!)
   - Crash recovery: replay WAL from last checkpoint

2. validium/node/src/queue/wal.ts:
   - Write-Ahead Log implementation
   - append(entry), checkpoint(sequenceNumber), recover()
   - File-based with fsync for durability

3. validium/node/src/batch/batch-aggregator.ts:
   - Configurable thresholds: maxBatchSize, maxWaitTimeMs
   - Hybrid trigger: size OR time
   - formBatch(): pulls from queue, returns batch
   - FIFO ordering with sequence tiebreaker

4. validium/node/src/batch/batch-builder.ts:
   - Constructs ZK circuit input from batch
   - Integrates with SparseMerkleTree (from src/state/)

5. validium/node/src/queue/types.ts y validium/node/src/batch/types.ts

6. Tests en validium/node/src/queue/__tests__/ y src/batch/__tests__/:
   - Enqueue/dequeue correctness
   - Crash recovery (WAL replay)
   - Batch formation (size trigger, time trigger, hybrid)
   - Determinism (same txs -> same batch)
   - Concurrent enqueue
   - Boundary: 0, 1, max, max+1 transactions
   - Adversarial: corrupt WAL, out-of-order, duplicate tx

7. ADVERSARIAL-REPORT.md en validium/tests/adversarial/batch-aggregation/

8. Session log: lab/3-architect/sessions/2026-03-18_batch-aggregation.md

IMPORTANTE: El package.json de validium/node/ ya existe (de RU-V1). Agrega dependencias si necesitas.

NO hagas commits. Comienza con /implement
