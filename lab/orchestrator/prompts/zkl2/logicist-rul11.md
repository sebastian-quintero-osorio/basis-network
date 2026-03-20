Formaliza la investigacion sobre hub-and-spoke cross-enterprise en TLA+.

Unidad: hub-and-spoke. Materiales en research-history/2026-03-hub-and-spoke/0-input/.

CONTEXTO: Target: zkl2, Fecha: 2026-03-20

Formaliza CrossEnterpriseTransaction(enterpriseA, enterpriseB, proof) con el L1 como hub.

Invariantes:
- Isolation: datos de empresa A nunca visibles para empresa B
- CrossConsistency: estado cross-enterprise consistente en L1
- AtomicSettlement: tx cross-enterprise se completa totalmente o se revierte totalmente
- MessageDelivery: mensajes enviados eventualmente se entregan (liveness)
- ReplayProtection: mensajes no pueden repetirse

Model check con 3 empresas, 2 txs cross-enterprise. Simular:
- Intento de romper isolation (empresa B lee datos de A)
- Settlement parcial (una mitad se ejecuta, la otra no)
- Replay de mensaje cross-enterprise
- Timeout y rollback de transaccion cross-enterprise

Comienza con /1-formalize
