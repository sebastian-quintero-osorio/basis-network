Investiga una state database basada en Sparse Merkle Tree con Poseidon para el L2 zkEVM.

HIPOTESIS: Una state database basada en SMT con Poseidon implementada en Go puede soportar 10,000+ cuentas con state root computation < 50ms, compatible con witness generation para el ZK prover.

CONTEXTO:
- REUTILIZAR investigacion de Validium RU-V1 (SMT con Poseidon, TypeScript, hipotesis CONFIRMADA)
- Los findings de RU-V1 estan en validium/research/experiments/2026-03-18_sparse-merkle-tree/findings.md
- Ahora necesitamos la misma estructura pero en Go para el nodo L2
- EVM account model: account trie (address -> account state) + storage trie per contract
- Target: zkl2, Fecha: 2026-03-19

TAREAS:
1. CREAR ESTRUCTURA: zkl2/research/experiments/2026-03-19_state-database/
2. LITERATURE REVIEW: gnark SMT, iden3-go, Hermez state DB, MPT vs SMT tradeoffs para EVM
3. CODIGO: Go prototype de SMT con Poseidon (usar gnark crypto o iden3-go)
4. BENCHMARKS: insert, prove, verify en Go vs TypeScript (RU-V1)
5. SESSION LOG: lab/1-scientist/sessions/2026-03-19_state-database.md

NO hagas commits. Comienza con /experiment
