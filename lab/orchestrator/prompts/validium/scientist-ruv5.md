Investiga patrones de arquitectura para un nodo validium empresarial que orquesta el ciclo completo de procesamiento.

HIPOTESIS: Un servicio Node.js event-driven que orquesta el ciclo (receive -> state update -> batch -> prove -> submit) puede procesar end-to-end un batch de 64 transacciones en < 90 segundos (60s proving + 30s overhead), con zero data leakage, crash recovery sin perdida de estado, y API REST/WebSocket para integracion con PLASMA y Trace.

CONTEXTO:
- Ya tenemos TODOS los componentes implementados y verificados:
  - SparseMerkleTree (validium/node/src/state/) -- RU-V1 VERIFIED
  - state_transition.circom (validium/circuits/circuits/) -- RU-V2 VERIFIED
  - TransactionQueue + BatchAggregator (validium/node/src/queue/ y src/batch/) -- RU-V4 VERIFIED
  - DACProtocol + Shamir (validium/node/src/da/) -- RU-V6 VERIFIED
  - StateCommitment.sol (l1/contracts/contracts/core/) -- RU-V3 VERIFIED
  - PLASMAAdapter + TraceAdapter (validium/adapters/src/)
- Necesitamos el servicio que integra todo
- Target: validium (MVP), Fecha: 2026-03-18

TAREAS:

1. CREAR ESTRUCTURA: validium/research/experiments/2026-03-18_enterprise-node/

2. LITERATURE REVIEW:
   - Polygon Hermez node proving orchestration
   - zkSync Era sequencer lifecycle
   - Event loop y state machine design para nodos blockchain
   - REST API patterns para enterprise integration

3. CODIGO EXPERIMENTAL:
   - Prototipo de state machine (TypeScript)
   - Estados: Idle, Receiving, Batching, Proving, Submitting, Error
   - Definir API contract para PLASMA/Trace
   - Benchmark end-to-end latency

4. SESSION LOG: lab/1-scientist/sessions/2026-03-18_enterprise-node.md

NO hagas commits. Comienza con /experiment
