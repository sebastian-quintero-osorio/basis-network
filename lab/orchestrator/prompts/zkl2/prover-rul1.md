Verifica la implementacion del EVM Executor contra su especificacion TLA+.

CONTEXTO: Target: zkl2, Fecha: 2026-03-19, Unidad: evm-executor

INPUTS:
1. TLA+ spec: zkl2/specs/units/2026-03-evm-executor/1-formalization/v0-analysis/specs/EVMExecutor/EvmExecutor.tla
2. Go impl: zkl2/node/executor/ (executor.go, tracer.go, opcodes.go, types.go)
3. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en zkl2/proofs/units/2026-03-evm-executor/

ENFOQUE:
- Probar Determinism: misma tx + mismo state = mismo resultado
- Probar TraceCompleteness: toda operacion state-modifying genera trace entry
- Modela Go como transiciones de estado (no goroutines para este modulo)
- Modela EVM opcodes como funciones abstractas

SESSION LOG: lab/4-prover/sessions/2026-03-19_evm-executor.md
NO hagas commits. Comienza con /verify
