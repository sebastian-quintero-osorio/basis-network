Implementa el pipeline E2E L2-to-L1 en Go.

SAFETY LATCH: TLC log en zkl2/specs/units/2026-03-e2e-pipeline muestra PASS.

CONTEXTO:
- TLA+ spec: zkl2/specs/units/2026-03-e2e-pipeline/.../specs/E2EPipeline/E2EPipeline.tla
- Integra TODOS los componentes existentes:
  - zkl2/node/executor/ (EVM execution)
  - zkl2/node/sequencer/ (block production)
  - zkl2/node/statedb/ (state management)
  - zkl2/prover/witness/ (Rust witness gen, via gRPC/CLI)
  - zkl2/contracts/ (L1 submission)
- Destino: zkl2/node/pipeline/

QUE IMPLEMENTAR:

1. zkl2/node/pipeline/orchestrator.go:
   - Pipeline orchestrator connecting all stages
   - Stage management: Execute -> Witness -> Prove -> Submit -> Finalize
   - Retry logic with exponential backoff
   - Concurrent batch processing

2. zkl2/node/pipeline/stages.go:
   - Each stage as an interface: Execute(), WitnessGen(), Prove(), Submit()
   - Error types per stage

3. zkl2/node/pipeline/types.go

4. Tests: E2E with mocked stages, retry, failure recovery
5. ADVERSARIAL-REPORT.md
6. Session log

NO hagas commits. Comienza con /implement
