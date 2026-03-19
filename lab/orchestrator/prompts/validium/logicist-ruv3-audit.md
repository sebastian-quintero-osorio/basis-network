Ejecuta Phase 2 (Audit) para la unidad state-commitment.

CONTEXTO:
- La unidad esta en validium/specs/units/2026-03-state-commitment/
- Phase 1 ya esta completa: StateCommitment.tla escrito, TLC PASS (3.78M states, 1.87M distinct)
- PHASE-1-FORMALIZATION_NOTES.md ya existe
- PERO Phase 2 (Audit Report) NO fue ejecutada
- Tu trabajo es verificar que la formalizacion TLA+ es fiel a los materiales fuente

QUE HACER:
1. Lee TODO el contenido de 0-input/ (REPORT.md con findings del Scientist, hypothesis.json, codigo Solidity de referencia)
2. Lee la especificacion TLA+ en 1-formalization/v0-analysis/specs/StateCommitment/StateCommitment.tla
3. Lee el PHASE-1-FORMALIZATION_NOTES.md
4. Ejecuta el audit comparando fuente vs spec:
   - State variable mapping: cada variable del source tiene contraparte TLA+?
   - State transition mapping: cada funcion del source tiene una Action TLA+?
   - Hallucination check: el spec invento mecanismos que no estan en la fuente?
   - Omission check: el spec omitio comportamiento critico?
   - Semantic drift: hay diferencias sutiles de semantica?
5. Escribe PHASE-2-AUDIT_REPORT.md en 1-formalization/v0-analysis/
6. Escribe session log en lab/2-logicist/sessions/

Veredicto esperado: TRUE TO SOURCE o DISCREPANCIES FOUND

NO hagas commits. Comienza con /2-audit
