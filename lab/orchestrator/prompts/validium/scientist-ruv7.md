Investiga modelos de verificacion cross-enterprise para un sistema validium con multiples empresas.

HIPOTESIS: Un modelo hub-and-spoke donde el L1 agrega proofs de multiples empresas puede verificar interacciones cross-enterprise (ej: empresa A vende a empresa B) sin revelar datos de ninguna, usando proof aggregation con < 2x overhead sobre verificacion individual.

CONTEXTO:
- Cada empresa tiene su propio state root verificado en L1 via StateCommitment.sol
- Ya tenemos todo el sistema implementado y verificado (RU-V1 a RU-V6)
- Target: validium (MVP), Fecha: 2026-03-18

TAREAS:
1. CREAR ESTRUCTURA: validium/research/experiments/2026-03-18_cross-enterprise/
2. LITERATURE REVIEW: recursive SNARKs (SnarkPack), proof aggregation, Rayls cross-privacy, Groth16 vs PLONK
3. CODIGO: prototype de cross-enterprise verification
4. BENCHMARKS
5. SESSION LOG: lab/1-scientist/sessions/2026-03-18_cross-enterprise.md

NO hagas commits. Comienza con /experiment
