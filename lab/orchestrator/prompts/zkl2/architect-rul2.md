Implementa la especificacion verificada del Sequencer y Block Production.

SAFETY LATCH: TLC log en zkl2/specs/units/2026-03-sequencer/1-formalization/v0-analysis/experiments/Sequencer/MC_Sequencer.log muestra PASS.

CONTEXTO:
- TLA+ spec: zkl2/specs/units/2026-03-sequencer/1-formalization/v0-analysis/specs/Sequencer/Sequencer.tla
- Scientist reference: zkl2/specs/units/2026-03-sequencer/0-input/code/
- EVM executor ya existe: zkl2/node/executor/
- Destino: zkl2/node/sequencer/
- Target: zkl2 (produccion completa)

QUE IMPLEMENTAR:

1. zkl2/node/sequencer/sequencer.go:
   - Sequencer main: StartSequencer(), ProduceBlock(), SealBlock()
   - Block lifecycle: pending -> sealed -> proved -> finalized
   - Integration con executor para ejecutar bloques

2. zkl2/node/sequencer/mempool.go:
   - Thread-safe mempool con priority queue
   - AddTransaction(), GetPending(), RemoveIncluded()
   - Gas price ordering (o FIFO para enterprise)

3. zkl2/node/sequencer/forced_inclusion.go:
   - ForcedInclusionQueue: reads forced txs from L1
   - CheckForcedInclusion(): verifica deadline
   - Forced txs tienen prioridad absoluta sobre mempool

4. zkl2/node/sequencer/block_builder.go:
   - BuildBlock(): selecciona txs de mempool + forced, ejecuta, produce block
   - GasLimit management
   - Block header construction

5. zkl2/node/sequencer/types.go

6. Tests: block production, mempool ordering, forced inclusion, adversarial

7. ADVERSARIAL-REPORT.md en zkl2/tests/adversarial/sequencer/

8. Session log: lab/3-architect/sessions/2026-03-19_sequencer.md

CALIDAD:
- Go idiomatico, goroutine-safe (sync.Mutex donde necesario)
- Context propagation
- Structured logging (slog)
- Todos los invariantes TLA+ mapeados a tests

NO hagas commits. Comienza con /implement
