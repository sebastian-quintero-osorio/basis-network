Verifica el E2E Pipeline contra su TLA+ spec.

CONTEXTO: Target: zkl2, Fecha: 2026-03-19, Unidad: e2e-pipeline

INPUTS:
1. TLA+ spec: zkl2/specs/units/2026-03-e2e-pipeline/.../specs/E2EPipeline/E2EPipeline.tla
2. Go impl: zkl2/node/pipeline/ (orchestrator.go, stages.go, types.go)
3. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en zkl2/proofs/units/2026-03-e2e-pipeline/

ENFOQUE:
- Probar PipelineIntegrity: finalized batch has valid proof
- Probar Atomicity: partial failure does not corrupt state
- Modela stages como transiciones de estado

SESSION LOG: lab/4-prover/sessions/2026-03-19_e2e-pipeline.md
NO hagas commits. Comienza con /verify
