Investiga el pipeline end-to-end L2-to-L1 para el zkEVM empresarial.

HIPOTESIS: Un pipeline E2E (L2 transaction -> EVM execution -> trace -> witness -> proof -> L1 verification) puede procesar un batch de 100 L2 transactions con latencia total < 5 minutos, con zero intervencion manual y retry automatico en fallo.

CONTEXTO:
- Ya tenemos TODOS los componentes de Phase 1 y Phase 2:
  - EVM Executor (Go): zkl2/node/executor/
  - Sequencer (Go): zkl2/node/sequencer/
  - State DB (Go): zkl2/node/statedb/
  - Witness Generator (Rust): zkl2/prover/witness/
  - BasisRollup.sol: zkl2/contracts/
- Necesitamos el pipeline orchestrator que conecta todo
- Target: zkl2 (produccion completa), Fecha: 2026-03-19

TAREAS:
1. CREAR ESTRUCTURA: zkl2/research/experiments/2026-03-19_e2e-pipeline/
2. LITERATURE REVIEW: Polygon CDK pipeline, Scroll proving pipeline, parallelism
3. CODIGO: Go pipeline orchestrator prototype
4. BENCHMARKS: E2E latency breakdown, bottleneck identification
5. SESSION LOG: lab/1-scientist/sessions/2026-03-19_e2e-pipeline.md

NO hagas commits. Comienza con /experiment
