# zkEVM L2 -- Pipeline Execution Checklist

## How to Use This Checklist

1. Execute items in order from top to bottom.
2. Each item is one fresh Claude Code session in the specified agent directory.
3. Before launching an agent, prepare the input materials as described in "Preparation".
4. After an agent completes, copy its outputs to the location specified in "Handoff".
5. Mark each item as done when complete: `[x]`.
6. If an agent fails or produces insufficient output, re-run it before proceeding.

**PREREQUISITE:** The Validium MVP (see `validium/ROADMAP_CHECKLIST.md`) should be substantially
complete before starting this checklist. Knowledge from Validium RUs directly informs this work.

## Directory Reference

| Agent | Directory |
|-------|-----------|
| Scientist | `lab/1-scientist/` |
| Logicist | `lab/2-logicist/` |
| Architect | `lab/3-architect/` |
| Prover | `lab/4-prover/` |

---

## Phase 1: L2 Foundation

---

## RU-L1: EVM Execution Engine (Geth Fork)

### [01] Scientist | RU-L1: EVM Executor

- [x] **Complete** (2026-03-19 -- Geth fork analysis, ZK opcode mapping, 4K-12K tx/s projected, 22 references)

**Directory:** `lab/1-scientist/`
**Prerequisite:** Validium MVP substantially complete.

**Prompt:**

> Investiga como hacer un fork minimo de go-ethereum para usarlo como motor de ejecucion EVM en un L2 zkEVM empresarial. Hipotesis: un fork minimo de Geth puede ejecutar transacciones EVM con state management propio, produciendo execution traces (reads/writes de storage, opcodes ejecutados) necesarios para witness generation, manteniendo 100% compatibilidad con opcodes Cancun y procesando 1000+ transacciones simples por segundo. Contexto: estamos construyendo un zkEVM L2 sobre Basis Network (Avalanche L1). El nodo L2 necesita ejecutar contratos Solidity y producir traces para que un prover ZK en Rust pueda generar proofs de validez. Las decisiones tecnicas estan documentadas en zkl2/docs/TECHNICAL_DECISIONS.md (TD-001: Go para nodo, TD-007: fork de Geth). Investiga: como Polygon CDK, Scroll y zkSync forkean Geth. Identifica los modulos minimos: core/vm, core/state, ethdb. Mide el overhead de trace generation vs Geth vanilla. Mapea opcodes Cancun que requieren tratamiento especial en ZK (KECCAK256, BLOCKHASH, SELFDESTRUCT, etc.). Benchmark: tx/s, tamano de trace por tx, uso de memoria. Comienza con /experiment.

**Expected Output:**
- Geth fork analysis (minimal modules needed)
- Trace generation overhead measurements
- ZK-problematic opcode mapping
- Benchmarks: tx/s, trace size, memory

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-evm-executor/0-input/
```

---

### [02] Logicist | RU-L1: EVM Executor

- [x] **Complete** (2026-03-19 -- TLC PASS: 6,217 states, 7 invariants incl Determinism + TraceCompleteness)

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [01] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre el motor de ejecucion EVM en TLA+. Unidad: evm-executor. Materiales en 0-input/. Formaliza la EVM como state machine con operaciones SLOAD, SSTORE, CALL, CREATE, LOG. Invariantes: Determinism (misma tx + mismo estado -> mismo resultado y mismo trace), TraceCompleteness (el trace captura TODAS las operaciones que modifican estado), OpcodeCorrectness (cada opcode produce output correcto segun especificacion EVM). Model check con 3 cuentas, 5 opcodes, 2 transacciones. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `EvmExecutor.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/node-evm-executor/
```

---

### [03] Architect | RU-L1: EVM Executor

- [x] **Complete** (2026-03-19 -- 1,748 lines Go, 13 tests, 15 adversarial vectors, executor+tracer+opcodes)

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [02] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada del motor de ejecucion EVM. Materiales en implementation-history/node-evm-executor/. Destino: zkl2/node/executor/. Implementa en Go: fork minimo de Geth con trace collector y state manager. El executor debe: recibir transacciones, ejecutarlas contra el estado actual, producir execution traces detallados (cada SLOAD/SSTORE/CALL con valores before/after). Incluye: interfaz para state backend (compatible con SMT de RU-L4 futuro), trace format serializable (JSON o protobuf). Tests: ejecutar contratos Solidity simples (transfer, storage write/read, contract creation) y verificar que los traces matchean el comportamiento esperado. Usa Go modules. No incluir modulos innecesarios de Geth (P2P, mining, etc). Comienza con /implement.

**Expected Output:**
- Go EVM executor in `zkl2/node/executor/`
- Trace collector with serialization
- Test suite with Solidity contract execution
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-evm-executor/
```

---

### [04] Prover | RU-L1: EVM Executor

- [x] **Complete** (2026-03-19 -- VERIFIED: 10 theorems Qed, 0 Admitted, Determinism + TraceCompleteness proved)

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [03] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del motor de ejecucion EVM contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-evm-executor/. Construye Spec.v (EVM como state machine), Impl.v (modelo del executor Go con goroutines como procesos concurrentes), Refinement.v (prueba de Determinism y TraceCompleteness). Modela el estado EVM como mappings (accounts, storage). Modela goroutines como transiciones de estado concurrentes donde corresponda. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## RU-L2: Sequencer and Block Production

### [05] Scientist | RU-L2: Sequencer

- [x] **Complete** (2026-03-19 -- Sequencer design, forced inclusion, mempool, Go prototype with benchmarks)

**Directory:** `lab/1-scientist/`
**Prerequisite:** Item [01] complete.

**Prompt:**

> Investiga disenos de sequencer para un L2 zkEVM empresarial. Hipotesis: un sequencer single-operator puede producir bloques L2 cada 1-2 segundos con ordering FIFO, manteniendo un mecanismo de forced inclusion via L1 que garantiza censorship resistance con latencia maxima de 24 horas. Contexto: el L2 es empresarial y permisionado. Cada empresa opera su propia cadena L2. El sequencer es operado por la empresa misma (trusted pero con mitigaciones). Decisiones tecnicas en zkl2/docs/TECHNICAL_DECISIONS.md (TD-005: per-enterprise chains). Investiga: disenos de sequencer de zkSync, Polygon CDK, Arbitrum, Scroll. Mecanismos de forced inclusion y sus costos de gas en L1. Consideraciones MEV en contexto empresarial (probablemente minimo). Benchmark: latencia de produccion de bloques, fairness de ordering, gestion de mempool. Comienza con /experiment.

**Expected Output:**
- Sequencer architecture comparison
- Forced inclusion mechanism design
- Block production benchmarks
- MEV analysis for enterprise context

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-sequencer/0-input/
```

---

### [06] Logicist | RU-L2: Sequencer

- [x] **Complete** (2026-03-19 -- TLC PASS: 4.8M states, 6 invariants incl ForcedInclusion + FIFO)

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [05] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre el sequencer en TLA+. Unidad: sequencer. Materiales en 0-input/. Formaliza el Sequencer como productor de bloques con mempool y cola de forced inclusion. Invariantes: Inclusion (toda tx valida se incluye eventualmente en un bloque), ForcedInclusion (tx enviada al L1 se incluye en L2 dentro de T bloques), Ordering (transacciones dentro de un bloque respetan una regla de ordering determinista). Model check con 5 txs, 2 txs forzadas, 3 bloques. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `Sequencer.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/node-sequencer/
```

---

### [07] Architect | RU-L2: Sequencer

- [x] **Complete** (2026-03-19 -- Go sequencer: mempool, block builder, forced inclusion, adversarial tests)

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [06] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada del sequencer. Materiales en implementation-history/node-sequencer/. Destino: zkl2/node/sequencer/. Implementa en Go: modulo sequencer con mempool, block builder, y cola de forced inclusion (lee del L1 via ethers). El sequencer recibe transacciones via JSON-RPC, las ordena por FIFO, y produce bloques cada 1-2 segundos. Incluye: interfaz con el executor EVM (RU-L1), monitoring de la cola de forced inclusion en L1, metricas de produccion de bloques. Tests: produccion de bloques bajo carga, forced inclusion con delays, ordering fairness. Comienza con /implement.

**Expected Output:**
- Go sequencer module in `zkl2/node/sequencer/`
- Block builder with configurable parameters
- Forced inclusion queue
- Test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-sequencer/
```

---

### [08] Prover | RU-L2: Sequencer

- [x] **Complete** (2026-03-19 -- VERIFIED: 1,383 lines Coq, 5 safety theorems, ForcedInclusionDeadline proved)

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [07] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del sequencer contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-sequencer/. Construye Spec.v, Impl.v, Refinement.v. Enfocate en probar Inclusion (toda tx valida se incluye eventualmente) y ForcedInclusion (txs forzadas respetan el deadline). Modela el mempool como una cola y los bloques como secuencias de transacciones. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## RU-L4: State Database (L2)

### [09] Scientist | RU-L4: State Database

- [x] **Complete** (2026-03-19 -- Go SMT+Poseidon2: 4.46us/hash, 125us insert, 18.77ms@100tx batch, 20 references)

**Directory:** `lab/1-scientist/`
**Prerequisite:** Item [01] complete. Validium RU-V1 (SMT) should be done.

**Prompt:**

> Investiga state databases para un L2 zkEVM usando Sparse Merkle Tree con Poseidon. Hipotesis: un state database basado en SMT con Poseidon implementado en Go puede soportar 10,000+ cuentas con computacion de state root < 50ms, compatible con witness generation para el prover ZK. Contexto: en el Validium MVP (validium/node/src/state/) ya implementamos un SMT con Poseidon en TypeScript. Ahora necesitamos la version Go para el nodo L2. El state DB debe manejar el modelo de cuentas EVM (account trie + storage trie por contrato). Decisiones tecnicas en zkl2/docs/TECHNICAL_DECISIONS.md (TD-008: Poseidon hash). Reutiliza la investigacion del Validium RU-V1. Investiga: implementaciones Go de SMT (gnark, iden3-go, Hermez state DB). Compara MPT (Merkle Patricia Trie de Ethereum) vs SMT para estado EVM. Benchmark en Go vs TypeScript: insert, prove, verify. Comienza con /experiment.

**Expected Output:**
- Go SMT implementation comparison
- MPT vs SMT analysis for EVM state
- Go vs TypeScript performance benchmarks
- Working Go prototype

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-l2-state-db/0-input/
```

---

### [10] Logicist | RU-L4: State Database

- [x] **Complete** (2026-03-19 -- TLC PASS: 883 states, 5 invariants, two-level trie verified)

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [09] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre el state database L2 en TLA+. Unidad: l2-state-db. Materiales en 0-input/. Reutiliza y extiende la formalizacion del SMT del Validium (si existe en research-history). Adapta al modelo de cuentas EVM: account trie (address -> {nonce, balance, codeHash, storageRoot}) + storage trie por contrato (slot -> value). Invariantes: RootConsistency (state root refleja contenido actual), AccountIntegrity (operaciones sobre cuenta no afectan otras cuentas), StorageIsolation (storage de contrato A aislado de contrato B). Model check con 3 cuentas, 2 contratos con 4 slots cada uno. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `L2StateDb.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/node-state-db/
```

---

### [11] Architect | RU-L4: State Database

- [x] **Complete** (2026-03-19 -- Go StateDB: two-level SMT, account+storage tries, Poseidon2, tests pass)

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [10] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada del state database L2. Materiales en implementation-history/node-state-db/. Destino: zkl2/node/statedb/. Implementa en Go: SMT con Poseidon compatible con modelo de cuentas EVM. Incluye: account trie y storage trie por contrato, computacion de state root, generacion de Merkle proofs para witness generation, persistencia en disco (LevelDB o similar). Interfaz compatible con el executor EVM (RU-L1). Tests: CRUD de cuentas, storage reads/writes, state root consistency despues de multiples operaciones, isolation entre contratos. Comienza con /implement.

**Expected Output:**
- Go state database in `zkl2/node/statedb/`
- Poseidon SMT with EVM account model
- Persistence layer
- Test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-l2-state-db/
```

---

### [12] Prover | RU-L4: State Database

- [x] **Complete** (2026-03-19 -- VERIFIED: 22 theorems, 0 Admitted, BalanceConservation + AccountIsolation + StorageIsolation)

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [11] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del state database L2 contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-l2-state-db/. Extiende los proofs del Validium RU-V1 para el modelo EVM con Go. Enfocate en RootConsistency y StorageIsolation. Modela ownership de Go como transiciones de estado lineales donde corresponda. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## Phase 2: ZK Proving

---

## RU-L3: Witness Generation from EVM Execution

### [13] Scientist | RU-L3: Witness Generation

- [x] **Complete** (2026-03-19 -- CONFIRMED: Rust 1000tx in 13.37ms, 2,243x under target, Cargo compiled, 17/17 tests)

**Directory:** `lab/1-scientist/`
**Prerequisite:** Items [01], [09] complete (needs executor and state DB knowledge).

**Prompt:**

> Investiga generacion de witnesses a partir de execution traces de la EVM para un prover ZK en Rust. Hipotesis: un witness generator en Rust puede extraer de un execution trace EVM los inputs privados necesarios para un circuito ZK de validez, procesando traces de 1000 transacciones en < 30 segundos con output deterministico (mismo trace -> mismo witness). Contexto: el executor EVM (Go) produce traces de ejecucion. El prover ZK (Rust) necesita witnesses. El witness generator es el puente entre ambos. Investiga: como Polygon Hermez, Scroll y zkSync generan witnesses desde traces EVM. Estudia algebraic intermediate representations (AIR). Analiza que operaciones EVM producen mas datos de witness (storage, memory, stack). Benchmark: tiempo de witness generation vs tamano del trace, uso de memoria durante generacion. Comienza con /experiment.

**Expected Output:**
- Witness generation architecture comparison
- AIR analysis
- Benchmarks: generation time, memory usage
- Working prototype or pseudocode

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-witness-generation/0-input/
```

---

### [14] Logicist | RU-L3: Witness Generation

- [x] **Complete** (2026-03-19 -- TLC PASS: 8 invariants + Termination liveness, Completeness/Soundness/Determinism)

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [13] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre witness generation en TLA+. Unidad: witness-generation. Materiales en 0-input/. Formaliza WitnessExtract(trace) -> witness como funcion. Invariantes: Completeness (el witness contiene toda la informacion necesaria para generar proof), Soundness (un witness invalido produce un proof invalido, no un falso positivo), Determinism (mismo trace siempre produce mismo witness). Model check con 3 transacciones, 5 operaciones EVM, 2 tipos de witness data (storage, arithmetic). Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `WitnessGeneration.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/prover-witness-gen/
```

---

### [15] Architect | RU-L3: Witness Generation

- [x] **Complete** (2026-03-19 -- Rust witness gen: 62/62 tests, 0 clippy warnings, thiserror, zero unwrap)

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [14] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada del witness generator. Materiales en implementation-history/prover-witness-gen/. Destino: zkl2/prover/witness/. Implementa en Rust: witness generator que consume execution traces del executor Go (RU-L1). Diseno modular: un modulo de witness por categoria de operacion EVM (aritmetica, memoria, storage, control flow). Formato de salida compatible con el prover ZK. Usa Rust idiomatico: no unwrap() ni expect() en paths de produccion, error types custom por modulo (thiserror), sin unsafe a menos que sea justificado. Tests: traces de transacciones simples, traces con operaciones de storage complejas, determinism check (mismo trace -> mismo witness). Comienza con /implement.

**Expected Output:**
- Rust witness generator in `zkl2/prover/witness/`
- Modular design per EVM operation category
- Test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-witness-generation/
```

---

### [16] Prover | RU-L3: Witness Generation

- [x] **Complete** (2026-03-19 -- VERIFIED: 7 key theorems, 14-field inductive invariant, Rust-TLA+ isomorphism)

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [15] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del witness generator contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-witness-generation/. Construye Spec.v, Impl.v, Refinement.v. Modela Result<T, E> de Rust como Inductive custom en Coq. Enfocate en probar Completeness (witness contiene toda la informacion necesaria) y Determinism (mismo trace -> mismo witness). Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## RU-L5: BasisRollup.sol (L1 Settlement)

### [17] Scientist | RU-L5: BasisRollup

- [x] **Complete** (2026-03-19 -- CONFIRMED: BasisRollup.sol 400+ lines, 287K gas, commit-prove-execute, 61 tests)

**Directory:** `lab/1-scientist/`
**Prerequisite:** Items [01], [13] complete. Validium RU-V3 should be done.

**Prompt:**

> Investiga contratos rollup en L1 para un zkEVM L2 empresarial. Hipotesis: un contrato BasisRollup.sol puede verificar validity proofs de batches L2, mantener state root chain por empresa, y procesar submissions a < 500K gas, extendiendo los patrones del Validium StateCommitment.sol al modelo zkEVM completo con tracking a nivel de bloque. Contexto: en el Validium MVP ya implementamos StateCommitment.sol (tracking de state roots por empresa). Ahora necesitamos extenderlo para el modelo L2 completo: bloques L2 (no solo batches), commit-prove-execute pattern, finality tracking. Investiga: contrato rollup de zkSync Era, Polygon zkEVM, Scroll. Gas optimization: compresion de calldata, batch commitment schemes. Analiza: commit-prove-execute vs verificacion directa. Benchmark: gas costs para diferentes tamanos de batch y sistemas de proof. Comienza con /experiment.

**Expected Output:**
- Rollup contract pattern comparison
- Gas cost analysis
- Commit-prove-execute analysis
- Benchmarks

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-basis-rollup/0-input/
```

---

### [18] Logicist | RU-L5: BasisRollup

- [x] **Complete** (2026-03-19 -- TLC PASS: 12 invariants, commit-prove-execute lifecycle, extends RU-V3)

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [17] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre el contrato BasisRollup en TLA+. Unidad: basis-rollup. Materiales en 0-input/. Extiende la formalizacion del Validium StateCommitment para modelo de bloques L2. Formaliza: CommitBatch, ProveBatch, FinalizeBatch como acciones. Invariantes: ChainContinuity (state roots forman cadena sin gaps), ProofBeforeFinality (batch solo se finaliza si proof es valido), ReorgProtection (batch finalizado no puede revertirse). Model check con 2 empresas, 4 batches, simular intento de reorg y commit sin proof. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `BasisRollup.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/contract-basis-rollup/
```

---

### [19] Architect | RU-L5: BasisRollup

- [x] **Complete** (2026-03-19 -- BasisRollup.sol: 88 tests, 12/12 invariants, commit-prove-execute, 23 adversarial)

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [18] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada de BasisRollup.sol. Materiales en implementation-history/contract-basis-rollup/. Destino: zkl2/contracts/. Implementa en Solidity 0.8.24 (evmVersion: cancun): BasisRollup.sol con batch commitment, proof verification, state root chain, y finality tracking. Integracion con EnterpriseRegistry.sol del L1 existente para permisos. Incluye: commit-prove-execute pattern si la investigacion lo justifica, eventos para indexing, view functions para queries. Setup Hardhat para el directorio zkl2/contracts/ con la misma configuracion que l1/contracts/ (Solidity 0.8.24, evmVersion cancun, zero-fee). Tests > 85% coverage + adversarial. Comienza con /implement.

**Expected Output:**
- `BasisRollup.sol` in `zkl2/contracts/`
- Hardhat project setup
- Comprehensive test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-basis-rollup/
```

---

### [20] Prover | RU-L5: BasisRollup

- [x] **Complete** (2026-03-19 -- VERIFIED: 13 theorems, 0 Admitted, 0 axioms, bidirectional refinement)

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [19] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion de BasisRollup.sol contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-basis-rollup/. Construye Spec.v, Impl.v, Refinement.v. Modela storage de Solidity como mappings y require/revert como precondiciones. Enfocate en probar ChainContinuity y ReorgProtection. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## RU-L6: End-to-End L2-to-L1 Proving Pipeline

### [21] Scientist | RU-L6: E2E Pipeline

- [x] **Complete** (2026-03-19 -- Go pipeline orchestrator, 4 benchmark result files, bottleneck analysis)

**Directory:** `lab/1-scientist/`
**Prerequisite:** Items [01], [05], [09], [13], [17] complete (all Scientist work for Phase 1-2).

**Prompt:**

> Investiga arquitecturas de pipeline end-to-end para un zkEVM L2 que conecta ejecucion, witness generation, proving y settlement. Hipotesis: un pipeline E2E (tx L2 -> ejecucion EVM -> trace -> witness -> proof -> verificacion L1) puede procesar un batch de 100 transacciones L2 con latencia total < 5 minutos, sin intervencion manual y con retry automatico en caso de fallo. Contexto: ya tenemos implementados los componentes individuales: executor EVM (Go), sequencer (Go), state DB (Go), witness generator (Rust), BasisRollup.sol (Solidity). Necesitamos orquestar todo en un pipeline coherente. Investiga: pipeline de proving de Polygon CDK, pipeline de Scroll, oportunidades de paralelismo (multiples batches proving concurrentemente). Benchmark: desglose de latencia E2E (ejecucion, witness gen, proving, submission). Identifica bottlenecks y oportunidades de optimizacion. Comienza con /experiment.

**Expected Output:**
- Pipeline architecture design
- Latency breakdown analysis
- Parallelism opportunities
- Bottleneck identification

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-e2e-pipeline/0-input/
```

---

### [22] Logicist | RU-L6: E2E Pipeline

- [x] **Complete** (2026-03-19 -- TLC PASS: Safety 2,024 states + Liveness 10,648 states, pipeline integrity verified)

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [21] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre el pipeline E2E en TLA+. Unidad: e2e-pipeline. Materiales en 0-input/. Formaliza la state machine completa del pipeline: stages (Execute, Witness, Prove, Submit, Finalize). Invariantes: PipelineIntegrity (todo batch committed tiene proof valido en L1), Liveness (batches pendientes eventualmente se prueban y envian), Atomicity (fallo parcial del pipeline no corrompe estado). Model check con 3 batches, simular fallo en stage Prove y en stage Submit. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `E2EPipeline.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/node-e2e-pipeline/
```

---

### [23] Architect | RU-L6: E2E Pipeline

- [x] **Complete** (2026-03-19 -- Go pipeline: 17/17 tests, 26 adversarial, Stages interface, concurrent batches)

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [22] complete, verified specs in `implementation-history/`.
**Also requires:** Items [03], [07], [11], [15], [19] complete (all Architect implementations).

**Prompt:**

> Implementa la especificacion verificada del pipeline E2E. Materiales en implementation-history/node-e2e-pipeline/. Destino: zkl2/node/pipeline/. Implementa en Go: pipeline orchestrator que conecta executor EVM (zkl2/node/executor/), sequencer (zkl2/node/sequencer/), state DB (zkl2/node/statedb/), witness generator (zkl2/prover/witness/ via IPC o FFI), y L1 submitter (ethers/Go client hacia BasisRollup.sol). Incluye: retry logic con exponential backoff, monitoring y metricas, logging estructurado, graceful shutdown. Tests E2E: ejecutar contratos Solidity reales en L2 y verificar proof en L1. Este es el core del nodo L2. Comienza con /implement.

**Expected Output:**
- Go pipeline orchestrator in `zkl2/node/pipeline/`
- Integration with all Phase 1-2 components
- E2E test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-e2e-pipeline/
```

---

### [24] Prover | RU-L6: E2E Pipeline

- [x] **Complete** (2026-03-19 -- VERIFIED: 5 theorems, PipelineIntegrity + AtomicFailure proved, 0 Admitted)

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [23] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del pipeline E2E contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-e2e-pipeline/. Construye Spec.v, Impl.v, Refinement.v. Enfocate en probar PipelineIntegrity (todo batch tiene proof valido) y Atomicity (fallo parcial no corrompe estado). Modela las etapas del pipeline como transiciones de estado secuenciales con posibilidad de fallo y retry. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## Phase 3: Bridge and Data Availability

---

## RU-L7: BasisBridge.sol (L1 <-> L2 Asset Transfer)

### [25] Scientist | RU-L7: Bridge

- [x] **Complete** (2026-03-19 -- BasisBridge.sol prototype + Go relayer, deposit/withdrawal/escape hatch)

**Directory:** `lab/1-scientist/`
**Prerequisite:** Items [17], [21] complete.

**Prompt:**

> Investiga disenos de bridge L1-L2 para un zkEVM empresarial. Hipotesis: un bridge puede procesar deposits (L1 -> L2) en < 5 minutos y withdrawals (L2 -> L1) en < 30 minutos, con escape hatch que permite withdrawal via Merkle proof directamente en L1 si el sequencer esta offline > 24 horas. Contexto: Basis Network L1 es zero-fee en Avalanche Fuji. El L2 es empresarial con sequencer single-operator. Necesitamos un bridge seguro para transferir assets entre capas. Investiga: bridge de zkSync Era, Polygon zkEVM, Scroll. Escape hatch mechanisms y sus asunciones de seguridad. Prevencion de double-spend. Benchmark: latencia de deposit/withdrawal, costos de gas. Comienza con /experiment.

**Expected Output:**
- Bridge design comparison
- Escape hatch mechanism design
- Double-spend prevention analysis
- Benchmarks

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-bridge/0-input/
```

---

### [26] Logicist | RU-L7: Bridge

- [x] **Complete** (2026-03-19 -- TLC PASS: NoDoubleSpend + EscapeHatchLiveness + BalanceConservation)

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [25] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre el bridge L1-L2 en TLA+. Unidad: bridge. Materiales en 0-input/. Formaliza: Deposit(L1->L2), Withdrawal(L2->L1), ForcedWithdrawal (escape hatch). Invariantes: NoDoubleSpend (un asset no puede retirarse dos veces), EscapeHatchLiveness (si sequencer offline > T, usuario puede retirar via L1), BalanceConservation (total locked en L1 == total minted en L2). Model check con 2 usuarios, 3 deposits, 2 withdrawals. Simular: double-spend attempt, sequencer offline + escape hatch. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `Bridge.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/contract-bridge/
```

---

### [27] Architect | RU-L7: Bridge

- [x] **Complete** (2026-03-19 -- BasisBridge.sol + Go relayer, 6 TLA+ invariants, escape hatch, nullifiers)

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [26] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada del bridge L1-L2. Materiales en implementation-history/contract-bridge/. Destinos: zkl2/contracts/BasisBridge.sol (L1 side), zkl2/bridge/relayer/ (Go relayer), zkl2/node/ integracion con pipeline. Implementa en Solidity 0.8.24: BasisBridge.sol con deposit (lock en L1, mint en L2), withdrawal (burn en L2, release en L1), y escape hatch (withdrawal via Merkle proof si sequencer offline > 24h). Implementa en Go: relayer que monitorea eventos en L1 y L2, procesa deposits y withdrawals. Tests: flow completo de deposit, flow completo de withdrawal, escape hatch, intento de double-spend. evmVersion: cancun. Comienza con /implement.

**Expected Output:**
- `BasisBridge.sol` in `zkl2/contracts/`
- Go relayer in `zkl2/bridge/relayer/`
- Test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-bridge/
```

---

### [28] Prover | RU-L7: Bridge

- [x] **Complete** (2026-03-19 -- VERIFIED: 9 theorems, 1,491 lines Coq, NoDoubleSpend + BalanceConservation + EscapeHatch)

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [27] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del bridge contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-bridge/. Construye Spec.v, Impl.v, Refinement.v. PRIORIDAD MAXIMA: probar NoDoubleSpend y BalanceConservation. Estos son criticos para la seguridad de assets. Modela deposits/withdrawals como transferencias atomicas entre dos dominios (L1 y L2). Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## RU-L8: Enterprise DAC (Production)

### [29] Scientist | RU-L8: Production DAC

- [x] **Complete** (2026-03-19 -- CONFIRMED: 99.997% availability, 8.94ms attestation, Go + Reed-Solomon, 36x faster than validium)

**Directory:** `lab/1-scientist/`
**Prerequisite:** Item [21] complete. Validium RU-V6 should be done.

**Prompt:**

> Investiga un Data Availability Committee de produccion para un zkEVM L2 empresarial, extendiendo el diseno basico del Validium (RU-V6). Hipotesis: un DAC de produccion con erasure coding puede lograr 99.9% disponibilidad de datos con asuncion de minoria honesta 5-of-7, latencia de attestation < 1 segundo, y recovery verificable de datos desde cualquier 5 nodos. Contexto: en el Validium MVP implementamos un DAC basico de 3 nodos con 2-of-3. Ahora necesitamos escalar a produccion con erasure coding y attestation on-chain robusta. Reutiliza la investigacion del Validium RU-V6. Investiga: erasure coding (Reed-Solomon), KZG commitments para DA, EigenDA, Celestia DA, Polygon Avail en produccion. Benchmark: latencia de attestation, overhead de storage, tiempo de recovery a escala. Comienza con /experiment.

**Expected Output:**
- Production DAC architecture
- Erasure coding analysis
- Scaling benchmarks
- Recovery protocol design

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-production-dac/0-input/
```

---

### [30] Logicist | RU-L8: Production DAC

- [x] **Complete** (2026-03-19 -- TLC PASS: 395K states, 7-node DAC with erasure coding, safety + liveness)

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [29] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre el DAC de produccion en TLA+. Unidad: production-dac. Materiales en 0-input/. Extiende la formalizacion del Validium RU-V6 para comite mayor (7 nodos) con erasure coding. Invariantes: DataRecoverability (datos recuperables desde cualquier 5 de 7 nodos), AttestationLiveness (attestation completa si >= 5 nodos online), IntegrityVerification (datos recuperados son verificablemente correctos). Model check con 7 nodos, simular 2 nodos caidos y 1 nodo malicioso simultaneamente. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `ProductionDAC.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/node-production-dac/
```

---

### [31] Architect | RU-L8: Production DAC

- [x] **Complete** (2026-03-19 -- Go DAC: 2,389 lines, 28/28 tests, BasisDAC.sol 342 lines, 23 adversarial vectors)

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [30] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada del DAC de produccion. Materiales en implementation-history/node-production-dac/. Destinos: zkl2/node/da/ (Go DAC module), zkl2/contracts/BasisDAC.sol (attestation on-chain). Implementa en Go: DACNode con erasure coding, protocolo de attestation para 7 nodos, recovery de datos desde 5 nodos. Implementa en Solidity 0.8.24: BasisDAC.sol para registro de attestations on-chain. Integracion con el pipeline E2E (RU-L6). Tests: recovery desde 5 de 7, 2 nodos caidos, nodo malicioso, attestation bajo carga. evmVersion: cancun. Comienza con /implement.

**Expected Output:**
- Go DAC module in `zkl2/node/da/`
- `BasisDAC.sol` in `zkl2/contracts/`
- Test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-production-dac/
```

---

### [32] Prover | RU-L8: Production DAC

- [x] **Complete** (2026-03-19 -- VERIFIED: 19 theorems, 0 Admitted, 1,360 lines Coq, 8 safety invariants + 3 crypto properties)

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [31] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del DAC de produccion contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-production-dac/. Construye Spec.v, Impl.v, Refinement.v. Enfocate en probar DataRecoverability (datos recuperables desde 5 de 7 nodos) y IntegrityVerification (datos recuperados son correctos). Modela erasure coding como funcion de codificacion/decodificacion con propiedades algebraicas. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## Phase 4: Production Hardening

---

## RU-L9: PLONK Migration

### [33] Scientist | RU-L9: PLONK

- [x] **Complete** (2026-03-19 -- halo2-KZG selected, Rust benchmarks, 402-line findings, BN254 field compatible)

**Directory:** `lab/1-scientist/`
**Prerequisite:** Item [21] complete (needs working E2E pipeline).

**Prompt:**

> Investiga la migracion de Groth16 a PLONK para el prover ZK del L2 zkEVM. Hipotesis: migrar de Groth16 a PLONK (via halo2 o plonky2 en Rust) elimina la necesidad de trusted setup por circuito, permite custom gates para operaciones EVM, y mantiene verificacion on-chain < 500K gas con proof size < 1KB. Contexto: actualmente usamos Groth16 con Circom (validium MVP). Para el L2 necesitamos un sistema de proofs mas flexible. Decisiones tecnicas en zkl2/docs/TECHNICAL_DECISIONS.md (TD-003: PLONK como target). Investiga: halo2 (Zcash/Scroll), plonky2 (Polygon), PLONK arithmetization. Custom gates para opcodes EVM (suma, multiplicacion, memory access). Benchmark comparativo: Groth16 vs PLONK en proving time, proof size, verification gas, complejidad de setup. Evalua madurez y readiness de produccion de cada libreria. Comienza con /experiment.

**Expected Output:**
- PLONK library comparison (halo2, plonky2)
- Custom gate analysis for EVM opcodes
- Groth16 vs PLONK benchmarks
- Maturity assessment

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-plonk-migration/0-input/
```

---

### [34] Logicist | RU-L9: PLONK

- [x] **Complete** (2026-03-19 -- TLC PASS: 3.98M states, 9 invariants, dual-verification + rollback)

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [33] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre migracion a PLONK en TLA+. Unidad: plonk-migration. Materiales en 0-input/. Formaliza las propiedades del proof system como axiomas. Verifica que cambiar de Groth16 a PLONK no rompe invariantes del sistema (Soundness, Completeness, Zero-Knowledge). Formaliza el proceso de migracion: periodo de verificacion dual (ambos proof systems aceptados), corte a PLONK-only. Invariantes: MigrationSafety (ningun batch queda sin verificar durante migracion), BackwardCompatibility (proofs Groth16 existentes siguen siendo verificables durante periodo dual). Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `PlonkMigration.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/prover-plonk-migration/
```

---

### [35] Architect | RU-L9: PLONK

- [ ] **Complete**

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [34] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada de migracion a PLONK. Materiales en implementation-history/prover-plonk-migration/. Destinos: zkl2/prover/circuit/ (Rust PLONK circuit), zkl2/contracts/ (verifier contract actualizado). Implementa en Rust: circuito PLONK con custom gates usando la libreria seleccionada por el Scientist (halo2 o plonky2). Implementa verifier contract actualizado en Solidity 0.8.24 que soporte verificacion dual (Groth16 + PLONK durante periodo de migracion). Plan de migracion: deploy del nuevo verifier, periodo dual, corte. Tests: verificacion de proofs PLONK, verificacion de proofs Groth16 legacy, periodo dual, corte. evmVersion: cancun. Comienza con /implement.

**Expected Output:**
- Rust PLONK circuit in `zkl2/prover/circuit/`
- Updated verifier contract
- Migration plan implementation
- Test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-plonk-migration/
```

---

### [36] Prover | RU-L9: PLONK

- [ ] **Complete**

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [35] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion de la migracion a PLONK contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-plonk-migration/. Construye Spec.v, Impl.v, Refinement.v. Enfocate en probar que la migracion preserva Soundness (el cambio de proof system no introduce falsos positivos) y MigrationSafety (ningun batch sin verificar durante migracion). Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## RU-L10: Proof Aggregation and Recursive Composition

### [37] Scientist | RU-L10: Proof Aggregation

- [ ] **Complete**

**Directory:** `lab/1-scientist/`
**Prerequisite:** Item [33] complete (needs PLONK knowledge).

**Prompt:**

> Investiga agregacion de proofs y composicion recursiva para un zkEVM L2 multi-empresa. Hipotesis: composicion recursiva de proofs puede agregar proofs de N batches empresariales en un solo proof verificable en L1, reduciendo gas de verificacion por empresa en N-fold manteniendo garantias de soundness. Contexto: cada empresa tiene su propia cadena L2. Cada cadena produce proofs individuales. Queremos agregar multiples proofs en uno para reducir costos de verificacion en L1. Investiga: recursive SNARKs, SnarkPack, Nova folding schemes. Estrategias de agregacion (arbol, secuencial, paralela). Benchmark: overhead de agregacion, ahorro de gas vs numero de proofs agregados. Comienza con /experiment.

**Expected Output:**
- Recursive proof techniques comparison
- Aggregation strategy analysis
- Gas savings benchmarks
- Feasibility assessment

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-proof-aggregation/0-input/
```

---

### [38] Logicist | RU-L10: Proof Aggregation

- [ ] **Complete**

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [37] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre agregacion de proofs en TLA+. Unidad: proof-aggregation. Materiales en 0-input/. Formaliza AggregateProof(proof1, ..., proofN) -> aggregatedProof. Invariantes: AggregationSoundness (proof agregado valido sii todos los proofs componentes son validos), IndependencePreservation (fallo de un proof de empresa no invalida los demas). Model check con 3 empresas, 2 proofs cada una, 1 agregacion. Simular: proof invalido en posicion 2, intento de incluir proof duplicado. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `ProofAggregation.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/prover-aggregation/
```

---

### [39] Architect | RU-L10: Proof Aggregation

- [ ] **Complete**

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [38] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada de agregacion de proofs. Materiales en implementation-history/prover-aggregation/. Destinos: zkl2/prover/aggregator/ (Rust aggregation pipeline), zkl2/contracts/ (verifier actualizado para proofs agregados). Implementa en Rust: pipeline de agregacion que toma N proofs individuales y produce un proof agregado. Implementa verifier contract actualizado que verifica proofs agregados. Tests: agregacion de 2, 4, 8 proofs, proof invalido en el medio, independence check. Comienza con /implement.

**Expected Output:**
- Rust aggregation pipeline in `zkl2/prover/aggregator/`
- Updated verifier contract
- Test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-proof-aggregation/
```

---

### [40] Prover | RU-L10: Proof Aggregation

- [ ] **Complete**

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [39] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion de agregacion de proofs contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-proof-aggregation/. Construye Spec.v, Impl.v, Refinement.v. Enfocate en probar AggregationSoundness (proof agregado valido sii todos los componentes son validos). Esta es una propiedad critica de seguridad. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## Phase 5: Enterprise Features

---

## RU-L11: Cross-Enterprise Hub-and-Spoke

### [41] Scientist | RU-L11: Hub-and-Spoke

- [ ] **Complete**

**Directory:** `lab/1-scientist/`
**Prerequisite:** Items [37], [25] complete. Validium RU-V7 should be done.

**Prompt:**

> Investiga un modelo hub-and-spoke para comunicacion cross-enterprise en un zkEVM L2 multi-empresa. Hipotesis: un modelo hub-and-spoke usando el L1 como hub puede verificar interacciones cross-enterprise con proofs recursivos, manteniendo aislamiento completo de datos entre empresas y habilitando transacciones inter-empresa verificables (ej: supply chain entre companias). Contexto: en el Validium MVP investigamos cross-enterprise basico (RU-V7). Ahora tenemos proofs recursivos (RU-L10) y bridge (RU-L7). Podemos construir un sistema mas robusto. Cada empresa tiene su L2 chain. Queremos que empresa A pueda verificar algo sobre empresa B sin ver sus datos. Investiga: modelo cross-privacy de Rayls (JP Morgan), Project EPIC (BIS), mensajeria inter-chain, transferencia de assets entre L2s empresariales. Comienza con /experiment.

**Expected Output:**
- Hub-and-spoke architecture design
- Cross-enterprise privacy analysis
- Recursive proof integration design
- Comparison with Rayls/EPIC

**Handoff:** Copy to Logicist:
```
lab/2-logicist/research-history/YYYY-MM-hub-and-spoke/0-input/
```

---

### [42] Logicist | RU-L11: Hub-and-Spoke

- [ ] **Complete**

**Directory:** `lab/2-logicist/`
**Prerequisite:** Item [41] complete, materials in `0-input/`.

**Prompt:**

> Formaliza la investigacion sobre hub-and-spoke cross-enterprise en TLA+. Unidad: hub-and-spoke. Materiales en 0-input/. Formaliza CrossEnterpriseTransaction(enterpriseA, enterpriseB, proof) con el L1 como hub. Invariantes: Isolation (datos de empresa A nunca visibles para empresa B), CrossConsistency (estado cross-enterprise consistente en L1), AtomicSettlement (tx cross-enterprise se completa totalmente o se revierte totalmente). Model check con 3 empresas, 2 txs cross-enterprise. Simular: intento de romper isolation, settlement parcial. Comienza con /1-formalize.

**Expected Output:**
- TLA+ spec: `HubAndSpoke.tla`
- Model check PASS
- Phase reports and walkthrough.md

**Handoff:** Copy to Architect:
```
lab/3-architect/implementation-history/cross-enterprise-hub/
```

---

### [43] Architect | RU-L11: Hub-and-Spoke

- [ ] **Complete**

**Directory:** `lab/3-architect/`
**Prerequisite:** Item [42] complete, verified specs in `implementation-history/`.

**Prompt:**

> Implementa la especificacion verificada del modelo hub-and-spoke cross-enterprise. Materiales en implementation-history/cross-enterprise-hub/. Destinos: zkl2/node/cross-enterprise/ (Go protocol), zkl2/contracts/ (hub contract en L1). Implementa en Go: protocolo cross-enterprise que permite a empresa A verificar claims sobre empresa B sin ver datos. El L1 actua como hub de routing y verificacion. Implementa en Solidity 0.8.24: contrato hub para routing y verificacion de proofs cross-enterprise, settlement atomico. Tests: tx cross-enterprise exitosa, intento de romper isolation, settlement parcial (debe fallar atomicamente), replay de tx cross-enterprise. evmVersion: cancun. Comienza con /implement.

**Expected Output:**
- Go cross-enterprise module in `zkl2/node/cross-enterprise/`
- Hub contract in `zkl2/contracts/`
- Test suite
- ADVERSARIAL-REPORT.md

**Handoff:** Prepare snapshots for Prover:
```
lab/4-prover/verification-history/YYYY-MM-hub-and-spoke/
```

---

### [44] Prover | RU-L11: Hub-and-Spoke

- [ ] **Complete**

**Directory:** `lab/4-prover/`
**Prerequisite:** Item [43] complete, snapshots prepared.

**Prompt:**

> Verifica la implementacion del modelo hub-and-spoke contra su especificacion TLA+. Snapshots en verification-history/YYYY-MM-hub-and-spoke/. Construye Spec.v, Impl.v, Refinement.v. PRIORIDADES: Isolation (datos de empresa A no visibles para B) y AtomicSettlement (tx cross-enterprise es atomica). Estas son propiedades criticas de seguridad y privacidad. Comienza con /verify.

**Expected Output:**
- Coq proofs in `1-proofs/`
- SUMMARY.md with verdict

---

## Summary

| # | Agent | RU | Phase | Component |
|---|-------|----|-------|-----------|
| 01 | Scientist | L1 | 1 | EVM Executor |
| 02 | Logicist | L1 | 1 | EVM Executor |
| 03 | Architect | L1 | 1 | EVM Executor |
| 04 | Prover | L1 | 1 | EVM Executor |
| 05 | Scientist | L2 | 1 | Sequencer |
| 06 | Logicist | L2 | 1 | Sequencer |
| 07 | Architect | L2 | 1 | Sequencer |
| 08 | Prover | L2 | 1 | Sequencer |
| 09 | Scientist | L4 | 1 | State Database |
| 10 | Logicist | L4 | 1 | State Database |
| 11 | Architect | L4 | 1 | State Database |
| 12 | Prover | L4 | 1 | State Database |
| 13 | Scientist | L3 | 2 | Witness Generation |
| 14 | Logicist | L3 | 2 | Witness Generation |
| 15 | Architect | L3 | 2 | Witness Generation |
| 16 | Prover | L3 | 2 | Witness Generation |
| 17 | Scientist | L5 | 2 | BasisRollup.sol |
| 18 | Logicist | L5 | 2 | BasisRollup.sol |
| 19 | Architect | L5 | 2 | BasisRollup.sol |
| 20 | Prover | L5 | 2 | BasisRollup.sol |
| 21 | Scientist | L6 | 2 | E2E Pipeline |
| 22 | Logicist | L6 | 2 | E2E Pipeline |
| 23 | Architect | L6 | 2 | E2E Pipeline |
| 24 | Prover | L6 | 2 | E2E Pipeline |
| 25 | Scientist | L7 | 3 | Bridge |
| 26 | Logicist | L7 | 3 | Bridge |
| 27 | Architect | L7 | 3 | Bridge |
| 28 | Prover | L7 | 3 | Bridge |
| 29 | Scientist | L8 | 3 | Production DAC |
| 30 | Logicist | L8 | 3 | Production DAC |
| 31 | Architect | L8 | 3 | Production DAC |
| 32 | Prover | L8 | 3 | Production DAC |
| 33 | Scientist | L9 | 4 | PLONK Migration |
| 34 | Logicist | L9 | 4 | PLONK Migration |
| 35 | Architect | L9 | 4 | PLONK Migration |
| 36 | Prover | L9 | 4 | PLONK Migration |
| 37 | Scientist | L10 | 4 | Proof Aggregation |
| 38 | Logicist | L10 | 4 | Proof Aggregation |
| 39 | Architect | L10 | 4 | Proof Aggregation |
| 40 | Prover | L10 | 4 | Proof Aggregation |
| 41 | Scientist | L11 | 5 | Hub-and-Spoke |
| 42 | Logicist | L11 | 5 | Hub-and-Spoke |
| 43 | Architect | L11 | 5 | Hub-and-Spoke |
| 44 | Prover | L11 | 5 | Hub-and-Spoke |

**Total: 44 agent executions for zkEVM L2.**

Note: Within each phase, some RUs can run in parallel if you have multiple agent instances.
For example, in Phase 1, RU-L1, RU-L2, and RU-L4 Scientist work can be parallelized.
The strict sequential order above is the safest execution path.
See `ROADMAP.md` for the pipelined execution timeline.
