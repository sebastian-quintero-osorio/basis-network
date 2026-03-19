Ejecuta Phase 2 (Audit) para la unidad cross-enterprise.

CONTEXTO:
- La unidad esta en validium/specs/units/2026-03-cross-enterprise/
- Phase 1 completa: CrossEnterprise.tla, TLC PASS (461,529 states, 54,009 distinct)
- PHASE-1-FORMALIZATION_NOTES.md existe
- Phase 2 (Audit Report) NO fue ejecutada
- Verifica que la formalizacion TLA+ es fiel a los materiales fuente

QUE HACER:
1. Lee TODO 0-input/ (REPORT.md, hypothesis.json, cross-enterprise-benchmark.ts)
2. Lee CrossEnterprise.tla
3. Lee PHASE-1-FORMALIZATION_NOTES.md
4. Audit: state variable mapping, state transition mapping, hallucination check, omission check, semantic drift
5. Escribe PHASE-2-AUDIT_REPORT.md en 1-formalization/v0-analysis/
6. Session log en lab/2-logicist/sessions/

NO hagas commits. Comienza con /2-audit
