Implementa BasisRollup.sol para el zkEVM L2.

SAFETY LATCH: TLC log en zkl2/specs/units/2026-03-basis-rollup muestra PASS con 12 invariants.

CONTEXTO:
- TLA+ spec: zkl2/specs/units/2026-03-basis-rollup/.../specs/BasisRollup/BasisRollup.tla
- Scientist prototype: zkl2/specs/units/2026-03-basis-rollup/0-input/code/contracts/BasisRollup.sol
- Referencia validium: l1/contracts/contracts/core/StateCommitment.sol
- Destino: zkl2/contracts/
- Solidity 0.8.24, evmVersion cancun

QUE IMPLEMENTAR:

1. zkl2/contracts/contracts/BasisRollup.sol:
   - Commit-prove-execute lifecycle
   - Per-enterprise state chains with L2 block tracking
   - Batch revert capability
   - Integration con EnterpriseRegistry
   - Inline Groth16 verification (from validium pattern)

2. Hardhat project setup: hardhat.config.ts, package.json, tsconfig.json

3. Tests: lifecycle, revert, isolation, adversarial
4. ADVERSARIAL-REPORT.md en zkl2/tests/adversarial/basis-rollup/
5. Session log

NO hagas commits. Comienza con /implement
