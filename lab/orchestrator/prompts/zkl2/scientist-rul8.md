Investiga una DAC de produccion con erasure coding para el zkEVM empresarial.

HIPOTESIS: Una DAC de produccion extendiendo el diseno de Validium RU-V6 con erasure coding puede lograr 99.9% data availability con asuncion 5-of-7 honest minority, < 1 segundo latencia de attestation, y recuperacion verificable desde cualquier 5 nodos.

CONTEXTO:
- Reutilizar research de Validium RU-V6 (Shamir-DAC, information-theoretic privacy)
- Findings de RU-V6: validium/research/experiments/2026-03-18_data-availability-committee/findings.md
- Necesitamos escalar de (2,3) a (5,7) con erasure coding (Reed-Solomon)
- Target: zkl2 (produccion completa), Fecha: 2026-03-19

TAREAS:
1. CREAR ESTRUCTURA: zkl2/research/experiments/2026-03-19_production-dac/
2. LITERATURE REVIEW: EigenDA, Celestia DA production, KZG commitments, Reed-Solomon
3. CODIGO: Go DAC node + erasure coding module
4. BENCHMARKS: attestation latency at scale, storage overhead, recovery time
5. SESSION LOG

NO hagas commits. Comienza con /experiment
