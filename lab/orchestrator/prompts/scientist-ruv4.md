Investiga sistemas de cola de transacciones y agregacion de batches para un nodo validium empresarial.

HIPOTESIS: Un sistema de cola con ordering cronologico y batch aggregation configurable puede mantener throughput de 100+ tx/min con latencia de formacion de batch < 5s, garantizando zero perdida de transacciones bajo crash recovery, y produciendo batches deterministicos (mismas transacciones -> mismo batch).

CONTEXTO:
- Ya tenemos un TransactionQueue basico en validium/adapters/src/common/queue.ts con retry y exponential backoff, pero NO tiene persistencia ni crash recovery
- Ya tenemos un SparseMerkleTree en validium/node/src/state/ (RU-V1 completo)
- Ya tenemos un circuito state_transition.circom en validium/circuits/circuits/ (RU-V2 completo)
- El batch formation debe producir inputs para el circuito de transicion de estado
- Target: validium (MVP), Fecha: 2026-03-18

TAREAS:

1. CREAR ESTRUCTURA: validium/research/experiments/2026-03-18_batch-aggregation/
   - hypothesis.json, state.json, journal.md, findings.md, code/, results/, memory/session.md

2. LITERATURE REVIEW:
   - Persistent queues: write-ahead logs, crash recovery strategies
   - Batch formation strategies: time-based, size-based, hybrid
   - Ordering guarantees: causal, total, FIFO
   - Reference: Polygon Hermez batch aggregation, zkSync Era sequencer
   - Benchmark: throughput under load, behavior under crash

3. CODIGO EXPERIMENTAL:
   - TypeScript prototype de TransactionQueue con persistencia (file-based WAL)
   - BatchAggregator con thresholds configurables (size, time, hybrid)
   - Benchmark script: throughput, latency, crash recovery simulation
   - Debe integrar con el SMT conceptualmente (cada tx modifica el tree)

4. EJECUTAR BENCHMARKS: throughput, latency, crash recovery

5. SESSION LOG: lab/1-scientist/sessions/2026-03-18_batch-aggregation.md

NO hagas commits. Comienza con /experiment
