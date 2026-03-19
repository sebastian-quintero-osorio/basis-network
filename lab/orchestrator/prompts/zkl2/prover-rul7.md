Verifica el Bridge contra su TLA+ spec.

CONTEXTO: Target: zkl2, Fecha: 2026-03-19, Unidad: bridge

INPUTS:
1. TLA+ spec: zkl2/specs/units/2026-03-bridge/.../specs/BasisBridge/BasisBridge.tla
2. Solidity + Go: zkl2/contracts/contracts/BasisBridge.sol + zkl2/bridge/relayer/
3. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en zkl2/proofs/units/2026-03-bridge/

ENFOQUE: Probar NoDoubleSpend, EscapeHatchLiveness, BalanceConservation.

SESSION LOG: lab/4-prover/sessions/2026-03-19_bridge.md
NO hagas commits. Comienza con /verify
