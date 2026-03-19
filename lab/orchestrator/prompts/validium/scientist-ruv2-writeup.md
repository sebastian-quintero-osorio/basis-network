Genera el paper academico para el experimento state-transition-circuit.

CONTEXTO:
- Experimento en validium/research/experiments/2026-03-18_state-transition-circuit/
- Hipotesis parcialmente confirmada: batch 64 excede 60s, pero batch 8-16 son viables
- 7 benchmarks reales: d10_b4 (45K, 3.4s), d10_b8 (91K, 5.1s), d10_b16 (183K, 8s), d20_b4 (87K, 8.7s), d20_b8 (174K, 13.6s), d32_b4 (137K, 6.9s), d32_b8 (274K, 12.8s)
- Circuito: StateTransition(depth, batchSize) con Poseidon Merkle proof verification
- El paper va en validium/research/experiments/2026-03-18_state-transition-circuit/paper/

QUE HACER:
1. Lee findings.md y todos los benchmark JSONs en results/
2. Lee el circuito state_transition_verifier.circom en code/
3. Escribe paper LaTeX (main.tex + secciones + references.bib)
   - Titulo: "State Transition Circuits for Enterprise ZK Validium: Constraint Analysis and Proving Time Benchmarks"
   - Incluye tabla con los 7 benchmarks
   - Analisis de escalabilidad (constraint linearity, depth scaling)
   - Comparacion con Semaphore, Tornado Cash, Hermez
4. Compila PDF: pdflatex + bibtex + pdflatex + pdflatex
5. Session log en lab/1-scientist/sessions/

NO hagas commits. Comienza con /writeup
