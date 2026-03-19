Formaliza la investigacion sobre el EVM Execution Engine en TLA+.

CONTEXTO:
- Unidad: evm-executor en zkl2/specs/units/2026-03-evm-executor/0-input/
- Target: zkl2 (produccion completa, NO MVP)
- Fecha: 2026-03-19
- TLC tools: lab/2-logicist/tools/tla2tools.jar

QUE FORMALIZAR:
- EVM como state machine con operaciones SLOAD/SSTORE/CALL/CREATE
- Execution trace generation como output de cada transaccion
- INVARIANTES:
  - Determinism: misma tx + mismo state -> mismo resultado y mismo trace
  - TraceCompleteness: el trace captura TODAS las operaciones state-modifying
  - OpcodeCorrectness: cada opcode produce output correcto segun EVM spec
- MODEL CHECK: 3 cuentas, 5 opcodes (ADD, SLOAD, SSTORE, CALL, PUSH), 2 transacciones

OUTPUT en zkl2/specs/units/2026-03-evm-executor/1-formalization/v0-analysis/

SESSION LOG: lab/2-logicist/sessions/2026-03-19_evm-executor.md
NO hagas commits. Comienza con /1-formalize
