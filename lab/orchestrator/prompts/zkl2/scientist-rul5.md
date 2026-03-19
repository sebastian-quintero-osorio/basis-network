Investiga contratos rollup en L1 para un zkEVM L2 empresarial.

HIPOTESIS: Un contrato rollup en Solidity puede verificar validity proofs de L2 batches, mantener state root chain por empresa, y procesar batch submissions a < 500K gas, extendiendo los patrones de Validium RU-V3 al modelo zkEVM completo con block-level tracking.

CONTEXTO:
- Ya tenemos StateCommitment.sol del validium (l1/contracts/contracts/core/StateCommitment.sol, 285K gas)
- Necesitamos extenderlo a BasisRollup.sol para el zkEVM L2 completo
- Block-level (no solo batch-level) state tracking
- Commit-prove-execute pattern (como zkSync Era)
- Target: zkl2 (produccion completa), Fecha: 2026-03-19

TAREAS:
1. CREAR ESTRUCTURA: zkl2/research/experiments/2026-03-19_basis-rollup/
2. LITERATURE REVIEW: zkSync Era, Polygon zkEVM, Scroll rollup contracts, gas optimization
3. CODIGO: Solidity prototype de BasisRollup.sol, Hardhat tests
4. BENCHMARKS: gas costs, batch sizes
5. SESSION LOG: lab/1-scientist/sessions/2026-03-19_basis-rollup.md

NO hagas commits. Comienza con /experiment
