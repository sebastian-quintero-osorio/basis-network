Implementa la especificacion verificada del protocolo de state commitment en L1.

SAFETY LATCH: TLC log en validium/specs/units/2026-03-state-commitment/1-formalization/v0-analysis/experiments/StateCommitment/MC_StateCommitment.log muestra PASS. Procede.

CONTEXTO:
- TLA+ spec: validium/specs/units/2026-03-state-commitment/1-formalization/v0-analysis/specs/StateCommitment/StateCommitment.tla
- Referencia: validium/specs/units/2026-03-state-commitment/0-input/code/StateCommitmentV1.sol
- Destino: l1/contracts/contracts/core/StateCommitment.sol
- Ya existe: ZKVerifier.sol, EnterpriseRegistry.sol, DACAttestation.sol
- Solidity 0.8.24, evmVersion cancun, zero-fee gas model
- Hardhat project en l1/contracts/

QUE IMPLEMENTAR:

1. l1/contracts/contracts/core/StateCommitment.sol:
   - mapping enterprise -> EnterpriseState (currentRoot, batchCount, lastTimestamp, initialized)
   - mapping enterprise -> mapping batchId -> bytes32 (root history)
   - initializeEnterprise(enterprise): admin only, sets genesis root
   - submitBatch(enterprise, prevRoot, newRoot, proof, publicSignals): enterprise only
   - Integracion con ZKVerifier.sol (inline Groth16 verification, no delegated call)
   - Integracion con EnterpriseRegistry.sol (onlyAuthorizedEnterprise)
   - ChainContinuity: require prevRoot == currentRoot
   - NoGap: batch ID = batchCount (auto-incremented)
   - Events: BatchCommitted(enterprise, batchId, prevRoot, newRoot, timestamp)
   - NatSpec documentation

2. l1/contracts/test/StateCommitment.test.ts:
   - Unit tests: initialization, batch submission, root chain integrity
   - Adversarial: gap attack, replay attack, wrong enterprise, invalid proof, uninitialized enterprise
   - Coverage > 85%

3. Update l1/contracts/scripts/deploy.ts (or create new deploy script)

4. ADVERSARIAL-REPORT.md en validium/tests/adversarial/state-commitment/

5. Session log: lab/3-architect/sessions/2026-03-18_state-commitment.md

NO hagas commits. Comienza con /implement
