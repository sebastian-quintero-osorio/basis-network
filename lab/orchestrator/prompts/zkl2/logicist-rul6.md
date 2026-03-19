Formaliza el pipeline E2E L2-to-L1 en TLA+.

CONTEXTO:
- Unidad: e2e-pipeline en zkl2/specs/units/2026-03-e2e-pipeline/0-input/
- Target: zkl2, Fecha: 2026-03-19
- TLC tools: lab/2-logicist/tools/tla2tools.jar

QUE FORMALIZAR:
- Pipeline state machine: Execute -> Witness -> Prove -> Submit -> Finalize
- INVARIANTES:
  - PipelineIntegrity: every finalized batch has valid proof on L1
  - Liveness: pending batches eventually proved and submitted
  - Atomicity: partial failure does not corrupt state
- MODEL CHECK: 3 batches, 5 pipeline stages, retry on failure

OUTPUT en zkl2/specs/units/2026-03-e2e-pipeline/1-formalization/v0-analysis/

SESSION LOG: lab/2-logicist/sessions/2026-03-19_e2e-pipeline.md
NO hagas commits. Comienza con /1-formalize
