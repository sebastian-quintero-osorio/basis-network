Verifica la implementacion del modelo hub-and-spoke contra su especificacion TLA+.

CONTEXTO: Target: zkl2, Fecha: 2026-03-20, Unidad: hub-and-spoke

INPUTS:
1. TLA+ spec: verification-history/2026-03-hub-and-spoke/specs/HubAndSpoke.tla
2. Go impl: verification-history/2026-03-hub-and-spoke/impl/ (hub.go, spoke.go)
3. Solidity: verification-history/2026-03-hub-and-spoke/impl/BasisHub.sol
4. TLC evidence: verification-history/2026-03-hub-and-spoke/tlc-evidence/
5. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en zkl2/proofs/units/2026-03-hub-and-spoke/

ENFOQUE:
- PRIORIDADES MAXIMAS: Isolation y AtomicSettlement -- son criticas de seguridad y privacidad
- Probar Isolation: datos de empresa A no visibles para empresa B
- Probar AtomicSettlement: tx cross-enterprise es atomica (all-or-nothing)
- Probar CrossConsistency: estado cross-enterprise consistente en L1
- Probar ReplayProtection: mensajes no pueden repetirse
- Modelar deposits/settlements como transferencias atomicas entre dos dominios (L2-A y L2-B via L1 hub)

SESSION LOG: lab/4-prover/sessions/2026-03-20_hub-and-spoke.md
NO hagas commits. Comienza con /verify
