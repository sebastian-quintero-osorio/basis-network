Investiga circuitos de transicion de estado para un sistema ZK validium.

HIPOTESIS: Un circuito Circom que prueba transiciones de estado (prevStateRoot -> newStateRoot) para batches de 64 transacciones puede generarse en < 60 segundos con < 100,000 constraints usando Groth16, verificando la integridad de cada Merkle proof y la consistencia de la cadena de state roots.

CONTEXTO:
- Ya tenemos batch_verifier.circom en validium/circuits/circuits/ (742 constraints, batch 4, solo verifica batch root y count, NO verifica transiciones de estado)
- Ya tenemos un SparseMerkleTree de profundidad 32 con Poseidon (RU-V1 completo, hipotesis confirmada)
- El SMT usa ~240 constraints por hash Poseidon en BN128
- Para verificar un Merkle proof de profundidad 32: ~7,680 constraints (32 * 240)
- Necesitamos escalar a batch 64 y agregar verificacion de transicion de estado (prev root -> cada tx actualiza el SMT -> new root)
- Target: validium (MVP)
- Fecha: 2026-03-18

TAREAS OBLIGATORIAS:

1. CREAR ESTRUCTURA DEL EXPERIMENTO en validium/research/experiments/2026-03-18_state-transition-circuit/ con:
   - hypothesis.json (name: state-transition-circuit, target: validium, domain: circuit-design)
   - state.json, journal.md, findings.md, code/, results/, memory/session.md

2. LITERATURE REVIEW (usar web search):
   - Constraint cost de verificacion de Merkle proof Poseidon in-circuit (depth 32)
   - Benchmarks de proof generation time de circuitos Groth16 por numero de constraints
   - Circom optimization techniques: signal reuse, template parameterization, lookup patterns
   - Circuitos de referencia: Semaphore (Merkle proof verification), Tornado Cash (deposit/withdraw), Hermez (state transitions)
   - Polygon zkEVM prover benchmarks (constraints vs proving time)
   - zkSync Era circuit design patterns
   - SnarkJS Groth16 benchmarks para diferentes constraint counts

3. ANALISIS DE CONSTRAINTS POR BATCH SIZE:
   - Para cada tx en un batch, necesitamos verificar:
     a) Merkle proof de la entrada anterior (old value)
     b) Actualizar el SMT (new value)
     c) Recalcular la ruta hasta la nueva raiz
   - Per-transaction constraint cost estimado:
     - 2 Merkle path verifications (old + new): 2 * 32 * 240 = 15,360 constraints
     - Leaf hash computation: 240 constraints
     - Total per tx: ~15,600 constraints
   - Batch-level overhead: state root chain check, batch metadata
   - Benchmark para batch sizes: 4, 8, 16, 32, 64, 128

4. CODIGO EXPERIMENTAL en code/:
   - Circom circuit: state_transition_poc.circom (batch size 4, proof of concept)
   - Template: MerkleProofVerifier(depth) -- verifica un Merkle proof Poseidon
   - Template: StateTransition(depth, batchSize) -- verifica batch de transiciones
   - Scripts: compile, generate witness, prove, verify
   - Benchmark script que mide constraints y proof generation time

5. EJECUTAR BENCHMARKS:
   - Compilar el circuito con circom
   - Generar witness con inputs de prueba
   - Medir constraint count (circom --r1cs)
   - Medir proving time con snarkjs groth16 prove (si es factible)
   - Extrapolar para batch 64

6. ANALISIS Y FINDINGS:
   - Es factible batch 64 en < 60s con < 100K constraints?
   - Si no, cual es el batch size maximo viable?
   - Que optimizaciones son necesarias?

7. SESSION LOG: lab/1-scientist/sessions/2026-03-18_state-transition-circuit.md

8. ACTUALIZAR FOUNDATIONS si se descubren nuevos invariantes o vectores de ataque

NO hagas commits de git, el orquestador se encarga.

Comienza con /experiment
