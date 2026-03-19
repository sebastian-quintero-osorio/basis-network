Formaliza la investigacion sobre circuitos de transicion de estado en TLA+.

CONTEXTO:
- Unidad: state-transition-circuit
- Materiales en validium/specs/units/2026-03-state-transition-circuit/0-input/
- Target: validium (MVP)
- Fecha: 2026-03-18
- TLA+ tools: lab/2-logicist/tools/tla2tools.jar (ya descargado en la sesion anterior)

MATERIALES DISPONIBLES EN 0-input/:
- README.md: contexto y objetivos
- REPORT.md: findings del Scientist con 7 benchmarks reales
- code/state_transition_verifier.circom: circuito Circom de referencia
- code/generate_input.js: generacion de witness
- results/benchmark_*.json: datos de benchmarks

QUE FORMALIZAR:

1. StateTransition(prevRoot, newRoot, txBatch) como accion TLA+:
   - prevRoot es el state root actual de una empresa
   - txBatch es una secuencia de transacciones, cada una con (key, oldValue, newValue, merkleProof)
   - Cada transaccion actualiza el SMT secuencialmente
   - newRoot es el root resultante despues de aplicar todas las transacciones
   - La transicion es valida si y solo si cada Merkle proof es correcto contra el estado intermedio

2. INVARIANTES CRITICOS:
   - StateRootChain: newRoot es el resultado deterministico de aplicar txBatch a prevRoot
   - BatchIntegrity: cada tx en el batch tiene un Merkle proof valido contra el estado intermedio
   - ProofSoundness: un proof invalido siempre es rechazado

3. MODEL CHECK:
   - 3 empresas
   - Batch size 4
   - 3 state roots de profundidad 3 (8 posibles hojas)
   - Valores: enteros 0..3
   - Simular: batch con tx validas, batch con tx invalida (proof incorrecto), batch con root incorrecto

ESTRUCTURA DE OUTPUT (en validium/specs/units/2026-03-state-transition-circuit/):
```
1-formalization/
  v0-analysis/
    specs/StateTransitionCircuit/
      StateTransitionCircuit.tla
    experiments/StateTransitionCircuit/
      MC_StateTransitionCircuit.tla
      MC_StateTransitionCircuit.cfg
      MC_StateTransitionCircuit.log
    PHASE-1-FORMALIZATION_NOTES.md
    PHASE-2-AUDIT_REPORT.md
```

HERRAMIENTAS:
- TLC ya descargado: lab/2-logicist/tools/tla2tools.jar
- Ejecutar con: java -cp lab/2-logicist/tools/tla2tools.jar tlc2.TLC [options]
- Copiar archivos a _build/ antes de ejecutar TLC (como en la sesion anterior)

REGLAS:
- Lee TODOS los materiales de 0-input/ antes de escribir TLA+
- NUNCA modifiques archivos en 0-input/
- NUNCA debilites un invariante
- Contraejemplos de TLC son descubrimientos valiosos

SESSION LOG: lab/2-logicist/sessions/2026-03-18_state-transition-circuit.md
NO hagas commits de git.

Comienza con /1-formalize
