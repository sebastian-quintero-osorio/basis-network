Implementa la especificacion verificada del Data Availability Committee.

SAFETY LATCH: El TLC log en validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/experiments/DataAvailability/MC_DataAvailability.log muestra PASS. Procede.

CONTEXTO:
- TLA+ spec: validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/specs/DataAvailability/DataAvailability.tla
- Codigo referencia: validium/specs/units/2026-03-data-availability/0-input/code/src/ (shamir.ts, dac-node.ts, dac-protocol.ts)
- Destino TypeScript: validium/node/src/da/
- Destino Solidity: l1/contracts/contracts/verification/DACAttestation.sol
- package.json de validium/node/ ya existe

QUE IMPLEMENTAR:

1. validium/node/src/da/shamir.ts:
   - Shamir Secret Sharing (k,n) threshold sobre campo BN128
   - split(secret, n, k): Share[]
   - recover(shares: Share[]): bigint
   - verifyShare(share, commitment): boolean

2. validium/node/src/da/dac-node.ts:
   - DACNode class: almacena shares, genera attestations
   - storeShare(batchId, share)
   - attest(batchId): Attestation
   - getShare(batchId): Share

3. validium/node/src/da/dac-protocol.ts:
   - DACProtocol: orquesta distribucion, attestation, recovery
   - distribute(batchId, data, nodes): Certificate
   - recover(batchId, nodes, threshold): Buffer
   - verify(certificate): boolean

4. l1/contracts/contracts/verification/DACAttestation.sol:
   - Solidity 0.8.24, evmVersion cancun
   - Registro on-chain de attestations
   - submitAttestation(batchId, commitment, signatures)
   - verifyAttestation(batchId): bool
   - Integration con EnterpriseRegistry para permisos

5. Tests en validium/node/src/da/__tests__/ y l1/contracts/test/:
   - Privacy: no nodo individual reconstruye datos
   - Recovery: 2 de 3 nodos recuperan datos
   - Nodo malicioso: attestation falsa detectada
   - Hardhat tests para DACAttestation.sol

6. ADVERSARIAL-REPORT.md en validium/tests/adversarial/data-availability/

7. Session log: lab/3-architect/sessions/2026-03-18_data-availability.md

NO hagas commits. Comienza con /implement
