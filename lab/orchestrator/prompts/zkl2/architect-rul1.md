Implementa la especificacion verificada del EVM Execution Engine.

SAFETY LATCH: TLC log en zkl2/specs/units/2026-03-evm-executor/1-formalization/v0-analysis/experiments/EVMExecutor/MC_EvmExecutor.log muestra PASS. Procede.

CONTEXTO:
- TLA+ spec: zkl2/specs/units/2026-03-evm-executor/1-formalization/v0-analysis/specs/EVMExecutor/EvmExecutor.tla
- Scientist findings: zkl2/specs/units/2026-03-evm-executor/0-input/REPORT.md
- Go code reference: zkl2/specs/units/2026-03-evm-executor/0-input/code/main.go
- Destino: zkl2/node/executor/
- Target: zkl2 (produccion completa)
- IMPORTANTE: Go puede no estar instalado. Si no lo esta, escribe el codigo Go igualmente -- sera compilado despues de instalar Go.

QUE IMPLEMENTAR:

1. zkl2/node/executor/executor.go:
   - EVM executor que importa conceptos de go-ethereum (core/vm, core/state)
   - ExecuteTransaction(tx, stateDB) -> (receipt, trace, error)
   - Produce execution traces con SLOAD/SSTORE/CALL entries
   - Cada trace entry: {opcode, pc, gas, stack_snapshot, storage_key, storage_value}

2. zkl2/node/executor/tracer.go:
   - ZKTracer que implementa la interfaz de tracing para capturar operaciones relevantes para ZK
   - OnStorageChange, OnBalanceChange hooks
   - Formato de trace optimizado para witness generation

3. zkl2/node/executor/opcodes.go:
   - Mapping de opcodes ZK-problematicos
   - Categorization: cheap (arithmetic), moderate (memory), expensive (storage), critical (crypto)

4. zkl2/node/executor/types.go:
   - ExecutionTrace, TraceEntry, TransactionResult types

5. zkl2/node/go.mod:
   - Go module initialization para zkl2/node
   - Dependencia: github.com/ethereum/go-ethereum (si es posible)

6. Tests en zkl2/node/executor/executor_test.go:
   - Test de ejecucion de transaccion simple
   - Test de trace generation
   - Test de determinismo (misma tx -> mismo trace)
   - Tests adversariales: tx invalida, out-of-gas, stack overflow

7. ADVERSARIAL-REPORT.md en zkl2/tests/adversarial/evm-executor/

8. Session log: lab/3-architect/sessions/2026-03-19_evm-executor.md

CALIDAD PRODUCCION:
- Go idiomatico: error handling explicito, no panic en codigo de libreria
- Context propagation para cancellation
- Structured logging (slog)
- Todos los tipos documentados con godoc comments
- No any/interface{} sin type assertions

NO hagas commits. Comienza con /implement
