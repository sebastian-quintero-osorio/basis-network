Continua la formalizacion de batch-aggregation. El Phase 1 encontro un CRITICAL flaw: NoLoss VIOLATED.

CONTEXTO:
- Unidad: batch-aggregation en validium/specs/units/2026-03-batch-aggregation/
- v0-analysis ya tiene: TLA+ spec, TLC log (FAIL), PHASE-1 y PHASE-2 reports
- TLC encontro: crash entre batch formation y processing causa perdida de tx
- Root cause: WAL checkpoint at formation time, not processing time
- TLA+ tools: lab/2-logicist/tools/tla2tools.jar

EJECUTA FASES 3, 4 y 5:

1. PHASE 3 (Diagnose): Escribe PHASE-3-DESIGN_PROPOSAL.md en v0-analysis/
   - Propuesta: mover checkpoint del WAL a DESPUES del batch processing
   - Opcion A (Conservative): checkpoint despues de verificacion on-chain
   - Opcion B (Aggressive): checkpoint despues de proof generation
   - Selecciona basado en Safety > Privacy > Simplicity > Speed

2. PHASE 4 (Fix): Crea v1-fix/ directory
   - Copia y corrige el spec de v0-analysis/specs/ a v1-fix/specs/
   - Corrige MC config en v1-fix/experiments/
   - Ejecuta TLC de nuevo - DEBE mostrar PASS
   - Escribe PHASE-4-VERIFICATION_REPORT.md

3. PHASE 5 (Review): Escribe PHASE-5-CRITICAL_REVIEW.md en v1-fix/
   - Verifica que el fix no debilita ningun invariante
   - Verifica liveness (el protocolo sigue haciendo progreso)
   - Veredicto: APPROVED o REJECTED

SESSION LOG: actualiza lab/2-logicist/sessions/2026-03-18_batch-aggregation.md
NO hagas commits.

Comienza con /3-diagnose
