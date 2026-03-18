# Validium MVP -- Pipeline Execution Checklist

## How to Use This Checklist

1. Execute items in order from top to bottom.
2. Each item is one fresh Claude Code session in the specified agent directory.
3. Before launching an agent, prepare the input materials as described in "Preparation".
4. After an agent completes, copy its outputs to the location specified in "Handoff".
5. Mark each item as done when complete: `[x]`.
6. If an agent fails or produces insufficient output, re-run it before proceeding.

## Directory Reference

| Agent | Directory |
|-------|-----------|
| Scientist | `lab/1-scientist/` |
| Logicist | `lab/2-logicist/` |
| Architect | `lab/3-architect/` |
| Prover | `lab/4-prover/` |

---

## RU-V1: Sparse Merkle Tree with Poseidon Hash

### [01] Scientist | RU-V1: Sparse Merkle Tree

- [x] **Complete** (2026-03-18 -- Hypothesis CONFIRMED, all targets PASS)

**Directory:** `lab/1-scientist/`
**Prerequisite:** None (first research unit).

**Prompt:**

> Investiga Sparse Merkle Trees con hash Poseidon para gestion de estado en un sistema ZK validium empresarial. Hipotesis: un Sparse Merkle Tree de profundidad 32 con Poseidon puede soportar 100,000+ entradas con insercion < 10ms, generacion de Merkle proof < 5ms, y verificacion < 2ms en TypeScript, manteniendo compatibilidad con el campo BN128 para circuitos Circom. Contexto: ya tenemos un circuito batch_verifier.circom en validium/circuits/ que usa Poseidon (circomlib) con 742 constraints para batch size 4. Necesitamos un tree que sea la base del estado del nodo validium. Investiga implementaciones existentes (Iden3 SMT, Polygon Hermez, Semaphore), compara funciones hash (Poseidon vs MiMC vs Rescue) en terminos de constraint cost in-circuit, y produce benchmarks reales en TypeScript con circomlibjs. Comienza con /experiment.

**Expected Output:**
- `experiments/<date>_sparse-merkle-tree/` with findings.md, code/, results/
- Benchmarks: insert latency, proof generation time, verification time
- Hash function comparison (constraints, security, performance)
- Working TypeScript prototype

**Handoff:** Copy the experiment directory contents to the Logicist input:
```
lab/2-logicist/research-history/YYYY-MM-sparse-merkle-tree/0-input/
  README.md    (context and objectives from the experiment)
  REPORT.md    (findings.md renamed)
  code/        (experimental code)
  results/     (benchmarks, metrics)
```
Use `python lab/2-logicist/tools/new_unit.py sparse-merkle-tree` to scaffold the directory first.

---

### [02] Logicist | RU-V1: Sparse Merkle Tree

- [x] **Complete** (2026-03-18 -- TLC PASS: 1.57M states, 65K distinct, all 3 invariants hold)

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [01] complete, materials copied to `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre Sparse Merkle Trees en una especificacion TLA+. La unidad de investigacion es sparse-merkle-tree. Los materiales del Scientist estan en research-history/YYYY-MM-sparse-merkle-tree/0-input/. Debes formalizar las operaciones Insert, Update, Delete, GetProof y VerifyProof. Invariantes criticos: ConsistencyInvariant (la raiz siempre refleja el contenido real del arbol), SoundnessInvariant (un proof invalido nunca es aceptado como valido), CompletenessInvariant (toda entrada existente tiene un proof valido). Model check con arbol de profundidad 4 y 8 entradas, suficiente para exponer bugs sin explosion de estados. Comienza con /1-formalize.

**Expected Output:**
- TLA+ specification in `1-formalization/v0-analysis/specs/SparseMerkleTree/`
- Model checking config and log (MC_SparseMerkleTree.tla, .cfg, .log)
- Phase reports (PHASE-1, PHASE-2, and PHASE-3 if needed)
- If v0 fails: v1-fix/ with corrected spec and PHASE-4, PHASE-5 reports
- Final: walkthrough.md at unit root (if APPROVED)

**Handoff:** Copy verified specs to the Architect:
```
lab/3-architect/implementation-history/state-machine-sparse-merkle-tree/
  specs/SparseMerkleTree/SparseMerkleTree.tla
  experiments/SparseMerkleTree/MC_SparseMerkleTree.log  (must show PASS)
  walkthrough.md
```

---

### [03] Architect | RU-V1: Sparse Merkle Tree

- [x] **Complete** (2026-03-18 -- 52/52 tests pass, 11 adversarial scenarios, production code in validium/node/src/state/)

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [02] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada del Sparse Merkle Tree. Los materiales verificados estan en implementation-history/state-machine-sparse-merkle-tree/. El destino del codigo es validium/node/src/state/. Implementa en TypeScript una clase SparseMerkleTree usando Poseidon de circomlibjs. Debe incluir: insert, update, delete, getProof, verifyProof, serialize, deserialize. Toda la aritmetica sobre campo BN128 (campo finito de la curva BN254). Tests unitarios exhaustivos mas tests adversarial: proofs falsificados, entradas duplicadas, arbol vacio, overflow de profundidad, proofs para entradas inexistentes. Sigue el protocolo de trazabilidad: cada funcion debe referenciar la accion TLA+ correspondiente. Comienza con /implement.

**Expected Output:**
- Production code in `validium/node/src/state/`
- TypeScript class with full API
- Comprehensive test suite
- ADVERSARIAL-REPORT.md in implementation-history

**Handoff:** Prepare snapshots for the Prover:
```
lab/4-prover/verification-history/YYYY-MM-sparse-merkle-tree/
  0-input-spec/    (copy TLA+ from logicist)
  0-input-impl/    (copy TypeScript from validium/node/src/state/)
```
Use `python lab/4-prover/tools/new_verification_unit.py sparse-merkle-tree` to scaffold.

---

### [04] Prover | RU-V1: Sparse Merkle Tree

- [x] **Complete** (2026-03-18 -- VERIFIED: 10 theorems Qed, 0 Admitted, 3 standard axioms)

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [03] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del Sparse Merkle Tree contra su especificacion TLA+. Los snapshots estan en verification-history/YYYY-MM-sparse-merkle-tree/. Debes construir: Spec.v (traduccion fiel del TLA+ a Coq), Impl.v (modelo abstracto de la implementacion TypeScript), y Refinement.v (prueba de que la implementacion refina la especificacion). Enfocate en probar que las operaciones insert, update y getProof preservan el ConsistencyInvariant. Modela los hashes Poseidon como funciones abstractas sobre Z (enteros modulo primo del campo BN128). Comienza con /verify.

**Expected Output:**
- Coq files in `1-proofs/`: Spec.v, Impl.v, Refinement.v
- Verification log in `2-reports/verification.log`
- SUMMARY.md with verdict (VERIFIED / INCOMPLETE / FAILED)

---

## RU-V2: State Transition Circuit

### [05] Scientist | RU-V2: State Transition Circuit

- [x] **Complete** (2026-03-18 -- 7 benchmarks across depth 10/20/32 x batch 4/8/16, d32_b8=274K constraints/12.8s proving)

**Directory:** `lab/1-scientist/`
**Prerequisite:** Item [01] complete (needs SMT knowledge).

**Prompt:**

> Investiga circuitos de transicion de estado para un sistema ZK validium. Hipotesis: un circuito Circom que prueba transiciones de estado (prevStateRoot -> newStateRoot) para batches de 64 transacciones puede generarse en < 60 segundos con < 100,000 constraints usando Groth16, verificando la integridad de cada Merkle proof y la consistencia de la cadena de state roots. Contexto: ya tenemos batch_verifier.circom en validium/circuits/ (742 constraints, batch 4, solo verifica batch root y count, NO verifica transiciones de estado). Necesitamos escalar a batch 64 y agregar verificacion de transicion de estado (prev root -> cada tx actualiza el SMT -> new root). Investiga el costo en constraints de verificar Merkle proofs Poseidon in-circuit (profundidad 32). Benchmark proof generation time para batch sizes 4, 16, 32, 64, 128. Compara con circuitos de Semaphore, Tornado Cash y Hermez. Investiga optimizaciones de Circom (reutilizacion de signals, parametrizacion de templates). Comienza con /experiment.

**Expected Output:**
- Benchmarks: constraint count and proving time per batch size
- In-circuit Merkle proof cost analysis
- Optimization strategies identified
- Working experimental circuit code

**Handoff:** Copy experiment to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-state-transition-circuit/0-input/
```
Use `python lab/2-logicist/tools/new_unit.py state-transition-circuit`.

---

### [06] Logicist | RU-V2: State Transition Circuit

- [x] **Complete** (2026-03-18 -- TLC PASS: 3.3M states, 4,096 distinct, 4/4 invariants hold)

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [05] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre circuitos de transicion de estado en TLA+. Unidad: state-transition-circuit. Materiales en 0-input/. Formaliza StateTransition(prevRoot, newRoot, txBatch) como accion TLA+. Invariantes: StateRootChain (newRoot es el resultado deterministico de aplicar txBatch a prevRoot), BatchIntegrity (cada tx en el batch tiene un Merkle proof valido contra el estado intermedio), ProofSoundness (un proof invalido siempre es rechazado). Model check con 3 empresas, batch size 4, 3 state roots de profundidad 3. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `StateTransitionCircuit.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/circuit-state-transition/
```

---

### [07] Architect | RU-V2: State Transition Circuit

- [x] **Complete** (2026-03-18 -- state_transition.circom + merkle_proof_verifier.circom, 45,715 constraints, 6/6 adversarial PASS)

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [06] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada del circuito de transicion de estado. Materiales en implementation-history/circuit-state-transition/. Destino: validium/circuits/circuits/. Implementa un circuito Circom state_transition.circom con templates para: verificacion de Merkle proof Poseidon, computacion de state root, y validacion de batch. El circuito debe soportar batch size 64 (parametrizable). Public inputs: prevStateRoot, newStateRoot, batchSize, enterpriseId. Private inputs: transacciones individuales y Merkle proofs. Actualiza los scripts de setup, prove y verify en validium/circuits/scripts/. Exporta el nuevo Groth16Verifier.sol. Tests con edge cases: batch vacio, tx duplicada, root incorrecto, batch size maximo. EVM target MUST be cancun. Comienza con /implement.

**Expected Output:**
- `state_transition.circom` in `validium/circuits/circuits/`
- Updated scripts in `validium/circuits/scripts/`
- New `Groth16Verifier.sol`
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-state-transition-circuit/
```

---

### [08] Prover | RU-V2: State Transition Circuit

- [x] **Complete** (2026-03-18 -- VERIFIED: 7 theorems Qed, 0 Admitted, batch_preserves_state_root_chain proved)

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [07] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del circuito de transicion de estado contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-state-transition-circuit/. Construye Spec.v (modelo del constraint system como ecuaciones sobre campo finito), Impl.v (modelo del circuito Circom), y Refinement.v (prueba de que cada constraint es necesario y suficiente para las propiedades de seguridad). Modela signals como elementos del campo BN128 (Z modulo p). Enfocate en probar StateRootChain y ProofSoundness. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## RU-V4: Transaction Queue and Batch Aggregation

### [09] Scientist | RU-V4: Batch Aggregation

- [x] **Complete** (2026-03-18 -- CONFIRMED: 274K tx/min, 0.01ms latency, 0 loss, 450/450 determinism)

**Directory:** `lab/1-scientist/`
**Prerequisite:** Item [01] complete (needs SMT knowledge).

**Prompt:**

> Investiga sistemas de cola de transacciones y agregacion de batches para un nodo validium empresarial. Hipotesis: un sistema de cola con ordering cronologico y batch aggregation configurable puede mantener throughput de 100+ tx/min con latencia de formacion de batch < 5s, garantizando zero perdida de transacciones bajo crash recovery, y produciendo batches deterministicos (mismas transacciones -> mismo batch). Contexto: ya tenemos un TransactionQueue basico en validium/adapters/src/common/queue.ts con retry y exponential backoff, pero no tiene persistencia ni crash recovery. Necesitamos extenderlo a un sistema robusto con write-ahead log. Investiga: persistent queues, write-ahead logs, estrategias de batch formation (time-based, size-based, hybrid), garantias de ordering (causal, total, FIFO). Benchmark throughput bajo carga y comportamiento bajo crash simulado. Comienza con /experiment.

**Expected Output:**
- Benchmarks: throughput, latency, crash recovery behavior
- Queue persistence strategies compared
- Batch formation algorithm analysis
- Working prototype code

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-batch-aggregation/0-input/
```

---

### [10] Logicist | RU-V4: Batch Aggregation

- [x] **Complete** (2026-03-18 -- CRITICAL flaw found (NoLoss), fixed in v1-fix, TLC PASS: 6,763 states, APPROVED)

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [09] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre cola de transacciones y agregacion de batches en TLA+. Unidad: batch-aggregation. Materiales en 0-input/. Formaliza Enqueue(tx), FormBatch(), ProcessBatch() como acciones TLA+. Invariantes: NoLoss (toda tx enqueued eventualmente aparece en un batch), Determinism (mismo set de txs produce mismo batch), Ordering (txs en batch respetan orden de llegada), Completeness (batch formation se dispara cuando el threshold se alcanza). Model check con 10 txs, batch size 4. Simula crash despues de enqueue pero antes de formacion de batch. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `BatchAggregation.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/queue-batch-aggregation/
```

---

### [11] Architect | RU-V4: Batch Aggregation

- [ ] **Complete**

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [10] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada de cola de transacciones y agregacion de batches. Materiales en implementation-history/queue-batch-aggregation/. Destino: validium/node/src/queue/ y validium/node/src/batch/. Implementa en TypeScript: TransactionQueue (persistente, crash-safe con write-ahead log), BatchAggregator (thresholds configurables: size, time, hybrid), BatchBuilder (construye input para el circuito ZK a partir del batch). Integra con el SparseMerkleTree de RU-V1 (cada tx debe actualizar el tree). Tests: enqueue concurrente, crash recovery, condiciones de borde (0, 1, max, max+1 txs). Comienza con /implement.

**Expected Output:**
- `TransactionQueue` and `BatchAggregator` in `validium/node/src/queue/` and `src/batch/`
- Comprehensive test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-batch-aggregation/
```

---

### [12] Prover | RU-V4: Batch Aggregation

- [ ] **Complete**

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [11] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion de la cola de transacciones y agregacion de batches contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-batch-aggregation/. Construye Spec.v (cola como secuencia, batch como subsecuencia), Impl.v (modelo de la implementacion TypeScript), Refinement.v (prueba de que NoLoss y Determinism se mantienen bajo todas las transiciones, incluyendo crash recovery). Modela operaciones asincronas como transiciones de estado. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## RU-V6: Data Availability Committee

### [13] Scientist | RU-V6: Data Availability

- [ ] **Complete**

**Directory:** `lab/1-scientist/`
**Prerequisite:** Item [01] complete (needs SMT knowledge).

**Prompt:**

> Investiga modelos de Data Availability Committee (DAC) para un sistema validium empresarial. Hipotesis: un DAC de 3 nodos con asuncion de minoria honesta (2-of-3) puede atestar disponibilidad de datos de batch en < 2 segundos, con almacenamiento gestionado por la empresa, sin exponer datos a ningun nodo individual, y con mecanismo de recovery si un nodo falla. Contexto: el sistema validium de Basis Network procesa datos empresariales privados (mantenimiento industrial, ERP comercial). Los datos NUNCA pueden ser publicos. Investiga: Polygon Avail DAC, EigenDA, Celestia (comparar modelos). Estudia: secret sharing (Shamir), erasure coding, protocolos de attestation. Analiza: honest minority vs honest majority en contexto empresarial. Benchmark: latencia de attestation, overhead de almacenamiento, tiempo de recovery. Comienza con /experiment.

**Expected Output:**
- DAC model comparison
- Attestation protocol design
- Secret sharing analysis
- Benchmarks

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-data-availability/0-input/
```

---

### [14] Logicist | RU-V6: Data Availability

- [ ] **Complete**

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [13] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre Data Availability Committee en TLA+. Unidad: data-availability. Materiales en 0-input/. Formaliza el DAC como conjunto de nodos con protocolo de attestation. Invariantes: DataAvailability (si 2/3 nodos atestan, los datos son recuperables), Privacy (ningun nodo individual puede reconstruir datos completos), Liveness (attestation se completa si >= 2 nodos estan online). Model check con 3 nodos. Simula: 1 nodo caido, 1 nodo malicioso (envia attestation falsa). Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `DataAvailability.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/da-committee/
```

---

### [15] Architect | RU-V6: Data Availability

- [ ] **Complete**

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [14] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada del Data Availability Committee. Materiales en implementation-history/da-committee/. Destino: validium/node/src/da/. Implementa en TypeScript: DACNode (almacena shares de datos), DACProtocol (attestation y recovery), integracion con el Enterprise Node (el nodo envia data shares al DAC despues de generar proof). Tambien implementa DACAttestation.sol en l1/contracts/contracts/verification/ para registro on-chain de attestations. Tests: nodo caido, nodo malicioso que envia attestation falsa, recovery completo de datos desde 2 de 3 nodos. Solidity 0.8.24, evmVersion: cancun. Comienza con /implement.

**Expected Output:**
- DAC modules in `validium/node/src/da/`
- `DACAttestation.sol` in `l1/contracts/contracts/verification/`
- Test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-data-availability/
```

---

### [16] Prover | RU-V6: Data Availability

- [ ] **Complete**

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [15] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del Data Availability Committee contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-data-availability/. Construye Spec.v, Impl.v, Refinement.v. Enfocate en probar DataAvailability (datos recuperables si 2/3 atestan) y Privacy (ningun nodo individual reconstruye datos). Modela el protocolo de attestation como un sistema distribuido con mensajes. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## RU-V3: L1 State Commitment Protocol

### [17] Scientist | RU-V3: L1 State Commitment

- [ ] **Complete**

**Directory:** `lab/1-scientist/`
**Prerequisite:** Item [07] complete (needs circuit proof format from RU-V2 Architect).

**Prompt:**

> Investiga protocolos de state commitment en L1 para un sistema ZK validium. Hipotesis: un contrato StateCommitment.sol que mantiene cadenas de state roots por empresa con verificacion de pruebas ZK integrada puede procesar submissions a < 300K gas, detectar gaps y reversiones en la cadena de roots, y mantener historia completa de batches con < 500 bytes de storage por batch. Contexto: ya tenemos ZKVerifier.sol en l1/contracts/contracts/verification/ que verifica proofs Groth16 on-chain (~200K gas) y EnterpriseRegistry.sol para permisos. Necesitamos un contrato nuevo que mantenga el estado por empresa (currentRoot, previousRoot, batchCount, timestamps). Investiga patrones: zkSync Era (commit-prove-execute), Polygon zkEVM (sequenceBatches + verifyBatches), Scroll (commitBatch + finalizeBatch). Mide gas costs de diferentes layouts de storage en Subnet-EVM (zero-fee pero el constraint es storage size). El circuito de RU-V2 produce public signals: prevStateRoot, newStateRoot, batchSize, enterpriseId. Comienza con /experiment.

**Expected Output:**
- State commitment pattern comparison
- Gas cost analysis
- Storage layout optimization
- Benchmarks

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-state-commitment/0-input/
```

---

### [18] Logicist | RU-V3: L1 State Commitment

- [ ] **Complete**

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [17] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre protocolo de state commitment en TLA+. Unidad: state-commitment. Materiales en 0-input/. Formaliza SubmitBatch(enterprise, prevRoot, newRoot, proof) como accion TLA+. Invariantes: ChainContinuity (newBatch.prevRoot == currentRoot[enterprise]), NoGap (batch IDs consecutivos por empresa), NoReversal (state root nunca retrocede a un valor anterior sin rollback explicito), ProofBeforeState (el estado solo cambia si el proof es valido). Model check con 2 empresas, 5 batches. Simula gap attack (batch ID saltado) y replay attack (mismo batch enviado dos veces). Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `StateCommitment.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/l1-state-commitment/
```

---

### [19] Architect | RU-V3: L1 State Commitment

- [ ] **Complete**

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [18] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada del protocolo de state commitment en L1. Materiales en implementation-history/l1-state-commitment/. Destino: l1/contracts/contracts/core/. Implementa StateCommitment.sol con: mapping enterprise -> EnterpriseState (currentRoot, previousRoot, batchCount, lastBatchTimestamp, isActive). Integracion con ZKVerifier.sol existente para verificacion de proofs. Integracion con EnterpriseRegistry.sol para control de acceso. Solo empresas autorizadas pueden enviar batches. Tests Hardhat unitarios + adversarial: gap attack (saltar batch ID), replay attack (reenviar batch), wrong enterprise (empresa A envia batch para empresa B), invalid proof (proof con datos falsos). Solidity 0.8.24, evmVersion cancun. Coverage > 85%. Actualiza el script de deploy en l1/contracts/scripts/. Comienza con /implement.

**Expected Output:**
- `StateCommitment.sol` in `l1/contracts/contracts/core/`
- Comprehensive Hardhat test suite
- Updated deploy script
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-state-commitment/
```

---

### [20] Prover | RU-V3: L1 State Commitment

- [ ] **Complete**

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [19] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del protocolo de state commitment contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-state-commitment/. Construye Spec.v (estado on-chain como mapping), Impl.v (modelo del contrato Solidity con storage y require/revert como precondiciones), Refinement.v (prueba de que ChainContinuity y ProofBeforeState se mantienen bajo todas las transiciones posibles del contrato). Modela el storage de Solidity como mappings en Coq. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## RU-V5: Enterprise Node Orchestrator

### [21] Scientist | RU-V5: Enterprise Node

- [ ] **Complete**

**Directory:** `lab/1-scientist/`
**Prerequisite:** Items [01], [05], [09], [17] complete (all Scientist work for dependencies).

**Prompt:**

> Investiga patrones de arquitectura para un nodo validium empresarial que orquesta el ciclo completo de procesamiento. Hipotesis: un servicio Node.js event-driven que orquesta el ciclo (receive -> state update -> batch -> prove -> submit) puede procesar end-to-end un batch de 64 transacciones en < 90 segundos (60s proving + 30s overhead), con zero data leakage, crash recovery sin perdida de estado, y API REST/WebSocket para integracion con PLASMA y Trace. Contexto: ya tenemos todos los componentes individuales implementados: SparseMerkleTree (validium/node/src/state/), TransactionQueue y BatchAggregator (validium/node/src/queue/ y src/batch/), circuito state_transition.circom (validium/circuits/), StateCommitment.sol (l1/contracts/), y PLASMAAdapter/TraceAdapter (validium/adapters/). Necesitamos el servicio que une todo. Investiga: como el nodo Hermez de Polygon orquesta proving, como el sequencer de zkSync Era maneja el lifecycle, patrones de event loop y state machine design para nodos blockchain. Define el contrato API para integracion con PLASMA/Trace. Benchmark end-to-end: latencia total, memory footprint, CPU durante proving. Comienza con /experiment.

**Expected Output:**
- Node architecture design with state machine diagram
- API contract for PLASMA/Trace integration
- Lifecycle management patterns
- End-to-end benchmarks

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-enterprise-node/0-input/
```

---

### [22] Logicist | RU-V5: Enterprise Node

- [ ] **Complete**

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [21] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre el nodo validium empresarial en TLA+. Unidad: enterprise-node. Materiales en 0-input/. Formaliza la state machine COMPLETA del nodo con estados: Idle, Receiving, Batching, Proving, Submitting, Error. Formaliza las transiciones y recovery paths. Invariantes: Liveness (si hay txs pendientes, eventualmente se prueba un batch), Safety (nunca se envia un proof sin el state root correcto), Privacy (ningun dato privado sale del nodo excepto proof + public signals). Model check con escenarios: happy path completo, crash durante proving, fallo de tx en L1, submissions concurrentes de multiples empresas. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `EnterpriseNode.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/service-enterprise-node/
```

---

### [23] Architect | RU-V5: Enterprise Node

- [ ] **Complete**

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [22] complete, verified specs in `implementation-history/`.
**Also requires:** Items [03], [07], [11], [19] complete (all Architect implementations for components).

**Prompt:**

> Implementa la especificacion verificada del nodo validium empresarial. Materiales en implementation-history/service-enterprise-node/. Destino: validium/node/. Implementa el servicio completo en TypeScript: entry point (src/index.ts), integrando todos los modulos existentes: SparseMerkleTree (src/state/), TransactionQueue y BatchAggregator (src/queue/, src/batch/), wrapper del prover ZK (invoca snarkjs para generar proofs con el circuito state_transition.circom de validium/circuits/), L1 Submitter (envia proof + state root a StateCommitment.sol via ethers.js v6). Incluye: API REST para recibir eventos de PLASMA y Trace, gestion de configuracion (.env), health checks y endpoints de monitoreo, graceful shutdown, crash recovery (checkpoint de estado), logging estructurado. Tests E2E: ciclo completo desde evento PLASMA hasta verificacion en L1. package.json con scripts para build, start, dev, test. Este es el MVP funcional. Comienza con /implement.

**Expected Output:**
- Complete `validium/node/` with all source files
- REST API endpoints
- package.json with build/start/test scripts
- E2E test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-enterprise-node/
```

---

### [24] Prover | RU-V5: Enterprise Node

- [ ] **Complete**

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [23] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del nodo validium empresarial contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-enterprise-node/. Construye Spec.v (state machine del nodo con estados Idle, Receiving, Batching, Proving, Submitting, Error), Impl.v (modelo del orchestrator TypeScript), Refinement.v (prueba de que Safety y Liveness se mantienen bajo todas las transiciones, incluyendo crash recovery). Modela las operaciones asincronas (proving, L1 submission) como transiciones de estado. Prioriza la prueba de Safety (nunca enviar proof con state root incorrecto) sobre Liveness. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## RU-V7: Cross-Enterprise Verification

### [25] Scientist | RU-V7: Cross-Enterprise

- [ ] **Complete**

**Directory:** `lab/1-scientist/`
**Prerequisite:** Items [21], [13] complete.

**Prompt:**

> Investiga modelos de verificacion cross-enterprise para un sistema validium con multiples empresas. Hipotesis: un modelo hub-and-spoke donde el L1 agrega proofs de multiples empresas puede verificar interacciones cross-enterprise (ej: empresa A vende a empresa B) sin revelar datos de ninguna, usando proof aggregation con < 2x overhead sobre verificacion individual. Contexto: cada empresa tiene su propio state root verificado en el L1 via StateCommitment.sol. Necesitamos verificar que una referencia cruzada (ej: venta registrada en empresa A coincide con compra registrada en empresa B) es valida sin revelar los datos de ninguna transaccion. Investiga: recursive SNARKs (SnarkPack), tecnicas de proof aggregation, modelo cross-privacy de Rayls (seleccionado por JP Morgan). Analiza viabilidad con Groth16 (limitado, no recursive) vs PLONK (mas flexible). Benchmark: costo de agregacion vs verificacion individual. Comienza con /experiment.

**Expected Output:**
- Proof aggregation feasibility analysis
- Cross-enterprise verification design
- Groth16 vs PLONK comparison for this use case
- Benchmarks

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-cross-enterprise/0-input/
```

---

### [26] Logicist | RU-V7: Cross-Enterprise

- [ ] **Complete**

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [25] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre verificacion cross-enterprise en TLA+. Unidad: cross-enterprise. Materiales en 0-input/. Formaliza CrossEnterpriseVerification como accion que toma proofs de 2+ empresas y verifica una referencia cruzada. Invariantes: Isolation (proof de empresa A no revela informacion de empresa B), Consistency (una referencia cruzada es valida solo si ambos proofs son validos). Model check con 2 empresas, 2 batches cada una, 1 referencia cruzada. Simula: referencia cruzada falsificada, proof de empresa incorrecta. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `CrossEnterprise.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/verification-cross-enterprise/
```

---

### [27] Architect | RU-V7: Cross-Enterprise

- [ ] **Complete**

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [26] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada de verificacion cross-enterprise. Materiales en implementation-history/verification-cross-enterprise/. Destinos: validium/node/src/cross-enterprise/ (modulo de agregacion de proofs) y l1/contracts/contracts/verification/CrossEnterpriseVerifier.sol (contrato L1). Implementa en TypeScript el modulo de agregacion que toma proofs de multiples empresas y genera evidencia de referencia cruzada valida. Implementa el contrato Solidity que verifica esta evidencia on-chain. Tests adversarial: falsificar referencia cruzada, usar proof de empresa incorrecta, replay de verificacion anterior. Solidity 0.8.24, evmVersion cancun. Comienza con /implement.

**Expected Output:**
- Cross-enterprise module in `validium/node/src/cross-enterprise/`
- `CrossEnterpriseVerifier.sol` in `l1/contracts/contracts/verification/`
- Test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-cross-enterprise/
```

---

### [28] Prover | RU-V7: Cross-Enterprise

- [ ] **Complete**

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [27] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion de verificacion cross-enterprise contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-cross-enterprise/. Construye Spec.v, Impl.v, Refinement.v. Enfocate en probar Isolation (datos de empresa A no son visibles para empresa B) y Consistency (referencia cruzada valida solo si ambos proofs son validos). Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## Summary

| # | Agent | RU | Component |
|---|-------|----|-----------|
| 01 | Scientist | V1 | Sparse Merkle Tree |
| 02 | Logicist | V1 | Sparse Merkle Tree |
| 03 | Architect | V1 | Sparse Merkle Tree |
| 04 | Prover | V1 | Sparse Merkle Tree |
| 05 | Scientist | V2 | State Transition Circuit |
| 06 | Logicist | V2 | State Transition Circuit |
| 07 | Architect | V2 | State Transition Circuit |
| 08 | Prover | V2 | State Transition Circuit |
| 09 | Scientist | V4 | Batch Aggregation |
| 10 | Logicist | V4 | Batch Aggregation |
| 11 | Architect | V4 | Batch Aggregation |
| 12 | Prover | V4 | Batch Aggregation |
| 13 | Scientist | V6 | Data Availability |
| 14 | Logicist | V6 | Data Availability |
| 15 | Architect | V6 | Data Availability |
| 16 | Prover | V6 | Data Availability |
| 17 | Scientist | V3 | L1 State Commitment |
| 18 | Logicist | V3 | L1 State Commitment |
| 19 | Architect | V3 | L1 State Commitment |
| 20 | Prover | V3 | L1 State Commitment |
| 21 | Scientist | V5 | Enterprise Node |
| 22 | Logicist | V5 | Enterprise Node |
| 23 | Architect | V5 | Enterprise Node |
| 24 | Prover | V5 | Enterprise Node |
| 25 | Scientist | V7 | Cross-Enterprise |
| 26 | Logicist | V7 | Cross-Enterprise |
| 27 | Architect | V7 | Cross-Enterprise |
| 28 | Prover | V7 | Cross-Enterprise |

**Total: 28 agent executions for Validium MVP.**

Note: Items 05-08 (RU-V2) and 09-16 (RU-V4, RU-V6) can run in parallel with items 01-04
if you have multiple agent instances available. The strict sequential order above is the
safest execution path. See `ROADMAP.md` for the pipelined execution timeline.
