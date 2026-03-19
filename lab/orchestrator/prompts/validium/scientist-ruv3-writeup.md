Genera el paper academico para el experimento state-commitment.

CONTEXTO:
- Experimento en validium/research/experiments/2026-03-18_state-commitment/
- Hipotesis CONFIRMADA: 285,756 gas Layout A, 32 bytes/batch
- HALLAZGO: ZK pairing verification = 72% del gas. Integrated verification es obligatoria.
- 3 layouts comparados (minimal/rich/events-only), 7 invariant tests
- El paper va en validium/research/experiments/2026-03-18_state-commitment/paper/

QUE HACER:
1. Lee findings.md, results/gas-benchmark.md, codigo Solidity de referencia
2. Escribe paper LaTeX:
   - Titulo: "L1 State Commitment for Enterprise ZK Validium: Gas-Optimal Storage Design on Avalanche Subnet-EVM"
   - 3 layouts comparados, gas breakdown (72% verification, 28% storage)
   - Comparacion con zkSync Era, Polygon zkEVM, Scroll commit patterns
3. Compila PDF
4. Session log

NO hagas commits. Comienza con /writeup
