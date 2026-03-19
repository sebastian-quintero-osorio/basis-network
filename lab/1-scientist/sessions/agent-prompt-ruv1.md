Investiga Sparse Merkle Trees con hash Poseidon para gestion de estado en un sistema ZK validium empresarial.

HIPOTESIS: Un Sparse Merkle Tree de profundidad 32 con Poseidon puede soportar 100,000+ entradas con insercion < 10ms, generacion de Merkle proof < 5ms, y verificacion < 2ms en TypeScript, manteniendo compatibilidad con el campo BN128 para circuitos Circom.

CONTEXTO:
- Ya tenemos un circuito batch_verifier.circom en validium/circuits/circuits/ que usa Poseidon (circomlib) con 742 constraints para batch size 4
- Necesitamos un tree que sea la base del estado del nodo validium
- El target es validium (MVP)
- Fecha: 2026-03-18

TAREAS OBLIGATORIAS:

1. CREAR ESTRUCTURA DEL EXPERIMENTO en validium/research/experiments/2026-03-18_sparse-merkle-tree/ con:
   - hypothesis.json (name: sparse-merkle-tree, target: validium, domain: state-management)
   - state.json (tracking del progreso)
   - journal.md (diario cientifico)
   - findings.md (hallazgos con literature review)
   - code/ (codigo experimental)
   - results/ (resultados de benchmarks)
   - memory/session.md (memoria del experimento)

2. LITERATURE REVIEW (usar web search):
   - Iden3 SMT library (@iden3/js-merkletree) - performance
   - Polygon Hermez SMT implementation
   - Semaphore protocol SMT usage
   - Poseidon hash paper (Grassi et al., USENIX Security 2021) - constraint counts
   - MiMC hash (Albrecht et al., ASIACRYPT 2016)
   - Produccion: zkSync Era, Polygon zkEVM, Scroll
   - Documentar benchmarks publicados REALES en findings.md

3. COMPARACION DE FUNCIONES HASH:
   - Poseidon: ~240 constraints por hash en Circom BN128
   - MiMC: ~340 constraints por hash
   - Rescue: ~600+ constraints
   - Keccak256: ~150,000+ constraints (no viable para ZK)
   - Para Merkle proof depth-32: multiplicar por 32
   - Conclusiones con recomendacion fundamentada

4. CODIGO EXPERIMENTAL en code/:
   a) package.json con deps: circomlibjs, snarkjs
   b) tsconfig.json
   c) smt-implementation.ts: Clase SparseMerkleTree depth 32 con Poseidon de circomlibjs
      - insert(key, value), update(key, value), delete(key)
      - getProof(key), verifyProof(root, key, value, proof)
      - Aritmetica sobre campo BN128
   d) smt-benchmark.ts: Benchmarks con 100, 1000, 10000 entradas
      - Insert latency, proof generation time, verification time
      - Memory usage
      - Output JSON estructurado
   e) hash-comparison.ts: Comparacion de funciones hash

5. EJECUTAR BENCHMARKS:
   - cd al directorio code/
   - npm install
   - Ejecutar benchmarks
   - Guardar resultados en results/

6. ANALISIS Y FINDINGS:
   - Comparar resultados con benchmarks publicados
   - Determinar si la hipotesis se confirma o rechaza
   - Documentar tradeoffs

7. SESSION LOG en lab/1-scientist/sessions/2026-03-18_sparse-merkle-tree.md

8. ACTUALIZAR FOUNDATIONS si descubres nuevos invariantes o vectores de ataque:
   - validium/research/foundations/zk-01-objectives-and-invariants.md
   - validium/research/foundations/zk-02-threat-model.md

ESTANDARES DE CALIDAD:
- Todo el codigo debe compilar y ejecutar
- Todos los benchmarks deben producir numeros reales (no inventados)
- Literature review con fuentes reales y numeros de performance reales
- Rigor estadistico: multiples ejecuciones, reportar media y desviacion estandar
- findings.md debe ser un reporte de investigacion comprehensivo y profesional
- NO hagas commits de git, el orquestador se encarga

Comienza con /experiment
