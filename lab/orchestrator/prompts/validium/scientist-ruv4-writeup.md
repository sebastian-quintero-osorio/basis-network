Genera el paper academico para el experimento batch-aggregation.

CONTEXTO:
- Experimento en validium/research/experiments/2026-03-18_batch-aggregation/
- Hipotesis CONFIRMADA: 274K tx/min, 0.01ms latency, 0 loss, 450/450 determinism
- HALLAZGO CRITICO: TLA+ model checking encontro un bug NoLoss que 150+ tests empiricos no detectaron. Un crash durante ZK proving (1.9-12.8s window) causa perdida silenciosa de transacciones. Fix: diferir WAL checkpoint a despues de batch processing.
- Este hallazgo es el highlight del paper -- demuestra el valor de la verificacion formal.
- El paper va en validium/research/experiments/2026-03-18_batch-aggregation/paper/

QUE HACER:
1. Lee findings.md, results/*.json
2. Escribe paper LaTeX:
   - Titulo: "Crash-Safe Batch Aggregation for Enterprise ZK Validium: A WAL-Based Approach with Formal Verification"
   - HIGHLIGHT: Section dedicada al bug NoLoss encontrado por TLA+ y no por testing
   - Tablas con benchmarks de throughput, crash recovery, determinism
   - Comparacion con Polygon Hermez, zkSync Era sequencer patterns
3. Compila PDF
4. Session log

NO hagas commits. Comienza con /writeup
