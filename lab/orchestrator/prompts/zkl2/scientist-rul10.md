Investiga agregacion de proofs y composicion recursiva para un zkEVM L2 multi-empresa.

HIPOTESIS: Composicion recursiva de proofs puede agregar proofs de N batches empresariales en un solo proof verificable en L1, reduciendo gas de verificacion por empresa en N-fold manteniendo garantias de soundness.

CONTEXTO:
- Cada empresa tiene su propia cadena L2 con proofs individuales
- Ya tenemos PLONK (halo2-KZG) del RU-L9
- Queremos agregar multiples proofs en uno para reducir costos de verificacion en L1
- Target: zkl2 (produccion completa), Fecha: 2026-03-19

TAREAS:
1. CREAR ESTRUCTURA: zkl2/research/experiments/2026-03-19_proof-aggregation/
2. LITERATURE REVIEW (15+ sources):
   - Recursive SNARKs (inner/outer proof composition)
   - SnarkPack (Gabizon et al., batch verification)
   - Nova folding schemes (Setty 2021, incrementally verifiable computation)
   - Protogalaxy (folding for PLONK)
   - halo2 recursion support (accumulation schemes)
   - Estrategias de agregacion: arbol binario, secuencial, paralela
   - Gas savings vs numero de proofs agregados
   - Trade-off: agregacion overhead vs verificacion savings
3. BENCHMARKS:
   - Gas de verificacion: 1 proof vs N proofs agregados (N=2,4,8,16)
   - Overhead de agregacion: tiempo adicional por proof
   - Proof size: individual vs agregado
   - Amortized cost per enterprise
4. CODIGO: Rust prototype for recursive proof composition using halo2
5. SESSION LOG

NO hagas commits. Comienza con /experiment
