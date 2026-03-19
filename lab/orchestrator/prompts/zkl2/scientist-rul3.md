Investiga witness generation desde EVM execution traces para un prover ZK en Rust.

HIPOTESIS: Un witness generator en Rust puede extraer de un EVM execution trace los private inputs necesarios para un circuito ZK de validez, procesando traces de 1000 transacciones en < 30 segundos con output deterministico (mismo trace -> mismo witness).

CONTEXTO:
- Ya tenemos el EVM executor en Go (zkl2/node/executor/) que produce execution traces
- Ya tenemos el state DB en Go (zkl2/node/statedb/) con SMT Poseidon
- El witness generator sera en Rust (TD-002) y consumira traces del executor Go via gRPC/IPC
- El witness alimentara un circuito ZK (PLONK target, TD-003)
- Target: zkl2 (produccion completa), Fecha: 2026-03-19

TAREAS:

1. CREAR ESTRUCTURA: zkl2/research/experiments/2026-03-19_witness-generation/
   hypothesis.json, state.json, journal.md, findings.md, code/, results/, memory/session.md

2. LITERATURE REVIEW:
   - Como Polygon Hermez genera witnesses desde EVM traces
   - Como Scroll genera witnesses (zkevm-circuits, bus-mapping)
   - Como zkSync Era genera witnesses (vm_runner, witness_generator crate)
   - Algebraic Intermediate Representation (AIR) y su rol
   - Que operaciones EVM producen mas witness data (storage, memory, stack)
   - Witness format: que estructura necesita el prover (columns, rows, lookups)
   - Rust ZK libraries: arkworks, bellman, halo2, plonky2

3. CODIGO EXPERIMENTAL en Rust:
   - Rust prototype de witness generator
   - Input: JSON execution trace (from Go executor)
   - Output: witness structure (vectors de field elements)
   - Modular: un modulo por categoria de operacion EVM
   - Benchmark: witness generation time vs trace size, memory usage
   - Cargo.toml con deps: ark-ff, ark-bn254 (o similar)

4. ANALISIS:
   - Que datos del trace necesita el witness para cada tipo de opcode
   - Memory layout del witness (columns para arithmetic, storage, memory, etc.)
   - Estimation de witness size para 100, 500, 1000 transacciones

5. SESSION LOG: lab/1-scientist/sessions/2026-03-19_witness-generation.md

NO hagas commits. Comienza con /experiment
