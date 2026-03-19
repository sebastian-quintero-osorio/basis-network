Genera el paper academico para el experimento data-availability-committee.

CONTEXTO:
- Experimento en validium/research/experiments/2026-03-18_data-availability-committee/
- Hipotesis CONFIRMADA: 175ms attestation, 0 bits leaked, recovery 30/30
- INNOVACION: Shamir SSS para DAC -- ninguna produccion (StarkEx, Polygon CDK, Arbitrum Nova) tiene privacidad de datos en su DAC. Nuestro approach es information-theoretic privacy.
- 24 referencias, 112 tests, 1255 lineas de findings
- El paper va en validium/research/experiments/2026-03-18_data-availability-committee/paper/

QUE HACER:
1. Lee findings.md (1255 lineas) y results/benchmark-results.json
2. Escribe paper LaTeX:
   - Titulo: "Information-Theoretic Data Availability for Enterprise Validium: Shamir Secret Sharing in DAC Design"
   - HIGHLIGHT: ninguna produccion tiene privacidad de datos en DAC. Este es un paper de innovacion.
   - Comparacion detallada: StarkEx vs Polygon CDK vs Arbitrum Nova vs nuestra propuesta
   - Benchmarks de attestation, storage overhead, recovery time
3. Compila PDF
4. Session log

NO hagas commits. Comienza con /writeup
