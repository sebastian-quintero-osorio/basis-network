Implementa la especificacion verificada del modelo hub-and-spoke cross-enterprise.

SAFETY LATCH: TLC log en implementation-history/cross-enterprise-hub/tlc-evidence/ muestra PASS.

CONTEXTO:
- TLA+ spec: implementation-history/cross-enterprise-hub/specs/HubAndSpoke.tla
- Scientist research: implementation-history/cross-enterprise-hub/research/findings.md
- Existing contracts: zkl2/contracts/contracts/ (BasisRollup.sol, BasisBridge.sol, BasisDAC.sol, BasisVerifier.sol, BasisAggregator.sol)
- Existing node: zkl2/node/ (executor, sequencer, statedb, pipeline, da)

QUE IMPLEMENTAR:

1. zkl2/node/cross-enterprise/ (Go):
   - hub.go: L1 hub protocol (message routing, proof verification, settlement)
   - spoke.go: L2 spoke protocol (message creation, ZK proof generation for claims)
   - message.go: Cross-enterprise message types and serialization
   - settlement.go: Atomic settlement logic (two-phase commit with ZK verification)
   - types.go: Shared types and interfaces
   - tests.go: Comprehensive test suite

   KEY INVARIANTS FROM TLA+:
   - Isolation: datos de empresa A nunca visibles para empresa B
   - CrossConsistency: estado cross-enterprise consistente en L1
   - AtomicSettlement: tx cross-enterprise atomica (all-or-nothing)
   - ReplayProtection: mensajes no pueden repetirse

2. zkl2/contracts/contracts/BasisHub.sol (Solidity 0.8.24, evmVersion cancun):
   - Cross-enterprise message verification
   - Atomic settlement with rollback
   - Replay protection (nonce-based)
   - Enterprise isolation enforcement
   - Integration with existing contracts

3. Tests:
   - Successful cross-enterprise transaction
   - Isolation violation attempt
   - Partial settlement (must fail atomically)
   - Message replay (must be rejected)
   - Timeout and rollback
   - Multiple concurrent cross-enterprise txs
   - 3-enterprise chain (A->B->C)

4. ADVERSARIAL-REPORT.md
5. Session log

NO hagas commits. Comienza con /implement
