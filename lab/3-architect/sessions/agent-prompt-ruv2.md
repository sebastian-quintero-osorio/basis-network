Implementa la especificacion verificada del circuito de transicion de estado.

CONTEXTO:
- Los materiales verificados estan en validium/specs/units/2026-03-state-transition-circuit/
- La especificacion TLA+ esta en 1-formalization/v0-analysis/specs/StateTransitionCircuit/StateTransitionCircuit.tla
- El TLC log (PASS) esta en 1-formalization/v0-analysis/experiments/StateTransitionCircuit/MC_StateTransitionCircuit.log
- El circuito de referencia del Scientist esta en 0-input/code/state_transition_verifier.circom
- Los benchmarks estan en 0-input/results/benchmark_*.json
- Destino: validium/circuits/circuits/
- Target: validium (MVP)

SAFETY LATCH:
1. Lee el TLC log y verifica "Model checking completed. No error has been found."
2. Solo si PASS, procede.

QUE IMPLEMENTAR:

1. CIRCUITO PRINCIPAL: validium/circuits/circuits/state_transition.circom
   - Template StateTransition(depth, batchSize) parametrizable
   - Public inputs: prevStateRoot, newStateRoot, batchSize, enterpriseId
   - Private inputs: transacciones individuales (key, oldValue, newValue) y Merkle proofs (siblings)
   - Para cada tx en el batch:
     a) Verificar Merkle proof del old value contra el estado intermedio
     b) Calcular nuevo leaf hash
     c) Recomputar la ruta hasta la nueva raiz
   - Verificar que la raiz final == newStateRoot
   - Usar Poseidon de circomlib para hashing

2. TEMPLATES AUXILIARES en validium/circuits/circuits/:
   - merkle_proof_verifier.circom: Template MerkleProofVerifier(depth)
   - poseidon_hasher.circom: Wrapper sobre Poseidon de circomlib (si necesario)

3. SCRIPTS en validium/circuits/scripts/:
   - setup.sh: Powers of Tau + circuit-specific key generation
   - prove.sh: Genera proof dado un input
   - verify.sh: Verifica un proof
   - generate_input.js: Genera inputs de prueba

4. NUEVO Groth16Verifier.sol:
   - Despues de compilar el circuito, genera el verifier con snarkjs
   - Exportar a validium/circuits/build/Groth16Verifier.sol
   - Solidity 0.8.24, evmVersion cancun

5. TESTS:
   - Compilar y verificar constraint count
   - Generar witness con inputs validos
   - Generar proof y verificar
   - Edge cases: batch vacio (all zero tx), tx duplicada, root incorrecto, batch size maximo
   - Los tests pueden ser scripts de shell que ejecutan circom + snarkjs

6. ADVERSARIAL-REPORT.md en validium/tests/adversarial/state-transition-circuit/

PARAMETROS DEL MVP:
- Basado en los benchmarks:
  - d32_b4: 137K constraints, 6.9s proving (VIABLE)
  - d32_b8: 274K constraints, 12.8s proving (VIABLE)
  - Recomendado: parametrizable, pero default batch 8 con depth 32
- El circuito debe ser PARAMETRIZABLE (template parameters)

CALIDAD:
- Cada signal documentado con su significado
- Constraint count reportado y justificado
- Test vectors para todos los edge cases
- No unconstrained signals

GIT: NO hagas commits.
SESSION LOG: lab/3-architect/sessions/2026-03-18_state-transition-circuit.md

Comienza con /implement
