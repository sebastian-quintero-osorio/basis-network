Formaliza el Bridge L1<->L2 en TLA+.

CONTEXTO:
- Unidad: bridge en zkl2/specs/units/2026-03-bridge/0-input/
- Target: zkl2, Fecha: 2026-03-19
- TLC tools: lab/2-logicist/tools/tla2tools.jar

QUE FORMALIZAR:
- Deposit(L1->L2), Withdrawal(L2->L1), ForcedWithdrawal(escape hatch)
- INVARIANTES:
  - NoDoubleSpend: asset no se puede retirar dos veces
  - EscapeHatchLiveness: si sequencer offline > T, user puede retirar via L1
  - BalanceConservation: total L1 locked == total L2 minted
- MODEL CHECK: 2 users, 3 operations (deposit, withdraw, forced withdraw)

OUTPUT en zkl2/specs/units/2026-03-bridge/1-formalization/v0-analysis/

SESSION LOG: lab/2-logicist/sessions/2026-03-19_bridge.md
NO hagas commits. Comienza con /1-formalize
