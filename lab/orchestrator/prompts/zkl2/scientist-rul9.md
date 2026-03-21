Investiga la migracion de Groth16 a PLONK para el prover ZK del L2 zkEVM.

HIPOTESIS: Migrar de Groth16 a PLONK (via halo2 o plonky2 en Rust) elimina la necesidad de trusted setup por circuito, permite custom gates para operaciones EVM, y mantiene verificacion on-chain < 500K gas con proof size < 1KB.

CONTEXTO:
- Actualmente usamos Groth16 con Circom (validium MVP)
- Para el L2 necesitamos un sistema de proofs mas flexible
- Decisiones tecnicas en zkl2/docs/TECHNICAL_DECISIONS.md (TD-003: PLONK como target)
- El witness generator esta en Rust (zkl2/prover/witness/)
- El nodo es Go (zkl2/node/)
- Target: zkl2 (produccion completa), Fecha: 2026-03-19

TAREAS:
1. CREAR ESTRUCTURA: zkl2/research/experiments/2026-03-19_plonk-migration/
2. LITERATURE REVIEW (15+ papers/sources):
   - halo2 (Zcash/Scroll): API, maturity, production usage
   - plonky2 (Polygon): recursion-friendly, Goldilocks field
   - PLONK arithmetization vs R1CS (Groth16)
   - Custom gates para opcodes EVM (ADD, MUL, memory, stack)
   - KZG vs IPA commitment schemes
   - Verificacion on-chain: gas costs comparativos
3. BENCHMARKS COMPARATIVOS:
   - Groth16 vs PLONK: proving time, proof size, verification gas
   - halo2 vs plonky2: developer experience, constraint count, recursion support
   - Custom gates: constraint reduction por opcode
4. CODIGO: Rust prototype comparing halo2 and plonky2 for simple EVM operations
5. SESSION LOG

NO hagas commits. Comienza con /experiment
