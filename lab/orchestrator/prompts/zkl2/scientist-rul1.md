Investiga como hacer un fork minimo de go-ethereum para usarlo como motor de ejecucion EVM en un L2 zkEVM empresarial.

HIPOTESIS: Un fork minimo de Geth puede ejecutar transacciones EVM con state management propio, produciendo execution traces (reads/writes de storage, opcodes ejecutados) necesarios para witness generation, manteniendo 100% compatibilidad con opcodes Cancun y procesando 1000+ transacciones simples por segundo.

CONTEXTO:
- Estamos construyendo un zkEVM L2 sobre Basis Network (Avalanche L1, Chain ID 43199)
- El nodo L2 necesita ejecutar contratos Solidity y producir traces para que un prover ZK en Rust pueda generar proofs
- Las decisiones tecnicas estan en zkl2/docs/TECHNICAL_DECISIONS.md (TD-001: Go para nodo, TD-007: fork de Geth)
- La arquitectura esta en zkl2/docs/ARCHITECTURE.md
- Ya completamos el Validium MVP (validium/) con SMT, circuits, state commitment, etc.
- El target es zkl2 (produccion completa, NO un MVP)
- Fecha: 2026-03-19

TAREAS OBLIGATORIAS:

1. CREAR ESTRUCTURA DEL EXPERIMENTO en zkl2/research/experiments/2026-03-19_evm-executor/ con:
   - hypothesis.json (name: evm-executor, target: zkl2, domain: l2-architecture)
   - state.json, journal.md, findings.md, code/, results/, memory/session.md

2. LITERATURE REVIEW (usar web search):
   - Como Polygon CDK forkea Geth (cdk-erigon, modulos usados)
   - Como Scroll forkea Geth (scroll-geth, modificaciones al state trie)
   - Como zkSync Era NO usa Geth (custom VM, por que)
   - Geth modulos minimos: core/vm (EVM interpreter), core/state (state management), ethdb (database)
   - Trace generation: Geth tracers (structLogger, callTracer), custom tracer para ZK
   - Opcodes Cancun que requieren tratamiento especial en ZK:
     - KECCAK256: extremadamente costoso en ZK (~150K constraints)
     - BLOCKHASH: requiere hash oracle
     - SELFDESTRUCT: deprecated en Cancun, tratamiento especial
     - CREATE/CREATE2: deployment de contratos
     - CALL/DELEGATECALL/STATICCALL: cross-contract calls
   - Publicaciones: Polygon zkEVM documentation, Scroll technical blog, PSE (Privacy and Scaling Explorations)

3. ANALISIS DE MODULOS MINIMOS DE GETH:
   - core/vm/: interpreter, opcodes, stack, memory, contracts -- NECESARIO
   - core/state/: stateDB, stateObject, journal -- NECESARIO (modificar para Poseidon SMT)
   - ethdb/: database interface -- NECESARIO (abstraccion)
   - core/types/: transaction, block, receipt -- NECESARIO
   - params/: chain config -- NECESARIO (configurar para L2)
   - crypto/: hashing, signing -- NECESARIO
   - NO necesario: p2p, eth/, les/, consensus/ (el L2 tiene su propio consensus via sequencer)
   - Medir: cuantas lineas de codigo es el fork minimo vs Geth completo

4. CODIGO EXPERIMENTAL en code/:
   - Go prototype que importa los modulos de Geth necesarios
   - Ejecuta una transaccion simple (transfer, storage write) y captura el trace
   - Benchmark: tx/s para transacciones simples (transfer, ERC20 transfer, storage)
   - Mide: tamano del trace por transaccion, overhead de tracing vs ejecucion vanilla
   - go.mod con dependencia de github.com/ethereum/go-ethereum

5. MAPPING DE OPCODES ZK-PROBLEMATICOS:
   - Tabla: opcode, constraint cost estimado, tratamiento especial requerido
   - Categorias: arithmetic (barato), memory (moderado), storage (caro), crypto (muy caro)
   - Opcodes que se deben reemplazar vs opcodes que se prueban directamente

6. BENCHMARKS: tx/s, trace size, memory usage

7. SESSION LOG: lab/1-scientist/sessions/2026-03-19_evm-executor.md

8. ACTUALIZAR FOUNDATIONS en zkl2/research/foundations/ si es necesario (crear los archivos si no existen)

NO hagas commits de git. Comienza con /experiment
