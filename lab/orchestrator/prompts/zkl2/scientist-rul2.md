Investiga disenos de sequencer y produccion de bloques para un L2 zkEVM empresarial.

HIPOTESIS: Un sequencer single-operator puede producir bloques L2 cada 1-2 segundos con ordering FIFO, manteniendo un mecanismo de forced inclusion via L1 que garantiza censorship resistance con latencia maxima de 24 horas para transacciones forzadas.

CONTEXTO:
- Construimos un zkEVM L2 sobre Basis Network (Avalanche L1)
- Ya tenemos el EVM executor (RU-L1 completo en zkl2/node/executor/)
- El sequencer ordena transacciones, produce bloques L2, y los envía al pipeline de proving
- Decisiones tecnicas: TD-005 (per-enterprise chains), TD-004 (validium mode)
- Target: zkl2 (produccion completa), Fecha: 2026-03-19

TAREAS:

1. CREAR ESTRUCTURA: zkl2/research/experiments/2026-03-19_sequencer/
   hypothesis.json, state.json, journal.md, findings.md, code/, results/, memory/session.md

2. LITERATURE REVIEW:
   - zkSync Era sequencer (server, operator, mempool management)
   - Polygon CDK sequencer (forced batches, L1 interaction)
   - Scroll sequencer (block production, prover coordination)
   - Arbitrum sequencer (fair ordering, MEV protection)
   - Forced inclusion: how L1 contracts enforce censorship resistance
   - Mempool management strategies for enterprise workloads
   - Block production lifecycle: pending -> sealed -> proved -> finalized

3. CODIGO EXPERIMENTAL en Go:
   - Sequencer prototype con mempool, block builder, forced inclusion queue
   - Benchmark: block production latency, tx ordering fairness
   - Medir: blocks/s, mempool throughput, forced inclusion latency

4. SESSION LOG: lab/1-scientist/sessions/2026-03-19_sequencer.md

NO hagas commits. Comienza con /experiment
