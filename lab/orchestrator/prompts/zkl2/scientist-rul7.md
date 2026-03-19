Investiga disenos de bridge L1<->L2 para el zkEVM empresarial.

HIPOTESIS: Un bridge puede procesar deposits (L1->L2) en < 5 minutos y withdrawals (L2->L1) en < 30 minutos, con escape hatch que permite withdrawal via Merkle proof si el sequencer esta offline > 24 horas.

CONTEXTO:
- Ya tenemos BasisRollup.sol (zkl2/contracts/)
- Necesitamos BasisBridge.sol para transfers L1<->L2
- Escape hatch es critico para censorship resistance
- Target: zkl2 (produccion completa), Fecha: 2026-03-19

TAREAS:
1. CREAR ESTRUCTURA: zkl2/research/experiments/2026-03-19_bridge/
2. LITERATURE REVIEW: zkSync Era bridge, Polygon zkEVM bridge, Scroll bridge, escape hatches
3. CODIGO: Solidity prototype BasisBridge.sol + Go relayer
4. BENCHMARKS: deposit/withdrawal latency, gas costs
5. SESSION LOG: lab/1-scientist/sessions/2026-03-19_bridge.md

NO hagas commits. Comienza con /experiment
