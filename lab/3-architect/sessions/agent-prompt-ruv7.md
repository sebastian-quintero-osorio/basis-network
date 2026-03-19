Implementa la especificacion verificada de verificacion cross-enterprise.

SAFETY LATCH: TLC log en validium/specs/units/2026-03-cross-enterprise/1-formalization/v0-analysis/experiments/CrossEnterprise/MC_CrossEnterprise.log muestra PASS.

CONTEXTO:
- TLA+ spec: validium/specs/units/2026-03-cross-enterprise/1-formalization/v0-analysis/specs/CrossEnterprise/CrossEnterprise.tla
- Referencia: validium/specs/units/2026-03-cross-enterprise/0-input/code/cross-enterprise-benchmark.ts
- Destinos: validium/node/src/cross-enterprise/ (TypeScript) y l1/contracts/contracts/verification/CrossEnterpriseVerifier.sol

QUE IMPLEMENTAR:

1. validium/node/src/cross-enterprise/cross-reference-builder.ts:
   - Construye evidencia de referencia cruzada entre 2 empresas
   - Takes proofs from both enterprises + reference data
   - Outputs proof of cross-reference validity

2. validium/node/src/cross-enterprise/types.ts
3. validium/node/src/cross-enterprise/index.ts

4. l1/contracts/contracts/verification/CrossEnterpriseVerifier.sol:
   - Solidity 0.8.24, evmVersion cancun
   - verifyCrossReference(enterpriseA, batchIdA, enterpriseB, batchIdB, referenceHash, proofA, proofB)
   - Integration con StateCommitment.sol y EnterpriseRegistry.sol

5. Tests + ADVERSARIAL-REPORT.md

6. Session log: lab/3-architect/sessions/2026-03-18_cross-enterprise.md

NO hagas commits. Comienza con /implement
