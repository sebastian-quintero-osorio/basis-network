Implementa el circuito Circom de transicion de estado para el sistema validium.

SAFETY LATCH: El TLC log en validium/specs/units/2026-03-state-transition-circuit/1-formalization/v0-analysis/experiments/StateTransitionCircuit/MC_StateTransitionCircuit.log ya muestra PASS. Procede directamente.

CONTEXTO RAPIDO:
- Circuito de referencia: validium/research/experiments/2026-03-18_state-transition-circuit/code/state_transition_verifier.circom
- Ya tenemos circomlib en validium/circuits/node_modules/circomlib/
- Depth 32, batch parametrizable (default 4 para testing rapido)
- Poseidon de circomlib para hashing

ENTREGABLES (solo estos, sin TLC ni benchmarks):

1. validium/circuits/circuits/state_transition.circom:
   - Template StateTransition(depth, batchSize)
   - Public inputs: prevStateRoot, newStateRoot, batchSize, enterpriseId
   - Private inputs: txKeys[batchSize], txOldValues[batchSize], txNewValues[batchSize], txSiblings[batchSize][depth]
   - Para cada tx: verificar Merkle proof del old value, calcular nuevo leaf hash, recomputar path
   - Verificar raiz final == newStateRoot
   - Usar Poseidon de circomlib/circuits/poseidon.circom

2. validium/circuits/circuits/merkle_proof_verifier.circom:
   - Template MerkleProofVerifier(depth)
   - Verifica que un leaf hash + siblings producen un root dado

3. validium/circuits/scripts/setup_state_transition.js:
   - Powers of Tau + circuit key generation para state_transition

4. validium/circuits/scripts/generate_state_transition_input.js:
   - Genera inputs de prueba para el circuito

5. Compilar el circuito con depth=10, batch=4 (rapido) y reportar constraint count

6. validium/tests/adversarial/state-transition-circuit/ADVERSARIAL-REPORT.md

7. lab/3-architect/sessions/2026-03-18_state-transition-circuit.md

RESTRICCIONES:
- Usa include de circomlib (ya instalado): include "circomlib/circuits/poseidon.circom"
- Compila con: circom state_transition.circom --r1cs --wasm --sym -o build/
- No pierdas tiempo en benchmarks extensos, solo compila y verifica constraint count
- NO hagas commits de git

Comienza con /implement
