Investiga protocolos de state commitment en L1 para un sistema ZK validium.

HIPOTESIS: Un contrato StateCommitment.sol que mantiene cadenas de state roots por empresa con verificacion de pruebas ZK integrada puede procesar submissions a < 300K gas, detectar gaps y reversiones en la cadena de roots, y mantener historia completa de batches con < 500 bytes de storage por batch.

CONTEXTO:
- Ya tenemos ZKVerifier.sol en l1/contracts/contracts/verification/ que verifica proofs Groth16 (~200K gas) y EnterpriseRegistry.sol para permisos
- El circuito de RU-V2 produce public signals: prevStateRoot, newStateRoot, batchSize, enterpriseId
- Basis Network L1 es zero-fee (permissioned), pero el constraint es storage size
- Target: validium (MVP), Fecha: 2026-03-18

TAREAS:

1. CREAR ESTRUCTURA: validium/research/experiments/2026-03-18_state-commitment/
   hypothesis.json, state.json, journal.md, findings.md, code/, results/, memory/session.md

2. LITERATURE REVIEW:
   - zkSync Era: commit-prove-execute pattern
   - Polygon zkEVM: sequenceBatches + verifyBatches
   - Scroll: commitBatch + finalizeBatch
   - Gas costs de storage layouts en Subnet-EVM
   - State commitment patterns para validium systems

3. CODIGO EXPERIMENTAL:
   - Solidity prototype de StateCommitment.sol
   - Benchmark gas costs de diferentes storage layouts
   - Test de detection de gaps y reversiones

4. EJECUTAR BENCHMARKS

5. SESSION LOG: lab/1-scientist/sessions/2026-03-18_state-commitment.md

NO hagas commits. Comienza con /experiment
