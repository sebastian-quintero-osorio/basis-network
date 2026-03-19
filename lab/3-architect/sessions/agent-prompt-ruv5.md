Implementa la especificacion verificada del nodo validium empresarial.

SAFETY LATCH: TLC log en validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/experiments/EnterpriseNode/MC_EnterpriseNode.log muestra PASS. Procede.

CONTEXTO:
- TLA+ spec: validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/specs/EnterpriseNode/EnterpriseNode.tla
- Todos los componentes ya implementados en validium/node/src/:
  - state/ (SparseMerkleTree -- RU-V1)
  - queue/ (TransactionQueue, WAL -- RU-V4)
  - batch/ (BatchAggregator, BatchBuilder -- RU-V4)
  - da/ (Shamir, DACNode, DACProtocol -- RU-V6)
- Circuito: validium/circuits/circuits/state_transition.circom (RU-V2)
- L1 contract: l1/contracts/contracts/core/StateCommitment.sol (RU-V3)
- Destino: validium/node/

QUE IMPLEMENTAR (el servicio que integra todo):

1. validium/node/src/index.ts: Entry point
   - Fastify server (REST API)
   - State machine from TLA+ (Idle, Receiving, Batching, Proving, Submitting, Error)
   - Connects all modules: SMT, Queue, Aggregator, Prover wrapper, L1 Submitter

2. validium/node/src/prover/zk-prover.ts:
   - Wrapper sobre snarkjs para generar Groth16 proofs
   - Input: batch (from BatchBuilder)
   - Output: proof + publicSignals

3. validium/node/src/submitter/l1-submitter.ts:
   - ethers.js v6 integration
   - Submits proof to StateCommitment.sol
   - Retry con exponential backoff

4. REST API:
   - POST /v1/transactions -- recibe eventos de PLASMA/Trace
   - GET /v1/status -- health check + estado del nodo
   - GET /v1/batches/:id -- informacion de batch

5. Configuration (.env support)
6. Health checks
7. Graceful shutdown
8. Structured logging

9. Tests E2E: ciclo completo (mock prover para velocidad)

10. package.json: actualizar con scripts build, start, dev, test

11. ADVERSARIAL-REPORT.md en validium/tests/adversarial/enterprise-node/

12. Session log: lab/3-architect/sessions/2026-03-18_enterprise-node.md

IMPORTANTE: Este es el MVP funcional. Integra todos los modulos existentes.
NO hagas commits. Comienza con /implement
