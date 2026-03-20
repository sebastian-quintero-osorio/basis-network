Investiga un modelo hub-and-spoke para comunicacion cross-enterprise en un zkEVM L2 multi-empresa.

HIPOTESIS: Un modelo hub-and-spoke usando el L1 como hub puede verificar interacciones cross-enterprise con proofs recursivos, manteniendo aislamiento completo de datos entre empresas y habilitando transacciones inter-empresa verificables.

CONTEXTO:
- En el Validium MVP investigamos cross-enterprise basico (RU-V7)
- Tenemos proofs recursivos (RU-L10) y bridge (RU-L7)
- Cada empresa tiene su L2 chain
- Queremos que empresa A pueda verificar algo sobre empresa B sin ver sus datos
- Target: zkl2 (produccion completa), Fecha: 2026-03-19

TAREAS:
1. CREAR ESTRUCTURA: zkl2/research/experiments/2026-03-19_hub-and-spoke/
2. LITERATURE REVIEW (15+ sources):
   - Modelo cross-privacy de Rayls (JP Morgan)
   - Project EPIC (BIS Innovation Hub)
   - Mensajeria inter-chain (IBC, LayerZero, Axelar)
   - Transferencia de assets entre L2s empresariales
   - Zero-knowledge proofs para verificacion cross-chain sin revelacion
   - Hub-and-spoke vs mesh topologies para privacy
   - Atomic settlement para transacciones cross-enterprise
3. BENCHMARKS:
   - Latencia de mensaje cross-enterprise
   - Gas de verificacion cross-enterprise proof en L1
   - Privacy garantizada: que se revela vs que se oculta
   - Throughput: mensajes/segundo cross-enterprise
4. CODIGO: Go prototype for hub-and-spoke messaging with ZK verification
5. SESSION LOG

NO hagas commits. Comienza con /experiment
