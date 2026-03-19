Implementa BasisBridge.sol + Go relayer para el zkEVM L2.

SAFETY LATCH: TLC log en zkl2/specs/units/2026-03-bridge muestra PASS.

CONTEXTO:
- TLA+ spec: zkl2/specs/units/2026-03-bridge/.../specs/BasisBridge/BasisBridge.tla
- Scientist prototype: zkl2/specs/units/2026-03-bridge/0-input/code/
- Destinos: zkl2/contracts/ (BasisBridge.sol) + zkl2/bridge/ (Go relayer)

QUE IMPLEMENTAR:

1. zkl2/contracts/contracts/BasisBridge.sol:
   - Deposit(L1->L2): lock tokens on L1, emit event for L2 mint
   - Withdrawal(L2->L1): verify Merkle proof, release tokens
   - ForcedWithdrawal: escape hatch if sequencer offline > 24h
   - Integration con BasisRollup.sol for state root verification

2. zkl2/bridge/relayer/relayer.go:
   - Go relayer watching L1 deposit events, forwarding to L2
   - Watch L2 withdrawal events, submitting to L1

3. Tests + adversarial (double-spend, replay, stale proof)
4. Session log

NO hagas commits. Comienza con /implement
