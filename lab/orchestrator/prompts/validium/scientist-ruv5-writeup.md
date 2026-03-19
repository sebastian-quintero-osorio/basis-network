Genera el paper academico para el experimento enterprise-node.

CONTEXTO:
- Experimento en validium/research/experiments/2026-03-18_enterprise-node/
- State machine: 6 estados, 17 transiciones, pipelined architecture
- Orchestration overhead: 593ms (0.66% del budget). Proving = 85%+ de latencia.
- Pipeline speedup: 1.29x. Fastify over Express (2-4x throughput).
- 20 referencias, comparison con Polygon Hermez, zkSync Era, push0/Zircuit
- El paper va en validium/research/experiments/2026-03-18_enterprise-node/paper/

QUE HACER:
1. Lee findings.md (540 lineas), benchmark results, experimental code (orchestrator.ts, state-machine.ts)
2. Escribe paper LaTeX:
   - Titulo: "Enterprise Node Orchestration for ZK Validium: Pipelined State Machine Design and Performance Analysis"
   - State machine diagram, transition table, pipeline architecture
   - Benchmarks de overhead, pipeline speedup, E2E latency
3. Compila PDF
4. Session log

NO hagas commits. Comienza con /writeup
